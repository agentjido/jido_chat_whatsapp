defmodule Jido.Chat.WhatsApp.ManagedStorageTest do
  use ExUnit.Case, async: false

  alias Jido.Chat.WhatsApp.Storage.Mnesia
  alias Jido.Chat.WhatsApp.ConnectionWorker

  setup do
    start_supervised!({Mnesia, max_value_bytes: 64, max_scope_bytes: 200})
    %{store: Mnesia.new(scope: make_ref()), other: Mnesia.new(scope: make_ref())}
  end

  test "isolates profiles and host scopes and preserves state after client exit", ctx do
    assert :ok = Mnesia.put(ctx.store, "one", :session, "key", "value")
    assert {:ok, "value"} = Mnesia.get(ctx.store, "one", :session, "key")
    assert :error = Mnesia.get(ctx.store, "two", :session, "key")
    assert :error = Mnesia.get(ctx.other, "one", :session, "key")
    assert {:ok, ["key"]} = Mnesia.list_keys(ctx.store, "one", :session)
    assert {:ok, ["one"]} = Mnesia.list_profiles(ctx.store)
  end

  test "seeding is atomic and cannot resurrect cleared records", %{store: store} do
    snapshot = %{{:session, "key"} => "initial"}
    assert :ok = Mnesia.seed(store, "one", snapshot)
    assert :ok = Mnesia.put(store, "one", :session, "key", "advanced")
    assert :ok = Mnesia.seed(store, "one", snapshot)
    assert {:ok, "advanced"} = Mnesia.get(store, "one", :session, "key")
    assert :ok = Mnesia.clear(store, "one")
    assert :ok = Mnesia.seed(store, "one", snapshot)
    assert :error = Mnesia.get(store, "one", :session, "key")
  end

  test "bounds writes and rolls back oversized seeds", %{store: store} do
    assert {:error, :invalid_request} = Mnesia.put(store, "one", :session, "key", String.duplicate("v", 65))
    snapshot = Map.new(1..10, &{{:session, to_string(&1)}, String.duplicate("v", 60)})
    assert {:error, :storage_full} = Mnesia.seed(store, "one", snapshot)
    assert {:ok, []} = Mnesia.list_keys(store, "one", :session)
    assert :ok = Mnesia.seed(store, "one", %{{:session, "key"} => "ok"})
  end

  test "explicit owner replacement retains records but fences old handles", %{store: store} do
    assert :ok = Mnesia.put(store, "one", :session, "key", "value")
    assert {:ok, token} = Mnesia.watch()
    stop_supervised!(Mnesia)
    refute Mnesia.current?(token)
    assert {:error, :storage_unavailable} = Mnesia.get(store, "one", :session, "key")
    start_supervised!({Mnesia, max_value_bytes: 64, max_scope_bytes: 200})
    assert {:error, :storage_unavailable} = Mnesia.get(store, "one", :session, "key")
    fresh = Mnesia.new(scope: store.scope)
    assert {:ok, "value"} = Mnesia.get(fresh, "one", :session, "key")
  end

  test "backend loss pauses only managed connections and recovers without worker restart" do
    managed = worker(:managed, {Mnesia, scope: :managed})
    other = worker(:other, nil)
    assert_receive {:connected, "managed", old_connection}
    %{attempt_id: old_attempt} = ConnectionWorker.status(managed)
    stop_supervised!(Mnesia)
    assert_receive {:lifecycle, %{profile: "managed", status: :failed, qr: nil}}
    assert %{status: :failed} = ConnectionWorker.status(managed)
    assert Process.alive?(other)
    assert {:error, :storage_unavailable} = ConnectionWorker.logout(managed)
    refute_receive {:connected, "managed", _}, 250
    start_supervised!({Mnesia, max_value_bytes: 64, max_scope_bytes: 200})
    assert_receive {:connected, "managed", connection}, 1_000
    refute connection == old_connection
    assert Process.alive?(managed)
    send(connection, {:amarula, :connection_update, %{qr: "fresh"}})
    assert_receive {:lifecycle, %{profile: "managed", status: :pairing, qr: "fresh"}}
    send(managed, {:transport_event, old_attempt, :connection_update, %{qr: "stale"}})
    assert %{qr: "fresh", attempt_id: attempt} = ConnectionWorker.status(managed)
    refute attempt == old_attempt
  end

  test "starting while storage is absent stays responsive and connects when ready" do
    stop_supervised!(Mnesia)
    managed = worker(:late, {Mnesia, scope: :late})
    assert %{status: :failed} = ConnectionWorker.status(managed)
    assert {:error, :storage_unavailable} = ConnectionWorker.reconnect(managed)
    refute_receive {:connected, "late", _}, 250
    start_supervised!({Mnesia, max_value_bytes: 64, max_scope_bytes: 200})
    assert_receive {:connected, "late", _}, 1_000
    assert Process.alive?(managed)
  end

  test "literal match-pattern atoms cannot clear another host scope" do
    first = Mnesia.new(scope: :_)
    other = Mnesia.new(scope: :other)
    assert :ok = Mnesia.put(first, "one", :session, "key", "one")
    assert :ok = Mnesia.put(other, "one", :session, "key", "other")
    assert :ok = Mnesia.clear(first, "one")
    assert {:ok, "other"} = Mnesia.get(other, "one", :session, "key")
  end

  test "configuration is explicit and duplicate or invalid starts cannot replace it" do
    assert {:error, :invalid_storage_configuration} = Mnesia.start_link(max_value_bytes: 0)
    assert {:error, :invalid_storage_configuration} = Mnesia.start_link(unknown: true)
    assert {:error, {:already_started, pid}} = Mnesia.start_link([])
    assert pid == Process.whereis(Mnesia)
    stop_supervised!(Mnesia)
    assert {:error, :storage_unavailable} = Mnesia.ready()
    assert {:error, :storage_unavailable} = Mnesia.put(Mnesia.new(scope: :absent), "one", :session, "key", "value")
    refute Process.whereis(Mnesia)
  end

  test "strict RAM policy rejects host disk schema while coexistence preserves host data" do
    directory = Path.join(System.tmp_dir!(), "whatsapp-schema-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(directory) end)
    ebin = Application.app_dir(:jido_chat_whatsapp, "ebin")

    script = """
    Process.flag(:trap_exit, true)
    alias Jido.Chat.WhatsApp.Storage.Mnesia, as: Store
    Application.put_env(:mnesia, :dir, String.to_charlist(#{inspect(directory)}))
    :ok = :mnesia.create_schema([node()])
    {:ok, _} = Application.ensure_all_started(:mnesia)
    {:atomic, :ok} = :mnesia.create_table(:host_records, attributes: [:key, :value], disc_copies: [node()])
    :ok = :mnesia.dirty_write({:host_records, :key, "host"})
    {:error, :invalid_storage_configuration} = Store.start_link(require_ram_schema: true)
    false = :jido_chat_whatsapp_sessions in :mnesia.system_info(:tables)
    {:ok, owner} = Store.start_link(require_ram_schema: false)
    {:ok, _} = Store.ready()
    :ram_copies = :mnesia.table_info(:jido_chat_whatsapp_sessions, :storage_type)
    [] = :mnesia.table_info(:jido_chat_whatsapp_sessions, :disc_copies)
    GenServer.stop(owner)
    [{:host_records, :key, "host"}] = :mnesia.dirty_read(:host_records, :key)
    :yes = :mnesia.system_info(:is_running)
    IO.puts("HOST_SCHEMA_PRESERVED")
    """

    {output, status} = System.cmd("elixir", ["--erl", "+S 2:2", "-pa", ebin, "-e", script], stderr_to_stdout: true)
    assert status == 0, output
    assert output =~ "HOST_SCHEMA_PRESERVED"
  end

  def connect(config, _) do
    send(config.observer, {:connected, config.profile, self()})
    {:ok, self()}
  end

  def lifecycle(observer, %Jido.Chat.EventEnvelope{event_type: :action, payload: %{metadata: payload}}, _),
    do: send(observer, {:lifecycle, payload})

  def stop(_, _), do: :ok
  def sink(_, _), do: :ok

  defp worker(id, storage) do
    start_supervised!(
      {ConnectionWorker,
       bridge_id: to_string(id),
       transport: __MODULE__,
       sink_mfa: {__MODULE__, :lifecycle, [self()]},
       config: %{profile: to_string(id), storage: storage, observer: self()}},
      id: id,
      restart: :temporary
    )
  end
end
