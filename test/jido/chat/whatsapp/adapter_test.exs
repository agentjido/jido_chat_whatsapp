defmodule Jido.Chat.WhatsApp.AdapterTest do
  use Jido.Chat.AdapterTestKit, adapter: Jido.Chat.WhatsApp.Adapter, async: true

  alias Jido.Chat
  alias Jido.Chat.Adapter, as: ChatAdapter
  alias Jido.Chat.Client
  alias Jido.Chat.WhatsApp
  alias Jido.Chat.WhatsApp.{Adapter, Source, TestTransport}

  @room "15551234567@s.whatsapp.net"

  defp client do
    Client.new!(Adapter,
      id: "whatsapp-#{System.unique_integer([:positive])}",
      config: [profile: "test-profile"],
      transport: TestTransport
    )
  end

  defp private, do: [options: [conn: self()]]

  test "client discovery is local and explicit" do
    value = client()

    assert WhatsApp.adapter() == Adapter
    assert WhatsApp.source() == Source
    assert Adapter.default_transport() == Jido.Chat.WhatsApp.Transport.AmarulaClient
    assert :ok = ChatAdapter.validate_capabilities(Adapter)
    assert Source.mode() == :push
    assert Source.key(value, []) == Source.key(value, profile: "test-profile")
  end

  test "message, stream, edit, delete, typing, and reactions use the selected connection" do
    value = client()

    assert {:ok, sent} = Chat.send_text(value, @room, "**hello**", private() ++ [format: :markdown])
    assert sent.data["result"]["id"] == "wamid.text"
    assert_receive {:send_text, _, @room, "*hello*", []}

    assert {:ok, streamed} = Chat.stream_text(value, @room, ["a", "b"], private())
    assert streamed.data["result"]["text"] == "ab"
    assert_receive {:send_text, _, @room, "ab", []}

    assert {:ok, edited} = Chat.edit_message(value, @room, "m-1", "fixed", private())
    assert edited.data["result"]["status"] == "updated"
    assert_receive {:send_edit, _, {@room, "m-1", true}, "fixed"}

    assert {:ok, deleted} = Chat.delete_message(value, @room, "m-1", private())
    assert deleted.data["result"] == %{"acknowledged" => true}
    assert_receive {:send_revoke, _, {@room, "m-1", true}}

    assert {:ok, typed} = Chat.start_typing(value, @room, private())
    assert typed.data["result"] == %{"acknowledged" => true}
    assert_receive {:send_chatstate, _, @room, :composing}

    assert {:ok, _} = Chat.add_reaction(value, @room, "m-1", "👍", private())
    assert_receive {:send_reaction, _, {@room, "m-1", false}, "👍"}

    assert {:ok, _} = Chat.remove_reaction(value, @room, "m-1", "👍", private())
    assert_receive {:send_reaction, _, {@room, "m-1", false}, ""}
  end

  test "files and client-scoped media downloads return canonical results" do
    value = client()
    source = %{"content_base64" => Base.encode64("image bytes"), "filename" => "photo.jpg"}

    assert {:ok, sent} =
             Chat.send_file(value, @room, source, private() ++ [caption: "photo", media_kind: :image])

    assert sent.data["result"]["id"] == "wamid.media"
    assert_receive {:send_media, _, @room, :image, "image bytes", media_opts}
    assert media_opts[:caption] == "photo"
    assert media_opts[:file_name] == "photo.jpg"

    reference = %{
      "client_id" => value.id,
      "kind" => "media",
      "id" => "whatsapp://media/v1/test-reference"
    }

    assert {:ok, downloaded} = Chat.download_file(value, reference, private())
    assert downloaded.data["result"]["content_base64"] == Base.encode64("whatsapp media bytes")
    assert_receive {:download_media, %Amarula.Content.Media{kind: :image}}

    assert {:error, _} = Chat.download_file(value, Map.put(reference, "client_id", "other"), private())
    refute_receive {:download_media, _}
  end

  test "local metadata, thread, user, and direct-message operations are canonical" do
    value = client()

    assert {:ok, metadata} = Chat.fetch_metadata(value, @room)
    assert metadata.data["result"] == %{"id" => @room, "kind" => "direct"}

    thread = operation_request(value, :fetch_thread, %{"room_id" => @room, "thread_id" => "reply-1"})
    assert {:ok, thread_result} = Chat.execute(value, thread)
    assert thread_result.data["result"]["delivery_room_ref"] == @room

    user = operation_request(value, :get_user, %{"user_id" => @room})
    assert {:ok, user_result} = Chat.execute(value, user, private())
    assert user_result.data["result"] == %{"id" => @room, "username" => "+15551234567"}

    dm = operation_request(value, :open_dm, %{"user_id" => "15550001111"})
    assert {:ok, dm_result} = Chat.execute(value, dm)
    assert dm_result.data["result"] == %{"id" => "15550001111@s.whatsapp.net", "kind" => "direct"}
  end

  test "normalization emits stable message, reaction, and failure facts" do
    value = client()

    payload = %{
      id: "m-1",
      channel_jid: @room,
      from_jid: "15550002222@s.whatsapp.net",
      type: :text,
      text: "hello",
      content: "hello",
      timestamp: 1_700_000_000
    }

    assert {:ok, first} = Chat.normalize(value, payload)
    assert {:ok, second} = Chat.normalize(value, payload)
    assert first.id == second.id
    assert [message] = first.signals
    assert message.type == "jido.chat.message.received"
    assert message.data["room_id"] == @room
    assert message.data["sender"]["id"] == "15550002222@s.whatsapp.net"

    reaction = %{
      id: "reaction-wire",
      channel_jid: @room,
      from_jid: "15550002222@s.whatsapp.net",
      type: :reaction,
      content: %{key: %{jid: @room, id: "m-1"}, emoji: "👍"}
    }

    assert {:ok, delivery} = Chat.normalize(value, reaction)
    assert [fact] = delivery.signals
    assert fact.type == "jido.chat.reaction.added"
    assert fact.data["message_id"] == "m-1"

    assert {:ok, failed} = Chat.normalize(value, %{type: :unknown})
    assert [failure] = failed.signals
    assert failure.type == "jido.chat.normalization.failed"
  end

  test "media normalization exposes only an opaque client-scoped reference" do
    value = client()

    payload = %{
      id: "media-1",
      channel_jid: @room,
      from_jid: "15550002222@s.whatsapp.net",
      type: :media,
      content: %{
        kind: :image,
        mimetype: "image/jpeg",
        media_key: :binary.copy(<<1>>, 32),
        direct_path: "/media/private",
        url: "https://mmg.whatsapp.net/private?token=secret",
        file_sha256: :binary.copy(<<2>>, 32),
        file_enc_sha256: :binary.copy(<<3>>, 32)
      }
    }

    assert {:ok, delivery} = Chat.normalize(value, payload, conn: self())
    assert [signal] = delivery.signals
    assert [media] = signal.data["media"]

    assert media["resource_ref"] == %{
             "client_id" => value.id,
             "kind" => "media",
             "id" => "whatsapp://media/v1/test-reference"
           }

    encoded = Jason.encode!(Jido.Signal.Codec.to_map(signal))
    refute encoded =~ "token=secret"
    refute encoded =~ "media_key"
  end

  test "unsupported operations do not attempt provider I/O" do
    value = client()
    request = operation_request(value, :fetch_messages, %{"room_id" => @room})

    assert {:error, {:not_attempted, :unsupported}} = Adapter.invoke(value, request, [])
    refute_receive _
  end
end
