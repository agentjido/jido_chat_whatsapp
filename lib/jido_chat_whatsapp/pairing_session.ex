defmodule Jido.Chat.WhatsApp.PairingSession do
  @moduledoc """
  Owns a temporary WhatsApp connection until operator confirmation.

  Messages are discarded. Protocol state stays in a separate volatile process so
  stopping the worker can finish its writes before durable records are transferred
  to the host's durable callback and messaging records are seeded into Mnesia. A bounded
  lifetime and browser monitor clean up abandoned pairings.
  Confirmation retains a receipt for repeat clicks; only the normal bridge handles
  messages after persistence. Handles are owner-scoped, including across nodes.

  The host authorizes every API call and supplies an opaque non-nil owner ID.
  Begin options include a host DynamicSupervisor, stable attempt ID, context,
  persist_mfa and start_mfa. Both callbacks receive context as their first extra
  argument. Persistence receives %{attempt_id: id, identity: identity, records:
  durable_records} and must be idempotent for the attempt ID. Success returns
  {:ok, %{receipt: public_map, storage: split_backend_options, runtime: opaque}}.
  The start callback receives that opaque runtime and returns :ok or an error.
  Receipt fields are public; snapshots and host context never enter status.
  Callbacks are bounded to ten seconds and the remaining pairing lifetime.
  A timed-out durable callback may have committed: retry the same attempt ID.

  `authenticate/3` adapts the shared contract to this same session machinery.
  Shared persistence receives normalized account/encoded credentials and returns
  an opaque binding. Storage conversion and seeding remain package-owned; legacy
  `execute/3` callbacks and results retain their existing shapes.
  """
  use GenServer, restart: :temporary
  alias Jido.Chat.WhatsApp.{Adapter, ConnectionWorker, Pairing}
  alias Jido.Chat.WhatsApp.Storage.{Split, Temporary}

  @doc "Starts a provisional session with trusted host callbacks and explicit ownership."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    if valid_options?(opts),
      do: GenServer.start_link(__MODULE__, opts),
      else: {:error, :invalid_pairing_configuration}
  end

  @doc "Starts or commands an owner-scoped pairing using trusted host options."
  @spec execute(map(), term(), keyword()) :: term()
  def execute(request, owner_id, opts)

  def execute(%{op: :begin, owner: owner}, owner_id, opts) when is_pid(owner) and not is_nil(owner_id) do
    opts = opts |> Keyword.put(:owner, owner) |> Keyword.put(:owner_id, owner_id)

    case DynamicSupervisor.start_child(Keyword.fetch!(opts, :supervisor), {__MODULE__, opts}) do
      {:ok, pid} -> {:ok, %{session: pid, phase: :pending, summary: "Preparing QR code"}}
      _ -> {:error, :pairing_unavailable}
    end
  end

  def execute(%{op: op, session: pid}, owner_id, _opts)
      when is_pid(pid) and not is_nil(owner_id) and op in [:status, :retry, :cancel, :confirm] do
    GenServer.call(pid, {owner_id, op}, 40_000)
  catch
    :exit, _ -> {:error, :pairing_expired}
  end

  def execute(_, _, _), do: {:error, :invalid_request}

  @doc "Translates the shared adapter contract without creating a separate pairing runtime."
  @spec authenticate(map(), term(), keyword()) :: Jido.Chat.Adapter.authentication_result()
  def authenticate(request, owner_id, opts)

  def authenticate(%{op: :begin}, owner_id, opts) when not is_nil(owner_id) do
    request = %{op: :begin, owner: opts[:owner]}

    case execute(request, owner_id, Keyword.put(opts, :contract, :shared)) do
      {:ok, %{session: session} = status} -> {:ok, Pairing.authentication_presentation(status, session)}
      _ -> {:error, :pairing_unavailable}
    end
  rescue
    _ -> {:error, :pairing_unavailable}
  catch
    _, _ -> {:error, :pairing_unavailable}
  end

  def authenticate(%{op: op, session: session} = request, owner_id, _opts)
      when is_pid(session) and not is_nil(owner_id) and op in [:status, :retry, :confirm, :cancel] do
    operation = if op == :confirm, do: {:confirm, request[:account_id]}, else: op

    case GenServer.call(session, {owner_id, operation}, 40_000) do
      {:ok, status} ->
        {:ok, Pairing.authentication_presentation(status, session)}

      :ok when op == :cancel ->
        {:ok, %{phase: :cancelled, session: session}}

      {:error, reason} when reason in [:unauthorized, :identity_changed, :identity_not_ready, :save_failed] ->
        {:error, reason}

      _ ->
        {:error, :pairing_unavailable}
    end
  catch
    :exit, _ -> {:error, :pairing_expired}
  end

  def authenticate(_, _, _), do: {:error, :invalid_request}

  @doc "Provisional devices cannot enter the agent message path."
  @spec discard_message(term(), keyword()) :: :ok
  def discard_message(_payload, _opts), do: :ok

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    id = Keyword.fetch!(opts, :attempt_id)
    profile = "pairing_#{id}"
    {:ok, storage} = Temporary.start_link(profile: profile)
    owner_ref = Process.monitor(Keyword.fetch!(opts, :owner))
    ttl = Keyword.get(opts, :ttl_ms, 180_000)
    Process.send_after(self(), :expire, ttl)

    state = %{
      id: id,
      profile: profile,
      storage: storage,
      user_id: Keyword.fetch!(opts, :owner_id),
      owner_ref: owner_ref,
      context: Keyword.fetch!(opts, :context),
      persist_mfa: Keyword.fetch!(opts, :persist_mfa),
      start_mfa: Keyword.fetch!(opts, :start_mfa),
      contract: Keyword.get(opts, :contract, :legacy),
      document_mfa: Keyword.get(opts, :document_mfa),
      adapter: Keyword.get(opts, :adapter, Adapter),
      transport: Keyword.get(opts, :transport, Jido.Chat.WhatsApp.Transport.AmarulaClient),
      connect_opts: Keyword.get(opts, :connect_opts, []),
      deadline: System.monotonic_time(:millisecond) + ttl,
      namespaces: Keyword.get(opts, :volatile_namespaces, ["session", "sender_key"]),
      runtime: nil,
      worker: nil,
      snapshot: nil,
      identity: nil,
      saved: nil,
      presented: nil
    }

    case connect(state) do
      {:ok, state} ->
        {:ok, state}

      _ ->
        GenServer.stop(storage)
        {:stop, :pairing_unavailable}
    end
  end

  @impl true
  def handle_call({id, _}, _, %{user_id: owner} = state) when id != owner,
    do: {:reply, {:error, :unauthorized}, state}

  def handle_call({_, :status}, _, state) do
    status = presentation(state)
    presented = confirmation_key(status)
    {:reply, {:ok, status}, %{state | presented: presented}}
  end

  def handle_call({_, :cancel}, _, state), do: {:stop, :normal, :ok, state}

  def handle_call({_, {:confirm, account_id}}, _, %{contract: :shared} = state) do
    case presentation(state) do
      %{phase: :saved} -> confirm(state)
      %{phase: :confirm, identity: %{phone_number: ^account_id}} when is_binary(account_id) -> confirm(state)
      %{phase: :confirm} -> {:reply, {:error, :identity_changed}, state}
      _ -> {:reply, {:error, :identity_not_ready}, state}
    end
  end

  def handle_call({_, :confirm}, _, %{contract: :legacy} = state), do: confirm(state)

  def handle_call({_, :confirm}, _, state), do: {:reply, {:error, :invalid_request}, state}

  def handle_call({_, {:confirm, _}}, _, state), do: {:reply, {:error, :invalid_request}, state}

  def handle_call({_, :retry}, _, %{saved: saved} = state) when not is_nil(saved),
    do: {:reply, {:ok, presentation(state)}, state}

  def handle_call({_, :retry}, _, %{snapshot: snapshot} = state) when not is_nil(snapshot),
    do: {:reply, {:ok, presentation(state)}, state}

  def handle_call({_, :retry}, _, state) do
    result = retry_connection(state.worker, ConnectionWorker.status(state.worker))

    if result == :ok do
      status = presentation(state)
      {:reply, {:ok, status}, %{state | presented: confirmation_key(status)}}
    else
      {:reply, result, state}
    end
  end

  @impl true
  def handle_info(:expire, state), do: {:stop, :normal, state}

  def handle_info({:DOWN, ref, :process, _, _}, %{owner_ref: ref} = state),
    do: {:stop, :normal, state}

  def handle_info({:EXIT, pid, _}, state) when pid == state.storage or pid == state.runtime,
    do: {:stop, :normal, state}

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def format_status(status),
    do:
      status
      |> Map.put(:state, :redacted)
      |> Map.put(:message, :redacted)
      |> Map.put(:reason, :redacted)

  @impl true
  def terminate(_, state) do
    if is_pid(state.worker) and Process.alive?(state.worker),
      do: safely(fn -> ConnectionWorker.logout(state.worker) end)

    if is_pid(state.runtime) and Process.alive?(state.runtime),
      do: safely(fn -> Supervisor.stop(state.runtime) end)

    if Process.alive?(state.storage), do: safely(fn -> GenServer.stop(state.storage) end)
    :ok
  end

  defp connect(state) do
    ingress = %{
      mode: :linked_device,
      transport: state.transport,
      connect_opts: state.connect_opts,
      profile: state.profile,
      config: %{
        profile: state.profile,
        storage: {Temporary, pid: state.storage},
        sync_history: false,
        sync_full_history: false
      }
    }

    with {:ok, [spec]} <-
           state.adapter.listener_child_specs(state.profile,
             ingress: ingress,
             sink_mfa: {__MODULE__, :discard_message, []}
           ),
         {:ok, runtime} <- Supervisor.start_link([spec], strategy: :one_for_one),
         [{_, worker, _, _}] <- Supervisor.which_children(runtime) do
      {:ok, %{state | runtime: runtime, worker: worker}}
    end
  end

  defp retry_connection(_worker, %{status: :connected, identity: %{phone_number: phone}})
       when is_binary(phone), do: :ok

  defp retry_connection(worker, %{status: :connected}), do: ConnectionWorker.refresh_identity(worker)

  defp retry_connection(_worker, %{status: status})
       when status in [:connecting, :reconnecting, :authenticating, :pairing], do: :ok

  defp retry_connection(worker, _status), do: ConnectionWorker.reconnect(worker)

  defp presentation(%{saved: saved}) when not is_nil(saved), do: %{phase: :saved, saved: saved}

  defp presentation(%{snapshot: snapshot, identity: identity}) when not is_nil(snapshot),
    do: %{phase: :confirm, identity: identity, summary: "Confirm this WhatsApp account"}

  defp presentation(state) do
    status = ConnectionWorker.status(state.worker)
    projected = Pairing.presentation(status)

    case status do
      %{status: :connected, identity: %{phone_number: phone} = identity} when is_binary(phone) ->
        Map.merge(projected, %{
          phase: :confirm,
          identity: identity,
          summary: "Confirm this WhatsApp account"
        })

      %{status: :connected, identity_status: :pending} ->
        Map.merge(projected, %{phase: :pending, summary: "Reading account details"})

      %{status: :connected} ->
        Map.merge(projected, %{
          phase: :failed,
          summary: "Account phone number unavailable; retry connection"
        })

      _ ->
        projected
    end
  end

  defp confirm(%{saved: saved} = state) when not is_nil(saved),
    do: {:reply, {:ok, %{saved: saved, phase: :saved}}, state}

  defp confirm(state) do
    case freeze(state) do
      {:ok, frozen} -> persist(frozen)
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp freeze(%{snapshot: snapshot} = state) when not is_nil(snapshot), do: {:ok, state}

  defp freeze(state) do
    case presentation(state) do
      %{phase: :confirm} = status ->
        if confirmation_key(status) == state.presented do
          freeze_confirmed(state, status.identity)
        else
          {:error, :identity_changed}
        end

      _ ->
        {:error, :identity_not_ready}
    end
  end

  defp confirmation_key(%{
         phase: :confirm,
         attempt_id: attempt,
         identity: %{phone_number: phone}
       }),
       do: {attempt, phone}

  defp confirmation_key(_), do: nil

  defp freeze_confirmed(state, identity) do
    Process.unlink(state.runtime)
    :ok = Supervisor.stop(state.runtime)

    {:ok,
     %{
       state
       | runtime: nil,
         worker: nil,
         snapshot: Temporary.freeze(state.storage),
         identity: identity
     }}
  end

  defp persist(state) do
    request = persistence_request(state)

    case callback(state.persist_mfa, [state.context, request], state.deadline) do
      {:ok, %{receipt: receipt} = result} when state.contract == :shared and is_map(receipt) ->
        saved(state, Pairing.public_receipt(receipt), shared_handoff(state, result))

      {:ok, %{receipt: receipt, storage: storage_opts, runtime: runtime}}
      when state.contract == :legacy and is_map(receipt) and is_list(storage_opts) ->
        saved(state, receipt, handoff(state, storage_opts, runtime))

      _ ->
        {:reply, {:error, :save_failed}, state}
    end
  end

  defp persistence_request(state) do
    records = Split.durable_records(state.snapshot, state.namespaces)

    if state.contract == :shared do
      %{attempt_id: state.id, account: Pairing.account(state.identity), credentials: Split.encode_records(records)}
    else
      %{attempt_id: state.id, identity: state.identity, records: records}
    end
  end

  defp saved(state, receipt, result) do
    :ok = Temporary.discard(state.storage)
    saved = Map.put(receipt, :runtime_pending, result != :ok)
    {:reply, {:ok, %{phase: :saved, saved: saved}}, %{state | saved: saved, snapshot: nil}}
  end

  defp shared_handoff(state, %{binding: binding, runtime: runtime}) when not is_nil(binding) do
    config =
      Adapter.connection_options(binding,
        context: state.context,
        document_mfa: state.document_mfa,
        volatile_namespaces: state.namespaces
      )

    {Split, storage_opts} = config.storage
    handoff(state, storage_opts, %{binding: binding, runtime: runtime, connection_options: config})
  rescue
    _ -> {:error, :runtime_unavailable}
  end

  defp shared_handoff(_, _), do: {:error, :runtime_unavailable}

  defp handoff(state, storage_opts, runtime) do
    with :ok <- bounded(fn -> Split.seed(Split.new(storage_opts), state.snapshot) end, state.deadline),
         do: callback(state.start_mfa, [state.context, runtime], state.deadline)
  rescue
    _ -> {:error, :runtime_unavailable}
  catch
    _, _ -> {:error, :runtime_unavailable}
  end

  defp callback({module, function, args}, values, deadline) do
    bounded(fn -> apply(module, function, args ++ values) end, deadline)
  end

  defp bounded(fun, deadline) do
    timeout = min(10_000, max(0, deadline - System.monotonic_time(:millisecond)))

    if timeout == 0, do: {:error, :callback_failed}, else: run_callback(fun, timeout)
  end

  defp run_callback(fun, timeout) do
    task =
      Task.async(fn ->
        try do
          fun.()
        rescue
          _ -> {:error, :callback_failed}
        catch
          _, _ -> {:error, :callback_failed}
        end
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, value} -> value
      _ -> {:error, :callback_failed}
    end
  end

  defp safely(fun) do
    fun.()
  catch
    _, _ -> :ok
  end

  defp valid_options?(opts) do
    Keyword.keyword?(opts) and is_pid(opts[:owner]) and not is_nil(opts[:owner_id]) and
      is_binary(opts[:attempt_id]) and byte_size(opts[:attempt_id]) in 1..128 and
      Keyword.has_key?(opts, :context) and valid_callback?(opts[:persist_mfa]) and
      (Keyword.get(opts, :contract, :legacy) == :legacy or valid_callback?(opts[:document_mfa])) and
      valid_callback?(opts[:start_mfa]) and is_integer(Keyword.get(opts, :ttl_ms, 180_000)) and
      Keyword.get(opts, :ttl_ms, 180_000) in 1..600_000
  end

  defp valid_callback?({module, function, args}),
    do: is_atom(module) and not is_nil(module) and is_atom(function) and is_list(args)

  defp valid_callback?(_), do: false
end
