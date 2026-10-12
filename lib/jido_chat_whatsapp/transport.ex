defmodule Jido.Chat.WhatsApp.Transport do
  @moduledoc """
  Transport contract for WhatsApp linked-device operations.

  `connect/2` owns startup cleanup and sends `{:amarula, event, data}` to the
  supplied `:parent`. Its handle must survive protocol process restarts without
  allowing stale cleanup to stop a different connection instance. `stop/2`
  preserves storage; optional `logout/2` explicitly clears it and returns errors.
  Optional `account_jids/1` returns only the connected account's phone/LID aliases.
  Optional `health/1` must report persistence failure before pairing/open events
  can be accepted. Custom transports without these callbacks retain message
  compatibility but must implement their own persistence guarantees.

  Configuration includes an isolated `:profile`, optional `:storage` callback
  specification, and `:sync_history` / `:sync_full_history` booleans. See
  `docs/adapter_contracts.md` for lifecycle and custom storage semantics.
  """

  @type conn :: GenServer.server()
  @type send_result :: {:ok, String.t()} | {:error, term()}
  @type message_ref :: {String.t(), String.t(), boolean()}

  @callback health(conn()) :: :ok | {:error, term()}
  @callback logout(conn(), keyword()) :: :ok | {:error, term()}
  @callback account_jids(conn()) :: {:ok, [String.t()]} | {:error, term()}

  @callback ensure_started(opts :: keyword()) :: :ok | {:error, term()}
  @callback connect(config :: map(), opts :: keyword()) :: {:ok, conn()} | {:error, term()}
  @callback stop(conn(), opts :: keyword()) :: :ok | {:error, term()}
  @callback render_qr(qr :: String.t(), opts :: keyword()) ::
              {:ok, String.t()} | {:error, term()}
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

  @optional_callbacks health: 1, logout: 2, account_jids: 1, ensure_started: 1, stop: 2, render_qr: 2
end
