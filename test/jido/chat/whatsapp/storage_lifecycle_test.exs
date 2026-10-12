defmodule Jido.Chat.WhatsApp.StorageLifecycleTest do
  use ExUnit.Case, async: false
  alias Jido.Chat.WhatsApp.Transport.{AmarulaClient, GuardedStorage}

  defmodule Store do
    def new(opts), do: Keyword.fetch!(opts, :table)

    def get(table, profile, namespace, key) do
      if :ets.member(table, :fail_second_read) and :ets.update_counter(table, :reads, 1, {:reads, 0}) > 1,
        do: raise("private read failure")

      case :ets.lookup(table, {profile, namespace, key}) do
        [{_, value}] -> value
        [] -> :error
      end
    end

    def put(table, profile, namespace, key, value) do
      if :ets.member(table, :fail_write) do
        {:error, "private details"}
      else
        :ets.insert(table, {{profile, namespace, key}, {:ok, value}})
        :ok
      end
    end

    def delete(table, profile, namespace, key) do
      :ets.delete(table, {profile, namespace, key})
      :ok
    end

    def clear(table, profile) do
      if :ets.member(table, :fail_clear), do: throw(:failure)
      :ets.match_delete(table, {{profile, :_, :_}, :_})
      :ok
    end

    def list_keys(_, _, _), do: {:ok, []}
    def list_profiles(_), do: {:ok, []}
  end

  setup do
    start_supervised!(Amarula.Supervisor)
    table = :ets.new(:storage, [:public, :set])
    profile = "storage_#{System.unique_integer([:positive])}"
    config = %{profile: profile, storage: {Store, table: table}, offline: true, connection_state: :connected}
    %{table: table, profile: profile, config: config}
  end

  test "fresh runtime restores isolated custom storage and stop preserves it", %{
    config: config,
    table: table,
    profile: profile
  } do
    creds =
      Amarula.Protocol.Auth.AuthUtils.init_auth_creds() |> Map.put(:me, %{id: "123@s.whatsapp.net", lid: "456@lid"})

    :ok = Store.put(table, profile, :creds, :self, creds)
    assert {:ok, conn} = AmarulaClient.connect(config, [])
    assert {:ok, ["123@s.whatsapp.net", "456@lid"]} = AmarulaClient.account_jids(conn)
    assert :ok = AmarulaClient.stop(conn, [])
    assert {:ok, ^creds} = Store.get(table, profile, :creds, :self)
    assert {:ok, restored} = AmarulaClient.connect(config, [])
    assert {:ok, ["123@s.whatsapp.net", "456@lid"]} = AmarulaClient.account_jids(restored)
    assert {:ok, other} = AmarulaClient.connect(%{config | profile: profile <> "_other"}, [])
    assert {:ok, []} = AmarulaClient.account_jids(other)
    assert :ok = AmarulaClient.stop(other, [])
  end

  test "stale connection cleanup cannot stop a newer owner of the same profile", %{config: config} do
    assert {:ok, old} = AmarulaClient.connect(config, [])
    assert :ok = AmarulaClient.stop(old, [])
    assert {:ok, current} = AmarulaClient.connect(config, [])
    assert :ok = AmarulaClient.stop(old, [])
    assert Process.alive?(GenServer.whereis(current))
  end

  test "cleanup removes the whole owned instance even while connection child is absent", %{config: config} do
    assert {:ok, {:via, Registry, {_, {instance, :connection}}} = conn} = AmarulaClient.connect(config, [])
    supervisor = Amarula.Protocol.Socket.ConnectionSupervisor.supervisor_name(instance)
    pid = GenServer.whereis(supervisor)
    assert :ok = Supervisor.terminate_child(supervisor, Amarula.Connection)
    assert GenServer.whereis(conn) == nil
    assert :ok = AmarulaClient.stop(conn, [])
    refute Process.alive?(pid)
  end

  test "prebuilt custom storage scopes retain their initialized state", %{config: config, table: table} do
    scope = %Amarula.Storage.Scope{adapter: Store, state: table}
    assert {:ok, conn} = AmarulaClient.connect(%{config | storage: scope}, [])
    actual = Amarula.Connection.get_conn(conn).storage
    assert actual.adapter == GuardedStorage
    assert actual.state.state == table
    assert :ok = AmarulaClient.stop(conn, [])
  end

  @tag capture_log: true
  test "rapid reconnect tolerates asynchronous registry removal without adopting another owner", %{config: config} do
    for _ <- 1..30 do
      assert {:ok, conn} = AmarulaClient.connect(config, [])
      assert :ok = AmarulaClient.stop(conn, [])
    end
  end

  test "duplicate connect never steals or stops owner", %{config: config, profile: profile} do
    assert {:ok, conn} = AmarulaClient.connect(config, [])
    pid = GenServer.whereis(conn)
    assert {:error, {:already_running, ^pid}} = AmarulaClient.connect(config, [])
    assert Amarula.whereis(profile) == pid
  end

  test "read failure and corrupt credentials fail before creating a connection", %{
    config: config,
    table: table,
    profile: profile
  } do
    for result <- [{:error, "secret"}, {:ok, "corrupt"}] do
      :ets.insert(table, {{profile, :creds, :self}, result})
      assert {:error, :connection_failed} = AmarulaClient.connect(config, [])
      assert Amarula.whereis(profile) == nil
    end
  end

  test "write failure is sticky and visible through transport health", %{config: config, table: table} do
    assert {:ok, conn} = AmarulaClient.connect(config, [])
    scope = Amarula.Connection.get_conn(conn).storage
    :ets.insert(table, {:fail_write, true})
    assert {:error, :storage_failed} = Amarula.Storage.put(scope, config.profile, :creds, :self, %{})
    assert {:error, :storage_failed} = AmarulaClient.health(conn)
    :ets.delete(table, :fail_write)
    assert :ok = Amarula.Storage.put(scope, config.profile, :session, "key", %{})
    refute GuardedStorage.healthy?(scope.state)
  end

  @tag capture_log: true
  test "partial protocol startup failure leaves no registered connection", %{config: config, table: table} do
    :ets.insert(table, {:fail_second_read, true})
    assert {:error, _} = AmarulaClient.connect(config, [])
    assert Amarula.whereis(config.profile) == nil
    assert DynamicSupervisor.count_children(Amarula.Supervisor.connections_supervisor()).active == 0
  end

  test "explicit logout deletes only the selected profile", %{config: config, table: table} do
    assert {:ok, conn} = AmarulaClient.connect(config, [])
    :ok = Store.put(table, config.profile, :session, "key", "session")
    :ok = Store.put(table, "other", :session, "key", "session")
    assert :ok = AmarulaClient.logout(conn, [])
    assert :error = Store.get(table, config.profile, :session, "key")
    assert {:ok, "session"} = Store.get(table, "other", :session, "key")
    assert Amarula.whereis(config.profile) == nil
  end

  @tag capture_log: true
  test "protocol process restart retains stable transport handle", %{config: config} do
    config = Map.merge(config, %{sync_history: false, sync_full_history: false})
    assert {:ok, conn} = AmarulaClient.connect(config, [])
    old = GenServer.whereis(conn)
    ref = Process.monitor(old)
    Process.exit(old, :kill)
    assert_receive {:DOWN, ^ref, :process, ^old, :killed}
    replacement = await_replacement(conn, old, 100)
    assert is_pid(replacement)
    assert {:ok, []} = AmarulaClient.account_jids(conn)
    actual = Amarula.Connection.get_conn(conn).config
    refute actual.sync_history
    refute actual.sync_full_history
    assert :ok = AmarulaClient.stop(conn, [])
    refute Process.alive?(replacement)
  end

  defmodule Sink do
    def emit(pid, event, _opts), do: send(pid, {:event, event})
  end

  test "worker cannot announce pairing success after persistence failure", %{config: config, table: table} do
    alias Jido.Chat.WhatsApp.ConnectionWorker

    worker =
      start_supervised!(
        {ConnectionWorker,
         bridge_id: "bridge",
         config: config,
         sink_mfa: {Sink, :emit, [self()]},
         lifecycle_sink_mfa: {Sink, :emit, [self()]}}
      )

    state = :sys.get_state(worker)
    scope = Amarula.Connection.get_conn(state.conn).storage
    :ets.insert(table, {:fail_write, true})
    assert {:error, :storage_failed} = Amarula.Storage.put(scope, config.profile, :creds, :self, %{})
    send(state.relay, {:amarula, :pairing_success, %{}})
    send(state.relay, {:amarula, :connection_update, %{connection: :open}})
    assert_receive {:event, %{status: :failed}}
    refute_receive {:event, %{status: :connected}}
    assert ConnectionWorker.status(worker).qr == nil
    assert Amarula.whereis(config.profile) == nil
  end

  test "reconnect rotates attempt, retains config, and stop releases ownership", %{config: config} do
    alias Jido.Chat.WhatsApp.ConnectionWorker

    worker =
      start_supervised!(
        {ConnectionWorker,
         bridge_id: "bridge",
         config: config,
         sink_mfa: {Sink, :emit, [self()]},
         lifecycle_sink_mfa: {Sink, :emit, [self()]}}
      )

    old = :sys.get_state(worker)
    assert :ok = ConnectionWorker.reconnect(worker)
    next = :sys.get_state(worker)
    assert next.config == old.config
    refute next.attempt_id == old.attempt_id
    send(worker, {:transport_event, old.attempt_id, :connection_update, %{connection: :open}})
    assert ConnectionWorker.status(worker).status == :connecting
    :ok = stop_supervised(ConnectionWorker)
    assert Amarula.whereis(config.profile) == nil
  end

  @tag capture_log: true
  test "worker logout failure is visible and success clears only its profile", %{config: config, table: table} do
    alias Jido.Chat.WhatsApp.ConnectionWorker

    worker =
      start_supervised!(
        {ConnectionWorker,
         bridge_id: "logout",
         config: config,
         sink_mfa: {Sink, :emit, [self()]},
         lifecycle_sink_mfa: {Sink, :emit, [self()]}}
      )

    :ets.insert(table, {:fail_clear, true})
    assert {:error, :logout_failed} = ConnectionWorker.logout(worker)
    :ets.delete(table, :fail_clear)
    # Failure is sticky; explicitly reconnect after correcting the backend.
    assert :ok = ConnectionWorker.reconnect(worker)
    assert :ok = ConnectionWorker.logout(worker)
    assert ConnectionWorker.status(worker).status == :logged_out
    assert Amarula.whereis(config.profile) == nil
  end

  test "invalid profile and stopped handle fail safely" do
    assert {:error, :missing_profile} = AmarulaClient.connect(%{}, [])

    for profile <- ["", "..", "../other", "a/b", "a\\b"] do
      assert {:error, :invalid_profile} = AmarulaClient.connect(%{profile: profile}, [])
    end

    pid = spawn(fn -> :ok end)
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}
    assert {:error, :identity_unavailable} = AmarulaClient.account_jids(pid)
    assert {:error, :connection_unavailable} = AmarulaClient.health(pid)
  end

  defp await_replacement(conn, old, retries) do
    case GenServer.whereis(conn) do
      pid when is_pid(pid) and pid != old ->
        pid

      _ when retries > 0 ->
        Process.sleep(10)
        await_replacement(conn, old, retries - 1)

      _ ->
        flunk("protocol restart did not register")
    end
  end
end
