defmodule Jido.Chat.WhatsApp.PreviewIntegrationTest do
  import Jido.Chat.WhatsApp.TestHelpers
  use ExUnit.Case, async: false

  alias Amarula.Address
  alias Jido.Chat.Incoming
  alias Jido.Chat.WhatsApp.{Adapter, ConnectionWorker}

  defmodule IngressTransport do
    use Jido.Chat.WhatsApp.TransportStub

    @impl true
    def connect(config, opts) do
      send(Map.fetch!(config, :test_pid), {:transport_connected, opts[:parent]})
      {:ok, self()}
    end
  end

  defmodule OutboundTransport do
    use Jido.Chat.WhatsApp.TransportStub

    @impl true
    def resolve_conn(opts), do: Keyword.fetch(opts, :conn)

    @impl true
    def send_text(conn, jid, text, opts) do
      send(conn, {:reply_sent, jid, text, opts})
      {:ok, "wamid.local-reply"}
    end
  end

  defmodule ReplySink do
    def emit(test_pid, %Jido.Chat.EventEnvelope{} = envelope, _opts) do
      chat =
        Jido.Chat.new(adapters: %{whatsapp: Adapter})
        |> Jido.Chat.on_action("connection_update", fn action ->
          send(test_pid, {:lifecycle_action, action})
        end)

      Jido.Chat.route_event(chat, :whatsapp, envelope)
    end

    def emit(test_pid, payload, opts) do
      with {:ok, %Incoming{} = incoming} <- Adapter.transform_incoming(payload),
           {:ok, response} <-
             Adapter.send_message(
               incoming.delivery_external_room_id,
               "reply: #{incoming.text}",
               conn: test_pid,
               transport: OutboundTransport,
               quoted: {incoming.external_message_id, incoming.external_user_id}
             ) do
        send(test_pid, {:incoming_normalized, incoming, opts, response})
        {:ok, :accepted}
      end
    end
  end

  test "receives, normalizes, and replies through the adapter boundary" do
    {:ok, _worker} =
      start_supervised(
        {ConnectionWorker,
         bridge_id: "bridge_whatsapp_preview",
         sink_mfa: {ReplySink, :emit, [self()]},
         transport: IngressTransport,
         config: %{profile: "preview_local", test_pid: self()}}
      )

    assert_receive {:transport_connected, parent}
    send(parent, {:amarula, :connection_update, %{connection: :open}})
    assert_receive {:lifecycle_action, %Jido.Chat.ActionEvent{metadata: %{status: :connected}}}
    refute_received {:reply_sent, _, _, _}

    incoming_message =
      message(
        id: "wamid.inbound",
        channel: Address.group("120363000000000000"),
        from: Address.pn("15557654321"),
        to: Address.group("120363000000000000"),
        from_me: false,
        pushname: "Alice",
        timestamp: 1_706_745_600
      )

    send(
      parent,
      {:amarula, :messages_upsert, %{id: "batch-preview", from: incoming_message.from, messages: [incoming_message]}}
    )

    assert_receive {:reply_sent, "120363000000000000@g.us", "reply: hello", send_opts}

    assert send_opts[:quoted] ==
             {"wamid.inbound", "15557654321@s.whatsapp.net"}

    assert_receive {:incoming_normalized, %Incoming{} = incoming, sink_opts, response}
    assert incoming.external_message_id == "wamid.inbound"
    assert incoming.delivery_external_room_id == "120363000000000000@g.us"
    assert incoming.external_user_id == "15557654321@s.whatsapp.net"
    assert incoming.text == "hello"
    assert sink_opts[:path] == "/whatsapp/messages_upsert"
    assert sink_opts[:method] == "WHATSAPP"
    assert response.external_message_id == "wamid.local-reply"
    assert response.status == :sent
  end
end
