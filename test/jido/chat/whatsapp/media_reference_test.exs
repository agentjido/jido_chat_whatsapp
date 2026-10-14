defmodule Jido.Chat.WhatsApp.MediaReferenceTest do
  use ExUnit.Case, async: true

  alias Jido.Chat.{EventEnvelope, WebhookRequest}
  alias Jido.Chat.WhatsApp.{Adapter, ConnectionWorker}
  alias Jido.Chat.WhatsApp.Transport.AmarulaClient

  defmodule Protocol do
    use GenServer
    def start_link(state), do: GenServer.start_link(__MODULE__, state)
    def init(state), do: {:ok, state}
    def handle_call(:conn, _from, state), do: {:reply, %{profile: state.profile}, state}
    def handle_call(:get_auth_creds, _from, state), do: {:reply, state.creds, state}
  end

  defmodule Transport do
    def connect(config, opts) do
      send(config.test_pid, {:receiver, opts[:parent]})
      {:ok, config.conn}
    end

    def stop(_, _), do: :ok
    def account_jids(_), do: {:ok, []}
    defdelegate resolve_conn(opts), to: AmarulaClient
    defdelegate media_reference(conn, media), to: AmarulaClient
    defdelegate resolve_media_reference(conn, reference), to: AmarulaClient

    def download_media(media) do
      send(self(), {:download, media})
      {:ok, "downloaded bytes"}
    end
  end

  defmodule Sink do
    def emit(pid, event, _opts), do: send(pid, {:ingress, event})
  end

  defmodule UnsupportedTransport do
    defdelegate resolve_conn(opts), to: AmarulaClient
  end

  defp protocol(profile, secret) do
    state = %{profile: profile, creds: %{signed_identity_key: %{private: secret}}}
    start_supervised!(%{id: make_ref(), start: {Protocol, :start_link, [state]}})
  end

  defp payload(kind \\ :image) do
    %{
      id: "media-1",
      channel_jid: "15550001@s.whatsapp.net",
      from_jid: "15550002@s.whatsapp.net",
      type: :media,
      content: %{
        kind: kind,
        caption: "Attachment caption",
        file_name: "attachment",
        file_length: 16,
        direct_path: "/mms/private-download-path",
        media_key: :binary.copy(<<255>>, 32),
        file_sha256: :binary.copy(<<254>>, 32),
        file_enc_sha256: :binary.copy(<<253>>, 32)
      }
    }
  end

  test "normalization emits only an opaque reference and fetching restores each provider kind" do
    conn = protocol("one", :crypto.strong_rand_bytes(32))

    for {kind, public_kind} <- [image: :image, video: :video, audio: :audio, document: :file, sticker: :image] do
      assert {:ok, incoming} = Adapter.transform_incoming(payload(kind), conn: conn, transport: Transport)
      assert [media] = incoming.media
      assert media.kind == public_kind
      assert media.filename == "attachment"
      assert media.size_bytes == 16
      assert incoming.text == "Attachment caption"
      assert "whatsapp://media/v1/" <> _ = media.url
      assert media.metadata == %{file_id: media.url}
      assert incoming.raw == %{}
      refute inspect(incoming) =~ "private-download-path"
      refute inspect(incoming) =~ "media_key"

      for reference <- [media.url, media, %{url: media.url}, %{"metadata" => %{"file_id" => media.url}}] do
        assert {:ok, "downloaded bytes"} = Adapter.fetch_media(reference, conn: conn, transport: Transport)
        assert_received {:download, %Amarula.Content.Media{kind: ^kind} = descriptor}
        assert descriptor.media_key == payload(kind).content.media_key
        assert descriptor.file_enc_sha256 == payload(kind).content.file_enc_sha256
      end
    end
  end

  test "references survive a fresh connection with restored credentials and reject other profiles or credentials" do
    secret = :crypto.strong_rand_bytes(32)
    conn = protocol("one", secret)
    assert {:ok, incoming} = Adapter.transform_incoming(payload(), conn: conn, transport: Transport)
    reference = hd(incoming.media).url
    GenServer.stop(conn)
    restored = protocol("one", secret)
    assert {:ok, "downloaded bytes"} = Adapter.fetch_media(reference, conn: restored, transport: Transport)
    assert_received {:download, _}

    for wrong <- [protocol("two", secret), protocol("one", :crypto.strong_rand_bytes(32))] do
      assert {:error, :invalid_media_reference} = Adapter.fetch_media(reference, conn: wrong, transport: Transport)
      refute_received {:download, _}
    end
  end

  test "malformed and tampered references never download and missing credentials fail closed" do
    conn = protocol("one", :crypto.strong_rand_bytes(32))
    assert {:ok, incoming} = Adapter.transform_incoming(payload(), conn: conn, transport: Transport)
    "whatsapp://media/v1/" <> encoded = hd(incoming.media).url
    bytes = Base.url_decode64!(encoded, padding: false)
    <<first, rest::binary>> = bytes
    tampered = "whatsapp://media/v1/" <> Base.url_encode64(<<Bitwise.bxor(first, 1), rest::binary>>, padding: false)

    for ref <- [
          tampered,
          "whatsapp://media/v1/!",
          "whatsapp://media/v2/abc",
          "whatsapp://media/v1/" <> String.duplicate("a", 40_000)
        ] do
      assert {:error, :invalid_media_reference} = Adapter.fetch_media(ref, conn: conn, transport: Transport)
      refute_received {:download, _}
    end

    invalid = protocol("one", nil)

    assert {:error, :media_reference_unavailable} =
             Adapter.transform_incoming(payload(), conn: invalid, transport: Transport)

    assert {:error, :media_reference_unavailable} =
             Adapter.fetch_media(hd(incoming.media).url, conn: invalid, transport: Transport)
  end

  test "linked-device ingress delivers a normalized envelope without download secrets" do
    conn = protocol("one", :crypto.strong_rand_bytes(32))

    start_supervised!(
      {ConnectionWorker,
       bridge_id: "media",
       sink_mfa: {Sink, :emit, [self()]},
       transport: Transport,
       config: %{profile: "one", conn: conn, test_pid: self(), sync_history: false}}
    )

    assert_receive {:receiver, receiver}

    message = %Amarula.Msg{
      id: "media-1",
      type: :media,
      raw: %{},
      channel: "15550001@s.whatsapp.net",
      from: "15550002@s.whatsapp.net",
      content: struct!(Amarula.Content.Media, payload().content)
    }

    send(receiver, {:amarula, :messages_upsert, %{messages: [message]}})
    assert_receive {:ingress, %EventEnvelope{event_type: :message, payload: incoming} = envelope}, 1_000
    assert envelope.raw == %{}
    assert incoming.raw == %{}
    assert {:ok, "downloaded bytes"} = Adapter.fetch_media(hd(incoming.media).url, conn: conn, transport: Transport)
    assert_received {:download, %Amarula.Content.Media{}}
  end

  test "parse_event propagates normalization failures instead of exposing a raw descriptor" do
    request = WebhookRequest.new(%{adapter_name: :whatsapp, payload: payload()})

    assert {:error, :media_reference_unavailable} =
             Adapter.parse_event(request, conn: protocol("one", nil), transport: Transport)
  end

  test "binary download keys round-trip without leaking into references across varied inputs" do
    conn = protocol("randomized", :crypto.strong_rand_bytes(32))

    for size <- [0, 1, 255, 65_536, 10_000_000], _ <- 1..5 do
      content = %{payload().content | media_key: :crypto.strong_rand_bytes(32), file_length: size}

      assert {:ok, incoming} =
               Adapter.transform_incoming(%{payload() | content: content}, conn: conn, transport: Transport)

      ref = hd(incoming.media).url
      assert String.valid?(ref)
      assert {:ok, "downloaded bytes"} = Adapter.fetch_media(ref, conn: conn, transport: Transport)
      assert_received {:download, descriptor}
      assert descriptor.media_key == content.media_key
      assert descriptor.file_length == size
    end
  end

  test "failed listener sealing reports a sanitized lifecycle event and emits no media payload" do
    conn = protocol("broken", nil)

    start_supervised!(
      {ConnectionWorker,
       bridge_id: "broken-media",
       sink_mfa: {Sink, :emit, [self()]},
       transport: Transport,
       config: %{profile: "broken", conn: conn, test_pid: self()}}
    )

    assert_receive {:receiver, receiver}

    message = %Amarula.Msg{
      id: "media-1",
      type: :media,
      raw: %{},
      channel: "15550001@s.whatsapp.net",
      from: "15550002@s.whatsapp.net",
      content: struct!(Amarula.Content.Media, payload().content)
    }

    send(receiver, {:amarula, :messages_upsert, %{messages: [message]}})

    assert_receive {:ingress,
                    %EventEnvelope{event_type: :action, payload: %{metadata: %{event: :ingress_normalization_failed}}} =
                      event},
                   1_000

    refute inspect(event) =~ "media_key"
    refute_receive {:ingress, %EventEnvelope{}}
    refute_receive {:ingress, %{type: :media}}
  end

  test "oversized descriptors, dead connections and unsupported transports return errors" do
    conn = protocol("one", :crypto.strong_rand_bytes(32))
    oversized = put_in(payload(), [:content, :direct_path], "/" <> String.duplicate("x", 17_000))
    assert {:error, :invalid_media_reference} = Adapter.transform_incoming(oversized, conn: conn, transport: Transport)

    assert {:error, :media_reference_unsupported} =
             Adapter.transform_incoming(payload(), conn: conn, transport: UnsupportedTransport)

    GenServer.stop(conn)

    assert {:error, :media_reference_unavailable} =
             Adapter.transform_incoming(payload(), conn: conn, transport: Transport)
  end
end
