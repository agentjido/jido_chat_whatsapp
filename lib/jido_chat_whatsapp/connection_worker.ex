defmodule Jido.Chat.WhatsApp.ConnectionWorker do
  @moduledoc """
  Amarula ingress worker. It validates a complete upsert unit before one public
  sink call. Connection, pairing, QR and profile controls remain private.
  Acquisition can precede acceptance. No durable replay or checkpoint is claimed.
  """
  use GenServer
  alias Jido.Chat.WhatsApp.Adapter
  alias Jido.Chat.WhatsApp.Transport.AmarulaClient
  @type sink_mfa :: {module(), atom(), [term()]}
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  @impl true
  def init(opts) do
    bridge = Keyword.fetch!(opts, :bridge_id)
    transport = Keyword.get(opts, :transport, AmarulaClient)
    config = Keyword.fetch!(opts, :config)

    connect_opts =
      Keyword.get(opts, :connect_opts, []) |> Keyword.put(:parent_pid, self()) |> Keyword.put(:parent, self())

    with {:ok, sink} <- validate_sink(Keyword.fetch!(opts, :sink_mfa)),
         {:ok, binding} <- worker_binding(bridge, opts),
         {:ok, conn} <- transport.connect(config, connect_opts) do
      {:ok,
       %{
         bridge_id: bridge,
         binding: binding,
         sink_mfa: sink,
         sink_opts: Keyword.get(opts, :sink_opts, []),
         control_mfa: Keyword.get(opts, :control_mfa),
         control_opts: Keyword.get(opts, :control_opts, []),
         transport: transport,
         conn: conn,
         profile: config[:profile] || config["profile"],
         last_result: nil,
         last_control: nil,
         last_control_result: nil
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_info({:amarula, :messages_upsert, data}, state) do
    result =
      with {:ok, unit} <- Jido.Chat.normalize_event(state.binding, {:amarula, :messages_upsert, data}),
           do:
             invoke_sink(
               state.sink_mfa,
               unit,
               state.sink_opts ++ [path: "/whatsapp/messages_upsert", method: "WHATSAPP"]
             )

    {:noreply, %{state | last_result: result}}
  end

  def handle_info({:amarula, type, data}, state)
      when type in [
             :connection_update,
             :pairing_code,
             :pairing_success,
             :pairing_failure,
             :call_update,
             :history_sync,
             :error
           ] do
    control = %{event: type, data: data, profile: state.profile}

    result =
      if state.control_mfa, do: invoke_sink(state.control_mfa, control, state.control_opts), else: {:ok, :private}

    {:noreply, %{state | last_control: control, last_control_result: result}}
  end

  def handle_info(_event, state), do: {:noreply, state}

  defp worker_binding(bridge, opts) do
    case opts[:binding] do
      %Jido.Chat.Binding{adapter: Adapter} = binding -> {:ok, binding}
      nil -> Jido.Chat.bind(Adapter, Keyword.put(opts, :id, bridge))
      _ -> Jido.Chat.Signal.Policy.error(:invalid_binding)
    end
  end

  defp invoke_sink({module, function, args}, unit, opts) do
    case apply(module, function, args ++ [unit, opts]) do
      :ok -> {:ok, :accepted}
      {:ok, _} = result -> result
      {:error, _} = error -> error
      _ -> {:error, :invalid_sink_result}
    end
  rescue
    _ -> {:error, :sink_exception}
  catch
    _, _ -> {:error, :sink_exception}
  end

  defp validate_sink({module, function, args}) when is_atom(module) and is_atom(function) and is_list(args),
    do: {:ok, {module, function, args}}

  defp validate_sink(_), do: {:error, :invalid_sink_mfa}
end
