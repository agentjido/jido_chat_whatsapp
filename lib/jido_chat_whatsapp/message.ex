defmodule Jido.Chat.WhatsApp.Message do
  @moduledoc """
  Normalization helpers for Amarula messages.
  """

  alias Jido.Chat.ReactionEvent

  @doc "Converts an Amarula message into a plain payload map suitable for listener ingress."
  @spec to_payload(Amarula.Msg.t(), map()) :: map()
  def to_payload(%Amarula.Msg{} = msg, metadata \\ %{}) when is_map(metadata) do
    forwarded = msg.forwarded == true
    preview = normalize_content_value(msg.preview)

    %{
      id: msg.id,
      channel_jid: address_to_jid(msg.channel),
      from_jid: address_to_jid(msg.from),
      to_jid: address_to_jid(msg.to),
      from_me: msg.from_me == true,
      pushname: msg.pushname,
      timestamp: msg.timestamp,
      type: normalize_type(msg.type),
      content: normalize_content(msg.type, msg.content),
      text: text_for(msg.type, msg.content),
      quoted: normalize_quoted(msg.quoted),
      mentions: Enum.map(List.wrap(msg.mentions), &address_to_jid/1),
      forwarded: forwarded,
      preview: preview,
      metadata: Map.merge(%{source: :amarula, forwarded: forwarded, preview: preview}, metadata)
    }
  end

  @doc "Builds canonical incoming attrs from an Amarula message or normalized payload."
  @spec incoming_attrs(Amarula.Msg.t() | map()) :: {:ok, map()} | {:error, term()}
  def incoming_attrs(%Amarula.Msg{} = msg), do: msg |> to_payload() |> incoming_attrs()

  def incoming_attrs(payload) when is_map(payload) do
    channel_jid = payload |> map_get([:channel_jid, "channel_jid", :channel, "channel"]) |> address_to_jid()
    from_jid = payload |> map_get([:from_jid, "from_jid", :from, "from"]) |> address_to_jid()
    to_jid = payload |> map_get([:to_jid, "to_jid", :to, "to"]) |> address_to_jid()
    type = payload |> map_get([:type, "type"]) |> normalize_type()
    payload_metadata = payload |> map_get([:metadata, "metadata"]) |> normalize_metadata()

    if is_nil(channel_jid) do
      {:error, :missing_channel}
    else
      chat_type = chat_type(channel_jid)

      {:ok,
       %{
         external_room_id: channel_jid,
         external_user_id: from_jid,
         text: map_get(payload, [:text, "text"]) || text_for(type, map_get(payload, [:content, "content"])),
         media: media_for(type, map_get(payload, [:content, "content"])),
         username: from_jid,
         display_name: map_get(payload, [:pushname, "pushname"]),
         external_message_id: map_get(payload, [:id, "id"]),
         external_reply_to_id: quoted_id(map_get(payload, [:quoted, "quoted"])),
         timestamp: normalize_timestamp(map_get(payload, [:timestamp, "timestamp"])),
         chat_type: chat_type,
         chat_title: nil,
         external_thread_id: nil,
         delivery_external_room_id: channel_jid,
         channel_meta: %{
           adapter_name: :whatsapp,
           external_room_id: channel_jid,
           external_thread_id: nil,
           delivery_external_room_id: channel_jid,
           chat_type: chat_type,
           chat_title: nil,
           is_dm: chat_type == :dm,
           metadata: %{to_jid: to_jid}
         },
         raw: payload,
         metadata: %{
           from_me: truthy?(map_get(payload, [:from_me, "from_me"])),
           message_type: type,
           to_jid: to_jid,
           forwarded:
             truthy?(
               map_get(payload, [:forwarded, "forwarded"]) || map_get(payload_metadata, [:forwarded, "forwarded"])
             ),
           preview: map_get(payload, [:preview, "preview"]) || map_get(payload_metadata, [:preview, "preview"])
         }
       }}
    end
  end

  @doc "Builds a canonical reaction event from a normalized Amarula reaction payload."
  @spec reaction_event(map()) :: {:ok, ReactionEvent.t()} | {:error, term()}
  def reaction_event(payload) when is_map(payload) do
    content = map_get(payload, [:content, "content"]) || %{}
    key = map_get(content, [:key, "key"])
    {channel_jid, message_id} = reaction_key(key, payload)
    emoji = map_get(content, [:emoji, "emoji"]) || ""

    if is_nil(channel_jid) or is_nil(message_id) do
      {:error, :missing_reaction_target}
    else
      {:ok,
       ReactionEvent.new(%{
         adapter_name: :whatsapp,
         thread_id: thread_id(channel_jid),
         channel_id: channel_jid,
         message_id: to_string(message_id),
         emoji: emoji,
         added: emoji != "",
         user: reaction_user(payload),
         raw: payload,
         metadata: %{from_me: truthy?(map_get(payload, [:from_me, "from_me"]))}
       })}
    end
  end

  @doc "Returns a stable Jido thread id for a WhatsApp chat JID."
  @spec thread_id(String.t() | nil) :: String.t() | nil
  def thread_id(nil), do: nil
  def thread_id(jid), do: "whatsapp:#{jid}"

  @doc "Converts an Amarula address, normalized address map, or JID string to a JID string."
  @spec address_to_jid(term()) :: String.t() | nil
  def address_to_jid(nil), do: nil
  def address_to_jid(""), do: nil
  def address_to_jid(jid) when is_binary(jid), do: jid

  def address_to_jid(%Amarula.Address{} = address) do
    case Amarula.Address.to_jid(address) do
      {:ok, jid} -> jid
      {:error, :no_jid} -> nil
    end
  end

  def address_to_jid(%{} = address) do
    user = map_get(address, [:user, "user"])
    kind = address |> map_get([:kind, "kind"]) |> normalize_kind()
    device = map_get(address, [:device, "device"])

    cond do
      is_nil(user) or user == "" or is_nil(kind) ->
        nil

      is_nil(device) ->
        "#{user}@#{server_for(kind)}"

      true ->
        "#{user}:#{device}@#{server_for(kind)}"
    end
  end

  def address_to_jid(_), do: nil

  defp normalize_content(:text, content) when is_binary(content), do: content
  defp normalize_content("text", content) when is_binary(content), do: content

  defp normalize_content(_type, %_{} = struct),
    do: struct |> Map.from_struct() |> normalize_content_map()

  defp normalize_content(_type, content) when is_map(content), do: normalize_content_map(content)
  defp normalize_content(_type, content), do: content

  defp normalize_content_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {key, normalize_content_value(value)} end)
  end

  defp normalize_content_value(%Amarula.Address{} = address), do: address_to_jid(address)

  defp normalize_content_value(%_{} = struct),
    do: struct |> Map.from_struct() |> normalize_content_map()

  defp normalize_content_value({jid, id}), do: %{jid: address_to_jid(jid), id: id}
  defp normalize_content_value(value) when is_map(value), do: normalize_content_map(value)
  defp normalize_content_value(value) when is_list(value), do: Enum.map(value, &normalize_content_value/1)
  defp normalize_content_value(value), do: value

  defp normalize_quoted(nil), do: nil

  defp normalize_quoted(quoted) when is_map(quoted) do
    %{
      id: map_get(quoted, [:id, "id"]),
      from_jid: quoted |> map_get([:from, "from"]) |> address_to_jid(),
      channel_jid: quoted |> map_get([:channel, "channel"]) |> address_to_jid()
    }
  end

  defp text_for(type, content) when type in [:text, "text"] and is_binary(content), do: content

  defp text_for(type, content) when type in [:media, "media"] and is_map(content),
    do: map_get(content, [:caption, "caption"])

  defp text_for(_type, _content), do: nil

  defp media_for(type, content) when type in [:media, "media"] and is_map(content) do
    [
      %{
        kind: content |> map_get([:kind, "kind"]) |> media_kind(),
        media_type: map_get(content, [:mimetype, "mimetype", :media_type, "media_type"]),
        filename: map_get(content, [:file_name, "file_name", :filename, "filename"]),
        size_bytes: map_get(content, [:file_length, "file_length", :size_bytes, "size_bytes"]),
        width: map_get(content, [:width, "width"]),
        height: map_get(content, [:height, "height"]),
        duration: map_get(content, [:seconds, "seconds", :duration, "duration"]),
        metadata: content
      }
    ]
  end

  defp media_for(_type, _content), do: []

  defp media_kind(:document), do: :file
  defp media_kind("document"), do: :file
  defp media_kind(:sticker), do: :image
  defp media_kind("sticker"), do: :image
  defp media_kind(kind) when kind in [:image, :audio, :video, :file], do: kind
  defp media_kind(kind) when kind in ["image", "audio", "video", "file"], do: String.to_atom(kind)
  defp media_kind(_), do: :file

  defp quoted_id(nil), do: nil
  defp quoted_id(quoted) when is_map(quoted), do: map_get(quoted, [:id, "id"])
  defp quoted_id(_), do: nil

  defp reaction_key(%{jid: jid, id: id}, _payload), do: {address_to_jid(jid), id}
  defp reaction_key(%{"jid" => jid, "id" => id}, _payload), do: {address_to_jid(jid), id}
  defp reaction_key({jid, id}, _payload), do: {address_to_jid(jid), id}

  defp reaction_key(_key, payload),
    do: {payload |> map_get([:channel_jid, "channel_jid"]) |> address_to_jid(), map_get(payload, [:id, "id"])}

  defp reaction_user(payload) do
    user_id = map_get(payload, [:from_jid, "from_jid"]) || "unknown"
    %{user_id: user_id, user_name: user_id}
  end

  defp normalize_type(type) when is_atom(type), do: type

  defp normalize_type(type) when is_binary(type) do
    type
    |> String.trim()
    |> String.downcase()
    |> String.to_atom()
  end

  defp normalize_type(_), do: :other

  defp normalize_kind(kind) when kind in [:pn, :lid, :group], do: kind
  defp normalize_kind(kind) when kind in ["pn", "lid", "group"], do: String.to_atom(kind)
  defp normalize_kind(_), do: nil

  defp server_for(:pn), do: "s.whatsapp.net"
  defp server_for(:lid), do: "lid"
  defp server_for(:group), do: "g.us"

  defp chat_type(jid) when is_binary(jid) do
    if String.ends_with?(jid, "@g.us"), do: :group, else: :dm
  end

  defp normalize_timestamp(nil), do: nil
  defp normalize_timestamp(value) when is_integer(value), do: value

  defp normalize_timestamp(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> value
    end
  end

  defp normalize_timestamp(value), do: value

  defp normalize_metadata(%{} = metadata), do: metadata
  defp normalize_metadata(_), do: %{}

  defp truthy?(value) when value in [true, "true", "1", 1], do: true
  defp truthy?(_), do: false

  defp map_get(map, keys) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, fn key -> Map.get(map, key) end)
  end

  defp map_get(_other, _keys), do: nil
end
