defmodule Jido.Chat.WhatsApp.AdapterTest do
  use ExUnit.Case, async: true

  alias Jido.Chat
  alias Jido.Chat.{EventEnvelope, ReactionEvent}
  alias Jido.Chat.WhatsApp.Adapter

  defmodule MockTransport do
    @behaviour Jido.Chat.WhatsApp.Transport

    @impl true
    def connect(config, opts) do
      send(self(), {:connect, config, opts})
      {:ok, self()}
    end

    @impl true
    def resolve_conn(opts) do
      send(self(), {:resolve_conn, opts})
      {:ok, Keyword.get(opts, :conn, self())}
    end

    @impl true
    def send_text(conn, jid, text, opts) do
      send(self(), {:send_text, conn, jid, text, opts})
      {:ok, "wamid.text"}
    end

    @impl true
    def send_media(conn, jid, media_type, data, opts) do
      send(self(), {:send_media, conn, jid, media_type, data, opts})
      {:ok, "wamid.media"}
    end

    @impl true
    def send_reaction(conn, message_ref, emoji) do
      send(self(), {:send_reaction, conn, message_ref, emoji})
      {:ok, "wamid.reaction"}
    end

    @impl true
    def send_edit(conn, message_ref, text) do
      send(self(), {:send_edit, conn, message_ref, text})
      {:ok, "wamid.edit"}
    end

    @impl true
    def send_revoke(conn, message_ref) do
      send(self(), {:send_revoke, conn, message_ref})
      {:ok, "wamid.revoke"}
    end

    @impl true
    def send_chatstate(conn, jid, state) do
      send(self(), {:send_chatstate, conn, jid, state})
      :ok
    end

    @impl true
    def request_pairing_code(conn, phone, opts) do
      send(self(), {:request_pairing_code, conn, phone, opts})
      {:ok, "12345678"}
    end
  end

  test "capabilities matrix declares supported surfaces" do
    caps = Adapter.capabilities()

    assert Adapter.channel_type() == :whatsapp
    assert caps.send_message == :native
    assert caps.send_file == :native
    assert caps.parse_event == :native
    assert caps.fetch_messages == :unsupported

    assert :ok = Chat.Adapter.validate_capabilities(Adapter)
  end

  test "transform_incoming/1 normalizes text payloads" do
    payload = %{
      id: "msg-1",
      channel_jid: "15551234567@s.whatsapp.net",
      from_jid: "15557654321@s.whatsapp.net",
      to_jid: "15551234567@s.whatsapp.net",
      from_me: false,
      pushname: "Alice",
      timestamp: 1_706_745_600,
      type: :text,
      content: "hello",
      text: "hello"
    }

    assert {:ok, incoming} = Adapter.transform_incoming(payload)
    assert incoming.external_room_id == "15551234567@s.whatsapp.net"
    assert incoming.external_user_id == "15557654321@s.whatsapp.net"
    assert incoming.text == "hello"
    assert incoming.chat_type == :dm
    assert incoming.channel_meta.adapter_name == :whatsapp
    assert incoming.channel_meta.is_dm == true
  end

  test "transform_incoming/1 normalizes media payloads" do
    payload = %{
      "id" => "msg-2",
      "channel_jid" => "120363000000000000@g.us",
      "from_jid" => "15557654321@s.whatsapp.net",
      "type" => "media",
      "content" => %{
        "kind" => "image",
        "mimetype" => "image/jpeg",
        "caption" => "look",
        "file_length" => 123,
        "width" => 640,
        "height" => 480
      }
    }

    assert {:ok, incoming} = Adapter.transform_incoming(payload)
    assert incoming.chat_type == :group
    assert incoming.text == "look"
    assert [%{kind: :image, media_type: "image/jpeg", size_bytes: 123}] = incoming.media
  end

  test "transform_incoming/1 handles wrapped and unsupported payloads" do
    payload = %{
      message: %{
        id: "msg-1",
        channel_jid: "15551234567@s.whatsapp.net",
        from_jid: "15557654321@s.whatsapp.net",
        type: :text,
        text: "hello"
      }
    }

    assert {:ok, incoming} = Adapter.transform_incoming(payload)
    assert incoming.text == "hello"

    assert {:ok, incoming} =
             Adapter.transform_incoming(%{
               "message" => %{
                 "id" => "msg-2",
                 "channel_jid" => "15551234567@s.whatsapp.net",
                 "from_jid" => "15557654321@s.whatsapp.net",
                 "type" => "text",
                 "text" => "from string wrapper"
               }
             })

    assert incoming.text == "from string wrapper"

    assert {:error, :unsupported_message_type} = Adapter.transform_incoming(:not_a_payload)
    assert {:error, :missing_channel} = Adapter.transform_incoming(%{id: "msg-1", text: "hello"})
  end

  test "parse_event/2 wraps messages in EventEnvelope" do
    request =
      Jido.Chat.WebhookRequest.new(%{
        adapter_name: :whatsapp,
        payload: %{
          id: "msg-1",
          channel_jid: "15551234567@s.whatsapp.net",
          from_jid: "15557654321@s.whatsapp.net",
          type: :text,
          text: "hello"
        }
      })

    assert {:ok, %EventEnvelope{} = envelope} = Adapter.parse_event(request)
    assert envelope.event_type == :message
    assert envelope.thread_id == "whatsapp:15551234567@s.whatsapp.net"
    assert envelope.payload.text == "hello"
  end

  test "parse_event/2 wraps reactions in ReactionEvent" do
    request =
      Jido.Chat.WebhookRequest.new(%{
        adapter_name: :whatsapp,
        payload: %{
          id: "reaction-msg",
          channel_jid: "15551234567@s.whatsapp.net",
          from_jid: "15557654321@s.whatsapp.net",
          type: :reaction,
          content: %{key: %{jid: "15551234567@s.whatsapp.net", id: "target-msg"}, emoji: "ok"}
        }
      })

    assert {:ok, %EventEnvelope{} = envelope} = Adapter.parse_event(request)
    assert envelope.event_type == :reaction
    assert %ReactionEvent{} = envelope.payload
    assert envelope.payload.message_id == "target-msg"
    assert envelope.payload.emoji == "ok"
  end

  test "parse_event/2 handles action payloads and existing envelopes as noops" do
    action_request =
      Jido.Chat.WebhookRequest.new(%{
        adapter_name: :whatsapp,
        payload: %{event: "connection_update", data: %{profile: "profile-1", connection: :open}}
      })

    assert {:ok, %EventEnvelope{} = action} = Adapter.parse_event(action_request)
    assert action.event_type == :action
    assert action.payload.action_id == "connection_update"
    assert action.payload.value == "open"

    qr_request =
      Jido.Chat.WebhookRequest.new(%{
        adapter_name: :whatsapp,
        payload: %{event: "connection_update", data: %{profile: "profile-1", qr: "qr-data"}}
      })

    assert {:ok, %EventEnvelope{} = qr} = Adapter.parse_event(qr_request)
    assert qr.payload.value == "qr"

    pairing_request =
      Jido.Chat.WebhookRequest.new(%{
        adapter_name: :whatsapp,
        payload: %{event: "pairing_code", data: %{profile: "profile-1", code: "12345678"}}
      })

    assert {:ok, %EventEnvelope{} = pairing} = Adapter.parse_event(pairing_request)
    assert pairing.payload.value == "12345678"

    fallback_request =
      Jido.Chat.WebhookRequest.new(%{
        adapter_name: :whatsapp,
        payload: %{event: "pairing_success", data: "paired"}
      })

    assert {:ok, %EventEnvelope{} = fallback} = Adapter.parse_event(fallback_request)
    assert fallback.payload.action_id == "pairing_success"
    assert fallback.payload.value == "pairing_success"
    assert fallback.raw == %{}

    noop_request =
      Jido.Chat.WebhookRequest.new(%{
        adapter_name: :whatsapp,
        payload: %{event_type: :message}
      })

    assert {:ok, :noop} = Adapter.parse_event(noop_request)
  end

  test "send_message/3 delegates to configured transport" do
    assert {:ok, response} =
             Adapter.send_message("15551234567", "hi",
               conn: self(),
               transport: MockTransport,
               mentions: ["15557654321@s.whatsapp.net"]
             )

    assert_receive {:resolve_conn, opts}
    assert opts[:conn] == self()

    assert_receive {:send_text, _, "15551234567@s.whatsapp.net", "hi", opts}
    assert opts[:mentions] == ["15557654321@s.whatsapp.net"]
    assert response.external_message_id == "wamid.text"
    assert response.external_room_id == "15551234567@s.whatsapp.net"
  end

  test "send_file/3 sends local file bytes through transport" do
    path = Path.join(System.tmp_dir!(), "jido_chat_whatsapp_test.txt")
    File.write!(path, "hello file")

    assert {:ok, response} =
             Adapter.send_file("15551234567@s.whatsapp.net", path,
               conn: self(),
               transport: MockTransport,
               caption: "file caption"
             )

    assert_receive {:send_media, _, "15551234567@s.whatsapp.net", :document, "hello file", opts}
    assert opts[:caption] == "file caption"
    assert response.external_message_id == "wamid.media"
  after
    File.rm(Path.join(System.tmp_dir!(), "jido_chat_whatsapp_test.txt"))
  end

  test "send_file/3 sends in-memory media and rejects remote upload references" do
    assert {:ok, response} =
             Adapter.send_file(
               "15551234567@s.whatsapp.net",
               %{data: "image-bytes", kind: :image, filename: "photo.jpg", media_type: "image/jpeg"},
               conn: self(),
               transport: MockTransport
             )

    assert_receive {:send_media, _, "15551234567@s.whatsapp.net", :image, "image-bytes", opts}
    assert opts[:file_name] == "photo.jpg"
    assert response.external_message_id == "wamid.media"

    assert {:error, {:unsupported_remote_upload, "https://example.com/photo.jpg"}} =
             Adapter.send_file(
               "15551234567@s.whatsapp.net",
               %{url: "https://example.com/photo.jpg", kind: :image, filename: "photo.jpg"},
               conn: self(),
               transport: MockTransport
             )

    assert {:error, :missing_upload_data} =
             Adapter.send_file(
               "15551234567@s.whatsapp.net",
               %{kind: :image, filename: "photo.jpg"},
               conn: self(),
               transport: MockTransport
             )
  end

  test "edit, delete, reaction, and typing delegate to transport" do
    assert {:ok, edited} =
             Adapter.edit_message("15551234567@s.whatsapp.net", "msg-1", "fixed",
               conn: self(),
               transport: MockTransport
             )

    assert edited.status == :edited
    assert_receive {:send_edit, _, {"15551234567@s.whatsapp.net", "msg-1"}, "fixed"}

    assert :ok =
             Adapter.delete_message("15551234567@s.whatsapp.net", "msg-1",
               conn: self(),
               transport: MockTransport
             )

    assert_receive {:send_revoke, _, {"15551234567@s.whatsapp.net", "msg-1"}}

    assert :ok =
             Adapter.add_reaction("15551234567@s.whatsapp.net", "msg-1", "ok",
               conn: self(),
               transport: MockTransport
             )

    assert_receive {:send_reaction, _, {"15551234567@s.whatsapp.net", "msg-1"}, "ok"}

    assert :ok =
             Adapter.remove_reaction("15551234567@s.whatsapp.net", "msg-1", "ok",
               conn: self(),
               transport: MockTransport
             )

    assert_receive {:send_reaction, _, {"15551234567@s.whatsapp.net", "msg-1"}, ""}

    assert :ok =
             Adapter.start_typing("15551234567@s.whatsapp.net",
               conn: self(),
               transport: MockTransport,
               status: :paused
             )

    assert_receive {:send_chatstate, _, "15551234567@s.whatsapp.net", :paused}

    for {input, expected} <- [
          {nil, :composing},
          {:typing, :composing},
          {"typing", :composing},
          {:recording, :recording},
          {"recording", :recording},
          {:stop, :paused},
          {"stop", :paused},
          {:unknown, :composing}
        ] do
      assert :ok =
               Adapter.start_typing("15551234567@s.whatsapp.net",
                 conn: self(),
                 transport: MockTransport,
                 action: input
               )

      assert_receive {:send_chatstate, _, "15551234567@s.whatsapp.net", ^expected}
    end
  end

  test "metadata, dm opening, pairing code, webhook, and response helpers" do
    assert {:ok, metadata} = Adapter.fetch_metadata("120363@g.us")
    assert metadata.id == "120363@g.us"
    assert metadata.is_dm == false

    assert {:ok, dm_metadata} = Adapter.fetch_metadata("15551234567")
    assert dm_metadata.id == "15551234567@s.whatsapp.net"
    assert dm_metadata.is_dm == true

    assert {:ok, "15551234567@s.whatsapp.net"} = Adapter.open_dm("15551234567")

    assert {:ok, "12345678"} =
             Adapter.request_pairing_code("15551234567", conn: self(), transport: MockTransport)

    assert_receive {:request_pairing_code, _, "15551234567", []}

    request = Jido.Chat.WebhookRequest.new(%{adapter_name: :whatsapp, payload: %{}})
    assert :ok = Adapter.verify_webhook(request)

    chat = Chat.new(%{id: "whatsapp-test"})

    assert %{status: 200} = Adapter.format_webhook_response({:ok, chat, :noop})
    assert %{status: 200} = Adapter.format_webhook_response({:ok, chat, %{}})
    assert %{status: 400} = Adapter.format_webhook_response({:error, :bad_payload})
  end

  test "listener_child_specs/2 returns linked-device worker spec" do
    assert {:ok, []} = Adapter.listener_child_specs("bridge_whatsapp", ingress: %{mode: "manual"})

    assert {:error, :invalid_sink_mfa} =
             Adapter.listener_child_specs("bridge_whatsapp", ingress: %{mode: "linked_device"})

    assert {:ok, [spec]} =
             Adapter.listener_child_specs("bridge_whatsapp",
               ingress: %{mode: "linked_device", profile: "test_profile"},
               sink_mfa: {__MODULE__, :emit, [self()]}
             )

    assert spec.id == {:whatsapp_connection_worker, "bridge_whatsapp"}

    assert {:error, :invalid_ingress_mode} =
             Adapter.listener_child_specs("bridge_whatsapp", ingress: %{mode: "bogus"})

    assert {:ok, [amarula_spec]} =
             Adapter.listener_child_specs("bridge_whatsapp",
               settings: %{profile: "settings_profile"},
               ingress: %{
                 mode: "amarula",
                 storage_root: "/tmp/amarula",
                 connect_opts: [name: :wa_conn]
               },
               sink_mfa: {__MODULE__, :emit, [self()]}
             )

    worker_opts = amarula_spec.start |> elem(2) |> hd()
    assert worker_opts[:config].profile == "settings_profile"
    assert worker_opts[:config].storage == {Amarula.Storage.File, root: "/tmp/amarula"}
    assert worker_opts[:connect_opts] == [name: :wa_conn]
  end

  def emit(test_pid, payload, opts) do
    send(test_pid, {:sink_emit, payload, opts})
    {:ok, :accepted}
  end
end
