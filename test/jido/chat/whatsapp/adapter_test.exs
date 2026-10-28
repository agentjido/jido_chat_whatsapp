defmodule Jido.Chat.WhatsApp.AdapterTest do
  use Jido.Chat.AdapterTestKit, adapter: Jido.Chat.WhatsApp.Adapter

  alias Jido.Chat.WhatsApp.Adapter

  defmodule FakeTransport do
    @behaviour Jido.Chat.WhatsApp.Transport
    def ensure_started(_), do: :ok
    def connect(_, _), do: {:ok, self()}
    def stop(_, _), do: :ok
    def render_qr(_, _), do: {:ok, "qr"}
    def resolve_conn(_), do: {:ok, self()}
    def send_text(_, _, _, _), do: {:ok, "m1"}
    def send_media(_, _, _, _, _), do: {:ok, "m2"}
    def download_media(_), do: {:error, :unused}
    def send_reaction(_, _, _), do: {:ok, "r1"}
    def send_edit(_, _, _), do: {:ok, "m3"}
    def send_revoke(_, _), do: {:ok, "m4"}
    def send_chatstate(_, _, _), do: :ok
    def request_pairing_code(_, _, _), do: {:ok, "12345678"}
  end

  setup do
    %{client: Jido.Chat.Client.new!(Adapter, id: "whatsapp-test", transport: FakeTransport)}
  end

  test "runs linked-device message operations through Chat Actions", %{client: client} do
    room = "15551234567@s.whatsapp.net"
    assert {:ok, sent} = Jido.Chat.send_text(client, room, "hello")
    assert sent.data["result"]["id"] == "m1"
    assert {:ok, edited} = Jido.Chat.edit_message(client, room, "m1", "edited")
    assert edited.data["result"]["id"] == "m3"
    assert {:ok, deleted} = Jido.Chat.delete_message(client, room, "m1")
    assert deleted.data["result"] == %{"acknowledged" => true}
  end

  test "normalizes linked-device messages with stable identities", %{client: client} do
    payload = %{
      id: "m1",
      channel_jid: "15551234567@s.whatsapp.net",
      from_jid: "15557654321@s.whatsapp.net",
      type: :text,
      text: "hello",
      timestamp: 1_706_745_600
    }

    assert {:ok, first} = Jido.Chat.normalize(client, payload)
    assert {:ok, second} = Jido.Chat.normalize(client, payload)
    assert first.id == second.id
    assert [signal] = first.signals
    assert signal.data["message_id"] == "m1"
    assert signal.data["conversation_kind"] == "direct"
  end
end
