defmodule Jido.Chat.WhatsApp.PairingSessionTest do
  use ExUnit.Case, async: false

  import Jido.Chat.WhatsApp.TestHelpers

  alias Jido.Chat.WhatsApp
  alias Jido.Chat.WhatsApp.Pairing.Request
  alias Jido.Chat.WhatsApp.Storage.{Mnesia, Split, Temporary}

  setup do
    start_supervised!(Mnesia)
    supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})

    host =
      start_supervised!(
        {Agent,
         fn ->
           %{credentials: %{}, fail: false, denied: false, saves: 0, starts: 0, runtime: nil}
         end}
      )

    opts = [
      owner: self(),
      supervisor: supervisor,
      attempt_id: "attempt",
      context: host,
      sink_mfa: {__MODULE__, :host_request, []},
      transport: __MODULE__,
      connect_opts: [observer: self()]
    ]

    %{opts: opts, host: host}
  end

  test "owner confirms once and retains the public receipt", %{opts: opts, host: host} do
    {:ok, %{session: session}} = begin_pairing(opts)
    assert_receive {:connection, config, _}
    {Temporary, storage_opts} = config.storage
    storage = Temporary.new(storage_opts)
    assert :ok = Temporary.put(storage, config.profile, :session, "peer", "ratchet")
    assert_authenticatable(session)
    assert {:error, :unauthorized} = command(session, :confirm, :other)

    assert {:ok, %{phase: :saved, receipt: receipt, runtime_pending: false}} =
             command(session, :confirm)

    assert {:ok, %{phase: :saved, receipt: ^receipt, runtime_pending: false}} =
             command(session, :confirm)

    assert {:ok, %{phase: :saved, receipt: ^receipt, runtime_pending: false}} =
             command(session, :retry)

    assert Agent.get(host, &{&1.saves, &1.starts}) == {1, 1}
    assert [{"creds", _}] = Agent.get(host, &Map.keys(&1.credentials))

    config = Agent.get(host, & &1.runtime.connection_options)
    {Split, stored_options} = config.storage
    state = Split.new(stored_options)
    assert {:ok, "ratchet"} = Split.get(state, config.profile, :session, "peer")
    assert {:ok, %{phase: :cancelled}} = command(session, :cancel)
  end

  test "save failure freezes safely and retries without a new pairing", %{opts: opts, host: host} do
    {:ok, %{session: session}} = begin_pairing(opts)
    assert_receive {:connection, config, _}
    assert_authenticatable(session)
    Agent.update(host, &%{&1 | fail: true})
    assert {:error, :save_failed} = command(session, :confirm)
    {Temporary, storage_opts} = config.storage
    assert {:error, :storage_frozen} = Temporary.put(Temporary.new(storage_opts), config.profile, :creds, :self, %{})
    assert {:ok, %{phase: :authenticated}} = command(session, :retry)
    Agent.update(host, &%{&1 | fail: false})
    assert {:ok, %{phase: :saved, runtime_pending: false}} = command(session, :confirm)
  end

  test "expired and abandoned sessions clean up without restart", %{opts: opts} do
    owner =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    {:ok, %{session: session}} = begin_pairing(Keyword.put(opts, :owner, owner))
    ref = Process.monitor(session)
    send(owner, :stop)
    assert_receive {:DOWN, ^ref, :process, ^session, :normal}
    assert {:error, :pairing_expired} = command(session, :status)

    {:ok, %{session: expiring}} = begin_pairing(Keyword.put(opts, :ttl_ms, 20))
    ref = Process.monitor(expiring)
    assert_receive {:DOWN, ^ref, :process, ^expiring, :normal}, 1_000
  end

  test "split storage reauthorizes RAM operations and reports a pending runtime", %{
    opts: opts,
    host: host
  } do
    {:ok, %{session: session}} = begin_pairing(opts)
    assert_receive {:connection, _, _}
    assert_authenticatable(session)
    Agent.update(host, &%{&1 | denied: true})

    assert {:ok, %{phase: :saved, runtime_pending: true}} =
             command(session, :confirm)

    assert Agent.get(host, &{&1.saves, &1.starts}) == {1, 0}
  end

  test "malformed runtime handoff cannot lose a persisted receipt", %{opts: opts, host: host} do
    opts = Keyword.put(opts, :sink_mfa, {__MODULE__, :host_request, [:malformed]})
    {:ok, %{session: session}} = begin_pairing(opts)
    assert_authenticatable(session)

    assert {:ok, %{phase: :saved, runtime_pending: true} = saved} =
             command(session, :confirm)

    assert {:ok, ^saved} = command(session, :confirm)
    assert Agent.get(host, &{&1.saves, &1.starts}) == {1, 0}
  end

  def host_request(
        :malformed,
        %Request{context: host, request: %{op: :persist} = request},
        _opts
      ) do
    {:ok, result} = persist(host, Map.delete(request, :op))
    {:ok, %{result | binding: nil}}
  end

  def host_request(:malformed, event, opts), do: host_request(event, opts)

  def host_request(%Request{context: host, request: %{op: :persist} = request}, _opts),
    do: persist(host, Map.delete(request, :op))

  def host_request(%Request{context: host, request: %{op: :start, runtime: runtime}}, _opts),
    do: start_runtime(host, runtime)

  def host_request(%Jido.Chat.WhatsApp.Storage.Request{binding: host, request: request}, _opts),
    do: document(host, request)

  def connect(config, opts) do
    {Temporary, options} = config.storage
    :ok = Temporary.put(Temporary.new(options), config.profile, :creds, :self, %{paired: true})
    send(opts[:observer], {:connection, config, self()})
    send(opts[:parent], {:amarula, :connection_update, %{connection: :open}})
    {:ok, self()}
  end

  def stop(_, _), do: :ok
  def logout(_, _), do: :ok

  def account_identity(_),
    do: {:ok, %{phone_number: "+15550001", display_name: "Account", account_jids: ["15550001@s.whatsapp.net"]}}

  def persist(host, request) do
    Agent.get_and_update(host, fn state ->
      if state.fail do
        {{:error, :failed}, state}
      else
        result = {:ok, %{receipt: %{id: 1, name: "Account"}, binding: host, runtime: :saved}}
        {result, %{state | saves: state.saves + 1, credentials: request.credentials}}
      end
    end)
  end

  def start_runtime(host, runtime) do
    Agent.update(host, &%{&1 | starts: &1.starts + 1, runtime: runtime})
  end

  def document(host, _) do
    if Agent.get(host, & &1.denied), do: {:error, :denied}, else: {:ok, []}
  end

  defp begin_pairing(opts), do: WhatsApp.authenticate(%{op: :begin}, :operator, opts)

  defp command(pid, :confirm, owner),
    do: WhatsApp.authenticate(%{op: :confirm, session: pid, account_id: "+15550001"}, owner, [])

  defp command(pid, op, owner),
    do: WhatsApp.authenticate(%{op: op, session: pid}, owner, [])

  defp command(pid, op), do: command(pid, op, :operator)

  defp assert_authenticatable(pid),
    do: eventually(fn -> match?({:ok, %{phase: :authenticated}}, command(pid, :status)) end)
end
