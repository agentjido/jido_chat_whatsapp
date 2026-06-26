defmodule Jido.Chat.WhatsApp.ConnectionWorker do
  @moduledoc """
  Bridge-ingress worker for Amarula connection events.
  """

  use GenServer

  alias Jido.Chat.{ActionEvent, EventEnvelope}
  alias Jido.Chat.WhatsApp.Message
  alias Jido.Chat.WhatsApp.Transport.AmarulaClient

  @type sink_mfa :: {module(), atom(), [term()]}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    bridge_id = Keyword.fetch!(opts, :bridge_id)
    sink_mfa = Keyword.fetch!(opts, :sink_mfa)
    sink_opts = Keyword.get(opts, :sink_opts, [])
    transport = Keyword.get(opts, :transport, AmarulaClient)
    config = Keyword.fetch!(opts, :config)
    connect_opts = Keyword.get(opts, :connect_opts, [])

    with {:ok, sink_mfa} <- validate_sink_mfa(sink_mfa),
         {:ok, conn} <- transport.connect(config, Keyword.put(connect_opts, :parent, self())) do
      {:ok,
       %{
         bridge_id: bridge_id,
         sink_mfa: sink_mfa,
         sink_opts: sink_opts,
         transport: transport,
         conn: conn,
         profile: config[:profile] || config["profile"]
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_info({:amarula, :messages_upsert, %{messages: messages} = data}, state)
      when is_list(messages) do
    Enum.each(messages, fn %Amarula.Msg{} = msg ->
      payload =
        Message.to_payload(msg, %{
          event: :messages_upsert,
          batch_id: Map.get(data, :id),
          from: Message.address_to_jid(Map.get(data, :from))
        })

      _ =
        invoke_sink(
          state.sink_mfa,
          payload,
          state.sink_opts ++ [mode: :payload, path: "/whatsapp/messages_upsert", method: "WHATSAPP"]
        )
    end)

    {:noreply, state}
  end

  def handle_info({:amarula, event_type, data}, state) do
    _ =
      case control_event_envelope(event_type, data, state) do
        {:ok, envelope} ->
          invoke_sink(
            state.sink_mfa,
            envelope,
            state.sink_opts ++ [mode: :payload, path: "/whatsapp/#{event_type}", method: "WHATSAPP"]
          )

        :ignore ->
          :ok
      end

    {:noreply, state}
  end

  defp control_event_envelope(event_type, data, state)
       when event_type in [:connection_update, :pairing_code, :pairing_success, :error] do
    raw = normalize_raw_data(data)

    payload =
      ActionEvent.new(%{
        adapter_name: :whatsapp,
        thread_id: "whatsapp:profile:#{state.profile}",
        channel_id: "profile:#{state.profile}",
        action_id: Atom.to_string(event_type),
        value: event_value(event_type, data),
        raw: raw,
        metadata: %{profile: state.profile, source: :amarula}
      })

    {:ok,
     EventEnvelope.new(%{
       adapter_name: :whatsapp,
       event_type: :action,
       thread_id: payload.thread_id,
       channel_id: payload.channel_id,
       payload: payload,
       raw: raw,
       metadata: %{source: :amarula, event: event_type, bridge_id: state.bridge_id}
     })}
  end

  defp control_event_envelope(_event_type, _data, _state), do: :ignore

  defp event_value(:connection_update, data) when is_map(data) do
    data
    |> Map.get(:connection)
    |> case do
      nil -> if Map.get(data, :qr), do: "qr", else: "connection_update"
      value -> to_string(value)
    end
  end

  defp event_value(:pairing_code, data) when is_map(data), do: to_string(Map.get(data, :code, "pairing_code"))
  defp event_value(:pairing_success, _data), do: "pairing_success"
  defp event_value(:error, data), do: inspect(data)
  defp event_value(event_type, _data), do: to_string(event_type)

  defp normalize_data(%_{} = struct), do: struct |> Map.from_struct() |> normalize_data()

  defp normalize_data(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {key, normalize_data(value)} end)
  end

  defp normalize_data(list) when is_list(list), do: Enum.map(list, &normalize_data/1)
  defp normalize_data(other), do: other

  defp normalize_raw_data(data) do
    case normalize_data(data) do
      %{} = map -> map
      other -> %{value: inspect(other)}
    end
  end

  defp invoke_sink({module, function, base_args}, payload, opts)
       when is_atom(module) and is_atom(function) and is_list(base_args) and is_list(opts) do
    apply(module, function, base_args ++ [payload, opts])
  end

  defp validate_sink_mfa({module, function, args})
       when is_atom(module) and is_atom(function) and is_list(args),
       do: {:ok, {module, function, args}}

  defp validate_sink_mfa(_), do: {:error, :invalid_sink_mfa}
end
