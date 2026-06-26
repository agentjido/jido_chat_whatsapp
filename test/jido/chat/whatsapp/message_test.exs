defmodule Jido.Chat.WhatsApp.MessageTest do
  use ExUnit.Case, async: true

  alias Amarula.Address
  alias Amarula.Protocol.Proto
  alias Jido.Chat.ReactionEvent
  alias Jido.Chat.WhatsApp.Message

  test "address_to_jid/1 handles common address shapes" do
    assert Message.address_to_jid(nil) == nil
    assert Message.address_to_jid("") == nil
    assert Message.address_to_jid("15551234567@s.whatsapp.net") == "15551234567@s.whatsapp.net"
    assert Message.address_to_jid(Address.pn("15551234567")) == "15551234567@s.whatsapp.net"
    assert Message.address_to_jid(%{user: "abc", kind: :lid}) == "abc@lid"
    assert Message.address_to_jid(%{"user" => "120363", "kind" => "group"}) == "120363@g.us"
    assert Message.address_to_jid(%{user: "15551234567", kind: :pn, device: 2}) == "15551234567:2@s.whatsapp.net"
    assert Message.address_to_jid(%{user: "", kind: :pn}) == nil
    assert Message.address_to_jid(%{user: "x", kind: :none}) == nil
    assert Message.address_to_jid(:not_an_address) == nil
  end

  test "to_payload/2 converts Amarula message structs into plain maps" do
    msg = %Amarula.Msg{
      id: "msg-1",
      channel: Address.pn("15551234567"),
      from: Address.pn("15557654321"),
      to: Address.pn("15551234567"),
      from_me: false,
      pushname: "Alice",
      timestamp: 1_706_745_600,
      type: :text,
      content: "hello",
      quoted: %{id: "q1", from: Address.pn("15550000000"), channel: Address.pn("15551234567")},
      mentions: [Address.pn("15559990000")],
      raw: %Proto.Message{}
    }

    payload = Message.to_payload(msg, %{batch_id: "batch-1"})

    assert payload.channel_jid == "15551234567@s.whatsapp.net"
    assert payload.from_jid == "15557654321@s.whatsapp.net"
    assert payload.text == "hello"
    assert payload.quoted.id == "q1"
    assert payload.mentions == ["15559990000@s.whatsapp.net"]
    assert payload.metadata.batch_id == "batch-1"
  end

  test "incoming_attrs/1 rejects payloads without channels" do
    assert {:error, :missing_channel} = Message.incoming_attrs(%{id: "msg-1", type: :text, text: "hello"})
  end

  test "incoming_attrs/1 normalizes groups, quoted messages, and metadata" do
    assert {:ok, attrs} =
             Message.incoming_attrs(%{
               "id" => "msg-1",
               "channel_jid" => "120363@g.us",
               "from_jid" => "15557654321@s.whatsapp.net",
               "to_jid" => "120363@g.us",
               "from_me" => "1",
               "pushname" => "Alice",
               "timestamp" => "1706745600",
               "type" => "text",
               "text" => "hello",
               "quoted" => %{"id" => "quoted-1"}
             })

    assert attrs.external_room_id == "120363@g.us"
    assert attrs.external_reply_to_id == "quoted-1"
    assert attrs.timestamp == 1_706_745_600
    assert attrs.chat_type == :group
    assert attrs.metadata.from_me == true
  end

  test "incoming_attrs/1 derives media metadata" do
    assert {:ok, attrs} =
             Message.incoming_attrs(%{
               id: "media-1",
               channel_jid: "15551234567@s.whatsapp.net",
               from_jid: "15557654321@s.whatsapp.net",
               type: :media,
               content: %{
                 kind: :sticker,
                 mimetype: "image/webp",
                 caption: "caption",
                 file_name: "sticker.webp",
                 file_length: 100,
                 seconds: 3
               }
             })

    assert attrs.text == "caption"
    assert [%{kind: :image, filename: "sticker.webp", duration: 3}] = attrs.media

    assert {:ok, attrs} =
             Message.incoming_attrs(%{
               id: "media-2",
               channel: %{user: "120363", kind: :group},
               from: %{user: "15557654321", kind: :pn},
               to: %{user: "120363", kind: :group},
               timestamp: "not-an-integer",
               type: "media",
               content: %{
                 "kind" => "document",
                 "media_type" => "application/pdf",
                 "filename" => "guide.pdf",
                 "size_bytes" => 200,
                 "duration" => 7
               }
             })

    assert attrs.timestamp == "not-an-integer"
    assert attrs.channel_meta.metadata.to_jid == "120363@g.us"

    assert [%{kind: :file, filename: "guide.pdf", media_type: "application/pdf", size_bytes: 200, duration: 7}] =
             attrs.media
  end

  test "reaction_event/1 supports map and tuple keys" do
    assert {:ok, %ReactionEvent{} = reaction} =
             Message.reaction_event(%{
               channel_jid: "15551234567@s.whatsapp.net",
               from_jid: "15557654321@s.whatsapp.net",
               type: :reaction,
               content: %{key: %{jid: "15551234567@s.whatsapp.net", id: "target-1"}, emoji: "ok"}
             })

    assert reaction.message_id == "target-1"
    assert reaction.added == true

    assert {:ok, %ReactionEvent{} = removed} =
             Message.reaction_event(%{
               channel_jid: "15551234567@s.whatsapp.net",
               from_jid: "15557654321@s.whatsapp.net",
               type: :reaction,
               content: %{key: {"15551234567@s.whatsapp.net", "target-2"}, emoji: ""}
             })

    assert removed.message_id == "target-2"
    assert removed.added == false

    assert {:ok, %ReactionEvent{} = string_key} =
             Message.reaction_event(%{
               "channel_jid" => "15551234567@s.whatsapp.net",
               "type" => "reaction",
               "content" => %{"key" => %{"jid" => "15551234567@s.whatsapp.net", "id" => "target-3"}, "emoji" => "ok"}
             })

    assert string_key.message_id == "target-3"

    assert {:ok, %ReactionEvent{} = fallback} =
             Message.reaction_event(%{
               id: "target-4",
               channel_jid: "15551234567@s.whatsapp.net",
               type: :reaction,
               content: %{emoji: "ok"}
             })

    assert fallback.user.user_id == "unknown"
    assert fallback.message_id == "target-4"
  end

  test "reaction_event/1 rejects missing reaction targets" do
    assert {:error, :missing_reaction_target} =
             Message.reaction_event(%{
               from_jid: "15557654321@s.whatsapp.net",
               type: :reaction,
               content: %{emoji: "ok"}
             })
  end
end
