defmodule Jido.Chat.WhatsApp.PairingSessionTest do
  use ExUnit.Case, async: false
  import Jido.Chat.WhatsApp.TestHelpers
  alias Jido.Chat.WhatsApp.PairingSession
  alias Jido.Chat.WhatsApp.Storage.{Mnesia, Split, Temporary}

  setup do
    start_supervised!(Mnesia)
    supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})
    host = start_supervised!({Agent, fn -> %{records: %{}, fail: false, denied: false, saves: 0, starts: 0} end})

    opts = [
      supervisor: supervisor,
      attempt_id: "attempt",
      context: host,
      sink_mfa: {__MODULE__, :host_request, []},
      transport: __MODULE__,
      connect_opts: [observer: self()]
    ]

    %{opts: opts, host: host}
  end

  test "standalone host confirms once and retains receipt after callbacks exit", %{opts: opts, host: host} do
    {:ok, %{session: session}} = PairingSession.execute(%{op: :begin, owner: self()}, :operator, opts)
    assert_receive {:connection, config, _}
    {Temporary, storage_opts} = config.storage
    storage = Temporary.new(storage_opts)
    assert :ok = Temporary.put(storage, config.profile, :session, "peer", "ratchet")
    assert_confirmable(session)
    assert {:error, :unauthorized} = command(session, :confirm, :other)
    assert {:ok, %{saved: saved}} = command(session, :confirm)
    refute saved.runtime_pending
    assert {:ok, %{saved: ^saved}} = command(session, :confirm)
    assert {:ok, %{saved: ^saved}} = command(session, :retry)
    assert Agent.get(host, &{&1.saves, &1.starts}) == {1, 1}
    durable = Agent.get(host, & &1.records)
    assert durable == %{{"creds", :self} => %{paired: true}}
    state = Split.new(storage_options(host))
    assert {:ok, "ratchet"} = Split.get(state, "saved", :session, "peer")
    assert :ok = command(session, :cancel)
  end

  test "save failure freezes safely and retries without re-pairing", %{opts: opts, host: host} do
    {:ok, %{session: session}} = PairingSession.execute(%{op: :begin, owner: self()}, :operator, opts)
    assert_receive {:connection, config, _}
    assert_confirmable(session)
    Agent.update(host, &%{&1 | fail: true})
    assert {:error, :save_failed} = command(session, :confirm)
    {Temporary, storage_opts} = config.storage
    assert {:error, :storage_frozen} = Temporary.put(Temporary.new(storage_opts), config.profile, :creds, :self, %{})
    assert {:ok, %{phase: :confirm}} = command(session, :retry)
    Agent.update(host, &%{&1 | fail: false})
    assert {:ok, %{saved: %{runtime_pending: false}}} = command(session, :confirm)
  end

  test "expired and abandoned sessions clean up without restarting", %{opts: opts} do
    owner =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    {:ok, %{session: session}} = PairingSession.execute(%{op: :begin, owner: owner}, :operator, opts)
    ref = Process.monitor(session)
    send(owner, :stop)
    assert_receive {:DOWN, ^ref, :process, ^session, :normal}
    assert {:error, :pairing_expired} = command(session, :status)

    {:ok, %{session: expiring}} =
      PairingSession.execute(%{op: :begin, owner: self()}, :operator, Keyword.put(opts, :ttl_ms, 20))

    ref = Process.monitor(expiring)
    assert_receive {:DOWN, ^ref, :process, ^expiring, :normal}, 1_000
  end

  test "split storage reauthorizes RAM operations and reports post-save failure as saved", %{opts: opts, host: host} do
    {:ok, %{session: session}} = PairingSession.execute(%{op: :begin, owner: self()}, :operator, opts)
    assert_receive {:connection, _, _}
    assert_confirmable(session)
    Agent.update(host, &%{&1 | denied: true})
    assert {:ok, %{saved: %{runtime_pending: true}}} = command(session, :confirm)
    assert Agent.get(host, &{&1.saves, &1.starts}) == {1, 0}
    store = Split.new(storage_options(host))
    assert {:error, :denied} = Split.get(store, "saved", :session, "peer")
    assert {:error, :denied} = Split.put(store, "saved", :session, "peer", "value")
    assert {:error, :denied} = Split.clear(store, "saved")
  end

  test "malformed runtime handoff cannot lose an already persisted receipt", %{opts: opts, host: host} do
    opts = Keyword.put(opts, :sink_mfa, {__MODULE__, :host_request, [:malformed]})
    {:ok, %{session: session}} = PairingSession.execute(%{op: :begin, owner: self()}, :operator, opts)
    assert_confirmable(session)
    assert {:ok, %{saved: %{runtime_pending: true} = saved}} = command(session, :confirm)
    assert {:ok, %{saved: ^saved}} = command(session, :confirm)
    assert Agent.get(host, &{&1.saves, &1.starts}) == {1, 0}
  end

  def host_request(
        :malformed,
        %Jido.Chat.Authentication.Request{context: host, request: %{op: :persist} = request},
        _opts
      ),
      do: malformed_handoff(host, Map.delete(request, :op))

  def host_request(:malformed, event, opts), do: host_request(event, opts)

  def host_request(%Jido.Chat.Authentication.Request{context: host, request: %{op: :persist} = request}, _opts),
    do: persist(host, Map.delete(request, :op))

  def host_request(%Jido.Chat.Authentication.Request{context: host, request: %{op: :start, runtime: runtime}}, _opts),
    do: start_runtime(host, runtime)

  def host_request(%Jido.Chat.Storage.Request{binding: host, request: request}, _opts),
    do: document(host, request)

  def malformed_handoff(host, request) do
    {:ok, result} = persist(host, request)
    {:ok, %{result | storage: []}}
  end

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
        result = {:ok, %{receipt: %{id: 1, name: "Account"}, storage: storage_options(host), runtime: :saved}}
        {result, %{state | saves: state.saves + 1, records: request.records}}
      end
    end)
  end

  def start_runtime(host, _), do: Agent.update(host, &%{&1 | starts: &1.starts + 1})

  def document(host, _) do
    if Agent.get(host, & &1.denied), do: {:error, :denied}, else: {:ok, []}
  end

  defp storage_options(host),
    do: [scope: host, profile: "saved", context: host, sink_mfa: {__MODULE__, :host_request, []}]

  defp command(pid, op, owner \\ :operator), do: PairingSession.execute(%{op: op, session: pid}, owner, [])

  defp assert_confirmable(pid),
    do: eventually(fn -> match?({:ok, %{phase: :confirm}}, command(pid, :status)) end)
end
