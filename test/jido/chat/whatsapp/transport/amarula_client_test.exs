defmodule Jido.Chat.WhatsApp.Transport.AmarulaClientTest do
  use Jido.Chat.WhatsApp.RuntimeCase, async: false
  use ExUnitProperties

  import ExUnit.CaptureLog

  alias Jido.Chat.WhatsApp.Transport.AmarulaClient

  defmodule MockMediaDownloadAdapter do
    def run(request) do
      body = Process.get({__MODULE__, :body})
      {request, %Req.Response{status: 200, body: body}}
    end
  end

  test "resolve_conn/1 handles explicit connections and missing profiles" do
    pid = self()

    assert {:ok, ^pid} = AmarulaClient.resolve_conn(conn: pid)
    assert {:ok, ^pid} = AmarulaClient.resolve_conn(connection: pid)
    assert {:error, :missing_profile} = AmarulaClient.resolve_conn([])

    assert {:error, :connection_not_running} =
             AmarulaClient.resolve_conn(profile: :"missing_#{System.unique_integer()}")
  end

  test "sender normalization uses only the originating connection's PN to LID mapping" do
    profile = :"sender_mapping_#{System.unique_integer([:positive])}"
    {:ok, conn} = Amarula.Testing.start_offline(profile: profile, parent_pid: self(), frame_sink: self())
    on_exit(fn -> Amarula.stop(conn) end)
    pn = "15550001111@s.whatsapp.net"
    lid = "987654@lid"

    assert {:ok, ^pn} = AmarulaClient.canonical_user_id(conn, pn)

    assert {1, _} =
             Amarula.Protocol.Signal.LidMappingFileStore.store_mappings(
               Amarula.Connection.get_conn(conn),
               [{lid, pn}]
             )

    assert {:ok, ^lid} = AmarulaClient.canonical_user_id(conn, pn)
    assert {:ok, ^lid} = AmarulaClient.canonical_user_id(conn, "15550001111:3@s.whatsapp.net")
    assert {:ok, ^lid} = AmarulaClient.canonical_user_id(conn, lid)
    assert {:error, :invalid_user} = AmarulaClient.canonical_user_id(conn, nil)
    assert {:error, :unavailable} = AmarulaClient.canonical_user_id(:missing_mapping_connection, pn)

    other_profile = :"other_sender_mapping_#{System.unique_integer([:positive])}"
    {:ok, other} = Amarula.Testing.start_offline(profile: other_profile, parent_pid: self(), frame_sink: self())
    on_exit(fn -> Amarula.stop(other) end)
    assert {:ok, ^pn} = AmarulaClient.canonical_user_id(other, pn)
  end

  property "mapped sender normalization is idempotent across device suffixes" do
    profile = :"sender_property_#{System.unique_integer([:positive])}"
    {:ok, conn} = Amarula.Testing.start_offline(profile: profile, parent_pid: self(), frame_sink: self())
    on_exit(fn -> Amarula.stop(conn) end)

    check all(user <- integer(10_000..99_999), device <- integer(1..99), max_runs: 15) do
      pn = "1555#{user}@s.whatsapp.net"
      lid = "9876#{user}@lid"

      assert {1, _} =
               Amarula.Protocol.Signal.LidMappingFileStore.store_mappings(
                 Amarula.Connection.get_conn(conn),
                 [{lid, pn}]
               )

      assert {:ok, ^lid} = AmarulaClient.canonical_user_id(conn, "1555#{user}:#{device}@s.whatsapp.net")
      assert {:ok, ^lid} = AmarulaClient.canonical_user_id(conn, lid)
    end
  end

  test "default transport can send through Amarula offline sandbox" do
    profile = :"jido_chat_whatsapp_transport_#{System.unique_integer([:positive])}"
    {:ok, conn} = Amarula.Testing.start_offline(profile: profile, parent_pid: self(), frame_sink: self())

    on_exit(fn -> Amarula.stop(conn) end)

    assert {:ok, _via} = AmarulaClient.resolve_conn(profile: profile)
    assert {:ok, aliases} = AmarulaClient.account_jids(conn)
    assert aliases != []
    assert {:ok, text_id} = AmarulaClient.send_text(conn, "15551234567@s.whatsapp.net", "hello", [])
    assert is_binary(text_id)

    assert {:ok, reaction_id} =
             AmarulaClient.send_reaction(
               conn,
               {"15551234567@s.whatsapp.net", "target-1", false},
               "ok"
             )

    assert is_binary(reaction_id)

    assert {:ok, edit_id} =
             AmarulaClient.send_edit(
               conn,
               {"15551234567@s.whatsapp.net", "target-1", true},
               "fixed"
             )

    assert is_binary(edit_id)

    assert {:ok, revoke_id} =
             AmarulaClient.send_revoke(
               conn,
               {"15551234567@s.whatsapp.net", "target-1", true}
             )

    assert is_binary(revoke_id)

    assert :ok = AmarulaClient.send_chatstate(conn, "15551234567@s.whatsapp.net", :paused)
    assert {:error, _reason} = AmarulaClient.send_media(conn, "15551234567@s.whatsapp.net", :image, "bytes", [])
  end

  test "download_media/1 downloads and decrypts media bytes" do
    plaintext = "downloaded whatsapp media"
    {:ok, encrypted} = Amarula.Protocol.Messages.Media.encrypt(plaintext, :image)
    mock_download(encrypted.enc)

    media = %Amarula.Content.Media{
      kind: :image,
      url: "https://mmg.whatsapp.net/mms/image/encrypted",
      media_key: encrypted.media_key,
      file_sha256: encrypted.file_sha256,
      file_enc_sha256: encrypted.file_enc_sha256
    }

    assert {:ok, ^plaintext} = AmarulaClient.download_media(media)
  end

  test "download_media/1 returns errors for invalid descriptors and malformed downloads" do
    media = %Amarula.Content.Media{kind: :image}

    assert {:error, :invalid_media} = AmarulaClient.download_media(media)

    mock_download("short")

    malformed = %Amarula.Content.Media{
      kind: :image,
      url: "https://mmg.whatsapp.net/mms/image/malformed",
      media_key: String.duplicate("k", 32)
    }

    log =
      capture_log(fn ->
        assert {:error, %ArgumentError{}} = AmarulaClient.download_media(malformed)
      end)

    assert log =~ "WhatsApp download_media failed"
  end

  test "opaque references fetch and decrypt through the real transport using the selected profile" do
    plaintext = "opaque reference download"
    {:ok, encrypted} = Amarula.Protocol.Messages.Media.encrypt(plaintext, :image)
    mock_download(encrypted.enc)
    profile = "media_#{System.unique_integer([:positive])}"
    {:ok, conn} = Amarula.Testing.start_offline(profile: profile)
    on_exit(fn -> Amarula.stop(conn) end)

    payload = %{
      id: "media-1",
      channel_jid: "123@s.whatsapp.net",
      from_jid: "456@s.whatsapp.net",
      type: :media,
      content: %{
        kind: :image,
        url: "https://mmg.whatsapp.net/mms/image/encrypted",
        media_key: encrypted.media_key,
        file_sha256: encrypted.file_sha256,
        file_enc_sha256: encrypted.file_enc_sha256
      }
    }

    assert {:ok, incoming} = Jido.Chat.WhatsApp.Adapter.transform_incoming(payload, profile: profile)
    assert {:ok, ^plaintext} = Jido.Chat.WhatsApp.Adapter.fetch_media(hd(incoming.media).url, profile: profile)
  end

  defp mock_download(body) do
    previous = Application.fetch_env(:amarula, :req_options)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:amarula, :req_options, value)
        :error -> Application.delete_env(:amarula, :req_options)
      end
    end)

    Application.put_env(:amarula, :req_options, adapter: MockMediaDownloadAdapter)
    Process.put({MockMediaDownloadAdapter, :body}, body)
  end
end
