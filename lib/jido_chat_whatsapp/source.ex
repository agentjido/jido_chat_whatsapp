defmodule Jido.Chat.WhatsApp.Source do
  @moduledoc "Receive-only WhatsApp linked-device push source for the shared Chat Sensor."

  @behaviour Jido.Chat.Sensor.Source

  @impl true
  def mode, do: :push

  @impl true
  def signal_types, do: Enum.map(Jido.Chat.WhatsApp.Adapter.event_definitions(), & &1.type())

  @impl true
  def key(client, options) do
    profile = options[:profile] || client.config[:profile]

    if is_binary(profile) and profile != "" do
      :crypto.hash(:sha256, :erlang.term_to_binary({client.transport, profile}, [:deterministic]))
    end
  end

  @impl true
  def start_link(client, sensor, options) do
    base = Map.new(client.config)
    supplied = options[:config]
    supplied = if is_map(supplied), do: supplied, else: %{}
    profile = options[:profile] || supplied[:profile] || base[:profile]

    if is_binary(profile) and profile != "" do
      config = base |> Map.merge(supplied) |> Map.put(:profile, profile)

      worker_options =
        options
        |> Keyword.put(:config, config)
        |> Keyword.put(:transport, client.transport)

      Jido.Chat.WhatsApp.ConnectionWorker.start_link({client, sensor, worker_options})
    else
      {:error, :missing_profile}
    end
  end
end
