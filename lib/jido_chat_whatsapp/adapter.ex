defmodule Jido.Chat.WhatsApp.Adapter do
  @moduledoc "Stateless WhatsApp adapter for native Chat request and result Signals."

  use Jido.Chat.Adapter

  alias Jido.Chat.Operations.Definitions
  alias Jido.Chat.WhatsApp.{Normalizer, Operations}
  alias Jido.Chat.WhatsApp.Transport.AmarulaClient

  @native ~w(stream_text send_message send_file edit_message delete_message start_typing fetch_metadata fetch_thread get_user download_file add_reaction remove_reaction open_dm)a

  @impl true
  def channel_type, do: :whatsapp

  @impl true
  def default_transport, do: AmarulaClient

  @impl true
  def event_definitions do
    [
      Jido.Chat.Signal.MessageReceived,
      Jido.Chat.Signal.MessageUpdated,
      Jido.Chat.Signal.MessageDeleted,
      Jido.Chat.Signal.ReactionAdded,
      Jido.Chat.Signal.ReactionRemoved,
      Jido.Chat.Signal.NormalizationFailed
    ]
  end

  @impl true
  def capabilities do
    Map.new(Definitions.all(), fn {_, {_, operation, _, _, _}} ->
      {operation, if(operation in @native, do: :native, else: :unsupported)}
    end)
  end

  @impl true
  def invoke(client, request, opts) do
    case Definitions.lookup(request.type) do
      {_, operation, _, _, _} -> Operations.invoke(operation, client, request, opts)
      _ -> {:error, {:not_attempted, :unsupported}}
    end
  end

  @impl true
  def normalize(client, input, opts), do: Normalizer.normalize(client, input, opts)
end
