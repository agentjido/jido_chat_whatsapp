defmodule Jido.Chat.WhatsApp.ConnectionWorker do
  @moduledoc """
  Linked-device ingress translation, supervised by the host runtime.

  `sink_mfa` receives chat payloads and normalized media/reaction event envelopes.
  Media envelopes carry opaque references, never private download descriptors.
  The same sink receives sanitized lifecycle ActionEvent envelopes, including
  sensitive QR data, with profile/attempt/source correlation. The callback
  receives its base arguments followed by `[payload, opts]`.
  Lifecycle callbacks run in order outside the worker and may query its status.
  Identity is fetched asynchronously after socket open and cached; availability
  is separate from connection status. `refresh_identity/1` can retrieve a late
  account name without enabling history synchronization. Its deadline defaults
  to 2,500 ms (`:identity_timeout_ms`, allowed range 1..5,000).
  Managed storage outages pause the connection and retry readiness without
  terminating the worker or consuming the host supervisor restart budget.
  Lifecycle actions never become chat messages. See `docs/adapter_contracts.md`.
  """

  use GenServer

  alias Jido.Chat.{ActionEvent, EventEnvelope, WebhookRequest}
  alias Jido.Chat.WhatsApp.{AccountIdentity, Adapter, Message, Pairing}
  alias Jido.Chat.WhatsApp.Transport.AmarulaClient

  @storage_retry_interval 100

  @type sink_mfa :: {module(), atom(), [term()]}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc """
  Returns cached profile/attempt status, QR and sanitized account identity.

  This performs no transport query. `identity_status` is `:pending`, `:available`
  or `:unavailable`; `identity_error` is nil or a fixed failure category.
  Missing phone/name fields may be nil even when identity is available.

  QR expiry retains `status: :expired` with `qr: nil` until the next lifecycle
  transition. This is distinct from transport `:disconnected` status.
  """
  @spec status(GenServer.server()) :: map()
  def status(worker), do: GenServer.call(worker, :status)

  @doc """
  Starts a bounded, asynchronous identity refresh while connected.

  Returns immediately. Observe `:identity_updated` lifecycle events or read
  `status/1` for the result. Concurrent refreshes coalesce. This never enables
  history synchronization and does not promise that the provider has a name.
  """
  @spec refresh_identity(GenServer.server()) :: :ok | {:error, :not_connected}
  def refresh_identity(worker), do: GenServer.call(worker, :refresh_identity)

  @doc "Stops and reconnects with the same profile, storage and protocol options."
  @spec reconnect(GenServer.server()) :: :ok | {:error, term()}
  def reconnect(worker), do: GenServer.call(worker, :reconnect)

  @doc "Explicitly unlinks and deletes the session through the transport."
  @spec logout(GenServer.server()) :: :ok | {:error, term()}
  def logout(worker), do: GenServer.call(worker, :logout)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    sink = Keyword.fetch!(opts, :sink_mfa)
    config = Keyword.fetch!(opts, :config)

    timeout = Keyword.get(opts, :identity_timeout_ms, 2_500)

    with :ok <- validate_identity_timeout(timeout),
         :ok <- validate_sink(sink) do
      state = %{
        bridge_id: Keyword.fetch!(opts, :bridge_id),
        sink_mfa: sink,
        sink_opts: Keyword.get(opts, :sink_opts, []),
        transport: Keyword.get(opts, :transport, AmarulaClient),
        storage_token: nil,
        storage_monitor: nil,
        storage_retry: nil,
        storage_retry_timer: nil,
        config: config,
        connect_opts: Keyword.get(opts, :connect_opts, []),
        profile: config[:profile] || config["profile"],
        attempt_id: make_ref(),
        status: :connecting,
        qr: nil,
        qr_token: nil,
        qr_timer: nil,
        qr_count: 0,
        relay: nil,
        relay_monitor: nil,
        conn: nil,
        identity: nil,
        identity_status: :unavailable,
        identity_error: :not_connected,
        identity_request: nil,
        identity_timeout_ms: timeout,
        lifecycle_dispatcher: start_dispatcher(sink)
      }

      case connect_with_storage(state) do
        {:ok, _} = result ->
          result

        error ->
          stop_dispatcher(state)
          error
      end
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, notification(state, :status), state}

  def handle_call(:refresh_identity, _from, %{status: :connected} = state) do
    next = begin_identity(state)
    if next != state, do: notify(next, :identity_pending)
    {:reply, :ok, next}
  end

  def handle_call(:refresh_identity, _from, state), do: {:reply, {:error, :not_connected}, state}

  def handle_call(:reconnect, _from, %{storage_retry: ref} = state) when is_reference(ref),
    do: {:reply, {:error, :storage_unavailable}, state}

  def handle_call(:reconnect, _from, state) do
    state = clear_identity(state)

    case stop_connection(state) do
      :ok ->
        state = %{
          (state
           |> clear_qr()
           |> release_storage())
          | attempt_id: make_ref(),
            qr_count: 0,
            status: :connecting,
            conn: nil,
            relay: nil,
            relay_monitor: nil
        }

        case connect_with_storage(state) do
          {:ok, %{storage_retry: ref} = next} when is_reference(ref) ->
            {:reply, {:error, :storage_unavailable}, next}

          {:ok, next} ->
            notify(next, :connecting)
            {:reply, :ok, next}

          _ ->
            next = %{state | status: :failed}
            notify(next, :error)
            {:reply, {:error, :connection_failed}, next}
        end

      _ ->
        state = %{clear_qr(state) | status: :failed}
        notify(state, :error)
        {:reply, {:error, :connection_failed}, state}
    end
  end

  def handle_call(:logout, _from, %{storage_retry: ref} = state) when is_reference(ref),
    do: {:reply, {:error, :storage_unavailable}, state}

  def handle_call(:logout, _from, state) do
    state = clear_identity(state)

    if function_exported?(state.transport, :logout, 2) do
      case state.transport.logout(state.conn, state.connect_opts) do
        :ok ->
          if state.relay_monitor, do: Process.demonitor(state.relay_monitor, [:flush])
          if state.relay, do: send(state.relay, :stop)

          next = %{
            (state
             |> clear_qr()
             |> release_storage())
            | conn: nil,
              relay: nil,
              relay_monitor: nil,
              status: :logged_out
          }

          notify(next, :logged_out)
          {:reply, :ok, next}

        {:error, _} ->
          {:reply, {:error, :logout_failed}, state}
      end
    else
      {:reply, {:error, :unsupported}, state}
    end
  end

  @impl true
  def format_status(status) do
    status
    |> Map.put(:state, Map.take(status.state, [:profile, :attempt_id, :status]))
    |> Map.put(:message, :redacted)
    |> Map.put(:reason, :redacted)
  end

  @impl true
  def terminate(_reason, state) do
    clear_identity(state)
    stop_dispatcher(state)
    stop_connection(state)
    :ok
  end

  @impl true
  def handle_info({:transport_event, attempt, event, data}, %{attempt_id: attempt} = state) do
    cond do
      is_nil(state.conn) ->
        {:noreply, state}

      not storage_healthy?(state.storage_token) ->
        {:noreply, wait_for_storage(state)}

      healthy?(state) ->
        {:noreply, handle_event(event, data, state)}

      true ->
        stop_connection(state)
        state = %{(state |> clear_qr() |> clear_identity()) | status: :failed, conn: nil}
        notify(state, :storage_or_connection_failed)
        {:noreply, state}
    end
  end

  def handle_info(
        {:identity_result, attempt, token, result},
        %{attempt_id: attempt, status: :connected, identity_request: %{token: token}} = state
      ) do
    state = clear_identity(state)

    next =
      case result do
        {:ok, identity} -> %{state | identity: identity, identity_status: :available, identity_error: nil}
        {:error, error} -> %{state | identity_error: error}
      end

    notify(next, :identity_updated)
    {:noreply, next}
  end

  def handle_info({:identity_timeout, token}, %{identity_request: %{token: token}} = state) do
    state = %{clear_identity(state) | identity_error: :timeout}
    notify(state, :identity_updated)
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{identity_request: %{monitor: ref}} = state) do
    state = %{clear_identity(state) | identity_error: :failed}
    notify(state, :identity_updated)
    {:noreply, state}
  end

  def handle_info({:EXIT, pid, _reason}, %{lifecycle_dispatcher: pid} = state),
    do: {:stop, :lifecycle_sink_failed, state}

  def handle_info({:qr_expired, attempt, token}, %{attempt_id: attempt, qr_token: token} = state) do
    state = %{(state |> clear_qr() |> clear_identity()) | status: :expired}
    notify(state, :qr_expired)
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _}, %{relay_monitor: ref} = state) do
    if storage_healthy?(state.storage_token),
      do: {:stop, :transport_receiver_failed, state},
      else: {:noreply, wait_for_storage(state)}
  end

  def handle_info({:whatsapp_storage_down, token}, %{storage_token: token} = state),
    do: {:noreply, wait_for_storage(state)}

  def handle_info({:DOWN, _, :process, pid, _}, %{storage_token: {pid, _}} = state),
    do: {:noreply, wait_for_storage(state)}

  def handle_info({:retry_storage, token}, %{storage_retry: token} = state) do
    case connect_with_storage(%{state | storage_retry: nil, storage_retry_timer: nil}) do
      {:ok, next} -> {:noreply, next}
      {:stop, _} -> {:noreply, wait_for_storage(state)}
    end
  end

  def handle_info(_, state), do: {:noreply, state}

  defp connect_with_storage(state) do
    case watch_storage(state.config) do
      {:ok, token, monitor} ->
        attempt = if state.status == :failed, do: make_ref(), else: state.attempt_id
        next = %{state | storage_token: token, storage_monitor: monitor, status: :connecting, attempt_id: attempt}
        if state.status == :failed, do: notify(next, :connecting)

        case connect(next) do
          {:ok, _} = result ->
            result

          error ->
            release_storage(next)
            error
        end

      {:error, :storage_unavailable} ->
        {:ok, wait_for_storage(state)}
    end
  end

  defp wait_for_storage(%{status: :failed, conn: nil, storage_token: nil} = state),
    do: schedule_storage_retry(state)

  defp wait_for_storage(state) do
    stop_connection(state)

    next = %{
      (state
       |> clear_qr()
       |> clear_identity()
       |> release_storage())
      | storage_token: nil,
        storage_monitor: nil,
        conn: nil,
        relay: nil,
        relay_monitor: nil,
        qr_count: 0,
        status: :failed
    }

    notify(next, :storage_unavailable)
    schedule_storage_retry(next)
  end

  defp schedule_storage_retry(state) do
    if state.storage_retry_timer, do: Process.cancel_timer(state.storage_retry_timer)
    token = make_ref()
    timer = Process.send_after(self(), {:retry_storage, token}, @storage_retry_interval)
    %{state | storage_retry: token, storage_retry_timer: timer}
  end

  defp release_storage(state) do
    if state.storage_token, do: Jido.Chat.WhatsApp.Storage.Mnesia.unwatch()
    if state.storage_monitor, do: Process.demonitor(state.storage_monitor, [:flush])
    if state.storage_retry_timer, do: Process.cancel_timer(state.storage_retry_timer)

    %{state | storage_token: nil, storage_monitor: nil, storage_retry: nil, storage_retry_timer: nil}
  end

  defp connect(state) do
    owner = self()
    attempt = state.attempt_id
    {relay, monitor} = spawn_monitor(fn -> establish(owner, attempt, state) end)

    receive do
      {:connection_result, ^attempt, {:ok, conn}} ->
        {:ok, %{state | conn: conn, relay: relay, relay_monitor: monitor}}

      {:connection_result, ^attempt, {:error, _}} ->
        Process.demonitor(monitor, [:flush])
        {:stop, :connection_failed}

      {:DOWN, ^monitor, :process, ^relay, _} ->
        {:stop, :connection_failed}
    end
  end

  # The receiver establishes the connection so a worker dying during startup
  # cannot strand resources before the receiver learns which instance it owns.
  defp establish(owner, attempt, state) do
    ref = Process.monitor(owner)
    result = connect_and_monitor(state)
    send(owner, {:connection_result, attempt, result})

    case result do
      {:ok, conn} -> relay_loop(owner, attempt, ref, {state.transport, conn, state.connect_opts})
      {:error, _} -> :ok
    end
  end

  defp connect_and_monitor(state) do
    with {:ok, conn} <- safe_connect(state) do
      case monitor_connection(state.transport, conn) do
        :ok ->
          {:ok, conn}

        {:error, _} ->
          safe_stop(state.transport, conn, state.connect_opts)
          {:error, :connection_failed}
      end
    end
  end

  defp monitor_connection(transport, conn) do
    if function_exported?(transport, :connection_processes, 1) do
      case transport.connection_processes(conn) do
        {:ok, processes} when is_list(processes) ->
          if Enum.all?(processes, &is_pid/1) do
            Enum.each(processes, &Process.monitor/1)
            :ok
          else
            {:error, :connection_failed}
          end

        _ ->
          {:error, :connection_failed}
      end
    else
      :ok
    end
  rescue
    _ -> {:error, :connection_failed}
  catch
    _, _ -> {:error, :connection_failed}
  end

  defp safe_connect(state) do
    state.transport.connect(state.config, Keyword.put(state.connect_opts, :parent, self()))
  rescue
    _ -> {:error, :connection_failed}
  catch
    _, _ -> {:error, :connection_failed}
  end

  defp relay_loop(owner, attempt, ref, connection) do
    receive do
      {:amarula, event, data} ->
        send(owner, {:transport_event, attempt, event, data})
        relay_loop(owner, attempt, ref, connection)

      {:DOWN, ^ref, :process, ^owner, _} ->
        {transport, conn, opts} = connection
        safe_stop(transport, conn, opts)

      {:DOWN, _ref, :process, _pid, _reason} ->
        {transport, conn, opts} = connection
        safe_stop(transport, conn, opts)

      :stop ->
        :ok
    end
  end

  defp healthy?(state) do
    storage_healthy?(state.storage_token) and
      (not function_exported?(state.transport, :health, 1) or state.transport.health(state.conn) == :ok)
  end

  defp storage_healthy?(nil), do: true
  defp storage_healthy?(token), do: Jido.Chat.WhatsApp.Storage.Mnesia.current?(token)

  defp watch_storage(%{storage: {module, _}})
       when module in [Jido.Chat.WhatsApp.Storage.Split, Jido.Chat.WhatsApp.Storage.Mnesia] do
    with {:ok, {pid, _} = token} <- Jido.Chat.WhatsApp.Storage.Mnesia.watch() do
      {:ok, token, Process.monitor(pid)}
    end
  end

  defp watch_storage(_), do: {:ok, nil, nil}

  defp stop_connection(state) do
    result = if state.conn, do: safe_stop(state.transport, state.conn, state.connect_opts), else: :ok

    if result == :ok and state.relay do
      if state.relay_monitor, do: Process.demonitor(state.relay_monitor, [:flush])
      send(state.relay, :stop)
    end

    result
  end

  defp safe_stop(transport, conn, opts) do
    if function_exported?(transport, :stop, 2), do: transport.stop(conn, opts), else: :ok
  rescue
    _ -> {:error, :stop_failed}
  catch
    _, _ -> {:error, :stop_failed}
  end

  defp handle_event(:history_sync, %{messages: messages}, state) when is_list(messages) do
    if Map.get(state.config, :sync_history, true),
      do: emit_messages(messages, %{history: true, event: :history_sync}, state)

    state
  end

  defp handle_event(:messages_upsert, %{messages: messages} = data, state) when is_list(messages) do
    emit_messages(
      messages,
      %{
        event: :messages_upsert,
        history: false,
        batch_id: Map.get(data, :id),
        from: Message.address_to_jid(Map.get(data, :from))
      },
      state
    )

    state
  end

  defp handle_event(:connection_update, %{qr: qr}, state) when is_binary(qr) do
    state = state |> clear_qr() |> clear_identity()
    token = make_ref()
    ttl = if state.qr_count == 0, do: Map.get(state.config, :qr_timeout, 60_000), else: 20_000
    timer = Process.send_after(self(), {:qr_expired, state.attempt_id, token}, ttl)
    state = %{state | qr: qr, qr_timer: timer, qr_token: token, qr_count: state.qr_count + 1, status: :pairing}
    notify(state, :qr_available)
    state
  end

  defp handle_event(event, data, state) do
    case lifecycle_status(event, data, state) do
      nil ->
        state

      status ->
        state = %{(state |> clear_qr() |> clear_identity()) | status: status}
        state = if status == :connected, do: begin_identity(state), else: state
        notify(state, event)
        state
    end
  end

  defp lifecycle_status(:error, _data, state), do: recovery_status(state)

  defp lifecycle_status(:connection_update, %{connection: :disconnected}, state),
    do: recovery_status(state)

  defp lifecycle_status(event, data, _state), do: Pairing.lifecycle_status(event, data)

  defp recovery_status(state) do
    if function_exported?(state.transport, :recovery_status, 1) and
         state.transport.recovery_status(state.conn) == :reconnecting,
       do: :reconnecting,
       else: :failed
  rescue
    _ -> :failed
  catch
    _, _ -> :failed
  end

  defp emit_messages(messages, metadata, state) do
    aliases = account_jids(state)

    Enum.each(messages, fn msg ->
      payload =
        msg
        |> Message.to_payload(Map.put(metadata, :profile, state.profile))
        |> Map.put(:account_jids, aliases)
        |> normalize_sender(state)

      case sink_payload(payload, state) do
        {:ok, event} ->
          invoke_sink(
            state.sink_mfa,
            event,
            state.sink_opts ++ [mode: :payload, path: "/whatsapp/#{metadata.event}", method: "WHATSAPP"]
          )

        {:error, _reason} ->
          if payload.type == :media, do: notify(state, :ingress_normalization_failed)
      end
    end)
  end

  defp normalize_sender(%{from_jid: jid} = payload, state) when is_binary(jid) do
    if function_exported?(state.transport, :canonical_user_id, 2) do
      case state.transport.canonical_user_id(state.conn, jid) do
        {:ok, canonical} when is_binary(canonical) and canonical != "" -> %{payload | from_jid: canonical}
        _ -> payload
      end
    else
      payload
    end
  end

  defp normalize_sender(payload, _state), do: payload

  defp sink_payload(%{type: type} = payload, state) when type in [:reaction, :media] do
    Adapter.parse_event(WebhookRequest.new(%{adapter_name: :whatsapp, payload: payload}),
      conn: state.conn,
      profile: state.profile,
      transport: state.transport
    )
  end

  defp sink_payload(payload, _state), do: {:ok, payload}

  defp clear_qr(state) do
    if state.qr_timer, do: Process.cancel_timer(state.qr_timer)
    %{state | qr: nil, qr_timer: nil, qr_token: nil}
  end

  defp notification(state, event),
    do: %{
      profile: state.profile,
      attempt_id: state.attempt_id,
      event: event,
      status: state.status,
      qr: state.qr,
      identity: state.identity,
      identity_status: state.identity_status,
      identity_error: state.identity_error
    }

  defp notify(state, event) do
    snapshot = notification(state, event)

    metadata =
      Map.merge(snapshot, %{
        category: :connection_lifecycle,
        source: self(),
        presentation: Pairing.presentation(snapshot)
      })

    payload =
      ActionEvent.new(%{
        adapter: Adapter,
        adapter_name: :whatsapp,
        action_id: "connection_update",
        value: Atom.to_string(event),
        raw: %{},
        metadata: metadata
      })

    envelope = EventEnvelope.new(%{adapter_name: :whatsapp, event_type: :action, payload: payload, raw: %{}})
    send(state.lifecycle_dispatcher, {:notify, envelope, state.sink_opts})
  end

  # Deliver callbacks in order outside the worker so sinks may safely query
  # status or request an identity refresh. No new runtime supervisor is needed.
  defp start_dispatcher(sink), do: spawn_link(fn -> dispatch_loop(sink) end)
  defp stop_dispatcher(state), do: Process.exit(state.lifecycle_dispatcher, :shutdown)

  defp dispatch_loop(sink) do
    receive do
      {:notify, payload, opts} ->
        dispatch_notification(sink, payload, opts)
        dispatch_loop(sink)
    end
  end

  defp dispatch_notification(sink, payload, opts) do
    case deliver_notification(sink, payload, opts) do
      {:error, :runtime_not_ready} ->
        receive do
        after
          100 -> dispatch_notification(sink, payload, opts)
        end

      _ ->
        :ok
    end
  end

  defp deliver_notification(sink, payload, opts) do
    invoke_sink(sink, payload, opts)
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  defp begin_identity(%{identity_request: request} = state) when not is_nil(request), do: state

  defp begin_identity(state) do
    if function_exported?(state.transport, :account_identity, 1) do
      owner = self()
      attempt = state.attempt_id
      token = make_ref()
      transport = state.transport
      conn = state.conn

      {pid, monitor} =
        :erlang.spawn_opt(
          fn ->
            result = read_identity(transport, conn)
            send(owner, {:identity_result, attempt, token, result})
          end,
          [:link, :monitor]
        )

      timer = Process.send_after(self(), {:identity_timeout, token}, state.identity_timeout_ms)

      %{
        state
        | identity: nil,
          identity_status: :pending,
          identity_error: nil,
          identity_request: %{pid: pid, monitor: monitor, token: token, timer: timer}
      }
    else
      %{state | identity: nil, identity_status: :unavailable, identity_error: :unsupported}
    end
  end

  defp read_identity(transport, conn) do
    case transport.account_identity(conn) do
      {:ok, identity} -> AccountIdentity.normalize(identity)
      {:error, error} when error in [:unsupported, :unavailable, :timeout] -> {:error, error}
      _ -> {:error, :failed}
    end
  rescue
    _ -> {:error, :failed}
  catch
    _, _ -> {:error, :failed}
  end

  defp clear_identity(state) do
    if request = state.identity_request do
      Process.cancel_timer(request.timer)
      Process.demonitor(request.monitor, [:flush])
      Process.unlink(request.pid)
      Process.exit(request.pid, :kill)
    end

    %{state | identity: nil, identity_status: :unavailable, identity_error: :not_connected, identity_request: nil}
  end

  defp validate_identity_timeout(value) when is_integer(value) and value > 0 and value <= 5_000, do: :ok
  defp validate_identity_timeout(_), do: {:error, :invalid_identity_timeout}

  defp account_jids(state) do
    if function_exported?(state.transport, :account_jids, 1) do
      case state.transport.account_jids(state.conn) do
        {:ok, jids} -> jids
        {:error, _} -> []
      end
    else
      []
    end
  end

  defp invoke_sink({module, function, args}, payload, opts), do: apply(module, function, args ++ [payload, opts])
  defp validate_sink({module, function, args}) when is_atom(module) and is_atom(function) and is_list(args), do: :ok
  defp validate_sink(_), do: {:error, :invalid_sink_mfa}
end
