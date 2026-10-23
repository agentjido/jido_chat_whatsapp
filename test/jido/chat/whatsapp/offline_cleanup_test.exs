defmodule Jido.Chat.WhatsApp.OfflineCleanupTest do
  import Jido.Chat.WhatsApp.TestHelpers
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Amarula.Storage
  alias Jido.Chat.WhatsApp.Adapter
  alias Jido.Chat.WhatsApp.Storage.{Mnesia, Split}
  alias Jido.Chat.WhatsApp.Transport.AmarulaClient

  defmodule Store do
    def new(opts), do: Keyword.fetch!(opts, :table)
    def get(_, _, _, _), do: raise("cleanup must not read credentials")

    def clear(table, profile) do
      case :ets.lookup(table, :failure) do
        [{_, :throw}] -> throw("private storage details")
        [{_, :error}] -> {:error, "private storage details"}
        _ -> :ets.delete(table, profile) && :ok
      end
    end
  end

  defmodule UnusedCache do
    def new(_), do: raise("cleanup must not initialize unrelated connection caches")
  end

  defmodule NoClear do
    def new(_), do: nil
  end

  defmodule NoCleanup do
    def channel_type, do: :other
  end

  defmodule BlockingTransport do
    def cleanup(_, opts) do
      send(Keyword.fetch!(opts, :observer), {:cleanup_waiting, self()})

      receive do
        :release -> :ok
      end
    end
  end

  defmodule InvalidTransport do
    def cleanup(_, _), do: {:error, "private details"}
  end

  setup do
    table = :ets.new(:offline_cleanup, [:set, :public])
    root = Path.join(System.tmp_dir!(), "offline_cleanup_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    %{table: table, root: root}
  end

  test "file root cleanup is profile-scoped and repeatable without a listener", %{root: root} do
    storage = Storage.scope({Storage.File, root: root})
    assert :ok = Storage.put(storage, "selected", :creds, :self, "corrupt identity")
    assert :ok = Storage.put(storage, "other", :session, "peer", "retained")

    config = %{profile: "selected", storage_root: root}
    assert :ok = AmarulaClient.cleanup(config, [])
    assert :ok = AmarulaClient.cleanup(config, [])
    refute File.exists?(Path.join(root, "selected"))
    assert {:ok, "retained"} = Storage.get(storage, "other", :session, "peer")
  end

  test "adapter extension clears standalone file configuration without managed storage", %{root: root} do
    storage = Storage.scope({Storage.File, root: root})
    assert :ok = Storage.put(storage, "selected", :creds, :self, "credentials")
    assert :ok = Adapter.cleanup_connection(nil, profile: "selected", storage_root: root)
    assert :error = Storage.get(storage, "selected", :creds, :self)
  end

  test "adapter extension derives its selected binding and ignores a supplied profile override", %{table: table} do
    start_supervised!(Mnesia)
    selected = split(:selected, table)
    assert :ok = Split.put(selected, selected.profile, :session, "peer", "ratchet")
    :ets.insert(table, {:selected, "durable"})

    assert :ok = Adapter.cleanup_connection(:selected, sink_mfa: {__MODULE__, :host, [table]}, profile: "untrusted")
    assert :ets.lookup(table, :selected) == []
    assert :error = Split.get(selected, selected.profile, :session, "peer")
  end

  test "adapter extension preserves custom and prebuilt standalone storage", %{table: table} do
    for storage <- [{Store, table: table}, %Storage.Scope{adapter: Store, state: table}] do
      :ets.insert(table, {"selected", "durable"})
      assert :ok = Adapter.cleanup_connection(nil, profile: "selected", storage: storage)
      assert :ets.lookup(table, "selected") == []
    end
  end

  test "a denied host callback preserves the binding's RAM records", %{table: table} do
    start_supervised!(Mnesia)
    state = split(:selected, table)
    assert :ok = Split.put(state, state.profile, :session, "peer", "ratchet")

    assert {:error, _} = Adapter.cleanup_connection(:selected, sink_mfa: {__MODULE__, :deny, []})
    assert {:ok, "ratchet"} = Split.get(state, state.profile, :session, "peer")
  end

  test "adapter extension rejects missing configuration and unsupported transports" do
    assert {:error, _} = Adapter.cleanup_connection(nil, [])
    assert {:error, _} = Adapter.cleanup_connection(:binding, [])
    assert {:error, _} = Adapter.cleanup_connection(:binding, sink_mfa: :invalid)
    assert {:error, _} = Adapter.cleanup_connection(nil, [:invalid])
    assert {:error, :unsupported} = Adapter.cleanup_connection(nil, profile: "selected", transport: NoCleanup)
    assert {:error, :cleanup_failed} = Adapter.cleanup_connection(nil, profile: "selected", transport: InvalidTransport)
  end

  test "adapter extension bounds offline cleanup and does not acknowledge an uncertain timeout" do
    observer = self()

    task =
      Task.async(fn ->
        Adapter.cleanup_connection(nil,
          profile: "selected",
          transport: BlockingTransport,
          observer: observer,
          cleanup_timeout_ms: 100
        )
      end)

    assert_receive {:cleanup_waiting, cleanup}
    monitor = Process.monitor(cleanup)
    assert {:error, :cleanup_timeout} = Task.await(task)
    assert_receive {:DOWN, ^monitor, :process, ^cleanup, :killed}
  end

  test "custom storage takes precedence over file root and never reads credentials", ctx do
    file = Storage.scope({Storage.File, root: ctx.root})
    assert :ok = Storage.put(file, "selected", :creds, :self, "preserved")
    :ets.insert(ctx.table, [{"selected", "clear"}, {"other", "retain"}])

    config = %{
      profile: "selected",
      storage_root: ctx.root,
      storage: {Store, table: ctx.table},
      retry_cache: {UnusedCache, []},
      message_secret_store: {UnusedCache, []}
    }

    assert :ok = AmarulaClient.cleanup(config, [])
    assert :ets.lookup(ctx.table, "selected") == []
    assert :ets.lookup(ctx.table, "other") == [{"other", "retain"}]
    assert {:ok, "preserved"} = Storage.get(file, "selected", :creds, :self)
  end

  test "prebuilt scopes keep their initialized backend state", %{table: table} do
    :ets.insert(table, {"selected", "clear"})
    scope = %Storage.Scope{adapter: Store, state: table}
    assert :ok = AmarulaClient.cleanup(%{profile: "selected", storage: scope}, [])
    assert :ets.lookup(table, "selected") == []
  end

  test "storage failures are reported without exposing backend details", %{table: table} do
    config = %{profile: "selected", storage: {Store, table: table}}

    for failure <- [:error, :throw] do
      :ets.insert(table, [{:failure, failure}, {"selected", "retained"}])
      assert {:error, reason} = AmarulaClient.cleanup(config, [])
      assert is_atom(reason)
      assert :ets.lookup(table, "selected") == [{"selected", "retained"}]
    end

    :ets.delete(table, :failure)
    assert :ok = AmarulaClient.cleanup(config, [])
  end

  test "a backend without clear cannot acknowledge cleanup" do
    assert {:error, _} = AmarulaClient.cleanup(%{profile: "selected", storage: {NoClear, []}}, [])
  end

  property "cleanup isolates arbitrary profiles and remains idempotent", %{table: table} do
    check all(
            profiles <- uniq_list_of(string(:alphanumeric, min_length: 1, max_length: 16), min_length: 2, max_length: 4),
            max_runs: 30
          ) do
      :ets.delete_all_objects(table)
      Enum.each(profiles, &:ets.insert(table, {&1, "saved"}))
      [selected | others] = profiles
      config = %{profile: selected, storage: {Store, table: table}}
      assert :ok = AmarulaClient.cleanup(config, [])
      assert :ok = AmarulaClient.cleanup(config, [])
      assert :ets.lookup(table, selected) == []
      for other <- others, do: assert(:ets.lookup(table, other) == [{other, "saved"}])
    end
  end

  test "invalid profiles cannot clear a directory or invoke a backend", %{table: table} do
    :ets.insert(table, {"selected", "retained"})

    for profile <- [nil, "", ".", "..", "../selected", "a/b", <<0>>] do
      assert {:error, _} = AmarulaClient.cleanup(%{profile: profile, storage: {Store, table: table}}, [])
    end

    assert :ets.lookup(table, "selected") == [{"selected", "retained"}]
  end

  test "Split clears host records and RAM only for its exact binding", %{table: table} do
    start_supervised!(Mnesia)
    selected = split(:selected, table)
    other = split(:other, table)

    for state <- [selected, other] do
      :ets.insert(table, {state.context, "durable"})
      assert :ok = Split.put(state, state.profile, :session, "peer", "ratchet")
    end

    assert :ok = AmarulaClient.cleanup(split_config(:selected, table), [])
    assert :ets.lookup(table, :selected) == []
    assert :ets.lookup(table, :other) == [{:other, "durable"}]
    assert :error = Split.get(selected, selected.profile, :session, "peer")
    assert {:ok, "ratchet"} = Split.get(other, other.profile, :session, "peer")
  end

  test "Split partial cleanup remains a failure and explicit retry can finish", %{table: table} do
    start_supervised!(Mnesia)
    :ets.insert(table, {:selected, "durable"})
    :ets.insert(table, {:pause_clear, self()})
    config = split_config(:selected, table)

    cleanup = Task.async(fn -> AmarulaClient.cleanup(config, []) end)
    assert_receive {:durable_cleared, callback}
    stop_supervised!(Mnesia)
    send(callback, :continue)
    assert {:error, _} = Task.await(cleanup)
    assert :ets.lookup(table, :selected) == []
    :ets.delete(table, :pause_clear)
    start_supervised!(Mnesia)
    assert :ok = AmarulaClient.cleanup(config, [])
  end

  test "unavailable Split storage cannot acknowledge cleanup", %{table: table} do
    refute Process.whereis(Mnesia)
    :ets.insert(table, {:selected, "durable"})
    assert {:error, _} = AmarulaClient.cleanup(split_config(:selected, table), [])
    assert :ets.lookup(table, :selected) == [{:selected, "durable"}]
  end

  test "upstream storage defaults work in a fresh VM without managed Mnesia", %{root: root} do
    script = ~S"""
    [root] = System.argv()
    System.put_env("AMARULA_DATA_DIR", root)
    Application.put_env(:amarula, :default_storage_adapter, Amarula.Storage.File)
    config = %{profile: "selected"}
    storage = Amarula.new(config).storage
    :ok = Amarula.Storage.put(storage, "selected", :creds, :self, "data")
    :ok = Jido.Chat.WhatsApp.Transport.AmarulaClient.cleanup(config, [])
    nil = Process.whereis(Jido.Chat.WhatsApp.Storage.Mnesia)
    false = File.exists?(Path.join(root, "selected"))

    defmodule ConfiguredDefault do
      defdelegate new(opts), to: Amarula.Storage.File
      def clear(state, profile) do
        send(self(), :configured_default_clear)
        Amarula.Storage.File.clear(state, profile)
      end
    end

    Application.put_env(:amarula, :default_storage_adapter, ConfiguredDefault)
    :ok = Jido.Chat.WhatsApp.Transport.AmarulaClient.cleanup(%{profile: "absent"}, [])
    receive do
      :configured_default_clear -> :ok
    after
      0 -> raise "configured storage default ignored"
    end
    IO.puts("default_cleanup=ok")
    """

    assert {output, 0} = fresh_vm(script, [root])

    assert output =~ "default_cleanup=ok"
  end

  def host(table, %Jido.Chat.Storage.Request{binding: binding, request: request}, _) do
    case request do
      %{op: :clear} ->
        :ets.delete(table, binding)

        case :ets.lookup(table, :pause_clear) do
          [{_, observer}] ->
            send(observer, {:durable_cleared, self()})

            receive do
              :continue -> :ok
            end

          [] ->
            :ok
        end

      %{op: :list_keys, namespace: "__binding_check__"} ->
        {:ok, []}

      _ ->
        {:error, :unexpected_operation}
    end
  end

  def deny(_, _), do: {:error, :unauthorized}

  defp split(binding, table), do: Split.new(Split.binding_options(binding, sink_mfa: {__MODULE__, :host, [table]}))

  defp split_config(binding, table) do
    options = Split.binding_options(binding, sink_mfa: {__MODULE__, :host, [table]})
    %{profile: Split.profile(binding), storage: {Split, options}}
  end
end
