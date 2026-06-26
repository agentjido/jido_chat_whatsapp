defmodule Jido.Chat.WhatsApp.Transport.AmarulaClient do
  @moduledoc """
  Default WhatsApp transport backed by `Amarula`.
  """

  @behaviour Jido.Chat.WhatsApp.Transport

  require Logger

  @impl true
  def connect(config, opts) when is_map(config) and is_list(opts) do
    config
    |> Amarula.new()
    |> Amarula.connect(opts)
  end

  @impl true
  def resolve_conn(opts) when is_list(opts) do
    cond do
      conn = Keyword.get(opts, :conn) ->
        {:ok, conn}

      conn = Keyword.get(opts, :connection) ->
        {:ok, conn}

      profile = configured_profile(opts) ->
        case Amarula.whereis(profile) do
          nil -> {:error, :connection_not_running}
          _pid -> {:ok, Amarula.via(profile)}
        end

      true ->
        {:error, :missing_profile}
    end
  end

  @impl true
  def send_text(conn, jid, text, opts) do
    Amarula.send_text(conn, jid, text, opts)
  rescue
    exception ->
      Logger.warning("WhatsApp send_text failed: #{Exception.message(exception)}")
      {:error, exception}
  catch
    kind, reason ->
      Logger.warning("WhatsApp send_text failed: #{inspect({kind, reason})}")
      {:error, {kind, reason}}
  end

  @impl true
  def send_media(conn, jid, media_type, data, opts) do
    Amarula.send_media(conn, jid, media_type, data, opts)
  rescue
    exception ->
      Logger.warning("WhatsApp send_media failed: #{Exception.message(exception)}")
      {:error, exception}
  catch
    kind, reason ->
      Logger.warning("WhatsApp send_media failed: #{inspect({kind, reason})}")
      {:error, {kind, reason}}
  end

  @impl true
  def send_reaction(conn, message_ref, emoji), do: Amarula.send_reaction(conn, message_ref, emoji)

  @impl true
  def send_edit(conn, message_ref, text), do: Amarula.send_edit(conn, message_ref, text)

  @impl true
  def send_revoke(conn, message_ref), do: Amarula.send_revoke(conn, message_ref)

  @impl true
  def send_chatstate(conn, jid, state), do: Amarula.send_chatstate(conn, jid, state)

  @impl true
  def request_pairing_code(conn, phone, opts), do: Amarula.request_pairing_code(conn, phone, opts)

  defp configured_profile(opts) do
    Keyword.get(opts, :profile) ||
      Application.get_env(:jido_chat_whatsapp, :profile) ||
      Application.get_env(:jido_chat_whatsapp, :whatsapp_profile)
  end
end
