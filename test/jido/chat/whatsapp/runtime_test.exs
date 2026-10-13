defmodule Jido.Chat.WhatsApp.RuntimeTest do
  use Jido.Chat.WhatsApp.RuntimeCase, async: false

  alias Jido.Chat.WhatsApp.{Adapter, ConnectionWorker}
  alias Jido.Chat.WhatsApp.Transport.{AmarulaClient, AmarulaRuntime, RuntimeHealth}

  @moduletag capture_log: true

  defmodule Store do
    def new(opts), do: Keyword.fetch!(opts, :table)

    def get(table, profile, namespace, key) do
      case :ets.lookup(table, {profile, namespace, key}) do
        [{_, value}] -> {:ok, value}
        [] -> :error
      end
    end

    def put(table, profile, namespace, key, value) do
      :ets.insert(table, {{profile, namespace, key}, value})
      :ok
    end

    def delete(table, profile, namespace, key) do
      :ets.delete(table, {profile, namespace, key})
      :ok
    end

    def clear(table, profile) do
      :ets.match_delete(table, {{profile, :_, :_}, :_})
      :ok
    end

    def list_keys(_, _, _), do: {:ok, []}
    def list_profiles(_), do: {:ok, []}
  end

  defmodule Sink do
    def emit(pid, event, _opts), do: send(pid, {:event, event})
  end

  setup do
    table = :ets.new(:runtime_storage, [:public, :set])
    config = %{storage: {Store, table: table}, offline: true, connection_state: :connected}
    %{config: config, table: table}
  end

  test "application owns idle infrastructure and caller exit cannot stop it" do
    runtime = Process.whereis(AmarulaRuntime)
    infrastructure = Process.whereis(Amarula.Supervisor)
    assert is_pid(runtime)

    assert {AmarulaRuntime, ^runtime, :supervisor, _} =
             List.keyfind(Supervisor.which_children(Jido.Chat.WhatsApp.Supervisor), AmarulaRuntime, 0)

    assert {Amarula.Supervisor, ^infrastructure, :supervisor, _} =
             List.keyfind(Supervisor.which_children(runtime), Amarula.Supervisor, 0)

    assert DynamicSupervisor.which_children(Amarula.ConnectionsSupervisor) == []

    assert :ok == Task.async(fn -> AmarulaClient.ensure_started([]) end) |> Task.await()
    assert Process.whereis(Amarula.Supervisor) == infrastructure
    assert Process.alive?(infrastructure)
  end

  test "simultaneous profiles share infrastructure and stopping one retains the other", %{config: config} do
    runtime = Process.whereis(Amarula.Supervisor)

    results =
      ["first", "second"]
      |> Task.async_stream(fn profile -> AmarulaClient.connect(Map.put(config, :profile, profile), []) end)
      |> Enum.map(fn {:ok, {:ok, conn}} -> conn end)

    [first, second] = results
    assert Process.whereis(Amarula.Supervisor) == runtime
    assert :ok = AmarulaClient.stop(first, [])
    assert Process.alive?(GenServer.whereis(second))
    assert {:error, {:already_running, _}} = AmarulaClient.connect(Map.put(config, :profile, "second"), [])
  end

  for failed <- [
        AmarulaRuntime,
        Amarula.Supervisor,
        Amarula.ProfileRegistry,
        Amarula.InstanceRegistry,
        Amarula.ConnectionsSupervisor
      ] do
    test "listeners recover both profiles after #{inspect(failed)} loss", %{config: config, table: table} do
      first = start_listener("first", config)
      second = start_listener("second", config)
      first_state = :sys.get_state(first)
      second_state = :sys.get_state(second)
      generation = Process.whereis(RuntimeHealth)
      first_ref = Process.monitor(first)
      second_ref = Process.monitor(second)
      :ok = Store.put(table, "first", :test, :preserved, "value")

      Process.exit(Process.whereis(unquote(failed)), :kill)

      assert_receive {:DOWN, ^first_ref, :process, ^first, _}, 5_000
      assert_receive {:DOWN, ^second_ref, :process, ^second, _}, 5_000
      assert {:ok, replacement_generation} = AmarulaRuntime.ready()
      refute replacement_generation == generation
      replacement_first = await_listener("first", first)
      replacement_second = await_listener("second", second)
      next_first = :sys.get_state(replacement_first)
      next_second = :sys.get_state(replacement_second)
      refute next_first.attempt_id == first_state.attempt_id
      refute next_second.attempt_id == second_state.attempt_id
      assert next_first.config == first_state.config
      assert next_second.config == second_state.config
      assert Process.alive?(GenServer.whereis(next_first.conn))
      assert Process.alive?(GenServer.whereis(next_second.conn))
      assert {:ok, "value"} = Store.get(table, "first", :test, :preserved)
      assert :ok = AmarulaClient.stop(first_state.conn, [])
      assert Process.alive?(GenServer.whereis(next_first.conn))
      send(replacement_first, {:transport_event, first_state.attempt_id, :connection_update, %{connection: :open}})
      assert ConnectionWorker.status(replacement_first).status == :connecting
    end
  end

  test "host shutdown releases its connection without stopping shared infrastructure", %{config: config} do
    runtime = Process.whereis(Amarula.Supervisor)
    worker = start_listener("first", config)
    state = :sys.get_state(worker)
    ref = Process.monitor(GenServer.whereis(state.conn))
    assert :ok = stop_supervised({:whatsapp_connection_worker, "first"})
    assert_receive {:DOWN, ^ref, :process, _, _}
    assert Amarula.whereis("first") == nil
    assert Process.whereis(Amarula.Supervisor) == runtime
    assert is_pid(start_listener("first", config))
  end

  test "losing one connection owner restarts only that listener", %{config: config} do
    first = start_listener("first", config)
    second = start_listener("second", config)
    state = :sys.get_state(first)
    {:ok, [generation, instance]} = AmarulaClient.connection_processes(state.conn)
    ref = Process.monitor(first)
    Process.exit(instance, :kill)
    assert_receive {:DOWN, ^ref, :process, ^first, _}, 5_000
    replacement = await_listener("first", first)
    assert Process.alive?(GenServer.whereis(:sys.get_state(replacement).conn))
    assert Process.alive?(second)
    assert Process.whereis(RuntimeHealth) == generation
  end

  test "default startup refuses a live host-owned runtime instead of adopting it" do
    :ok = Application.stop(:jido_chat_whatsapp)
    host_runtime = start_supervised!(Amarula.Supervisor)
    on_exit(fn -> {:ok, _} = Application.ensure_all_started(:jido_chat_whatsapp) end)
    assert {:error, _} = Application.ensure_all_started(:jido_chat_whatsapp)
    assert Process.whereis(Amarula.Supervisor) == host_runtime
    assert Process.alive?(host_runtime)
    assert Process.whereis(Jido.Chat.WhatsApp.Supervisor) == nil
  end

  test "legacy mode retains an explicitly host-owned shared tree" do
    :ok = Application.stop(:jido_chat_whatsapp)
    Application.put_env(:jido_chat_whatsapp, :start_runtime, false)

    on_exit(fn ->
      Application.stop(:jido_chat_whatsapp)
      Application.delete_env(:jido_chat_whatsapp, :start_runtime)
      {:ok, _} = Application.ensure_all_started(:jido_chat_whatsapp)
    end)

    {:ok, _} = Application.ensure_all_started(:jido_chat_whatsapp)
    assert Supervisor.which_children(Jido.Chat.WhatsApp.Supervisor) == []
    assert Process.whereis(Amarula.Supervisor) == nil
    host_runtime = start_supervised!(Amarula.Supervisor)
    assert :ok = AmarulaClient.ensure_started([])
    assert {:ok, ^host_runtime} = AmarulaRuntime.ready()
    :ok = Application.stop(:jido_chat_whatsapp)
    assert Process.alive?(host_runtime)
  end

  test "application stop removes its infrastructure and all profiles", %{config: config} do
    {:ok, conn} = AmarulaClient.connect(Map.put(config, :profile, "first"), [])
    ref = Process.monitor(GenServer.whereis(conn))
    on_exit(fn -> {:ok, _} = Application.ensure_all_started(:jido_chat_whatsapp) end)
    assert :ok = Application.stop(:jido_chat_whatsapp)
    assert_receive {:DOWN, ^ref, :process, _, _}
    assert Process.whereis(Amarula.Supervisor) == nil
    assert Process.whereis(RuntimeHealth) == nil
    assert {:error, :runtime_unavailable} = AmarulaClient.connect(Map.put(config, :profile, "first"), [])
    assert Process.whereis(Jido.Chat.WhatsApp.Supervisor) == nil
    # ensure_started is the CLI's explicit application startup entry point.
    assert :ok = AmarulaClient.ensure_started([])
    assert DynamicSupervisor.which_children(Amarula.ConnectionsSupervisor) == []
  end

  defp start_listener(profile, config) do
    {:ok, [spec]} =
      Adapter.listener_child_specs(profile,
        ingress: %{profile: profile, mode: :linked_device, config: config, storage: config.storage},
        sink_mfa: {Sink, :emit, [self()]}
      )

    start_supervised!(spec)
  end

  defp await_listener(profile, previous, attempts \\ 500)
  defp await_listener(_profile, _previous, 0), do: flunk("listener did not recover")

  defp await_listener(profile, previous, attempts) do
    {:ok, supervisor} = ExUnit.fetch_test_supervisor()

    case List.keyfind(
           Supervisor.which_children(supervisor),
           {:whatsapp_connection_worker, profile},
           0
         ) do
      {_, pid, _, _} when is_pid(pid) and pid != previous ->
        pid

      _ ->
        Process.sleep(10)
        await_listener(profile, previous, attempts - 1)
    end
  end
end
