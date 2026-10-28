defmodule Jido.Chat.WhatsApp.Source do
  @moduledoc "WhatsApp linked-device push source for the shared Chat Sensor."
  @behaviour Jido.Chat.Sensor.Source

  @impl true
  def mode, do: :push

  @impl true
  def signal_types, do: Enum.map(Jido.Chat.WhatsApp.event_definitions(), & &1.type())

  @impl true
  def key(client, _opts) do
    options = Jido.Chat.Client.options(client)
    :crypto.hash(:sha256, :erlang.term_to_binary(options[:profile], [:deterministic]))
  end

  @impl true
  def start_link(client, sensor, opts) do
    Jido.Chat.WhatsApp.ConnectionWorker.start_link(Keyword.merge(opts, client: client, sensor: sensor))
  end

  def emit(client, sensor, input) do
    with {:ok, delivery} <- Jido.Chat.normalize(client, input),
         :ok <- Jido.Chat.Sensor.push(sensor, delivery.signals) do
      :ok
    end
  end
end
