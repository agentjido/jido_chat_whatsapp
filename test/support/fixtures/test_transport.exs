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
    notify(conn, {:send_text, conn, jid, text, opts})
    {:ok, "wamid.text"}
  end

  @impl true
  def send_media(conn, jid, media_type, data, opts) do
    notify(conn, {:send_media, conn, jid, media_type, data, opts})
    {:ok, "wamid.media"}
  end

  @impl true
  def download_media(media) do
    notify(Process.get({__MODULE__, :observer}), {:download_media, media})
    {:ok, "whatsapp media bytes"}
  end

  @impl true
  def media_reference(_conn, _media), do: {:ok, "whatsapp://media/v1/test-reference"}

  @impl true
  def resolve_media_reference(conn, "whatsapp://media/v1/test-reference") do
    Process.put({__MODULE__, :observer}, conn)

    {:ok,
     struct(Amarula.Content.Media,
       kind: :image,
       media_key: :binary.copy(<<1>>, 32),
       direct_path: "/media/test"
     )}
  end

  def resolve_media_reference(_, _), do: {:error, :invalid_media_reference}

  @impl true
  def user_phone(_conn, _jid), do: {:ok, "+15551234567"}

  @impl true
  def send_reaction(conn, message_ref, emoji) do
    notify(conn, {:send_reaction, conn, message_ref, emoji})
    {:ok, "wamid.reaction"}
  end

  @impl true
  def send_edit(conn, message_ref, text) do
    notify(conn, {:send_edit, conn, message_ref, text})
    {:ok, "wamid.edit"}
  end

  @impl true
  def send_revoke(conn, message_ref) do
    notify(conn, {:send_revoke, conn, message_ref})
    {:ok, "wamid.revoke"}
  end

  @impl true
  def send_chatstate(conn, jid, state) do
    notify(conn, {:send_chatstate, conn, jid, state})
    :ok
  end

  @impl true
  def request_pairing_code(conn, phone, opts) do
    notify(conn, {:request_pairing_code, conn, phone, opts})
    {:ok, "12345678"}
  end

  defp notify(pid, message) when is_pid(pid), do: send(pid, message)
  defp notify(_, _), do: :ok
end
