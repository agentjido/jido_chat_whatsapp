defmodule Jido.Chat.WhatsApp.ConnectionDefaultsTest do
  import Jido.Chat.WhatsApp.TestHelpers
  use ExUnit.Case, async: false

  alias Jido.Chat.Storage.Request
  alias Jido.Chat.WhatsApp.Adapter
  alias Jido.Chat.WhatsApp.Storage.{Mnesia, Runtime, Split}

  test "provider runtime enforces a RAM schema without host configuration" do
    assert {:ok, [spec]} = Adapter.provider_child_specs([])
    assert spec.start == {Runtime, :start_link, [[require_ram_schema: true]]}
    start_supervised!(spec)
    assert {:ok, _} = Mnesia.ready()
    refute :mnesia.system_info(:use_dir)
  end

  test "both saved and authenticated connections honor history flags without trusting connection identity" do
    start_supervised!({Mnesia, require_ram_schema: true})
    binding = %{channel_config_id: 12, credential_id: 34}
    sink = {__MODULE__, :host_request, [binding]}
    expected = Adapter.connection_options(binding, sink_mfa: sink)

    for history <- [false, true], full <- [false, true], handoff <- [[], [connection_options: expected]] do
      ingress = %{
        "profile" => "untrusted",
        "storage_root" => "/untrusted",
        "sync_history" => history,
        "sync_full_history" => full
      }

      assert {:ok, prepared} = Adapter.prepare_connection([sink_mfa: sink, ingress: ingress] ++ handoff)
      assert prepared.profile == expected.profile
      assert prepared.storage == expected.storage
      assert prepared.mode == :linked_device
      assert prepared.sync_history == history
      assert prepared.sync_full_history == full
      refute Map.has_key?(prepared, :storage_root)
      assert {Split, _} = prepared.storage
    end

    assert {:error, :storage_unavailable} = Adapter.prepare_connection(sink_mfa: {__MODULE__, :failed_request, []})
  end

  test "prepared history options use explicit booleans, trusted fallback and compatible defaults" do
    options = %{profile: "trusted", sync_history: true, sync_full_history: true}
    assert {:ok, inherited} = Adapter.prepare_connection(connection_options: options)
    assert inherited.sync_history
    assert inherited.sync_full_history

    assert {:ok, overridden} =
             Adapter.prepare_connection(
               connection_options: options,
               ingress: %{sync_history: false, sync_full_history: false}
             )

    refute overridden.sync_history
    refute overridden.sync_full_history

    assert {:ok, defaults} = Adapter.prepare_connection(connection_options: %{profile: "trusted"})
    refute defaults.sync_history
    refute defaults.sync_full_history

    for key <- [:sync_history, :sync_full_history], value <- [nil, "false", 0, [], %{}] do
      assert {:error, :invalid_history_options} =
               Adapter.prepare_connection(connection_options: options, ingress: %{key => value})
    end
  end

  test "adapter rejects disk schemas while explicitly configured raw storage remains available" do
    directory = Path.join(System.tmp_dir!(), "whatsapp-schema-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(directory) end)

    script = """
    Process.flag(:trap_exit, true)
    Application.put_env(:mnesia, :dir, String.to_charlist(#{inspect(directory)}))
    :ok = :mnesia.create_schema([node()])
    {:ok, _} = Application.ensure_all_started(:mnesia)
    true = :mnesia.system_info(:use_dir)
    {:ok, [spec]} = Jido.Chat.WhatsApp.Adapter.provider_child_specs([])
    {module, function, args} = spec.start
    {:error, reason} = apply(module, function, args)
    true = inspect(reason) =~ "invalid_storage_configuration"
    {:ok, owner} = Jido.Chat.WhatsApp.Storage.Mnesia.start_link(require_ram_schema: false)
    GenServer.stop(owner)
    :stopped = :mnesia.stop()
    IO.puts("SCHEMA_POLICY_OK")
    """

    {output, status} = fresh_vm(script, [], paths: [Application.app_dir(:jido_chat_whatsapp, "ebin")])
    assert status == 0, output
    assert output =~ "SCHEMA_POLICY_OK"
  end

  def host_request(binding, %Request{binding: nil, request: %{op: :bind}}, _opts), do: {:ok, binding}
  def host_request(binding, %Request{binding: binding, request: %{op: :list_keys}}, _opts), do: {:ok, []}
  def host_request(binding, %Request{binding: binding, request: %{op: :delete_namespace}}, _opts), do: :ok
  def failed_request(_, _), do: {:error, :storage_unavailable}
end
