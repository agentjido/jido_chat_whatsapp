defmodule Jido.Chat.WhatsApp.Normalizer do
  @moduledoc false

  alias Jido.Chat.{Client, Delivery, Signal}
  alias Jido.Chat.Signal.Identity
  alias Jido.Chat.WhatsApp.Message

  @media_type_pattern ~r/^[a-z0-9!#$&^_.+-]+\/[a-z0-9!#$&^_.+-]+$/
  @limits [:signal_too_large, :delivery_too_large, :too_many_signals, :too_many_failures]

  @doc false
  @spec normalize(Client.t(), term(), keyword()) ::
          {:ok, Delivery.t()} | {:error, Jido.Chat.Errors.Contract.t()}
  def normalize(%Client{} = client, input, opts) when is_list(opts) do
    items = if is_list(input), do: input, else: [input]
    payloads = Enum.map(items, &payload/1)
    delivery_id = "whatsapp:" <> digest({client.id, Enum.map(payloads, &provider_identity/1)})

    with {:ok, signals} <- facts(client, delivery_id, payloads, opts),
         do: Delivery.new(client, delivery_id, signals)
  rescue
    _ -> Signal.Policy.error(:invalid_delivery)
  catch
    _, _ -> Signal.Policy.error(:invalid_delivery)
  end

  def normalize(_, _, _), do: Signal.Policy.error(:invalid_delivery)

  defp facts(client, delivery_id, items, opts) do
    items
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {item, index}, {:ok, acc} ->
      case fact(client, delivery_id, item, opts) do
        {:ok, signals} -> {:cont, {:ok, Enum.reverse(List.wrap(signals), acc)}}
        {:error, %Jido.Chat.Errors.Contract{code: code}} = error when code in @limits -> {:halt, error}
        _ -> append_failure(client, delivery_id, item, index, acc)
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp append_failure(client, delivery_id, item, index, acc) do
    room = room_id(item)

    data =
      %{
        "item_id" => "whatsapp:failure:" <> digest({provider_identity(item), index}),
        "delivery_id" => delivery_id,
        "code" =>
          if(provider_kind(item) in ["message", "edit", "revoke", "reaction"],
            do: "invalid_item",
            else: "unsupported_item"
          ),
        "item_index" => index,
        "provider_kind" => provider_kind(item)
      }
      |> optional("room_id", room)

    case signal(client, Signal.NormalizationFailed, room, data) do
      {:ok, value} -> {:cont, {:ok, [value | acc]}}
      error -> {:halt, error}
    end
  end

  defp fact(client, delivery_id, item, opts) do
    case provider_kind(item) do
      "reaction" -> reaction(client, delivery_id, item)
      "edit" -> message_updated(client, delivery_id, item, opts)
      "revoke" -> message_deleted(client, delivery_id, item)
      kind when kind in ["message", "media"] -> message_received(client, delivery_id, item, opts)
      _ -> {:error, :unsupported}
    end
  end

  defp message_received(client, delivery_id, item, opts) do
    with {:ok, attrs} <- Message.incoming_attrs(item),
         {:ok, media} <- media(client, attrs.media, opts),
         true <- present?(attrs.external_message_id),
         true <- is_map(attrs.author) and present?(attrs.author.user_id) do
      room = attrs.external_room_id
      reply = attrs.external_thread_id

      data =
        %{
          "item_id" => item_id(item, :message),
          "delivery_id" => delivery_id,
          "room_id" => room,
          "message_id" => to_string(attrs.external_message_id),
          "sender" => actor(attrs.author),
          "text" => attrs.text || "",
          "conversation_kind" => if(attrs.chat_type == :group, do: "group", else: "direct"),
          "mentioned" => attrs.was_mentioned == true,
          "mentions" => Enum.map(attrs.mentions, & &1.user_id)
        }
        |> optional("reply_to_id", reply)
        |> optional("thread_id", if(reply, do: Message.thread_id(room, reply)))
        |> optional("media", media)
        |> optional("timestamp", timestamp(attrs.timestamp))
        |> optional("conversation_name", attrs.chat_title)

      signal(client, Signal.MessageReceived, room, data)
    else
      _ -> {:error, :invalid}
    end
  end

  defp message_updated(client, delivery_id, item, opts) do
    with {:ok, attrs} <- Message.incoming_attrs(item),
         {:ok, media} <- media(client, attrs.media, opts),
         true <- present?(target_id(item)) do
      room = attrs.external_room_id

      data =
        %{
          "item_id" => item_id(item, :edit),
          "delivery_id" => delivery_id,
          "room_id" => room,
          "message_id" => target_id(item),
          "text" => attrs.text
        }
        |> optional("sender", actor(attrs.author))
        |> optional("thread_id", attrs.external_thread_id)
        |> optional("media", media)
        |> optional("timestamp", timestamp(attrs.timestamp))

      signal(client, Signal.MessageUpdated, room, data)
    else
      _ -> {:error, :invalid}
    end
  end

  defp message_deleted(client, delivery_id, item) do
    with {:ok, attrs} <- Message.incoming_attrs(item),
         true <- present?(target_id(item)) do
      room = attrs.external_room_id

      data =
        %{
          "item_id" => item_id(item, :revoke),
          "delivery_id" => delivery_id,
          "room_id" => room,
          "message_id" => target_id(item)
        }
        |> optional("actor_id", attrs.external_user_id)
        |> optional("thread_id", attrs.external_thread_id)
        |> optional("timestamp", timestamp(attrs.timestamp))

      signal(client, Signal.MessageDeleted, room, data)
    else
      _ -> {:error, :invalid}
    end
  end

  defp reaction(client, delivery_id, item) do
    with {:ok, event} <- Message.reaction_event(item),
         true <- present?(event.user.user_id) do
      definition = if(event.added, do: Signal.ReactionAdded, else: Signal.ReactionRemoved)

      data = %{
        "item_id" => item_id(item, if(event.added, do: :reaction_added, else: :reaction_removed)),
        "delivery_id" => delivery_id,
        "room_id" => event.channel_id,
        "message_id" => event.message_id,
        "actor_id" => event.user.user_id,
        "reaction" => if(event.added, do: event.emoji, else: nil),
        "thread_id" => event.thread_id
      }

      signal(client, definition, event.channel_id, data)
    else
      _ -> {:error, :invalid}
    end
  end

  defp signal(client, definition, room, data) do
    subject = if is_binary(room), do: Identity.conversation_subject(client.id, room)
    definition.new(data, source: client.source, subject: subject)
  end

  defp media(_client, [], _opts), do: {:ok, nil}

  defp media(client, entries, opts) when is_list(entries) do
    transport = opts[:transport] || client.transport

    with true <- is_atom(transport),
         true <- function_exported?(transport, :resolve_conn, 1),
         true <- function_exported?(transport, :media_reference, 2),
         {:ok, conn} <- transport.resolve_conn(connection_opts(opts)) do
      Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
        with {:ok, descriptor} <- media_descriptor(entry),
             {:ok, reference} when is_binary(reference) <- transport.media_reference(conn, descriptor) do
          public =
            %{
              "kind" => media_kind(entry[:kind]),
              "resource_ref" => %{"client_id" => client.id, "kind" => "media", "id" => reference}
            }
            |> optional("name", entry[:filename])
            |> optional("media_type", entry[:media_type])
            |> optional("width", non_negative(entry[:width]))
            |> optional("height", non_negative(entry[:height]))
            |> optional("duration", non_negative(entry[:duration]))

          {:cont, {:ok, [public | acc]}}
        else
          _ -> {:halt, {:error, :invalid_media_reference}}
        end
      end)
      |> case do
        {:ok, values} -> {:ok, Enum.reverse(values)}
        error -> error
      end
    else
      _ -> {:error, :media_reference_unavailable}
    end
  rescue
    _ -> {:error, :media_reference_unavailable}
  catch
    _, _ -> {:error, :media_reference_unavailable}
  end

  defp media_descriptor(%{metadata: metadata}) when is_map(metadata) do
    kind = media_value(metadata, [:kind, "kind"])

    with {:ok, kind} <- amarula_media_kind(kind) do
      media =
        struct(Amarula.Content.Media,
          kind: kind,
          mimetype: normalized_media_type(media_value(metadata, [:mimetype, "mimetype", :media_type, "media_type"])),
          caption: media_value(metadata, [:caption, "caption"]),
          file_length: media_value(metadata, [:file_length, "file_length", :size_bytes, "size_bytes"]),
          width: media_value(metadata, [:width, "width"]),
          height: media_value(metadata, [:height, "height"]),
          seconds: media_value(metadata, [:seconds, "seconds", :duration, "duration"]),
          file_name: media_value(metadata, [:file_name, "file_name", :filename, "filename"]),
          url: media_value(metadata, [:url, "url"]),
          direct_path: media_value(metadata, [:direct_path, "direct_path"]),
          media_key: media_value(metadata, [:media_key, "media_key"]),
          file_sha256: media_value(metadata, [:file_sha256, "file_sha256"]),
          file_enc_sha256: media_value(metadata, [:file_enc_sha256, "file_enc_sha256"])
        )

      validate_media(media)
    end
  end

  defp media_descriptor(_), do: {:error, :invalid_media_reference}

  defp validate_media(%Amarula.Content.Media{} = media) do
    media = if valid_direct_path?(media.direct_path), do: %{media | url: nil}, else: media

    if media.kind in [:image, :video, :audio, :document, :sticker] and
         is_binary(media.media_key) and byte_size(media.media_key) == 32 and
         (valid_direct_path?(media.direct_path) or valid_media_url?(media.url)) and
         valid_hash?(media.file_sha256) and valid_hash?(media.file_enc_sha256) do
      {:ok, media}
    else
      {:error, :invalid_media_reference}
    end
  end

  defp valid_direct_path?(value), do: is_binary(value) and value != "" and String.starts_with?(value, "/")

  defp valid_media_url?(value) when is_binary(value) do
    case URI.parse(value) do
      %URI{scheme: "https", host: host, userinfo: nil} when is_binary(host) ->
        host = String.downcase(host)
        host == "whatsapp.net" or String.ends_with?(host, ".whatsapp.net")

      _ ->
        false
    end
  end

  defp valid_media_url?(_), do: false
  defp valid_hash?(nil), do: true
  defp valid_hash?(value), do: is_binary(value) and byte_size(value) == 32

  defp normalized_media_type(value) when is_binary(value) do
    type = value |> String.split(";", parts: 2) |> hd() |> String.trim() |> String.downcase()
    if Regex.match?(@media_type_pattern, type), do: type
  end

  defp normalized_media_type(_), do: nil
  defp amarula_media_kind(kind) when kind in [:image, "image"], do: {:ok, :image}
  defp amarula_media_kind(kind) when kind in [:video, "video"], do: {:ok, :video}
  defp amarula_media_kind(kind) when kind in [:audio, "audio"], do: {:ok, :audio}
  defp amarula_media_kind(kind) when kind in [:document, "document", :file, "file"], do: {:ok, :document}
  defp amarula_media_kind(kind) when kind in [:sticker, "sticker"], do: {:ok, :sticker}
  defp amarula_media_kind(_), do: {:error, :invalid_media_reference}

  defp payload(%Amarula.Msg{} = message), do: Message.to_payload(message)
  defp payload(%{message: message}) when is_map(message), do: payload(message)
  defp payload(%{"message" => message}) when is_map(message), do: payload(message)
  defp payload(item), do: item

  defp provider_kind(item) when is_map(item) do
    case value(item, [:type, "type"]) do
      type when type in [:reaction, "reaction"] -> "reaction"
      type when type in [:edit, "edit"] -> "edit"
      type when type in [:revoke, "revoke"] -> "revoke"
      type when type in [:media, "media"] -> "media"
      type when type in [:text, "text", :other, "other"] -> "message"
      _ -> "unknown"
    end
  end

  defp provider_kind(_), do: "unknown"
  defp provider_identity(item), do: {room_id(item), target_id(item), value(item, [:id, "id"]), provider_kind(item)}
  defp item_id(item, kind), do: "whatsapp:item:" <> digest({provider_identity(item), kind})

  defp room_id(item) when is_map(item) do
    item
    |> value([:channel_jid, "channel_jid", :channel, "channel"])
    |> Message.address_to_jid()
  end

  defp room_id(_), do: nil

  defp target_id(item) do
    content = value(item, [:content, "content"])
    key = if is_map(content), do: value(content, [:key, "key"])

    identifier(
      if(is_map(key), do: value(key, [:id, "id"])) ||
        if(is_map(content), do: value(content, [:id, "id", :message_id, "message_id"])) ||
        value(item, [:id, "id"])
    )
  end

  defp actor(nil), do: nil

  defp actor(author) do
    %{"id" => author.user_id}
    |> optional("username", author.user_name)
    |> optional("display_name", author.full_name)
    |> optional("is_self", author.is_me)
  end

  defp timestamp(value) when is_integer(value) do
    unit = if value > 9_999_999_999, do: :millisecond, else: :second

    case DateTime.from_unix(value, unit) do
      {:ok, date} -> DateTime.to_iso8601(date)
      _ -> nil
    end
  end

  defp timestamp(_), do: nil
  defp connection_opts(opts), do: Keyword.take(opts, [:conn, :connection, :profile])
  defp media_value(map, keys), do: value(map, keys)
  defp media_kind(kind) when kind in [:image, "image"], do: "image"
  defp media_kind(kind) when kind in [:audio, "audio"], do: "audio"
  defp media_kind(kind) when kind in [:video, "video"], do: "video"
  defp media_kind(_), do: "file"
  defp non_negative(value) when is_number(value) and value >= 0, do: value
  defp non_negative(_), do: nil
  defp present?(value), do: is_binary(value) and value != ""
  defp identifier(nil), do: nil
  defp identifier(value), do: to_string(value)
  defp optional(map, _key, nil), do: map
  defp optional(map, _key, []), do: map
  defp optional(map, key, value), do: Map.put(map, key, value)

  defp value(map, keys) when is_map(map), do: Enum.find_value(keys, &Map.get(map, &1))
  defp value(_, _), do: nil

  defp digest(value) do
    :crypto.hash(:sha256, :erlang.term_to_binary(canonical(value), [:deterministic]))
    |> Base.url_encode64(padding: false)
  end

  defp canonical(%_{} = value), do: value |> Map.from_struct() |> canonical()

  defp canonical(value) when is_map(value),
    do: value |> Enum.map(fn {key, item} -> {to_string(key), canonical(item)} end) |> Enum.sort()

  defp canonical(value) when is_list(value), do: Enum.map(value, &canonical/1)
  defp canonical(value) when is_tuple(value), do: value |> Tuple.to_list() |> canonical()
  defp canonical(value), do: value
end
