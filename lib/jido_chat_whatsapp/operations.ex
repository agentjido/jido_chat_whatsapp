defmodule Jido.Chat.WhatsApp.Operations do
  @moduledoc false

  alias Jido.Chat.{Client, Signal}
  alias Jido.Chat.WhatsApp.{Adapter, MessageFormatter, SendOptions}

  @native ~w(stream_text send_message send_file edit_message delete_message start_typing fetch_metadata fetch_thread get_user download_file add_reaction remove_reaction open_dm)a
  @option_keys ~w(conn connection profile quoted mentions caption seconds ptt ptv view_once file_name filename title status action)a

  @doc false
  @spec invoke(atom(), Client.t(), Jido.Signal.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def invoke(operation, %Client{adapter: Adapter} = client, request, opts)
      when operation in @native and is_list(opts) do
    call(operation, client, request.data, Keyword.merge(client.config, opts))
  rescue
    _ -> {:error, :invalid_request}
  catch
    _, _ -> {:error, :invalid_request}
  end

  def invoke(_, _, _, _), do: {:error, {:not_attempted, :unsupported}}

  defp call(:stream_text, client, data, opts) do
    case Jido.Chat.Adapter.render_stream(opts[:stream]) do
      text when is_binary(text) -> send_message(client, data, text, opts)
      _ -> {:error, :invalid_stream}
    end
  end

  defp call(:send_message, client, data, opts),
    do: send_message(client, data, data["text"], opts)

  defp call(:send_file, client, data, opts) do
    with {:ok, jid} <- jid(data["room_id"]),
         {:ok, bytes, filename} <- file_source(data["source"]),
         {:ok, send_opts} <- send_options(client, data, opts),
         {:ok, conn} <- resolve(client, send_opts),
         media_kind <- if(data["media_kind"] == "image", do: :image, else: :document),
         media_opts <-
           send_opts
           |> SendOptions.media_transport_opts()
           |> Keyword.put(:caption, render(data["caption"] || "", data["format"]))
           |> Keyword.put(:file_name, filename),
         {:ok, id} <- client.transport.send_media(conn, jid, media_kind, bytes, media_opts) do
      message(id, jid, data["caption"] || "", data)
    end
  end

  defp call(:edit_message, client, data, opts) do
    with {:ok, jid} <- jid(data["room_id"]),
         {:ok, send_opts} <- send_options(client, data, opts),
         {:ok, conn} <- resolve(client, send_opts),
         text <- render(data["text"], data["format"]),
         {:ok, id} <-
           client.transport.send_edit(
             conn,
             {jid, data["message_id"], true},
             text
           ) do
      message(id, jid, text, Map.put(data, "status", "updated"))
    end
  end

  defp call(:delete_message, client, data, opts) do
    with {:ok, jid} <- jid(data["room_id"]),
         {:ok, send_opts} <- send_options(client, data, opts),
         {:ok, conn} <- resolve(client, send_opts),
         {:ok, _} <-
           client.transport.send_revoke(
             conn,
             {jid, data["message_id"], true}
           ) do
      acknowledgement()
    end
  end

  defp call(:start_typing, client, data, opts) do
    with {:ok, jid} <- jid(data["room_id"]),
         {:ok, send_opts} <- send_options(client, data, opts),
         {:ok, conn} <- resolve(client, send_opts),
         :ok <-
           client.transport.send_chatstate(
             conn,
             jid,
             chatstate(data["state"] || data["action"] || send_opts.status || send_opts.action)
           ) do
      acknowledgement()
    end
  end

  defp call(:fetch_metadata, _client, data, _opts) do
    with {:ok, jid} <- jid(data["room_id"]) do
      result(:conversation, %{
        "id" => jid,
        "kind" => if(String.ends_with?(jid, "@g.us"), do: "group", else: "direct")
      })
    end
  end

  defp call(:fetch_thread, _client, data, _opts) do
    result(:thread, %{
      "id" => data["thread_id"],
      "room_id" => data["room_id"],
      "parent_message_id" => nil,
      "delivery_room_ref" => data["room_id"]
    })
  end

  defp call(:get_user, client, data, opts) do
    with true <- function_exported?(client.transport, :user_phone, 2),
         {:ok, send_opts} <- send_options(client, data, opts),
         {:ok, conn} <- resolve(client, send_opts),
         {:ok, phone} <- client.transport.user_phone(conn, data["user_id"]) do
      result(:user, compact(%{"id" => data["user_id"], "username" => phone}))
    else
      false -> {:error, {:not_attempted, :unsupported}}
      error -> error
    end
  end

  defp call(:download_file, client, data, opts) do
    reference = data["resource_ref"]

    with true <- reference["client_id"] == client.id,
         true <- reference["kind"] == "media",
         "whatsapp://media/v1/" <> _ = token <- reference["id"],
         true <- byte_size(token) <= 24_000,
         true <- function_exported?(client.transport, :resolve_media_reference, 2),
         {:ok, send_opts} <- send_options(client, data, opts),
         {:ok, conn} <- resolve(client, send_opts),
         {:ok, media} <- client.transport.resolve_media_reference(conn, token),
         {:ok, bytes} when is_binary(bytes) <- client.transport.download_media(media) do
      result(:resource, %{"content_base64" => Base.encode64(bytes)})
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_resource_reference}
    end
  end

  defp call(operation, client, data, opts) when operation in [:add_reaction, :remove_reaction] do
    reaction = if(operation == :remove_reaction, do: "", else: data["reaction"])

    with {:ok, jid} <- jid(data["room_id"]),
         {:ok, send_opts} <- send_options(client, data, opts),
         {:ok, conn} <- resolve(client, send_opts),
         {:ok, _} <-
           client.transport.send_reaction(
             conn,
             {jid, data["message_id"], false},
             reaction
           ) do
      acknowledgement()
    end
  end

  defp call(:open_dm, _client, data, _opts) do
    with {:ok, jid} <- jid(data["user_id"]) do
      result(:conversation, %{"id" => jid, "kind" => "direct"})
    end
  end

  defp send_message(client, data, source, opts) when is_binary(source) do
    with {:ok, jid} <- jid(data["room_id"]),
         {:ok, send_opts} <- send_options(client, data, opts),
         {:ok, conn} <- resolve(client, send_opts),
         text <- render(source, data["format"]),
         {:ok, id} <-
           client.transport.send_text(
             conn,
             jid,
             text,
             SendOptions.text_transport_opts(send_opts)
           ) do
      message(id, jid, text, data)
    end
  end

  defp send_message(_, _, _, _), do: {:error, :invalid_message}

  defp send_options(client, data, opts) do
    values =
      opts
      |> Keyword.take(@option_keys)
      |> Keyword.put(:transport, client.transport)
      |> maybe_put(:quoted, quoted(data))
      |> maybe_put(:format, format(data["format"]))

    {:ok, SendOptions.new(values)}
  rescue
    _ -> {:error, :invalid_options}
  end

  defp resolve(client, send_opts),
    do: client.transport.resolve_conn(SendOptions.conn_opts(send_opts))

  defp file_source(%{"content_base64" => content, "filename" => filename}) do
    case Base.decode64(content) do
      {:ok, bytes} when byte_size(bytes) > 0 -> {:ok, bytes, filename}
      _ -> {:error, :invalid_file_source}
    end
  end

  defp file_source(_), do: {:error, :invalid_file_source}

  defp message(id, room_id, text, data) do
    result(
      :message,
      compact(%{
        "id" => identifier(id),
        "room_id" => room_id,
        "text" => text,
        "status" => data["status"] || "sent",
        "thread_id" => data["thread_id"],
        "reply_to_id" => data["reply_to_id"]
      })
    )
  end

  defp acknowledgement, do: result(:acknowledgement, %{"acknowledged" => true})

  defp result(kind, value) do
    case Jido.Joi.parse(Signal.Schemas.result(kind), value) do
      {:ok, checked} -> {:ok, checked}
      _ -> {:error, :invalid_provider_result}
    end
  end

  defp jid(value) when is_binary(value) and value != "" do
    if String.contains?(value, "@") do
      {:ok, value}
    else
      {:ok, value |> Amarula.Address.pn() |> Amarula.Address.to_jid!()}
    end
  rescue
    _ -> {:error, :invalid_room}
  end

  defp jid(_), do: {:error, :invalid_room}

  defp quoted(%{"reply_to_id" => id, "room_id" => room})
       when is_binary(id) and id != "" and is_binary(room),
       do: {room, id, false}

  defp quoted(_), do: nil
  defp format("markdown"), do: :markdown
  defp format(_), do: :plain_text
  defp render(value, format), do: MessageFormatter.render(value, format(format))

  defp chatstate(value) when value in [:recording, "recording"], do: :recording
  defp chatstate(value) when value in [:paused, "paused", :stop, "stop"], do: :paused
  defp chatstate(_), do: :composing

  defp maybe_put(keyword, _key, nil), do: keyword
  defp maybe_put(keyword, key, value), do: Keyword.put(keyword, key, value)
  defp compact(map), do: Map.reject(map, fn {_, value} -> is_nil(value) end)
  defp identifier(nil), do: nil
  defp identifier(value), do: to_string(value)
end
