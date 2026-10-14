defmodule Jido.Chat.WhatsApp.ConnectionWorkerTest do
  use ExUnit.Case, async: false

  alias Jido.Chat.WhatsApp.ConnectionWorker
  alias Amarula.{Address, Msg}
  alias Amarula.Protocol.Proto

  defmodule Sink do
    def control(test_pid, control, opts) do
      send(test_pid, {:control, control, opts})
      {:ok, :accepted}
    end

    def emit(test_pid, payload, opts) do
      send(test_pid, {:sink_emit, payload, opts})
      {:ok, :accepted}
    end
  end

  defmodule MockTransport do
    @behaviour Jido.Chat.WhatsApp.Transport

    @impl true
    def connect(config, opts) do
      send(Map.fetch!(config, :test_pid), {:transport_connect, config, opts})
      {:ok, self()}
    end

    @impl true
    def resolve_conn(_opts), do: {:ok, self()}

    @impl true
    def send_text(_conn, _jid, _text, _opts), do: {:ok, "msg"}

    @impl true
    def send_media(_conn, _jid, _media_type, _data, _opts), do: {:ok, "msg"}

    @impl true
    def download_media(_media), do: {:error, :unsupported}

    @impl true
    def send_reaction(_conn, _message_ref, _emoji), do: {:ok, "msg"}

    @impl true
    def send_edit(_conn, _message_ref, _text), do: {:ok, "msg"}

    @impl true
    def send_revoke(_conn, _message_ref), do: {:ok, "msg"}

    @impl true
    def send_chatstate(_conn, _jid, _state), do: :ok

    @impl true
    def request_pairing_code(_conn, _phone, _opts), do: {:ok, "12345678"}
  end

  test "connects transport with worker as Amarula parent" do
    {:ok, _pid} =
      start_supervised(
        {ConnectionWorker,
         bridge_id: "bridge_whatsapp",
         sink_mfa: {Sink, :emit, [self()]},
         control_mfa: {Sink, :control, [self()]},
         transport: MockTransport,
         config: %{profile: "worker_test", test_pid: self()}}
      )

    assert_receive {:transport_connect, %{profile: "worker_test"}, opts}
    assert is_pid(opts[:parent])
  end

  test "emits connection updates as action event envelopes" do
    {:ok, pid} =
      start_supervised(
        {ConnectionWorker,
         bridge_id: "bridge_whatsapp",
         sink_mfa: {Sink, :emit, [self()]},
         control_mfa: {Sink, :control, [self()]},
         transport: MockTransport,
         config: %{profile: "worker_test_events", test_pid: self()}}
      )

    send(pid, {:amarula, :connection_update, %{connection: :open}})

    assert_receive {:control, %{event: :connection_update, data: %{connection: :open}}, []}
    refute_receive {:sink_emit, _, _}
    assert :sys.get_state(pid).last_result == nil
  end

  test "emits messages_upsert entries as payload messages" do
    {:ok, pid} =
      start_supervised(
        {ConnectionWorker,
         bridge_id: "bridge_whatsapp",
         sink_mfa: {Sink, :emit, [self()]},
         control_mfa: {Sink, :control, [self()]},
         transport: MockTransport,
         config: %{profile: "worker_test_messages", test_pid: self()}}
      )

    msg = %Msg{
      id: "msg-1",
      channel: Address.pn("15551234567"),
      from: Address.pn("15557654321"),
      to: Address.pn("15551234567"),
      from_me: false,
      pushname: "Alice",
      timestamp: 1_706_745_600,
      type: :text,
      content: "hello",
      raw: %Proto.Message{}
    }

    send(pid, {:amarula, :messages_upsert, %{id: "batch-1", from: Address.pn("15557654321"), messages: [msg]}})

    assert_receive {:sink_emit, %Jido.Chat.Delivery{signals: [fact]}, opts}
    assert fact.type == "jido.chat.message.received"
    assert fact.data["message_id"] == "msg-1" and fact.data["room_id"] == "15551234567@s.whatsapp.net"
    assert opts[:path] == "/whatsapp/messages_upsert"
    assert :sys.get_state(pid).last_result == {:ok, :accepted}
  end

  test "emits pairing and error lifecycle events and ignores unsupported events" do
    {:ok, pid} =
      start_supervised(
        {ConnectionWorker,
         bridge_id: "bridge_whatsapp",
         sink_mfa: {Sink, :emit, [self()]},
         control_mfa: {Sink, :control, [self()]},
         transport: MockTransport,
         config: %{profile: "worker_test_lifecycle", test_pid: self()}}
      )

    controls = [
      {:pairing_code, %{code: "12345678"}},
      {:pairing_success, %{via: :link_code}},
      {:pairing_failure, %{reason: :timeout}},
      {:call_update, %{status: :offer}},
      {:history_sync, %{chats: []}},
      {:connection_update, %{qr: "qr-data"}},
      {:error, :boom}
    ]

    for {event, data} <- controls do
      send(pid, {:amarula, event, data})
      assert_receive {:control, %{event: ^event, data: ^data, profile: "worker_test_lifecycle"}, []}
    end

    send(pid, {:amarula, :contacts_update, []})
    assert :sys.get_state(pid).last_control.event == :error
    refute_receive {:sink_emit, _, _}
    refute_receive {:control, _, _}
  end
end
