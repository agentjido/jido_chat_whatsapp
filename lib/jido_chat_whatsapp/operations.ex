defmodule Jido.Chat.WhatsApp.Operations do
  @moduledoc false
  alias Jido.Chat.{Client, Signal}
  alias Jido.Chat.WhatsApp.Adapter

  @doc "Executes one supported WhatsApp operation."
  @spec invoke(atom(), Client.t(), Jido.Signal.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def invoke(operation, %Client{adapter: Adapter} = client, request, opts) do
    call(operation, client, request.data, Keyword.merge(Client.options(client), opts))
  end

  def invoke(_, _, _, _), do: {:error, {:not_attempted, :unsupported}}

  defp call(:send_message, client, data, opts) do
    jid = to_jid(data["room_id"])
    send_opts = optional([], :quoted, quoted_ref(data["reply_to_id"], jid))

    with {:ok, conn} <- client.transport.resolve_conn(opts),
         {:ok, id} <- client.transport.send_text(conn, jid, data["text"], send_opts) do
      message(id, jid, data["text"], "sent", data)
    end
  end

  defp call(:send_file, client, data, opts) do
    jid = to_jid(data["room_id"])
    media_type = if data["media_kind"] == "image", do: :image, else: :document

    with {:ok, bytes, filename} <- file_source(data["source"]),
         {:ok, conn} <- client.transport.resolve_conn(opts),
         media_opts <- [caption: data["caption"], file_name: filename] |> Enum.reject(&is_nil(elem(&1, 1))),
         {:ok, id} <- client.transport.send_media(conn, jid, media_type, bytes, media_opts) do
      message(id, jid, data["caption"] || "", "sent", data)
    end
  end

  defp call(:edit_message, client, data, opts) do
    jid = to_jid(data["room_id"])

    with {:ok, conn} <- client.transport.resolve_conn(opts),
         {:ok, id} <- client.transport.send_edit(conn, {jid, data["message_id"], true}, data["text"]) do
      message(id, jid, data["text"], "updated", data)
    end
  end

  defp call(:delete_message, client, data, opts) do
    jid = to_jid(data["room_id"])

    with {:ok, conn} <- client.transport.resolve_conn(opts),
         {:ok, _id} <- client.transport.send_revoke(conn, {jid, data["message_id"], true}) do
      {:ok, %{"acknowledged" => true}}
    end
  end

  defp call(:start_typing, client, data, opts) do
    with {:ok, conn} <- client.transport.resolve_conn(opts),
         :ok <- client.transport.send_chatstate(conn, to_jid(data["room_id"]), :composing) do
      {:ok, %{"acknowledged" => true}}
    end
  end

  defp call(operation, client, data, opts) when operation in [:add_reaction, :remove_reaction] do
    jid = to_jid(data["room_id"])
    emoji = if operation == :add_reaction, do: data["reaction"], else: ""

    with {:ok, conn} <- client.transport.resolve_conn(opts),
         {:ok, _id} <- client.transport.send_reaction(conn, {jid, data["message_id"], false}, emoji) do
      {:ok, %{"acknowledged" => true}}
    end
  end

  defp call(:fetch_metadata, _client, data, _opts) do
    jid = to_jid(data["room_id"])
    {:ok, %{"id" => jid, "room_id" => jid, "kind" => "conversation"}}
  end

  defp call(:open_dm, _client, data, _opts),
    do: {:ok, %{"id" => to_jid(data["user_id"]), "kind" => "direct"}}

  defp call(_, _, _, _), do: {:error, {:not_attempted, :unsupported}}

  defp message(id, room, text, status, data) do
    result =
      %{"id" => to_string(id), "room_id" => room, "text" => text, "status" => status}
      |> optional("reply_to_id", data["reply_to_id"])

    case Zoi.parse(Signal.Schemas.result(:message), result) do
      {:ok, checked} -> {:ok, checked}
      _ -> {:error, :invalid_provider_result}
    end
  end

  defp file_source(%{"content_base64" => content, "filename" => filename}) do
    case Base.decode64(content) do
      {:ok, bytes} when byte_size(bytes) > 0 -> {:ok, bytes, filename}
      _ -> {:error, :invalid_file_source}
    end
  end

  defp file_source(%{"kind" => "file", "id" => path}) do
    case File.read(path) do
      {:ok, bytes} -> {:ok, bytes, Path.basename(path)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp file_source(_), do: {:error, :invalid_file_source}
  defp quoted_ref(nil, _), do: nil
  defp quoted_ref(id, jid), do: {id, jid}

  defp to_jid(value) when is_binary(value) do
    if String.contains?(value, "@"), do: value, else: value <> "@s.whatsapp.net"
  end

  defp optional(value, _key, nil), do: value
  defp optional(value, key, item) when is_map(value), do: Map.put(value, key, item)
  defp optional(value, key, item) when is_list(value), do: Keyword.put(value, key, item)
end
