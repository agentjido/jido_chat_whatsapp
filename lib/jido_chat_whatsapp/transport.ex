defmodule Jido.Chat.WhatsApp.Transport do
  @moduledoc """
  Transport contract for WhatsApp linked-device operations.
  """

  @type conn :: GenServer.server()
  @type send_result :: {:ok, String.t()} | {:error, term()}
  @type message_ref :: {String.t(), String.t(), boolean()}

  @callback connect(config :: map(), opts :: keyword()) :: {:ok, conn()} | {:error, term()}
  @callback resolve_conn(opts :: keyword()) :: {:ok, conn()} | {:error, term()}

  @callback send_text(conn(), jid :: String.t(), text :: String.t(), opts :: keyword()) ::
              send_result()

  @callback send_media(
              conn(),
              jid :: String.t(),
              media_type :: :image | :video | :audio | :document | :sticker,
              data :: binary(),
              opts :: keyword()
            ) :: send_result()

  @callback download_media(Amarula.Content.Media.t()) ::
              {:ok, binary()} | {:error, term()}

  @callback send_reaction(conn(), message_ref(), emoji :: String.t()) ::
              send_result()

  @callback send_edit(conn(), message_ref(), text :: String.t()) ::
              send_result()

  @callback send_revoke(conn(), message_ref()) :: send_result()

  @callback send_chatstate(
              conn(),
              jid :: String.t(),
              state :: :composing | :recording | :paused
            ) :: :ok | {:error, term()}

  @callback request_pairing_code(conn(), phone :: String.t(), opts :: keyword()) ::
              {:ok, String.t()} | {:error, term()}
end
