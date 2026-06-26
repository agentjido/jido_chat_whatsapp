defmodule Jido.Chat.WhatsApp.ConnectionWorkerTest do
  use ExUnit.Case, async: false

  alias Jido.Chat.EventEnvelope
  alias Jido.Chat.WhatsApp.ConnectionWorker
  alias Amarula.{Address, Msg}
  alias Amarula.Protocol.Proto

  defmodule Sink do
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
         transport: MockTransport,
         config: %{profile: "worker_test_events", test_pid: self()}}
      )

    send(pid, {:amarula, :connection_update, %{connection: :open}})

    assert_receive {:sink_emit, %EventEnvelope{} = envelope, opts}
    assert envelope.event_type == :action
    assert envelope.payload.action_id == "connection_update"
    assert envelope.payload.value == "open"
    assert opts[:mode] == :payload
  end

  test "emits messages_upsert entries as payload messages" do
    {:ok, pid} =
      start_supervised(
        {ConnectionWorker,
         bridge_id: "bridge_whatsapp",
         sink_mfa: {Sink, :emit, [self()]},
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

    assert_receive {:sink_emit, %{id: "msg-1", channel_jid: "15551234567@s.whatsapp.net"} = payload, opts}
    assert payload.metadata.batch_id == "batch-1"
    assert opts[:path] == "/whatsapp/messages_upsert"
  end

  test "emits pairing and error lifecycle events and ignores unsupported events" do
    {:ok, pid} =
      start_supervised(
        {ConnectionWorker,
         bridge_id: "bridge_whatsapp",
         sink_mfa: {Sink, :emit, [self()]},
         transport: MockTransport,
         config: %{profile: "worker_test_lifecycle", test_pid: self()}}
      )

    send(pid, {:amarula, :pairing_code, %{code: "12345678"}})
    assert_receive {:sink_emit, %EventEnvelope{} = pairing, pairing_opts}
    assert pairing.payload.action_id == "pairing_code"
    assert pairing.payload.value == "12345678"
    assert pairing_opts[:path] == "/whatsapp/pairing_code"

    send(pid, {:amarula, :pairing_success, %{via: :link_code}})
    assert_receive {:sink_emit, %EventEnvelope{} = success, _opts}
    assert success.payload.action_id == "pairing_success"

    send(pid, {:amarula, :connection_update, %{qr: "qr-data"}})
    assert_receive {:sink_emit, %EventEnvelope{} = qr, _opts}
    assert qr.payload.action_id == "connection_update"
    assert qr.payload.value == "qr"

    send(pid, {:amarula, :error, :boom})
    assert_receive {:sink_emit, %EventEnvelope{} = error, _opts}
    assert error.payload.action_id == "error"
    assert error.payload.value == ":boom"
    assert error.raw == %{value: ":boom"}

    send(pid, {:amarula, :contacts_update, []})
    refute_receive {:sink_emit, _, _}, 50
  end
end
