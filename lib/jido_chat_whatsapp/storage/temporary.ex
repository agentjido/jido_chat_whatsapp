defmodule Jido.Chat.WhatsApp.Storage.Temporary do
  @moduledoc "Bounded, volatile pairing storage. No protocol state is persisted before confirmation."
  use GenServer

  @doc "Starts isolated provisional records for :profile with an optional :max_bytes bound."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true

  def init(opts) do
    profile = Keyword.fetch!(opts, :profile)
    limit = Keyword.get(opts, :max_bytes, 8 * 1024 * 1024)

    if is_binary(profile) and byte_size(profile) > 0 and is_integer(limit) and limit > 0,
      do: {:ok, %{profile: profile, records: %{}, frozen: false, max_bytes: limit}},
      else: {:stop, :invalid_storage_configuration}
  end

  @doc "Uses the existing provisional process; does not implicitly start storage."
  @spec new(keyword()) :: pid()
  def new(opts), do: Keyword.fetch!(opts, :pid)

  @doc "Reads one term within the provisional profile."
  @spec get(pid(), String.t(), term(), term()) :: term()
  def get(pid, profile, namespace, key),
    do: call(pid, profile, {:get, {to_string(namespace), key}})

  @doc "Writes atomically within the size bound until frozen."
  @spec put(pid(), String.t(), term(), term(), term()) :: :ok | {:error, atom()}
  def put(pid, profile, namespace, key, value),
    do: call(pid, profile, {:put, {to_string(namespace), key}, value})

  @doc "Deletes a provisional term before confirmation."
  @spec delete(pid(), String.t(), term(), term()) :: :ok | {:error, atom()}
  def delete(pid, profile, namespace, key),
    do: call(pid, profile, {:delete, {to_string(namespace), key}})

  @doc "Clears the exact mutable profile."
  @spec clear(pid(), String.t()) :: :ok | {:error, atom()}
  def clear(pid, profile), do: call(pid, profile, :clear)

  @doc "Enumerates keys without crossing profiles."
  @spec list_keys(pid(), String.t(), term()) :: {:ok, list()} | {:error, atom()}
  def list_keys(pid, profile, namespace), do: call(pid, profile, {:keys, to_string(namespace)})
  @doc "Returns the sole provisional profile."
  @spec list_profiles(pid()) :: {:ok, [String.t()]}
  def list_profiles(pid), do: GenServer.call(pid, :profiles)
  @doc "Freezes callbacks atomically with the snapshot, rejecting any late protocol writes."
  @spec freeze(pid()) :: map()
  def freeze(pid), do: GenServer.call(pid, :freeze)

  @doc "Discards secrets and leaves the process frozen."
  @spec discard(pid()) :: :ok
  def discard(pid), do: GenServer.call(pid, :discard)
  defp call(pid, profile, operation), do: GenServer.call(pid, {profile, operation})

  @impl true
  def handle_call(:profiles, _, state), do: {:reply, {:ok, [state.profile]}, state}
  def handle_call(:freeze, _, state), do: {:reply, state.records, %{state | frozen: true}}
  def handle_call(:discard, _, state), do: {:reply, :ok, %{state | records: %{}, frozen: true}}

  def handle_call({profile, _}, _, %{profile: profile, frozen: true} = state),
    do: {:reply, {:error, :storage_frozen}, state}

  def handle_call({profile, operation}, _, %{profile: profile} = state) do
    {result, records} = operate(operation, state.records)

    if :erlang.external_size(records) <= state.max_bytes,
      do: {:reply, result, %{state | records: records}},
      else: {:reply, {:error, :storage_full}, state}
  end

  def handle_call(_, _, state), do: {:reply, {:error, :invalid_profile}, state}

  @impl true
  def format_status(status),
    do:
      status
      |> Map.put(:state, :redacted)
      |> Map.put(:message, :redacted)
      |> Map.put(:reason, :redacted)

  defp operate({:get, key}, records), do: {Map.fetch(records, key), records}
  defp operate({:put, key, value}, records), do: {:ok, Map.put(records, key, value)}
  defp operate({:delete, key}, records), do: {:ok, Map.delete(records, key)}
  defp operate(:clear, _), do: {:ok, %{}}

  defp operate({:keys, namespace}, records),
    do: {{:ok, for({{^namespace, key}, _} <- records, do: key)}, records}
end
