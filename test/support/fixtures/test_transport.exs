defmodule Jido.Chat.WhatsApp.TestTransport do
  @moduledoc false
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
  def download_media(media) do
    send(self(), {:download_media, media})
    {:ok, "whatsapp media bytes"}
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
