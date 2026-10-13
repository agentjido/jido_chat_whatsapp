defmodule Jido.Chat.WhatsApp.MnesiaContractTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Jido.Chat.WhatsApp.Storage.Mnesia, as: SessionStorage

  @table :jido_chat_whatsapp_sessions

  setup do
    start_supervised!({SessionStorage, require_ram_schema: true})
    scope = {System.unique_integer([:positive]), 1, Base.encode16(:crypto.strong_rand_bytes(16))}
    on_exit(fn -> execute(scope, %{op: :clear}) end)
    %{scope: scope}
  end

  test "the table and schema are RAM-only and node-local" do
    assert :mnesia.table_info(@table, :storage_type) == :ram_copies
    assert :mnesia.table_info(@table, :local_content)
    assert :mnesia.table_info(@table, :disc_copies) == []
    assert :mnesia.table_info(@table, :disc_only_copies) == []
    refute :mnesia.system_info(:use_dir)
  end

  property "records round-trip independently by namespace and profile", %{scope: scope} do
    other = put_elem(scope, 2, Base.encode16(:crypto.strong_rand_bytes(16)))
    on_exit(fn -> execute(other, %{op: :clear}) end)

    check all(value <- binary(max_length: 4096), max_runs: 25) do
      assert :ok = put(scope, "session", "peer", value)
      assert :ok = put(scope, "sender_key", "peer", "group")
      assert :ok = put(other, "session", "peer", "other")
      assert {:ok, ^value} = get(scope, "session", "peer")
      assert {:ok, "group"} = get(scope, "sender_key", "peer")
      assert {:ok, "other"} = get(other, "session", "peer")
      assert :ok = execute(scope, %{op: :clear})
      assert :error = get(scope, "session", "peer")
      assert {:ok, "other"} = get(other, "session", "peer")
    end
  end

  test "concurrent callbacks preserve records after the writer processes exit", %{scope: scope} do
    results =
      Task.async_stream(1..30, fn n -> put(scope, "session", to_string(n), "value") end)
      |> Enum.to_list()

    assert Enum.all?(results, &(&1 == {:ok, :ok}))
    assert {:ok, keys} = execute(scope, %{op: :list_keys, namespace: "session"})
    assert Enum.sort(keys) == Enum.sort(Enum.map(1..30, &to_string/1))
    assert :ok = execute(scope, %{op: :delete, namespace: "session", key: "1"})
    assert :error = get(scope, "session", "1")
    assert {:ok, "value"} = get(scope, "session", "2")
  end

  test "snapshot seeding is atomic and never overwrites advanced or deleted sessions", %{
    scope: scope
  } do
    records = %{{"session", "peer"} => "initial", {"sender_key", "group"} => "key"}
    assert :ok = seed(scope, records)
    assert :ok = put(scope, "session", "peer", "advanced")

    assert :ok =
             execute(scope, %{op: :delete, namespace: "sender_key", key: "group"})

    assert :ok = seed(scope, records)
    assert {:ok, "advanced"} = get(scope, "session", "peer")
    assert :error = get(scope, "sender_key", "group")
  end

  test "capacity failures preserve existing state and deletion releases capacity", %{scope: scope} do
    value = String.duplicate("v", 1024 * 1024)
    for n <- 1..15, do: assert(:ok = put(scope, "session", to_string(n), value))
    assert {:error, :storage_full} = put(scope, "session", "overflow", value)
    assert :error = get(scope, "session", "overflow")
    assert {:ok, ^value} = get(scope, "session", "1")
    assert :ok = execute(scope, %{op: :delete, namespace: "session", key: "1"})
    assert :ok = put(scope, "session", "replacement", value)
    assert {:error, :invalid_request} = put(scope, "session", "large", value <> "v")
  end

  test "late snapshots cannot overwrite a running connection or restore cleared keys", %{
    scope: scope
  } do
    assert :ok = put(scope, "session", "peer", "running")
    snapshot = %{{"session", "peer"} => "old"}
    assert :ok = seed(scope, snapshot)
    assert {:ok, "running"} = get(scope, "session", "peer")
    assert :ok = execute(scope, %{op: :clear})
    assert :ok = seed(scope, snapshot)
    assert :error = get(scope, "session", "peer")
  end

  test "an oversized snapshot leaves no partial records or seed marker", %{scope: scope} do
    records = Map.new(1..16, &{{"session", to_string(&1)}, String.duplicate("s", 1024 * 1024)})
    assert {:error, :storage_full} = seed(scope, records)
    assert {:ok, []} = execute(scope, %{op: :list_keys, namespace: "session"})
    assert :ok = seed(scope, %{{"session", "peer"} => "valid"})
    assert {:ok, "valid"} = get(scope, "session", "peer")
  end

  test "an unavailable store fails closed and Mnesia restart loses state without writing files" do
    directory = Path.join(System.tmp_dir!(), "zaq-mnesia-#{Base.encode16(:crypto.strong_rand_bytes(16))}")
    on_exit(fn -> File.rm_rf!(directory) end)
    ebin = SessionStorage |> :code.which() |> List.to_string() |> Path.dirname()

    script = """
    alias Jido.Chat.WhatsApp.Storage.Mnesia, as: Store
    Application.put_env(:mnesia, :schema_location, :ram)
    Application.put_env(:mnesia, :dir, String.to_charlist(#{inspect(directory)}))
    {:ok, _} = Application.ensure_all_started(:mnesia)
    {:ok, owner} = Store.start_link(require_ram_schema: true)
    state = Store.new(scope: {1, 2})
    :ok = Store.put(state, "account", "session", "peer", "state")
    {:ok, token} = Store.watch()
    GenServer.stop(owner)
    false = Store.current?(token)
    {:ok, _owner} = Store.start_link(require_ram_schema: true)
    fresh = Store.new(scope: {1, 2})
    {:ok, "state"} = Store.get(fresh, "account", "session", "peer")
    {:error, :storage_unavailable} = Store.get(state, "account", "session", "peer")
    :stopped = :mnesia.stop()
    {:error, :storage_unavailable} = Store.get(fresh, "account", "session", "peer")
    wait = fn recur, n ->
      case Store.ready() do
        {:ok, new_token} when new_token != fresh.generation -> :ok
        _ when n > 0 -> Process.sleep(10); recur.(recur, n - 1)
        _ -> raise "storage did not recover"
      end
    end
    wait.(wait, 200)
    recovered = Store.new(scope: {1, 2})
    :error = Store.get(recovered, "account", "session", "peer")
    {:error, :storage_unavailable} = Store.get(fresh, "account", "session", "peer")
    false = :mnesia.system_info(:use_dir)
    false = File.exists?(#{inspect(directory)})
    IO.puts("RAM_RESTART_OK")
    """

    {output, status} =
      System.cmd("elixir", ["--erl", "+S 2:2", "-pa", ebin, "-e", script], stderr_to_stdout: true)

    assert status == 0, output
    assert output =~ "RAM_RESTART_OK"
  end

  defp put(scope, namespace, key, value),
    do: execute(scope, %{op: :put, namespace: namespace, key: key, value: value})

  defp get(scope, namespace, key),
    do: execute(scope, %{op: :get, namespace: namespace, key: key})

  defp seed({host, credential, profile}, records),
    do: SessionStorage.seed(SessionStorage.new(scope: {host, credential}), profile, records)

  defp execute({host, credential, profile}, request) do
    state = SessionStorage.new(scope: {host, credential})

    case request do
      %{op: :get, namespace: ns, key: key} -> SessionStorage.get(state, profile, ns, key)
      %{op: :put, namespace: ns, key: key, value: value} -> SessionStorage.put(state, profile, ns, key, value)
      %{op: :delete, namespace: ns, key: key} -> SessionStorage.delete(state, profile, ns, key)
      %{op: :list_keys, namespace: ns} -> SessionStorage.list_keys(state, profile, ns)
      %{op: :clear} -> SessionStorage.clear(state, profile)
    end
  end
end
