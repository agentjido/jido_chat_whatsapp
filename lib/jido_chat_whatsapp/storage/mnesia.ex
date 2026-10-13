defmodule Jido.Chat.WhatsApp.Storage.Mnesia do
  @moduledoc """
  Explicitly supervised, node-local RAM protocol storage.

  Start `{Mnesia, require_ram_schema: true}` before storage consumers. Options
  are immutable for that process. This child owns only its table, never the host
  Mnesia application or schema. An existing disk schema is accepted unless
  `:require_ram_schema` is set. Records survive owner/listener replacement but
  not Mnesia/node restart. Handles belong to one infrastructure generation.

  `:scope` is an opaque host tenant/credential identifier; every callback also
  isolates the profile. Hosts must authorize access before invoking callbacks.
  Writes are transactional, bounded and immediately visible. Defaults are 1 MiB
  per value and 16 MiB per scope/profile. No disk fallback or replication occurs.
  """
  use GenServer

  @table :jido_chat_whatsapp_sessions
  @defaults [require_ram_schema: false, max_value_bytes: 1_048_576, max_scope_bytes: 16_777_216]
  @type handle :: %{scope: term(), generation: term()}

  @doc "Starts the single storage owner; invalid configuration creates no children or tables."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    if valid_options?(opts),
      do: GenServer.start_link(__MODULE__, Keyword.merge(@defaults, opts), name: __MODULE__),
      else: {:error, :invalid_storage_configuration}
  end

  @doc "Returns the ready generation without starting infrastructure implicitly."
  @spec ready() :: {:ok, term()} | {:error, :storage_unavailable}
  def ready, do: call(:ready)

  @doc "Subscribes the caller to generation loss and returns its owner/generation token."
  @spec watch() :: {:ok, {pid(), reference()}} | {:error, :storage_unavailable}
  def watch, do: call(:watch)

  @doc "Checks readiness and the exact generation, including before monitor delivery."
  @spec current?(term()) :: boolean()
  def current?(token), do: ready() == {:ok, token}

  @doc "Creates a generation-bound backend context. Missing infrastructure fails closed."
  @spec new(keyword()) :: handle()
  def new(opts) do
    generation =
      case ready() do
        {:ok, token} -> token
        _ -> nil
      end

    %{scope: Keyword.fetch!(opts, :scope), generation: generation}
  end

  @doc "Reads a profile-scoped term."
  @spec get(handle(), term(), term(), term()) :: {:ok, term()} | :error | {:error, atom()}
  def get(state, profile, namespace, key), do: execute(state, profile, {:get, namespace, key})

  @doc "Stores one term within the configured capacity."
  @spec put(handle(), term(), term(), term(), term()) :: :ok | {:error, atom()}
  def put(state, profile, namespace, key, value), do: execute(state, profile, {:put, namespace, key, value})

  @doc "Deletes an entry and prevents a late snapshot from restoring it."
  @spec delete(handle(), term(), term(), term()) :: :ok | {:error, atom()}
  def delete(state, profile, namespace, key), do: execute(state, profile, {:delete, namespace, key})

  @doc "Clears only this scope/profile, retaining a seed tombstone."
  @spec clear(handle(), term()) :: :ok | {:error, atom()}
  def clear(state, profile), do: execute(state, profile, :clear)

  @doc "Lists keys in one namespace."
  @spec list_keys(handle(), term(), term()) :: {:ok, list()} | {:error, atom()}
  def list_keys(state, profile, namespace), do: execute(state, profile, {:keys, namespace})

  @doc "Lists profiles only within this host scope."
  @spec list_profiles(handle()) :: {:ok, list()} | {:error, atom()}
  def list_profiles(state), do: execute(state, nil, :profiles)

  @doc "Seeds an untouched scope atomically; late snapshots cannot roll state back."
  @spec seed(handle(), term(), map()) :: :ok | {:error, atom()}
  def seed(state, profile, records), do: execute(state, profile, {:seed, records})

  @impl true
  def init(options) do
    case Application.ensure_all_started(:mnesia) do
      {:ok, _} ->
        if options[:require_ram_schema] and :mnesia.system_info(:use_dir) do
          {:stop, :invalid_storage_configuration}
        else
          state = %{options: options, generation: make_ref(), identity: nil, watchers: %{}}
          send(self(), :reconcile)
          {:ok, reconcile(state)}
        end

      _ ->
        {:stop, :storage_unavailable}
    end
  end

  @impl true
  def handle_call(:ready, _, state), do: {:reply, readiness(state), state}

  def handle_call(:watch, {pid, _}, state) do
    case readiness(state) do
      {:ok, _} = result ->
        ref = Process.monitor(pid)
        {:reply, result, %{state | watchers: Map.put(state.watchers, ref, pid)}}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:execute, generation, scope, profile, operation}, _, state) do
    result =
      with {:ok, ^generation} <- readiness(state),
           true <- valid_operation?(operation, state.options) do
        transact(fn -> operate({scope, profile}, operation, state.options) end)
      else
        false -> {:error, :invalid_request}
        _ -> {:error, :storage_unavailable}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_info(:reconcile, state) do
    state = reconcile(state)
    Process.send_after(self(), :reconcile, 100)
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _, _}, state),
    do: {:noreply, %{state | watchers: Map.delete(state.watchers, ref)}}

  @impl true
  def format_status(status),
    do: status |> Map.put(:state, :redacted) |> Map.put(:message, :redacted) |> Map.put(:reason, :redacted)

  defp execute(%{scope: scope, generation: generation}, profile, op),
    do: call({:execute, generation, scope, profile, op})

  defp call(request) do
    GenServer.call(__MODULE__, request, 5_000)
  catch
    :exit, _ -> {:error, :storage_unavailable}
  end

  defp valid_options?(opts) do
    Keyword.keyword?(opts) and length(opts) == length(Keyword.keys(opts) |> Enum.uniq()) and
      Enum.all?(opts, fn
        {:require_ram_schema, v} -> is_boolean(v)
        {key, v} when key in [:max_value_bytes, :max_scope_bytes] -> is_integer(v) and v > 0
        _ -> false
      end)
  end

  defp readiness(state) do
    if not is_nil(state.identity) and identity(state.options) == state.identity,
      do: {:ok, {self(), state.generation}},
      else: {:error, :storage_unavailable}
  end

  defp reconcile(state) do
    if readiness(state) == {:ok, {self(), state.generation}} do
      state
    else
      Enum.each(state.watchers, fn {ref, pid} ->
        send(pid, {:whatsapp_storage_down, {self(), state.generation}})
        Process.demonitor(ref, [:flush])
      end)

      create_table(state.options)
      %{state | identity: identity(state.options), generation: make_ref(), watchers: %{}}
    end
  end

  defp create_table(options) do
    with {:ok, _} <- Application.ensure_all_started(:mnesia),
         false <- options[:require_ram_schema] and :mnesia.system_info(:use_dir) do
      :mnesia.create_table(@table, attributes: [:key, :value], type: :set, ram_copies: [node()], local_content: true)
    end
  catch
    _, _ -> :unavailable
  end

  defp identity(options) do
    if (not options[:require_ram_schema] or not :mnesia.system_info(:use_dir)) and
         :mnesia.wait_for_tables([@table], 0) == :ok and
         :mnesia.table_info(@table, :attributes) == [:key, :value] and
         :mnesia.table_info(@table, :type) == :set and
         :mnesia.table_info(@table, :ram_copies) == [node()] and
         :mnesia.table_info(@table, :local_content) and
         :mnesia.table_info(@table, :disc_copies) == [] and
         :mnesia.table_info(@table, :disc_only_copies) == [] do
      {Process.whereis(:mnesia_sup), :mnesia.table_info(@table, :cookie)}
    else
      nil
    end
  catch
    _, _ -> nil
  end

  defp valid_operation?({:put, ns, key, value}, opts),
    do: valid_address?(ns, key) and value_size(value) <= opts[:max_value_bytes]

  defp valid_operation?({op, ns, key}, _) when op in [:get, :delete], do: valid_address?(ns, key)
  defp valid_operation?({:keys, ns}, _), do: is_atom(ns) or is_binary(ns)

  defp valid_operation?({:seed, records}, opts) when is_map(records),
    do:
      Enum.all?(records, fn
        {{ns, key}, value} -> valid_operation?({:put, ns, key, value}, opts)
        _ -> false
      end)

  defp valid_operation?(op, _) when op in [:clear, :profiles], do: true
  defp valid_operation?(_, _), do: false
  defp valid_address?(ns, key), do: (is_atom(ns) or is_binary(ns)) and :erlang.external_size(key) <= 1_024
  defp value_size(v) when is_binary(v), do: byte_size(v)
  defp value_size(v), do: :erlang.external_size(v)

  defp transact(fun) do
    case :mnesia.transaction(fun, [], 10) do
      {:atomic, result} -> result
      {:aborted, :storage_full} -> {:error, :storage_full}
      _ -> {:error, :storage_unavailable}
    end
  end

  defp operate(scope, {:get, ns, key}, _), do: read({scope, ns, key})

  defp operate(scope, {:keys, ns}, _) do
    {:ok,
     for({@table, {^scope, ^ns, key}, _} <- :mnesia.match_object(@table, {@table, {scope, ns, :_}, :_}, :read), do: key)
     |> Enum.sort()}
  end

  defp operate({host, _}, :profiles, _) do
    {:ok,
     for(
       {@table, {{^host, profile}, :metadata}, _} <-
         :mnesia.match_object(@table, {@table, {{host, :_}, :metadata}, :_}, :read),
       do: profile
     )
     |> Enum.uniq()
     |> Enum.sort()}
  end

  defp operate(scope, {:put, ns, key, value}, opts) do
    meta = metadata(scope)
    address = {scope, ns, key}
    bytes = meta.bytes - record_size(address) + :erlang.external_size({ns, key, value})
    if bytes > opts[:max_scope_bytes], do: :mnesia.abort(:storage_full)
    :mnesia.write({@table, address, value})
    write_metadata(scope, %{bytes: bytes, seeded: true})
  end

  defp operate(scope, {:delete, ns, key}, _) do
    meta = metadata(scope)
    address = {scope, ns, key}
    bytes = meta.bytes - record_size(address)
    :mnesia.delete({@table, address})
    write_metadata(scope, %{bytes: bytes, seeded: true})
  end

  defp operate(scope, :clear, _) do
    metadata(scope)

    for {@table, {^scope, _, _} = key, _} <- :mnesia.match_object(@table, {@table, {scope, :_, :_}, :_}, :write),
        do: :mnesia.delete({@table, key})

    write_metadata(scope, %{bytes: 0, seeded: true})
  end

  defp operate(scope, {:seed, records}, opts) do
    unless metadata(scope).seeded do
      Enum.each(records, fn {{ns, key}, value} -> operate(scope, {:put, ns, key, value}, opts) end)
      write_metadata(scope, %{metadata(scope) | seeded: true})
    end

    :ok
  end

  defp read(key) do
    case :mnesia.read(@table, key, :read) do
      [{@table, ^key, value}] -> {:ok, value}
      [] -> :error
    end
  end

  defp metadata(scope) do
    case :mnesia.read(@table, {scope, :metadata}, :write) do
      [{@table, _, meta}] -> meta
      [] -> %{bytes: 0, seeded: false}
    end
  end

  defp write_metadata(scope, meta), do: :mnesia.write({@table, {scope, :metadata}, meta})

  defp record_size({_, ns, key} = address) do
    case read(address) do
      {:ok, value} -> :erlang.external_size({ns, key, value})
      :error -> 0
    end
  end
end
