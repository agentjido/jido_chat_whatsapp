defmodule Jido.Chat.WhatsApp.ConnectionWorker do
  @moduledoc false
  use GenServer
  alias Jido.Chat.WhatsApp.Source

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    client = Keyword.fetch!(opts, :client)
    sensor = Keyword.fetch!(opts, :sensor)
    transport = Keyword.get(opts, :transport, client.transport)
    config = Keyword.get(opts, :config, %{profile: client.config[:profile]})

    connect_opts =
      Keyword.get(opts, :connect_opts, []) |> Keyword.put(:parent_pid, self()) |> Keyword.put(:parent, self())

    with {:ok, conn} <- transport.connect(config, connect_opts) do
      {:ok, %{client: client, sensor: sensor, transport: transport, conn: conn, last_result: nil}}
    end
  end

  @impl true
  def handle_info({:amarula, :messages_upsert, _data} = event, state) do
    result = Source.emit(state.client, state.sensor, event)
    {:noreply, %{state | last_result: result}}
  end

  def handle_info(_event, state), do: {:noreply, state}
end
