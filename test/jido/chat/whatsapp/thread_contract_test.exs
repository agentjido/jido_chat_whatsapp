defmodule Jido.Chat.WhatsApp.ThreadContractTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Amarula.{Address, Msg}
  alias Amarula.Protocol.Proto
  alias Jido.Chat.WebhookRequest
  alias Jido.Chat.WhatsApp.{Adapter, Message}

  test "reply targets populate incoming, channel metadata and event routing" do
    for room <- ["group@g.us", "123@s.whatsapp.net", "456@lid"] do
      payload = payload(room, %{id: "root", text: "INLINE_TEXT"})
      assert {:ok, event} = Adapter.parse_event(WebhookRequest.new(%{payload: payload}))
      assert event.thread_id == "whatsapp:#{room}:root"
      assert event.channel_id == room
      assert event.message_id == "reply"
      assert event.payload.external_thread_id == "root"
      assert event.payload.channel_meta.external_thread_id == "root"
      assert event.payload.external_room_id == room
      assert event.payload.delivery_external_room_id == room
      assert event.payload.text == "Question"
      assert event.payload.reply_context == nil
      assert event.payload.external_reply_to_id == nil
    end
  end

  test "Amarula payloads and string-keyed references use the immediate target" do
    message = %Msg{
      id: "reply",
      channel: Address.group("123"),
      from: Address.pn("456"),
      type: :text,
      content: "Question",
      quoted: %{id: "root", channel: Address.group("123"), from: Address.pn("789")},
      raw: %Proto.Message{}
    }

    assert {:ok, attrs} = Message.incoming_attrs(message)
    assert attrs.external_thread_id == "root"
    refute Map.has_key?(attrs, :reply_context)
    refute Map.has_key?(attrs, :external_reply_to_id)

    assert {:ok, incoming} =
             Adapter.transform_incoming(%{
               "channel_jid" => "123@g.us",
               "text" => "Question",
               "quoted" => %{"id" => "root", "channel_jid" => "123@g.us"}
             })

    assert incoming.external_thread_id == "root"
  end

  test "a reply to a reply starts at its immediate target without resolving an ancestor" do
    assert {:ok, first} = Adapter.transform_incoming(payload("group@g.us", %{id: "A"}))
    assert {:ok, second} = Adapter.transform_incoming(payload("group@g.us", %{id: "B"}))
    assert first.external_thread_id == "A"
    assert second.external_thread_id == "B"
  end

  test "missing, malformed and conflicting targets retain ordinary chat routing" do
    invalid = [
      nil,
      :invalid,
      [],
      %{},
      %{id: nil},
      %{id: ""},
      %{id: "  "},
      %{id: 12},
      %{id: <<255>>},
      %{id: String.duplicate("x", 1_025)},
      %{id: "root", channel_jid: "other@g.us"},
      %{id: "root", channel: :invalid}
    ]

    for quoted <- invalid do
      request = WebhookRequest.new(%{payload: payload("group@g.us", quoted)})
      assert {:ok, event} = Adapter.parse_event(request)
      assert event.thread_id == "whatsapp:group@g.us"
      assert event.payload.external_thread_id == nil
      assert event.payload.channel_meta.external_thread_id == nil
      assert event.payload.text == "Question"
    end
  end

  property "valid target IDs are preserved exactly and stay scoped to their chat" do
    check all(id <- string(:alphanumeric, min_length: 1, max_length: 80)) do
      assert {:ok, first} = Message.incoming_attrs(payload("first@g.us", %{id: id}))
      assert {:ok, second} = Message.incoming_attrs(payload("second@g.us", %{id: id}))
      assert first.external_thread_id == id
      assert second.external_thread_id == id
      assert Message.thread_id(first.external_room_id, id) != Message.thread_id(second.external_room_id, id)
      assert Message.incoming_attrs(payload("first@g.us", %{id: id})) == {:ok, first}
    end
  end

  test "thread targets respect the persisted identifier size boundary" do
    valid = String.duplicate("x", 255)
    assert {:ok, attrs} = Message.incoming_attrs(payload("group@g.us", %{id: valid}))
    assert attrs.external_thread_id == valid

    for invalid <- [valid <> "x", String.duplicate("é", 128)] do
      assert {:ok, attrs} = Message.incoming_attrs(payload("group@g.us", %{id: invalid}))
      assert attrs.external_thread_id == nil
      assert attrs.channel_meta.external_thread_id == nil
    end
  end

  property "arbitrary non-string target IDs never create a thread" do
    check all(id <- one_of([integer(), list_of(integer(), max_length: 5), boolean()])) do
      assert {:ok, attrs} = Message.incoming_attrs(payload("group@g.us", %{id: id}))
      assert attrs.external_thread_id == nil
      assert attrs.channel_meta.external_thread_id == nil
    end
  end

  defp payload(room, quoted) do
    %{id: "reply", channel_jid: room, from_jid: "123@s.whatsapp.net", type: :text, text: "Question", quoted: quoted}
  end
end
