defmodule Jido.Chat.WhatsApp.IdentityLifecycleTest do
  use ExUnit.Case, async: true

  alias Jido.Chat.WhatsApp.{Adapter, ConnectionWorker}

  defmodule Transport do
    def connect(config, opts) do
      send(config.test_pid, {:connected, config.profile, opts[:parent], config})
      {:ok, config.session}
    end

    def stop(_, _), do: :ok
    def logout(_, _), do: :ok
    def account_jids(session), do: {:ok, Agent.get(session, & &1.identity.account_jids)}

    def account_identity(session) do
      data = Agent.get(session, & &1)
      send(data.test_pid, {:identity_called, session, self()})

      case Map.get(data, :mode) do
        :blocked ->
          receive do: ({:reply, result} -> result)

        :error ->
          {:error, %{secret: "secret-sentinel"}}

        :exit ->
          exit({:private, "secret-sentinel"})

        :raise ->
          raise "secret-sentinel"

        :kill ->
          Process.exit(self(), :kill)

        :reentrant ->
          send(data.test_pid, {:reentrant_status, ConnectionWorker.status(data.worker)})
          {:ok, data.identity}

        _ ->
          {:ok, data.identity}
      end
    end
  end

  defmodule LegacyTransport do
    defdelegate connect(config, opts), to: Transport
    defdelegate stop(conn, opts), to: Transport
  end

  defmodule Sink do
    def emit(test_pid, %Jido.Chat.EventEnvelope{event_type: :action, payload: %{metadata: payload}}, _opts),
      do: send(test_pid, {:lifecycle, payload})

    def emit(test_pid, payload, opts), do: chat(test_pid, payload, opts)
    def chat(test_pid, payload, _opts), do: send(test_pid, {:chat, payload})
  end

  defmodule ReentrantSink do
    def emit(test_pid, session, %Jido.Chat.EventEnvelope{event_type: :action, payload: %{metadata: payload}}, _opts) do
      worker = Agent.get(session, &Map.get(&1, :worker))
      if worker, do: send(test_pid, {:sink_snapshot, ConnectionWorker.status(worker)})
      send(test_pid, {:lifecycle, payload})
    end
  end

  defp identity(number \\ "15551234567", name \\ "Alice") do
    %{
      account_jids: [number <> ":7@s.whatsapp.net", number <> ":2@lid"],
      display_name: name,
      creds: %{key: "secret-sentinel"},
      qr: "secret-sentinel",
      phone_number: "untrusted"
    }
  end

  defp worker(data \\ %{}, opts \\ []) do
    test_pid = self()

    session =
      start_supervised!(%{
        id: make_ref(),
        start:
          {Agent, :start_link,
           [
             fn ->
               Map.merge(%{identity: identity(), test_pid: test_pid}, data)
             end
           ]}
      })

    profile = "identity_#{System.unique_integer([:positive])}"
    sink = if opts[:reentrant_sink], do: {ReentrantSink, :emit, [self(), session]}, else: {Sink, :emit, [self()]}

    {:ok, [spec]} =
      Adapter.listener_child_specs(profile,
        sink_mfa: sink,
        identity_timeout_ms: Keyword.get(opts, :identity_timeout_ms, 2_500),
        ingress: %{
          mode: :linked_device,
          profile: profile,
          transport: Keyword.get(opts, :transport, Transport),
          sync_history: false,
          sync_full_history: false,
          config: %{session: session, test_pid: self()}
        }
      )

    worker = start_supervised!(spec)
    Agent.update(session, &Map.put(&1, :worker, worker))
    assert_receive {:connected, ^profile, parent, config}
    refute config.sync_history
    refute config.sync_full_history
    {worker, parent, session, profile}
  end

  defp open(parent, profile) do
    send(parent, {:amarula, :connection_update, %{connection: :open}})
    assert_receive {:lifecycle, %{event: :connection_update, status: :connected, profile: ^profile} = event}
    event
  end

  defp available(profile) do
    assert_receive {:lifecycle, %{event: :identity_updated, profile: ^profile, identity_status: :available} = event},
                   1_000

    event
  end

  test "open publishes sanitized identity and status caches it without new callbacks" do
    {worker, parent, session, profile} = worker()
    assert %{identity: nil, identity_error: :not_connected} = ConnectionWorker.status(worker)
    assert {:error, :not_connected} = ConnectionWorker.refresh_identity(worker)
    assert %{identity_status: :pending, identity: nil} = open(parent, profile)
    event = available(profile)

    assert event.identity == %{
             phone_number: "+15551234567",
             display_name: "Alice",
             account_jids: ["15551234567@s.whatsapp.net", "15551234567@lid"]
           }

    assert event.identity_error == nil
    refute inspect(event) =~ "secret-sentinel"
    assert_receive {:identity_called, ^session, _}
    assert ConnectionWorker.status(worker).identity == event.identity
    refute_receive {:identity_called, _, _}
    refute_receive {:chat, _}
  end

  test "name arriving later can be refreshed with both history options disabled" do
    {worker, parent, session, profile} = worker(%{identity: identity("123", "~")})
    open(parent, profile)
    assert available(profile).identity.display_name == nil
    Agent.update(session, &Map.put(&1, :identity, identity("123", " New name ")))
    assert :ok = ConnectionWorker.refresh_identity(worker)
    assert_receive {:lifecycle, %{event: :identity_pending, identity: nil, status: :connected}}
    assert available(profile).identity.display_name == "New name"
    assert ConnectionWorker.status(worker).identity.display_name == "New name"
  end

  test "legacy transports remain connected with explicit unsupported identity" do
    {worker, parent, _, profile} = worker(%{}, transport: LegacyTransport)
    assert %{identity_status: :unavailable, identity_error: :unsupported, identity: nil} = open(parent, profile)
    assert ConnectionWorker.status(worker).status == :connected
    assert :ok = ConnectionWorker.refresh_identity(worker)
  end

  test "an unavailable identity can become available on explicit refresh" do
    {worker, parent, session, profile} = worker(%{identity: %{account_jids: []}})
    open(parent, profile)
    assert_receive {:lifecycle, %{event: :identity_updated, profile: ^profile, identity_error: :unavailable}}
    Agent.update(session, &Map.put(&1, :identity, %{account_jids: ["opaque:7@lid"]}))
    assert :ok = ConnectionWorker.refresh_identity(worker)
    assert available(profile).identity == %{phone_number: nil, display_name: nil, account_jids: ["opaque@lid"]}
  end

  test "old results cannot replace a new lookup in the same socket attempt" do
    {worker, parent, session, profile} = worker(%{mode: :blocked})
    open(parent, profile)
    old = :sys.get_state(worker)
    send(parent, {:amarula, :connection_update, %{connection: :closed}})
    assert_receive {:lifecycle, %{profile: ^profile, status: :disconnected}}
    open(parent, profile)
    current = :sys.get_state(worker)
    assert current.attempt_id == old.attempt_id
    send(worker, {:identity_result, old.attempt_id, old.identity_request.token, {:ok, identity("999")}})
    send(worker, {:identity_timeout, old.identity_request.token})
    assert ConnectionWorker.status(worker).identity_status == :pending
    send(current.identity_request.pid, {:reply, {:ok, identity("456")}})
    assert available(profile).identity.phone_number == "+456"
    assert Process.alive?(session)
  end

  test "worker shutdown releases pending lookup and lifecycle dispatcher" do
    {worker, parent, _, profile} = worker(%{mode: :blocked})
    open(parent, profile)
    state = :sys.get_state(worker)
    query = state.identity_request.pid
    dispatcher = state.lifecycle_dispatcher
    query_monitor = Process.monitor(query)
    dispatcher_monitor = Process.monitor(dispatcher)
    GenServer.stop(worker)
    assert_receive {:DOWN, ^query_monitor, :process, ^query, _}
    assert_receive {:DOWN, ^dispatcher_monitor, :process, ^dispatcher, _}
  end

  test "missing identity and callback failures never fail a healthy connection or expose raw errors" do
    for {mode, id, error} <- [
          {nil, %{account_jids: []}, :unavailable},
          {:error, identity(), :failed},
          {:exit, identity(), :failed},
          {:raise, identity(), :failed},
          {:kill, identity(), :failed}
        ] do
      {worker, parent, _, profile} = worker(%{mode: mode, identity: id})
      open(parent, profile)
      assert_receive {:lifecycle, %{event: :identity_updated, profile: ^profile, identity_error: ^error} = event}, 1_000
      assert event.identity == nil
      assert event.status == :connected
      assert ConnectionWorker.status(worker).identity_status == :unavailable
      refute inspect(event) =~ "secret-sentinel"
    end
  end

  test "slow lookup is bounded, coalesced and does not block status or lifecycle" do
    {worker, parent, session, profile} = worker(%{mode: :blocked}, identity_timeout_ms: 100)
    open(parent, profile)
    assert_receive {:identity_called, ^session, query}
    monitor = Process.monitor(query)
    assert ConnectionWorker.status(worker).identity_status == :pending
    assert :ok = ConnectionWorker.refresh_identity(worker)
    assert_receive {:lifecycle, %{event: :identity_updated, identity_error: :timeout, status: :connected}}, 1_000
    assert_receive {:DOWN, ^monitor, :process, ^query, _}
    refute_receive {:identity_called, ^session, _}
    assert ConnectionWorker.status(worker).identity == nil
  end

  test "identity callback and lifecycle sink may query worker status without deadlocking" do
    {_worker, parent, _, profile} = worker(%{mode: :reentrant}, reentrant_sink: true)
    open(parent, profile)
    assert_receive {:reentrant_status, %{status: :connected, identity_status: :pending}}
    assert_receive {:sink_snapshot, %{status: :connected}}
    assert available(profile).identity.display_name == "Alice"
  end

  test "late results and timers cannot cross reconnects or profiles" do
    {worker, parent, session, profile} = worker(%{mode: :blocked})
    open(parent, profile)
    assert_receive {:identity_called, ^session, old_query}
    old = :sys.get_state(worker)
    {other, other_parent, _, other_profile} = worker(%{identity: identity("999", "Other")})
    open(other_parent, other_profile)
    other_identity = available(other_profile).identity

    Agent.update(session, &Map.merge(&1, %{mode: nil, identity: identity("456", "Switched")}))
    assert :ok = ConnectionWorker.reconnect(worker)
    assert_receive {:connected, ^profile, new_parent, _}
    assert %{identity: nil, status: :connecting} = ConnectionWorker.status(worker)
    refute Process.alive?(old_query)
    open(new_parent, profile)
    current = available(profile)
    refute current.attempt_id == old.attempt_id
    stale = {:identity_result, old.attempt_id, old.identity_request.token, {:ok, other_identity}}
    send(worker, stale)
    send(other, stale)
    send(worker, {:identity_timeout, old.identity_request.token})
    assert ConnectionWorker.status(worker).identity.phone_number == "+456"
    assert ConnectionWorker.status(other).identity == other_identity
  end

  test "pairing, disconnection, failure and logout clear identity and invalidate pending refresh" do
    for transition <- [:qr, :closed, :error, :logout] do
      {worker, parent, session, profile} = worker()
      open(parent, profile)
      available(profile)
      Agent.update(session, &Map.put(&1, :mode, :blocked))
      ConnectionWorker.refresh_identity(worker)
      assert_receive {:lifecycle, %{event: :identity_pending, profile: ^profile}}
      state = :sys.get_state(worker)

      {status, event} =
        case transition do
          :qr ->
            send(parent, {:amarula, :connection_update, %{qr: "test-only"}})
            {:pairing, :qr_available}

          :closed ->
            send(parent, {:amarula, :connection_update, %{connection: :closed}})
            {:disconnected, :connection_update}

          :error ->
            send(parent, {:amarula, :error, "secret-sentinel"})
            {:failed, :error}

          :logout ->
            assert :ok = ConnectionWorker.logout(worker)
            {:logged_out, :logged_out}
        end

      assert_receive {:lifecycle, %{event: ^event, status: ^status, profile: ^profile, identity: nil}}
      send(worker, {:identity_result, state.attempt_id, state.identity_request.token, {:ok, %{phone_number: "bad"}}})

      assert %{identity: nil, identity_status: :unavailable, identity_error: :not_connected} =
               ConnectionWorker.status(worker)
    end
  end

  test "inbound sender metadata never supplies authenticated identity and self mentions still work" do
    {worker, parent, _, profile} = worker(%{identity: identity("123", nil)})
    open(parent, profile)
    available(profile)

    msg = %Amarula.Msg{
      id: "self",
      channel: Amarula.Address.group("group"),
      from_me: true,
      from: Amarula.Address.pn("123"),
      mentions: [Amarula.Address.lid("123")],
      type: :text,
      content: "hello",
      pushname: "Sender name",
      raw: %Amarula.Protocol.Proto.Message{}
    }

    send(parent, {:amarula, :messages_upsert, %{messages: [msg]}})
    assert_receive {:chat, payload}
    assert {:ok, incoming} = Adapter.transform_incoming(payload)
    assert incoming.author.is_me
    assert incoming.was_mentioned
    assert ConnectionWorker.status(worker).identity.display_name == nil
  end
end
