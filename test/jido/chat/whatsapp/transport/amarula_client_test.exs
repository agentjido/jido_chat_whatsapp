defmodule Jido.Chat.WhatsApp.Transport.AmarulaClientTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Jido.Chat.WhatsApp.Transport.AmarulaClient

  defmodule MockMediaDownloadAdapter do
    def run(request) do
      body = Process.get({__MODULE__, :body})
      {request, %Req.Response{status: 200, body: body}}
    end
  end

  setup_all do
    start_supervised!(Amarula.Supervisor)
    :ok
  end

  test "resolve_conn/1 handles explicit connections and missing profiles" do
    pid = self()

    assert {:ok, ^pid} = AmarulaClient.resolve_conn(conn: pid)
    assert {:ok, ^pid} = AmarulaClient.resolve_conn(connection: pid)
    assert {:error, :missing_profile} = AmarulaClient.resolve_conn([])

    assert {:error, :connection_not_running} =
             AmarulaClient.resolve_conn(profile: :"missing_#{System.unique_integer()}")
  end

  test "default transport can send through Amarula offline sandbox" do
    profile = :"jido_chat_whatsapp_transport_#{System.unique_integer([:positive])}"
    {:ok, conn} = Amarula.Testing.start_offline(profile: profile, parent_pid: self(), frame_sink: self())

    on_exit(fn -> Amarula.stop(conn) end)

    assert {:ok, _via} = AmarulaClient.resolve_conn(profile: profile)
    assert {:ok, text_id} = AmarulaClient.send_text(conn, "15551234567@s.whatsapp.net", "hello", [])
    assert is_binary(text_id)

    assert {:ok, reaction_id} =
             AmarulaClient.send_reaction(conn, {"15551234567@s.whatsapp.net", "target-1"}, "ok")

    assert is_binary(reaction_id)

    assert {:ok, edit_id} = AmarulaClient.send_edit(conn, {"15551234567@s.whatsapp.net", "target-1"}, "fixed")
    assert is_binary(edit_id)

    assert {:ok, revoke_id} = AmarulaClient.send_revoke(conn, {"15551234567@s.whatsapp.net", "target-1"})
    assert is_binary(revoke_id)

    assert :ok = AmarulaClient.send_chatstate(conn, "15551234567@s.whatsapp.net", :paused)
    assert {:error, _reason} = AmarulaClient.send_media(conn, "15551234567@s.whatsapp.net", :image, "bytes", [])
  end

  test "download_media/1 downloads and decrypts media bytes" do
    previous_req_options = Application.get_env(:amarula, :req_options)

    on_exit(fn ->
      if previous_req_options do
        Application.put_env(:amarula, :req_options, previous_req_options)
      else
        Application.delete_env(:amarula, :req_options)
      end
    end)

    Application.put_env(:amarula, :req_options, adapter: MockMediaDownloadAdapter)

    plaintext = "downloaded whatsapp media"
    {:ok, encrypted} = Amarula.Protocol.Messages.Media.encrypt(plaintext, :image)
    Process.put({MockMediaDownloadAdapter, :body}, encrypted.enc)

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

    previous_req_options = Application.get_env(:amarula, :req_options)

    on_exit(fn ->
      if previous_req_options do
        Application.put_env(:amarula, :req_options, previous_req_options)
      else
        Application.delete_env(:amarula, :req_options)
      end
    end)

    Application.put_env(:amarula, :req_options, adapter: MockMediaDownloadAdapter)
    Process.put({MockMediaDownloadAdapter, :body}, "short")

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
end
