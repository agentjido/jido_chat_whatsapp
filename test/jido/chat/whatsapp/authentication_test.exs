defmodule Jido.Chat.WhatsApp.AuthenticationTest do
  use ExUnit.Case, async: false
  alias Jido.Chat.Adapter, as: Core
  alias Jido.Chat.WhatsApp.{Adapter, ConnectionWorker}
  alias Jido.Chat.WhatsApp.Storage.Mnesia

  setup do
    start_supervised!(Mnesia)
    supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})

    host =
      start_supervised!(
        {Agent,
         fn ->
           %{
             requests: [],
             starts: 0,
             records: %{},
             mode: :ok,
             identity: %{account_jids: ["15550001@s.whatsapp.net"], display_name: "Account", secret: "private"}
           }
         end}
      )

    context = %{host: host, supervisor: supervisor, observer: self()}

    opts = [
      supervisor: supervisor,
      owner: self(),
      attempt_id: "attempt",
      context: context,
      sink_mfa: {__MODULE__, :host_request, [context]},
      transport: __MODULE__,
      connect_opts: [host: host, observer: self()]
    ]

    %{opts: opts, host: host, context: context}
  end

  test "shared dispatch covers QR replacement, recovery, explicit save and ordinary startup", c do
    assert Core.capabilities(Adapter).authenticate == :native
    assert :ok = Core.validate_capabilities(Adapter)
    session = begin(c.opts)
    assert_receive {:connection, config, _}
    event(session, :connection_update, %{qr: "first"})
    assert {:ok, %{phase: :challenge, challenge: %{type: :qr, value: "first"}}} = command(session, :status)
    event(session, :connection_update, %{qr: "replacement"})
    assert {:ok, %{challenge: %{value: "replacement"}}} = command(session, :status)
    worker = :sys.get_state(session).worker
    worker_state = :sys.get_state(worker)
    send(worker, {:qr_expired, worker_state.attempt_id, worker_state.qr_token})
    assert {:ok, %{phase: :failed} = expired} = command(session, :status)
    refute Map.has_key?(expired, :challenge)
    event(session, :connection_update, %{qr: "after-expiry"})
    assert {:ok, %{phase: :challenge}} = command(session, :status)
    event(session, :pairing_success, %{})
    event(session, :error, %{secret: "private"})
    assert {:ok, %{phase: :pending}} = command(session, :retry)
    authenticate(session)
    assert {:ok, %{phase: :authenticated, account: account}} = command(session, :retry)
    assert account == %{external_id: "+15550001", display_name: "Account"}
    assert Agent.get(c.host, & &1.requests) == []
    refute_received {:connection, _, _}

    message = %Amarula.Msg{
      id: "ordinary",
      channel: Amarula.Address.pn("123"),
      from: Amarula.Address.pn("456"),
      type: :text,
      content: "hello",
      raw: %Amarula.Protocol.Proto.Message{}
    }

    event(session, :messages_upsert, %{messages: [message]})
    refute_received {:message, _}
    {storage_module, storage_opts} = config.storage
    assert :ok = storage_module.put(storage_module.new(storage_opts), config.profile, :session, "peer", "ratchet")

    assert {:ok, %{phase: :saved, receipt: %{id: 1, name: "Account"}, runtime_pending: false} = saved} =
             confirm(session)

    assert {:ok, ^saved} = confirm(session)
    assert {:ok, ^saved} = command(session, :status)
    assert {:ok, ^saved} = command(session, :retry)
    assert_receive {:activated, ["ratchet", %{paired: true}]}
    assert_receive {:connection, _, saved_relay}
    send(saved_relay, {:amarula, :messages_upsert, %{messages: [message]}})
    assert_receive {:message, %{id: "ordinary", text: "hello"}}
    assert Agent.get(c.host, & &1.starts) == 1
    [request] = Agent.get(c.host, & &1.requests)
    assert request.attempt_id == "attempt"
    assert request.account == account

    assert Enum.all?(request.credentials, fn {{ns, key}, value} ->
             is_binary(ns) and is_binary(key) and is_binary(value)
           end)

    refute inspect(saved) =~ "private"
    assert {:ok, %{phase: :cancelled}} = command(session, :cancel)
  end

  test "wrong/nil owners and changed displayed identity cannot confirm", c do
    session = begin(c.opts)
    authenticate(session)

    for op <- [:status, :retry, :confirm, :cancel] do
      assert {:error, :unauthorized} = command(session, op, :other)
      assert {:error, :invalid_request} = command(session, op, nil)
    end

    Agent.update(c.host, &put_in(&1.identity.account_jids, ["15550002@s.whatsapp.net"]))
    worker = :sys.get_state(session).worker
    :ok = ConnectionWorker.refresh_identity(worker)
    await_phase(session, :authenticated, "+15550002")
    assert {:error, :identity_changed} = confirm(session)
    assert Agent.get(c.host, & &1.requests) == []
  end

  test "uncertain persistence retries identical encoded records and attempt without reconnect", c do
    session = begin(c.opts)
    authenticate(session)
    Agent.update(c.host, &%{&1 | mode: :uncertain})
    assert {:error, :save_failed} = confirm(session)
    assert {:ok, %{phase: :authenticated}} = command(session, :retry)
    Agent.update(c.host, &%{&1 | mode: :ok})
    assert {:ok, %{phase: :saved}} = confirm(session)
    [retry, first] = Agent.get(c.host, & &1.requests)
    assert retry == first
    assert Agent.get(c.host, & &1.starts) == 1
  end

  test "successful persistence survives invalid binding, rejected seeding and activation failure", c do
    for mode <- [:invalid_binding, :denied, :activation_failed, :activation_exception] do
      Agent.update(c.host, &%{&1 | mode: mode})
      session = begin(c.opts)
      authenticate(session)
      assert {:ok, %{phase: :saved, runtime_pending: true} = saved} = confirm(session)
      assert saved.receipt == %{id: 1, name: "Account"}
      assert {:ok, ^saved} = confirm(session)
      assert {:ok, %{phase: :cancelled}} = command(session, :cancel)
    end
  end

  test "a timed-out commit retries on the same live handle with identical credentials", c do
    session = begin(c.opts)
    authenticate(session)
    Agent.update(c.host, &%{&1 | mode: :timeout})
    assert {:error, :save_failed} = confirm(session)
    assert Process.alive?(session)
    Agent.update(c.host, &%{&1 | mode: :ok})
    assert {:ok, %{phase: :authenticated}} = command(session, :retry)
    assert {:ok, %{phase: :saved, runtime_pending: false}} = confirm(session)
    [retry, first] = Agent.get(c.host, & &1.requests)
    assert retry == first
  end

  test "callback exceptions and timeouts are sanitized and expired handles fail", c do
    Agent.update(c.host, &%{&1 | mode: :exception})
    session = begin(c.opts)
    authenticate(session)
    assert {:error, :save_failed} = confirm(session)
    assert {:ok, %{phase: :cancelled}} = command(session, :cancel)
    assert {:error, :pairing_expired} = command(session, :status)
    Agent.update(c.host, &%{&1 | mode: :timeout})
    session = begin(Keyword.put(c.opts, :ttl_ms, 1_000))
    authenticate(session)
    monitor = Process.monitor(session)
    assert {:error, :save_failed} = confirm(session)
    assert_receive {:DOWN, ^monitor, :process, ^session, :normal}, 1_000
  end

  test "owner death cleans up provisional state and bad options stay sanitized", c do
    owner =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    session = begin(Keyword.put(c.opts, :owner, owner))
    storage = :sys.get_state(session).storage
    ref = Process.monitor(session)
    send(owner, :stop)
    assert_receive {:DOWN, ^ref, :process, ^session, :normal}
    refute Process.alive?(storage)
    assert {:error, :pairing_unavailable} = Core.authenticate(Adapter, %{op: :begin}, :owner, [])
  end

  # External transport edge. It uses only the configured storage callback protocol.
  def connect(config, opts) do
    {mod, store_opts} = config.storage
    store = mod.new(store_opts)

    if String.starts_with?(config.profile, "pairing_") do
      :ok = mod.put(store, config.profile, :creds, :self, %{paired: true})
      :ok = mod.put(store, config.profile, :session, "peer", "ratchet")
    else
      values = for {ns, key} <- [{:session, "peer"}, {:creds, :self}], do: mod.get(store, config.profile, ns, key)
      send(opts[:observer], {:activated, Enum.map(values, fn {:ok, value} -> value end)})
    end

    send(opts[:observer], {:connection, config, self()})
    {:ok, opts[:host]}
  end

  def stop(_, _), do: :ok
  def logout(_, _), do: :ok
  def recovery_status(_), do: :reconnecting
  def account_identity(host), do: {:ok, Agent.get(host, & &1.identity)}

  def host_request(
        _configured,
        %Jido.Chat.WhatsApp.Pairing.Request{context: context, request: %{op: :persist} = request},
        _opts
      ),
      do: persist(context, Map.delete(request, :op))

  def host_request(
        _configured,
        %Jido.Chat.WhatsApp.Pairing.Request{context: context, request: %{op: :start, runtime: runtime}},
        _opts
      ),
      do: activate(context, runtime)

  def host_request(context, %Jido.Chat.WhatsApp.Storage.Request{binding: binding, request: request}, _opts),
    do: document(context, binding, request)

  # Host callbacks never call PairingSession or Split.
  def persist(%{host: host}, request) do
    mode =
      Agent.get_and_update(host, fn state ->
        {state.mode, %{state | requests: [request | state.requests], records: request.credentials}}
      end)

    case mode do
      :exception ->
        raise "private credentials"

      :timeout ->
        Process.sleep(15_000)
        {:error, :private}

      :uncertain ->
        {:error, :response_lost_after_commit}

      _ ->
        {:ok,
         %{
           receipt: %{id: 1, name: "Account", secret: "private"},
           binding: if(mode == :invalid_binding, do: nil, else: %{id: host}),
           runtime: :host_config
         }}
    end
  end

  def document(%{host: host}, %{id: host}, request) do
    if Agent.get(host, & &1.mode) == :denied do
      {:error, :denied}
    else
      case request do
        %{namespace: "__binding_check__"} ->
          {:ok, []}

        %{op: :get, namespace: ns, key: key} ->
          case Agent.get(host, &Map.fetch(&1.records, {ns, key})) do
            {:ok, value} -> {:ok, value}
            :error -> :error
          end

        _ ->
          :ok
      end
    end
  end

  def activate(context, %{connection_options: config, binding: binding, runtime: :host_config}) do
    Agent.update(context.host, &%{&1 | starts: &1.starts + 1})
    assert config == Adapter.connection_options(binding, sink_mfa: {__MODULE__, :host_request, [context]})

    case Agent.get(context.host, & &1.mode) do
      :activation_failed ->
        {:error, :private}

      :activation_exception ->
        raise "private"

      _ ->
        {:ok, [spec]} =
          Adapter.listener_child_specs("saved",
            ingress:
              Map.merge(config, %{
                mode: :linked_device,
                transport: __MODULE__,
                connect_opts: [host: context.host, observer: context.observer]
              }),
            sink_mfa: {__MODULE__, :sink, [context.observer]}
          )

        case DynamicSupervisor.start_child(context.supervisor, spec) do
          {:ok, _} -> :ok
          error -> error
        end
    end
  end

  def sink(observer, payload, _opts), do: send(observer, {:message, payload})

  defp begin(opts) do
    assert {:ok, %{phase: :pending, session: session}} = Core.authenticate(Adapter, %{op: :begin}, :owner, opts)
    session
  end

  defp command(session, op, owner \\ :owner),
    do: Core.authenticate(Adapter, %{op: op, session: session, account_id: "+15550001"}, owner)

  defp confirm(session), do: command(session, :confirm)

  defp event(session, event, payload) do
    worker = :sys.get_state(session).worker
    attempt = ConnectionWorker.status(worker).attempt_id
    send(worker, {:transport_event, attempt, event, payload})
    ConnectionWorker.status(worker)
  end

  defp authenticate(session) do
    event(session, :connection_update, %{connection: :open})
    await_phase(session, :authenticated, "+15550001")
  end

  defp await_phase(session, phase, id, remaining \\ 100)
  defp await_phase(_, _, _, 0), do: flunk("authentication did not settle")

  defp await_phase(session, phase, id, remaining) do
    case command(session, :status) do
      {:ok, %{phase: ^phase, account: %{external_id: ^id}}} ->
        :ok

      _ ->
        Process.sleep(5)
        await_phase(session, phase, id, remaining - 1)
    end
  end
end
