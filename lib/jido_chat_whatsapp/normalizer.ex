defmodule Jido.Chat.WhatsApp.Normalizer do
  @moduledoc false
  alias Jido.Chat.{Client, Delivery}
  alias Jido.Chat.Signal.{Identity, MessageReceived, NormalizationFailed, Policy, ReactionAdded, ReactionRemoved}
  alias Jido.Chat.WhatsApp.Message

  @doc "Normalizes WhatsApp input into one canonical delivery."
  @spec normalize(Client.t(), term()) :: {:ok, Delivery.t()} | {:error, term()}
  def normalize(%Client{} = client, input) do
    items = items(input)
    delivery_id = "whatsapp:" <> digest({client.id, Enum.map(items, &identity/1)})

    with {:ok, signals} <- map_items(client, delivery_id, items),
         do: Delivery.new(client, delivery_id, signals)
  rescue
    _ -> Policy.error(:invalid_delivery)
  catch
    _, _ -> Policy.error(:invalid_delivery)
  end

  defp items({:amarula, :messages_upsert, data}) when is_map(data),
    do: data[:messages] || data["messages"] || []

  defp items(items) when is_list(items), do: items
  defp items(item), do: [item]

  defp map_items(client, delivery_id, items) do
    items
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {item, index}, {:ok, acc} ->
      case map_item(client, delivery_id, item, index) do
        {:ok, signal} -> {:cont, {:ok, acc ++ [signal]}}
        error -> {:halt, error}
      end
    end)
  end

  defp map_item(client, delivery_id, item, index) do
    case item_type(item) do
      type when type in [:reaction, "reaction"] -> reaction(client, delivery_id, item, index)
      type when type in [:text, "text", :media, "media"] -> message(client, delivery_id, item, index)
      _ -> failure(client, delivery_id, item, index, nil, "unsupported_item")
    end
  end

  defp message(client, delivery_id, item, index) do
    case Message.incoming_attrs(item) do
      {:ok, attrs} ->
        room = attrs.external_room_id
        sender_id = attrs.external_user_id || "unknown"

        data =
          %{
            "item_id" => item_id(item),
            "delivery_id" => delivery_id,
            "room_id" => room,
            "message_id" => identifier(attrs.external_message_id),
            "sender" => %{"id" => sender_id},
            "text" => attrs.text || "",
            "conversation_kind" => if(attrs.chat_type == :group, do: "group", else: "direct")
          }
          |> optional("reply_to_id", identifier(attrs.external_reply_to_id))
          |> optional("timestamp", timestamp(attrs.timestamp))
          |> optional("media", media(client, attrs.media))

        if present?(room) and present?(data["message_id"]),
          do: signal(client, MessageReceived, room, data),
          else: failure(client, delivery_id, item, index, room, "invalid_item")

      _ ->
        failure(client, delivery_id, item, index, nil, "invalid_item")
    end
  end

  defp reaction(client, delivery_id, item, index) do
    case Message.reaction_event(map(item)) do
      {:ok, event} ->
        definition = if event.added, do: ReactionAdded, else: ReactionRemoved

        data = %{
          "item_id" => item_id(item),
          "delivery_id" => delivery_id,
          "room_id" => event.channel_id,
          "message_id" => event.message_id,
          "actor_id" => event.user.user_id,
          "reaction" => event.emoji
        }

        signal(client, definition, event.channel_id, data)

      _ ->
        failure(client, delivery_id, item, index, nil, "invalid_item")
    end
  end

  defp failure(client, delivery_id, item, index, room, code) do
    data =
      %{
        "item_id" => item_id(item),
        "delivery_id" => delivery_id,
        "code" => code,
        "item_index" => index,
        "provider_kind" => "whatsapp_message"
      }
      |> optional("room_id", room)

    signal(client, NormalizationFailed, room, data)
  end

  defp signal(client, definition, room, data) do
    subject = if present?(room), do: Identity.conversation_subject(client.id, room)
    definition.new(data, source: client.source, subject: subject)
  end

  defp media(_client, []), do: nil

  defp media(client, media) do
    Enum.map(media, fn item ->
      %{
        "kind" => item.kind |> to_string(),
        "resource_ref" => %{
          "client_id" => client.id,
          "kind" => "media",
          "id" => "whatsapp:media:" <> digest(item.metadata)
        }
      }
      |> optional("name", item.filename)
      |> optional("media_type", item.media_type)
      |> optional("width", item.width)
      |> optional("height", item.height)
      |> optional("duration", item.duration)
    end)
  end

  defp item_type(%Amarula.Msg{type: type}), do: type
  defp item_type(item) when is_map(item), do: item[:type] || item["type"]
  defp item_type(_), do: nil
  defp map(%_{} = value), do: Map.from_struct(value)
  defp map(value), do: value
  defp identity(%Amarula.Msg{id: id}), do: id
  defp identity(item) when is_map(item), do: item[:id] || item["id"] || digest(item)
  defp identity(item), do: digest(item)
  defp item_id(item), do: "whatsapp:item:" <> digest(identity(item))
  defp identifier(nil), do: nil
  defp identifier(value), do: to_string(value)
  defp present?(value), do: is_binary(value) and value != ""
  defp optional(map, _key, nil), do: map
  defp optional(map, key, value), do: Map.put(map, key, value)

  defp timestamp(value) when is_integer(value) do
    unit = if value > 10_000_000_000, do: :millisecond, else: :second

    case DateTime.from_unix(value, unit) do
      {:ok, date} -> DateTime.to_iso8601(date)
      _ -> nil
    end
  end

  defp timestamp(value) when is_binary(value), do: value
  defp timestamp(_), do: nil

  defp digest(value) do
    :crypto.hash(:sha256, :erlang.term_to_binary(value, [:deterministic]))
    |> Base.url_encode64(padding: false)
  end
end
