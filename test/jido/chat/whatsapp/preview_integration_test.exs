defmodule Jido.Chat.WhatsApp.PreviewIntegrationTest do
  use ExUnit.Case, async: false

  alias Amarula.{Address, Msg}
  alias Amarula.Protocol.Proto
  alias Jido.Chat.Incoming
  alias Jido.Chat.WhatsApp.{Adapter, ConnectionWorker}

  defmodule IngressTransport do
    @behaviour Jido.Chat.WhatsApp.Transport

    @impl true
    def connect(config, opts) do
      send(Map.fetch!(config, :test_pid), {:transport_connected, opts[:parent]})
      {:ok, self()}
    end

    @impl true
    def resolve_conn(_opts), do: {:error, :not_used}

    @impl true
    def send_text(_conn, _jid, _text, _opts), do: {:error, :not_used}

    @impl true
    def send_media(_conn, _jid, _media_type, _data, _opts), do: {:error, :not_used}

    @impl true
    def download_media(_media), do: {:error, :not_used}

    @impl true
    def send_reaction(_conn, _message_ref, _emoji), do: {:error, :not_used}

    @impl true
    def send_edit(_conn, _message_ref, _text), do: {:error, :not_used}

    @impl true
    def send_revoke(_conn, _message_ref), do: {:error, :not_used}

    @impl true
    def send_chatstate(_conn, _jid, _state), do: {:error, :not_used}

    @impl true
    def request_pairing_code(_conn, _phone, _opts), do: {:error, :not_used}
  end

  defmodule OutboundTransport do
    @behaviour Jido.Chat.WhatsApp.Transport

    @impl true
    def connect(_config, _opts), do: {:error, :not_used}

    @impl true
    def resolve_conn(opts), do: Keyword.fetch(opts, :conn)

    @impl true
    def send_text(conn, jid, text, opts) do
      send(conn, {:reply_sent, jid, text, opts})
      {:ok, "wamid.local-reply"}
    end

    @impl true
    def send_media(_conn, _jid, _media_type, _data, _opts), do: {:error, :not_used}

    @impl true
    def download_media(_media), do: {:error, :not_used}

    @impl true
    def send_reaction(_conn, _message_ref, _emoji), do: {:error, :not_used}

    @impl true
    def send_edit(_conn, _message_ref, _text), do: {:error, :not_used}

    @impl true
    def send_revoke(_conn, _message_ref), do: {:error, :not_used}

    @impl true
    def send_chatstate(_conn, _jid, _state), do: {:error, :not_used}

    @impl true
    def request_pairing_code(_conn, _phone, _opts), do: {:error, :not_used}
  end

  defmodule ReplySink do
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
    {:ok, worker} =
      start_supervised(
        {ConnectionWorker,
         bridge_id: "bridge_whatsapp_preview",
         sink_mfa: {ReplySink, :emit, [self()]},
         transport: IngressTransport,
         config: %{profile: "preview_local", test_pid: self()}}
      )

    assert_receive {:transport_connected, ^worker}

    incoming_message = %Msg{
      id: "wamid.inbound",
      channel: Address.group("120363000000000000"),
      from: Address.pn("15557654321"),
      to: Address.group("120363000000000000"),
      from_me: false,
      pushname: "Alice",
      timestamp: 1_706_745_600,
      type: :text,
      content: "hello",
      raw: %Proto.Message{}
    }

    send(
      worker,
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
