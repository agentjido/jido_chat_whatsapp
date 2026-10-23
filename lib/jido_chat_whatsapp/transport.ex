defmodule Jido.Chat.WhatsApp.Transport do
  @moduledoc """
  Transport contract for WhatsApp linked-device operations.

  `connect/2` owns startup cleanup and sends `{:amarula, event, data}` to the
  supplied `:parent`. Its handle must survive protocol process restarts without
  allowing stale cleanup to stop a different connection instance. `stop/2`
  preserves storage; optional `logout/2` explicitly clears it and returns errors.
  Optional `cleanup/2` clears configured storage without a live connection.
  Hosts must exclude concurrent startup and writes until their lifecycle command
  completes; offline cleanup cannot guarantee a remote unlink acknowledgment.
  Optional `account_jids/1` returns only the connected account's phone/LID aliases.
  Optional `account_identity/1` returns only authenticated `phone_number`,
  `display_name` and `account_jids`, normalized by `AccountIdentity`. Phone must
  come from a PN alias, never a LID; unknown names are nil. Read only the supplied
  connection, never inbound sender metadata or a global default. Do not return
  credentials or enable history to obtain a name. The worker runs this callback
  in a bounded asynchronous query and makes unavailable identity explicit.
  Optional `health/1` must report persistence failure before pairing/open events
  can be accepted. Custom transports without these callbacks retain message
  compatibility but must implement their own persistence guarantees.

  Configuration includes an isolated `:profile`, optional `:storage` callback
  specification, and `:sync_history` / `:sync_full_history` booleans. See
  `docs/adapter_contracts.md` for lifecycle and custom storage semantics.

  Optional `connection_processes/1` returns the processes defining a connection's
  lifetime. Their loss terminates the listener so its host can restart it. Include
  shared runtime generations and connection owners, not protocol children that
  restart transparently behind a stable handle. Custom transports may omit it.
  """

  @type conn :: GenServer.server()
  @type send_result :: {:ok, String.t()} | {:error, term()}
  @type message_ref :: {String.t(), String.t(), boolean()}

  @doc "Classifies transport recovery after an error; never returns raw provider data."
  @callback recovery_status(conn()) :: :reconnecting | :failed
  @callback health(conn()) :: :ok | {:error, term()}
  @callback logout(conn(), keyword()) :: :ok | {:error, term()}
  @doc "Clears one trusted profile's configured storage without connecting or reading credentials."
  @callback cleanup(config :: map(), opts :: keyword()) :: :ok | {:error, atom()}
  @callback account_identity(conn()) ::
              {:ok, Jido.Chat.WhatsApp.AccountIdentity.t()} | {:error, :unavailable | :timeout}
  @callback account_jids(conn()) :: {:ok, [String.t()]} | {:error, term()}
  @callback user_phone(conn(), String.t()) :: {:ok, String.t() | nil} | {:error, term()}

  @doc "Resolves a sender to a LID using this connection's verified mapping, retaining unmapped IDs."
  @callback canonical_user_id(conn(), String.t()) :: {:ok, String.t()} | {:error, term()}

  @callback ensure_started(opts :: keyword()) :: :ok | {:error, term()}
  @callback connection_processes(conn()) :: {:ok, [pid()]} | {:error, term()}
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

  @doc "Creates an opaque media reference scoped to this connection's persisted identity."
  @callback media_reference(conn(), Amarula.Content.Media.t()) :: {:ok, String.t()} | {:error, term()}

  @doc "Resolves an opaque reference using this connection, without returning credentials."
  @callback resolve_media_reference(conn(), String.t()) :: {:ok, Amarula.Content.Media.t()} | {:error, term()}

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

  @optional_callbacks recovery_status: 1,
                      canonical_user_id: 2,
                      media_reference: 2,
                      connection_processes: 1,
                      resolve_media_reference: 2,
                      user_phone: 2,
                      account_identity: 1,
                      health: 1,
                      logout: 2,
                      cleanup: 2,
                      account_jids: 1,
                      ensure_started: 1,
                      stop: 2,
                      render_qr: 2
end
