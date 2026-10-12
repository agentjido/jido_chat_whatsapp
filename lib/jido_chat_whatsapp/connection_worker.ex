defmodule Jido.Chat.WhatsApp.ConnectionWorker do
  @moduledoc """
  Linked-device ingress translation, supervised by the host runtime.

  `sink_mfa` receives chat payloads. Optional `lifecycle_sink_mfa` receives
  sanitized profile/attempt-correlated status maps (including sensitive QR data).
  Both callbacks receive their base arguments followed by `[payload, opts]`.
  Lifecycle data is never sent to the chat sink. See `docs/adapter_contracts.md`.
  """

  use GenServer

  alias Jido.Chat.WhatsApp.{Message, Pairing}
  alias Jido.Chat.WhatsApp.Transport.AmarulaClient

  @type sink_mfa :: {module(), atom(), [term()]}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc """
  Returns the current profile and attempt status, including the current QR.

  QR expiry retains `status: :expired` with `qr: nil` until the next lifecycle
  transition. This is distinct from transport `:disconnected` status.
  """
  @spec status(GenServer.server()) :: map()
  def status(worker), do: GenServer.call(worker, :status)

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
    lifecycle = Keyword.get(opts, :lifecycle_sink_mfa)
    config = Keyword.fetch!(opts, :config)

    with :ok <- validate_sink(sink),
         :ok <- validate_optional_sink(lifecycle) do
      state = %{
        bridge_id: Keyword.fetch!(opts, :bridge_id),
        sink_mfa: sink,
        lifecycle_sink_mfa: lifecycle,
        sink_opts: Keyword.get(opts, :sink_opts, []),
        transport: Keyword.get(opts, :transport, AmarulaClient),
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
        conn: nil
      }

      connect(state)
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, notification(state, :status), state}

  def handle_call(:reconnect, _from, state) do
    with :ok <- stop_connection(state),
         {:ok, next} <-
           connect(%{clear_qr(state) | attempt_id: make_ref(), qr_count: 0, status: :connecting, conn: nil}) do
      notify(next, :connecting)
      {:reply, :ok, next}
    else
      _ ->
        state = %{clear_qr(state) | status: :failed}
        notify(state, :error)
        {:reply, {:error, :connection_failed}, state}
    end
  end

  def handle_call(:logout, _from, state) do
    if function_exported?(state.transport, :logout, 2) do
      case state.transport.logout(state.conn, state.connect_opts) do
        :ok ->
          if state.relay_monitor, do: Process.demonitor(state.relay_monitor, [:flush])
          send(state.relay, :stop)
          next = %{clear_qr(state) | conn: nil, status: :logged_out}
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
    stop_connection(state)
    :ok
  end

  @impl true
  def handle_info({:transport_event, attempt, event, data}, %{attempt_id: attempt} = state) do
    cond do
      is_nil(state.conn) ->
        {:noreply, state}

      healthy?(state) ->
        {:noreply, handle_event(event, data, state)}

      true ->
        stop_connection(state)
        state = %{clear_qr(state) | status: :failed, conn: nil}
        notify(state, :storage_or_connection_failed)
        {:noreply, state}
    end
  end

  def handle_info({:qr_expired, attempt, token}, %{attempt_id: attempt, qr_token: token} = state) do
    state = %{clear_qr(state) | status: :expired}
    notify(state, :qr_expired)
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _}, %{relay_monitor: ref} = state),
    do: {:stop, :transport_receiver_failed, state}

  def handle_info(_, state), do: {:noreply, state}

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
    result = safe_connect(state)
    send(owner, {:connection_result, attempt, result})

    case result do
      {:ok, conn} -> relay_loop(owner, attempt, ref, {state.transport, conn, state.connect_opts})
      {:error, _} -> :ok
    end
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

      :stop ->
        :ok
    end
  end

  defp healthy?(state) do
    not function_exported?(state.transport, :health, 1) or state.transport.health(state.conn) == :ok
  end

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
    state = clear_qr(state)
    token = make_ref()
    ttl = if state.qr_count == 0, do: Map.get(state.config, :qr_timeout, 60_000), else: 20_000
    timer = Process.send_after(self(), {:qr_expired, state.attempt_id, token}, ttl)
    state = %{state | qr: qr, qr_timer: timer, qr_token: token, qr_count: state.qr_count + 1, status: :pairing}
    notify(state, :qr_available)
    state
  end

  defp handle_event(event, data, state) do
    case Pairing.lifecycle_status(event, data) do
      nil ->
        state

      status ->
        state = %{clear_qr(state) | status: status}
        notify(state, event)
        state
    end
  end

  defp emit_messages(messages, metadata, state) do
    aliases = account_jids(state)

    Enum.each(messages, fn msg ->
      payload = Message.to_payload(msg, Map.put(metadata, :profile, state.profile)) |> Map.put(:account_jids, aliases)

      invoke_sink(
        state.sink_mfa,
        payload,
        state.sink_opts ++ [mode: :payload, path: "/whatsapp/#{metadata.event}", method: "WHATSAPP"]
      )
    end)
  end

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
      qr: state.qr
    }

  defp notify(%{lifecycle_sink_mfa: nil}, _), do: :ok
  defp notify(state, event), do: invoke_sink(state.lifecycle_sink_mfa, notification(state, event), state.sink_opts)

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
  defp validate_optional_sink(nil), do: :ok
  defp validate_optional_sink(sink), do: validate_sink(sink)
  defp validate_sink({module, function, args}) when is_atom(module) and is_atom(function) and is_list(args), do: :ok
  defp validate_sink(_), do: {:error, :invalid_sink_mfa}
end
