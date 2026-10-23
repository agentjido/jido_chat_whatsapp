defmodule Jido.Chat.WhatsApp.MarkdownDeliveryTest do
  use ExUnit.Case, async: true

  alias Jido.Chat.FileUpload
  alias Jido.Chat.WhatsApp.TestTransport, as: Transport
  alias Jido.Chat.WhatsApp.{Adapter, SendOptions}

  @jid "15551234567@s.whatsapp.net"
  @source "**Ready**: *review* the ~~old~~ value. Keep `**literal**` unchanged."
  @rendered "*Ready*: _review_ the ~old~ value. Keep `**literal**` unchanged."

  defmodule FailingTransport do
    @moduledoc false
    def resolve_conn(_opts), do: {:error, :not_connected}
  end

  defmodule DeliveryFailure do
    @moduledoc false
    def resolve_conn(_opts), do: {:ok, self()}
    def send_text(_, _, _, _), do: {:error, :send_failed}
    def send_edit(_, _, _), do: {:error, :edit_failed}
    def send_media(_, _, _, _, _), do: {:error, :media_failed}
  end

  test "new replies render Markdown and retain routing, quoting, mentions and receipts" do
    for format <- [:markdown, "markdown"] do
      opts = [
        transport: Transport,
        conn: :selected,
        profile: "profile",
        format: format,
        quoted: :quote,
        mentions: [@jid]
      ]

      assert {:ok, response} = Adapter.send_message("15551234567", @source, opts)
      assert response.external_message_id == "wamid.text"
      assert response.external_room_id == @jid
      assert response.status == :sent
      assert_received {:resolve_conn, [profile: "profile", conn: :selected]}
      assert_received {:send_text, :selected, @jid, @rendered, transport_opts}
      assert Keyword.get(transport_opts, :quoted) == :quote
      assert Keyword.get(transport_opts, :mentions) == [@jid]
      refute Keyword.has_key?(transport_opts, :format)
    end
  end

  test "status-message edits use the same rendering path and retain the target and receipt" do
    opts = %{"transport" => Transport, "conn" => :selected, "format" => "markdown"}
    assert {:ok, response} = Adapter.edit_message(@jid, "status-1", @source, opts)
    assert_received {:send_edit, :selected, {@jid, "status-1", true}, @rendered}
    assert response.external_message_id == "wamid.edit"
    assert response.status == :edited
    assert response.raw.edited_message_id == "status-1"
  end

  test "sends and edits preserve source with absent, plain, HTML and unknown formats" do
    for format_opts <- [
          [],
          [format: :plain_text],
          [format: "plain_text"],
          [format: :html],
          [format: "html"],
          [format: :unknown]
        ] do
      opts = [transport: Transport] ++ format_opts
      assert {:ok, _} = Adapter.send_message(@jid, @source, opts)
      assert_received {:send_text, _, @jid, @source, _}
      assert {:ok, _} = Adapter.edit_message(@jid, "status-1", @source, opts)
      assert_received {:send_edit, _, {@jid, "status-1", true}, @source}
    end
  end

  test "captions select explicit options over atom/string metadata then render exactly once" do
    for metadata <- [%{caption: @source}, %{"caption" => @source}] do
      upload = FileUpload.new(%{kind: :image, data: "bytes", filename: "image.png", metadata: metadata})
      opts = SendOptions.new(transport: Transport, format: :markdown, quoted: :quote, mentions: [@jid])
      assert {:ok, response} = Adapter.send_file(@jid, upload, opts)
      assert response.external_message_id == "wamid.media"
      assert_received {:send_media, _, @jid, :image, "bytes", media_opts}
      assert media_opts[:caption] == @rendered
      assert media_opts[:file_name] == "image.png"
      assert media_opts[:quoted] == :quote
      assert media_opts[:mentions] == [@jid]
      refute Keyword.has_key?(media_opts, :format)

      assert {:ok, _} = Adapter.send_file(@jid, upload, %{opts | caption: "**Override**"})
      assert_received {:send_media, _, @jid, :image, "bytes", explicit_opts}
      assert explicit_opts[:caption] == "*Override*"

      assert {:ok, _} = Adapter.send_file(@jid, upload, %{opts | caption: ""})
      assert_received {:send_media, _, @jid, :image, "bytes", empty_opts}
      assert empty_opts[:caption] == ""
    end
  end

  test "captions preserve pass-through formats and missing captions remain omitted" do
    upload = FileUpload.new(%{data: "bytes", metadata: %{caption: @source}})

    for format_opts <- [[], [format: :plain_text], [format: :html], [format: "unknown"]] do
      assert {:ok, _} = Adapter.send_file(@jid, upload, [transport: Transport] ++ format_opts)
      assert_received {:send_media, _, @jid, :document, "bytes", opts}
      assert opts[:caption] == @source
    end

    assert {:ok, _} = Adapter.send_file(@jid, %{upload | metadata: %{}}, transport: Transport, format: :markdown)
    assert_received {:send_media, _, @jid, :document, "bytes", opts}
    refute Keyword.has_key?(opts, :caption)
  end

  test "formatting preserves connection and delivery error results" do
    upload = FileUpload.new(%{data: "bytes"})
    opts = [transport: FailingTransport, format: :markdown]
    assert Adapter.send_message(@jid, @source, opts) == {:error, :not_connected}
    assert Adapter.edit_message(@jid, "status-1", @source, opts) == {:error, :not_connected}
    assert Adapter.send_file(@jid, upload, opts) == {:error, :not_connected}

    opts = [transport: DeliveryFailure, format: :markdown]
    assert Adapter.send_message(@jid, @source, opts) == {:error, :send_failed}
    assert Adapter.edit_message(@jid, "status-1", @source, opts) == {:error, :edit_failed}
    assert Adapter.send_file(@jid, upload, opts) == {:error, :media_failed}
  end
end
