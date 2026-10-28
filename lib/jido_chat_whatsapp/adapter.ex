defmodule Jido.Chat.WhatsApp.Adapter do
  @moduledoc "Stateless WhatsApp linked-device adapter for Jido Chat."
  use Jido.Chat.Adapter

  @native [
    :send_message,
    :send_file,
    :edit_message,
    :delete_message,
    :start_typing,
    :fetch_metadata,
    :add_reaction,
    :remove_reaction,
    :open_dm
  ]

  @impl true
  def channel_type, do: :whatsapp

  @impl true
  def default_transport, do: Jido.Chat.WhatsApp.Transport.AmarulaClient

  @impl true
  def event_definitions, do: Jido.Chat.WhatsApp.event_definitions()

  @impl true
  def capabilities do
    Map.new(Jido.Chat.Operations.Definitions.all(), fn {_, {_, operation, _, _, _}} ->
      {operation, if(operation in @native, do: :native, else: :unsupported)}
    end)
  end

  @impl true
  def invoke(client, request, opts) do
    case Jido.Chat.Operations.Definitions.lookup(request.type) do
      {_, operation, _, _, _} -> Jido.Chat.WhatsApp.Operations.invoke(operation, client, request, opts)
      _ -> {:error, {:not_attempted, :unsupported}}
    end
  end

  @impl true
  def normalize(client, input, _opts), do: Jido.Chat.WhatsApp.Normalizer.normalize(client, input)
end
