defmodule Jido.Chat.WhatsApp.Storage.Split do
  @moduledoc """
  Composes host-authorized durable records with package-owned volatile storage.

  Options require `:profile`, opaque `:context` and `:scope`, and
  `:document_mfa` receiving its configured arguments followed by
  `(context, request)`. It must authorize every request, including the
  reserved `__binding_check__` namespace used before RAM operations.
  It returns :ok, :error, {:ok, value}, or {:error, reason}; failures stop
  progress. Only trusted host code may construct these options.

  `:volatile_namespaces` defaults to session and sender_key. Durable values
  retain Base64-encoded uncompressed Erlang terms for compatible host storage.
  The host owns encryption/transactions; this module owns routing and encoding.

  Shared authentication uses `binding_options/2` to translate opaque host bindings
  into this backend; generic host callers need not construct Split options.
  """

  alias Jido.Chat.WhatsApp.Storage.Mnesia

  @volatile_namespaces ["session", "sender_key"]

  @type state :: map()

  @doc "Builds stable storage options; host document callbacks authorize the opaque binding on every access."
  @spec binding_options(term(), keyword()) :: keyword()
  def binding_options(binding, opts) when not is_nil(binding) do
    {module, function, args} =
      case Keyword.fetch(opts, :sink_mfa) do
        {:ok, sink} -> {Jido.Chat.WhatsApp.Storage.Request, :document, [sink]}
        :error -> Keyword.fetch!(opts, :document_mfa)
      end

    context = Keyword.fetch!(opts, :context)

    [
      profile: profile(binding),
      scope: {:whatsapp, binding},
      context: binding,
      document_mfa: {module, function, args ++ [context]},
      volatile_namespaces: Keyword.get(opts, :volatile_namespaces, @volatile_namespaces)
    ]
  end

  @doc "Derives a stable profile from an opaque durable binding without performing storage I/O."
  @spec profile(term()) :: String.t()
  def profile(binding) do
    digest = :crypto.hash(:sha256, :erlang.term_to_binary(binding, [:deterministic])) |> Base.encode16(case: :lower)
    "jido_chat_whatsapp_" <> digest
  end

  @doc "Creates a callback context; it has no transient protocol state."
  @spec new(keyword()) :: state()
  def new(opts) do
    %{
      context: Keyword.fetch!(opts, :context),
      profile: Keyword.fetch!(opts, :profile),
      document_mfa: Keyword.fetch!(opts, :document_mfa),
      volatile_namespaces: Keyword.get(opts, :volatile_namespaces, @volatile_namespaces),
      volatile: Mnesia.new(scope: Keyword.fetch!(opts, :scope))
    }
  end

  @doc "Reads one stored term, distinguishing absence from invalid state."
  @spec get(state(), String.t(), term(), term()) :: {:ok, term()} | :error | {:error, term()}
  def get(state, profile, namespace, key) do
    case call(state, profile, %{op: :get, namespace: to_string(namespace), key: encode(key)}) do
      {:ok, value} -> decode(value)
      result -> result
    end
  rescue
    _ -> {:error, :invalid_state}
  end

  @doc "Commits a term to its namespace's store before reporting success."
  @spec put(state(), String.t(), term(), term(), term()) :: :ok | {:error, term()}
  def put(state, profile, namespace, key, value),
    do:
      call(state, profile, %{
        op: :put,
        namespace: to_string(namespace),
        key: encode(key),
        value: encode(value)
      })

  @doc "Deletes one term idempotently."
  @spec delete(state(), String.t(), term(), term()) :: :ok | {:error, term()}
  def delete(state, profile, namespace, key),
    do: call(state, profile, %{op: :delete, namespace: to_string(namespace), key: encode(key)})

  @doc "Clears this account's durable and RAM records, retaining its credential association."
  @spec clear(state(), String.t()) :: :ok | {:error, term()}
  def clear(state, profile) do
    with :ok <- call(state, profile, %{op: :clear}),
         do: Mnesia.clear(state.volatile, state.profile)
  end

  @doc "Removes obsolete database sessions before starting a saved connector."
  @spec prepare(state()) :: :ok | {:error, atom()}
  def prepare(state) do
    with {:ok, _} <- authorize(state),
         true <- Mnesia.current?(state.volatile.generation) do
      Enum.reduce_while(state.volatile_namespaces, :ok, &delete_durable_namespace(state, &1, &2))
    else
      false -> {:error, :storage_unavailable}
      error -> error
    end
  end

  defp delete_durable_namespace(state, namespace, :ok) do
    case document_call(state, %{op: :delete_namespace, namespace: namespace}) do
      :ok -> {:cont, :ok}
      error -> {:halt, error}
    end
  end

  @doc "Selects the frozen protocol records that require encrypted persistence."
  @spec durable_records(map()) :: map()
  @spec durable_records(map(), [String.t()]) :: map()
  def durable_records(records, namespaces \\ @volatile_namespaces),
    do:
      Map.reject(records, fn {{namespace, _}, _} ->
        to_string(namespace) in namespaces
      end)

  @doc "Transfers a confirmed pairing's volatile records before the normal runtime starts."
  @spec seed(state(), map()) :: :ok | {:error, atom()}
  def seed(state, records) do
    namespaces = state.volatile_namespaces

    with {:ok, _} <- authorize(state) do
      encoded =
        for {{namespace, key}, value} <- records,
            to_string(namespace) in namespaces,
            into: %{},
            do: {{to_string(namespace), encode(key)}, encode(value)}

      Mnesia.seed(state.volatile, state.profile, encoded)
    end
  end

  @doc "Encodes protocol records for a host batch write using the same format as put/5."
  @spec encode_records(map()) :: %{{String.t(), String.t()} => String.t()}
  def encode_records(records) when is_map(records) do
    Map.new(records, fn {{namespace, key}, value} ->
      {{to_string(namespace), encode(key)}, encode(value)}
    end)
  end

  @doc "Lists only the authorized profile after revalidating its binding."
  @spec list_profiles(state()) :: {:ok, [String.t()]} | {:error, term()}
  def list_profiles(state) do
    with {:ok, _} <- call(state, state.profile, %{op: :list_keys, namespace: "__binding_check__"}),
         do: {:ok, [state.profile]}
  end

  @doc "Lists decoded keys within one namespace."
  @spec list_keys(state(), String.t(), term()) :: {:ok, list()} | {:error, term()}
  def list_keys(state, profile, namespace) do
    with {:ok, keys} <- call(state, profile, %{op: :list_keys, namespace: to_string(namespace)}) do
      Enum.reduce_while(keys, {:ok, []}, &decode_key/2)
    end
  end

  defp decode_key(key, {:ok, acc}) do
    case decode(key) do
      {:ok, term} -> {:cont, {:ok, acc ++ [term]}}
      error -> {:halt, error}
    end
  end

  defp call(%{profile: profile} = state, profile, request) do
    if request[:namespace] in state.volatile_namespaces do
      with {:ok, _} <- authorize(state), do: volatile_call(state, request)
    else
      document_call(state, request)
    end
  end

  defp call(_, _, _), do: {:error, :invalid_profile}

  defp authorize(state),
    do: document_call(state, %{op: :list_keys, namespace: "__binding_check__"})

  defp volatile_call(state, %{op: :get, namespace: ns, key: key}),
    do: Mnesia.get(state.volatile, state.profile, ns, key)

  defp volatile_call(state, %{op: :put, namespace: ns, key: key, value: value}),
    do: Mnesia.put(state.volatile, state.profile, ns, key, value)

  defp volatile_call(state, %{op: :delete, namespace: ns, key: key}),
    do: Mnesia.delete(state.volatile, state.profile, ns, key)

  defp volatile_call(state, %{op: :list_keys, namespace: ns}),
    do: Mnesia.list_keys(state.volatile, state.profile, ns)

  defp document_call(%{context: context, document_mfa: {module, function, args}} = state, request) do
    if Mnesia.current?(state.volatile.generation) do
      result = apply(module, function, args ++ [context, request])
      if Mnesia.current?(state.volatile.generation), do: result, else: {:error, :storage_unavailable}
    else
      {:error, :storage_unavailable}
    end
  rescue
    _ -> {:error, :storage_unavailable}
  catch
    _, _ -> {:error, :storage_unavailable}
  end

  defp encode(value), do: value |> :erlang.term_to_binary() |> Base.encode64()

  defp decode(value) do
    with {:ok, <<131, tag, _::binary>> = bytes} when tag != 80 <- Base.decode64(value),
         term <- :erlang.binary_to_term(bytes, [:safe]) do
      {:ok, term}
    else
      _ -> {:error, :invalid_state}
    end
  rescue
    _ -> {:error, :invalid_state}
  end
end
