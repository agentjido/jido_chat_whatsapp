defmodule Jido.Chat.WhatsApp.Adapter do
  @moduledoc """
  WhatsApp `Jido.Chat.Adapter` implementation using Amarula.
  """

  use Jido.Chat.Adapter

  alias Jido.Chat.{
    ActionEvent,
    ChannelInfo,
    EventEnvelope,
    FileUpload,
    Incoming,
    Response,
    WebhookRequest,
    WebhookResponse
  }

  alias Jido.Chat.WhatsApp.{ConnectionWorker, Message, SendOptions}
  alias Jido.Chat.WhatsApp.Transport.AmarulaClient

  @impl true
  def channel_type, do: :whatsapp

  @impl true
  @spec capabilities() :: map()
  def capabilities,
    do: %{
      initialize: :fallback,
      shutdown: :fallback,
      send_message: :native,
      send_file: :native,
      edit_message: :native,
      delete_message: :native,
      start_typing: :native,
      fetch_metadata: :native,
      fetch_thread: :fallback,
      fetch_message: :unsupported,
      add_reaction: :native,
      remove_reaction: :native,
      post_ephemeral: :unsupported,
      open_dm: :native,
      fetch_messages: :unsupported,
      fetch_channel_messages: :unsupported,
      list_threads: :unsupported,
      open_thread: :unsupported,
      post_channel_message: :fallback,
      stream: :fallback,
      open_modal: :unsupported,
      webhook: :fallback,
      verify_webhook: :fallback,
      parse_event: :native,
      format_webhook_response: :native
    }

  @impl true
  def listener_child_specs(bridge_id, opts \\ []) when is_binary(bridge_id) and is_list(opts) do
    ingress = normalize_ingress_opts(opts)

    case ingress_mode(ingress) do
      :linked_device ->
        with {:ok, sink_mfa} <- validate_sink_mfa(Keyword.get(opts, :sink_mfa)) do
          {:ok,
           [
             Supervisor.child_spec(
               {ConnectionWorker, connection_worker_opts(bridge_id, ingress, opts, sink_mfa)},
               id: {:whatsapp_connection_worker, bridge_id}
             )
           ]}
        end

      :manual ->
        {:ok, []}

      :invalid ->
        {:error, :invalid_ingress_mode}
    end
  end

  @impl true
  def transform_incoming(%Amarula.Msg{} = msg) do
    with {:ok, attrs} <- Message.incoming_attrs(msg) do
      {:ok, Incoming.new(attrs)}
    end
  end

  def transform_incoming(%{message: message}) when is_map(message), do: transform_incoming(message)
  def transform_incoming(%{"message" => message}) when is_map(message), do: transform_incoming(message)

  def transform_incoming(%{} = payload) do
    with {:ok, attrs} <- Message.incoming_attrs(payload) do
      {:ok, Incoming.new(attrs)}
    end
  end

  def transform_incoming(_), do: {:error, :unsupported_message_type}

  @impl true
  def send_message(jid, text, opts \\ []) do
    opts = SendOptions.new(opts)
    jid = to_jid(jid)

    with {:ok, conn} <- transport(opts).resolve_conn(SendOptions.conn_opts(opts)),
         {:ok, msg_id} <- transport(opts).send_text(conn, jid, text, SendOptions.text_transport_opts(opts)) do
      {:ok,
       Response.new(%{
         external_message_id: msg_id,
         external_room_id: jid,
         channel_type: :whatsapp,
         status: :sent,
         raw: %{id: msg_id, jid: jid}
       })}
    end
  end

  @impl true
  def send_file(jid, file, opts \\ []) do
    opts = SendOptions.new(opts)
    upload = FileUpload.normalize(file)
    jid = to_jid(jid)

    with {:ok, conn} <- transport(opts).resolve_conn(SendOptions.conn_opts(opts)),
         {:ok, media_type, data, media_opts} <- upload_input(upload, opts),
         {:ok, msg_id} <- transport(opts).send_media(conn, jid, media_type, data, media_opts) do
      {:ok,
       Response.new(%{
         external_message_id: msg_id,
         external_room_id: jid,
         channel_type: :whatsapp,
         status: :sent,
         raw: %{id: msg_id, jid: jid, media_type: media_type},
         metadata: %{filename: upload.filename, media_type: upload.media_type}
       })}
    end
  end

  @impl true
  def edit_message(jid, message_id, text, opts \\ []) do
    opts = SendOptions.new(opts)
    jid = to_jid(jid)

    with {:ok, conn} <- transport(opts).resolve_conn(SendOptions.conn_opts(opts)),
         {:ok, msg_id} <- transport(opts).send_edit(conn, {jid, to_string(message_id)}, text) do
      {:ok,
       Response.new(%{
         external_message_id: msg_id,
         external_room_id: jid,
         channel_type: :whatsapp,
         status: :edited,
         raw: %{id: msg_id, jid: jid, edited_message_id: message_id}
       })}
    end
  end

  @impl true
  def delete_message(jid, message_id, opts \\ []) do
    opts = SendOptions.new(opts)

    with {:ok, conn} <- transport(opts).resolve_conn(SendOptions.conn_opts(opts)),
         {:ok, _msg_id} <- transport(opts).send_revoke(conn, {to_jid(jid), to_string(message_id)}) do
      :ok
    end
  end

  @impl true
  def start_typing(jid, opts \\ []) do
    opts = SendOptions.new(opts)
    chatstate = chatstate(opts.status || opts.action)

    with {:ok, conn} <- transport(opts).resolve_conn(SendOptions.conn_opts(opts)) do
      transport(opts).send_chatstate(conn, to_jid(jid), chatstate)
    end
  end

  @impl true
  def fetch_metadata(jid, _opts \\ []) do
    jid = to_jid(jid)

    {:ok,
     ChannelInfo.new(%{
       id: jid,
       name: nil,
       is_dm: not String.ends_with?(jid, "@g.us"),
       member_count: nil,
       metadata: %{jid: jid, chat_type: if(String.ends_with?(jid, "@g.us"), do: :group, else: :dm)}
     })}
  end

  @impl true
  def open_dm(user_id, _opts \\ []) do
    {:ok, to_jid(user_id)}
  end

  @impl true
  def add_reaction(jid, message_id, emoji, opts \\ []) do
    opts = SendOptions.new(opts)

    with {:ok, conn} <- transport(opts).resolve_conn(SendOptions.conn_opts(opts)),
         {:ok, _msg_id} <- transport(opts).send_reaction(conn, {to_jid(jid), to_string(message_id)}, emoji) do
      :ok
    end
  end

  @impl true
  def remove_reaction(jid, message_id, _emoji, opts \\ []) do
    opts = SendOptions.new(opts)

    with {:ok, conn} <- transport(opts).resolve_conn(SendOptions.conn_opts(opts)),
         {:ok, _msg_id} <- transport(opts).send_reaction(conn, {to_jid(jid), to_string(message_id)}, "") do
      :ok
    end
  end

  @impl true
  def verify_webhook(%WebhookRequest{}, _opts \\ []), do: :ok

  @impl true
  def parse_event(%WebhookRequest{payload: payload}, opts \\ []) do
    parse_payload_event(payload, opts)
  end

  @impl true
  def format_webhook_response(result, _opts \\ [])
  def format_webhook_response({:ok, _chat, :noop}, _opts), do: WebhookResponse.accepted(%{ok: true})
  def format_webhook_response({:ok, _chat, _event}, _opts), do: WebhookResponse.accepted(%{ok: true})
  def format_webhook_response({:error, reason}, _opts), do: WebhookResponse.error(400, %{error: to_string(reason)})

  @doc """
  Requests a WhatsApp link-code pairing code for a running Amarula connection.
  """
  @spec request_pairing_code(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def request_pairing_code(phone, opts \\ []) when is_binary(phone) and is_list(opts) do
    opts = SendOptions.new(opts)

    with {:ok, conn} <- transport(opts).resolve_conn(SendOptions.conn_opts(opts)) do
      transport(opts).request_pairing_code(conn, phone, [])
    end
  end

  defp parse_payload_event(%{} = payload, _opts) do
    case payload_event(payload) do
      {:message, payload} ->
        with {:ok, %Incoming{} = incoming} <- transform_incoming(payload) do
          {:ok,
           EventEnvelope.new(%{
             adapter_name: :whatsapp,
             event_type: :message,
             thread_id: Message.thread_id(to_string(incoming.external_room_id)),
             channel_id: to_string(incoming.external_room_id),
             message_id: stringify(incoming.external_message_id),
             payload: incoming,
             raw: payload,
             metadata: %{source: :payload}
           })}
        end

      {:reaction, payload} ->
        with {:ok, reaction} <- Message.reaction_event(payload) do
          {:ok,
           EventEnvelope.new(%{
             adapter_name: :whatsapp,
             event_type: :reaction,
             thread_id: reaction.thread_id,
             channel_id: reaction.channel_id,
             message_id: reaction.message_id,
             payload: reaction,
             raw: payload,
             metadata: %{source: :payload}
           })}
        end

      {:action, event_name, data} ->
        {:ok, action_envelope(event_name, data)}

      :noop ->
        {:ok, :noop}
    end
  end

  defp payload_event(payload) do
    cond do
      event_envelope_shape?(payload) ->
        :noop

      payload_type(payload) == :reaction ->
        {:reaction, payload}

      payload_type(payload) in [:text, :media, :edit, :revoke, :other] ->
        {:message, payload}

      event_name = map_get(payload, [:event, "event"]) ->
        {:action, event_name, map_get(payload, [:data, "data"]) || payload}

      true ->
        {:message, payload}
    end
  end

  defp action_envelope(event_name, data) do
    normalized_data = ensure_map(data)
    event_name = to_string(event_name)
    profile = map_get(normalized_data, [:profile, "profile"]) || "unknown"

    action =
      ActionEvent.new(%{
        adapter_name: :whatsapp,
        thread_id: "whatsapp:profile:#{profile}",
        channel_id: "profile:#{profile}",
        action_id: event_name,
        value: action_value(event_name, normalized_data),
        raw: normalized_data,
        metadata: %{source: :payload}
      })

    EventEnvelope.new(%{
      adapter_name: :whatsapp,
      event_type: :action,
      thread_id: action.thread_id,
      channel_id: action.channel_id,
      payload: action,
      raw: normalized_data,
      metadata: %{source: :payload, event: event_name}
    })
  end

  defp action_value("connection_update", data) do
    data
    |> map_get([:connection, "connection"])
    |> case do
      nil -> if map_get(data, [:qr, "qr"]), do: "qr", else: "connection_update"
      value -> to_string(value)
    end
  end

  defp action_value("pairing_code", data), do: to_string(map_get(data, [:code, "code"]) || "pairing_code")
  defp action_value(event_name, _data), do: event_name

  defp upload_input(%FileUpload{} = upload, %SendOptions{} = opts) do
    with {:ok, data} <- upload_data(upload) do
      media_type = upload.kind |> whatsapp_media_type()

      media_opts =
        opts
        |> SendOptions.media_transport_opts()
        |> Keyword.put_new(:caption, upload_caption(upload, opts))
        |> Keyword.put_new(:file_name, upload.filename)
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)

      {:ok, media_type, data, media_opts}
    end
  end

  defp upload_data(%FileUpload{data: data}) when is_binary(data), do: {:ok, data}
  defp upload_data(%FileUpload{path: path}) when is_binary(path), do: File.read(path)
  defp upload_data(%FileUpload{url: url}) when is_binary(url), do: {:error, {:unsupported_remote_upload, url}}
  defp upload_data(_upload), do: {:error, :missing_upload_data}

  defp upload_caption(%FileUpload{} = upload, %SendOptions{} = opts) do
    opts.caption || upload.metadata[:caption] || upload.metadata["caption"]
  end

  defp whatsapp_media_type(:image), do: :image
  defp whatsapp_media_type(:video), do: :video
  defp whatsapp_media_type(:audio), do: :audio
  defp whatsapp_media_type(:file), do: :document

  defp chatstate(nil), do: :composing
  defp chatstate(:typing), do: :composing
  defp chatstate("typing"), do: :composing
  defp chatstate(:recording), do: :recording
  defp chatstate("recording"), do: :recording
  defp chatstate(:paused), do: :paused
  defp chatstate("paused"), do: :paused
  defp chatstate(:stop), do: :paused
  defp chatstate("stop"), do: :paused
  defp chatstate(_), do: :composing

  defp connection_worker_opts(bridge_id, ingress, opts, sink_mfa) do
    profile = configured_profile(bridge_id, ingress, opts)

    [
      bridge_id: bridge_id,
      sink_mfa: sink_mfa,
      sink_opts: [bridge_id: bridge_id],
      transport: get_map_value(ingress, [:transport, "transport"]) || AmarulaClient,
      config: connection_config(profile, ingress, opts),
      connect_opts: connection_connect_opts(ingress)
    ]
  end

  defp connection_config(profile, ingress, opts) do
    settings = Keyword.get(opts, :settings, %{}) |> ensure_map()

    settings
    |> get_map_value([:amarula, "amarula", :config, "config"])
    |> ensure_map()
    |> Map.merge(get_map_value(ingress, [:amarula, "amarula", :config, "config"]) |> ensure_map())
    |> Map.put(:profile, profile)
    |> maybe_put_storage(ingress)
  end

  defp maybe_put_storage(config, ingress) do
    case get_map_value(ingress, [:storage_root, "storage_root"]) do
      nil -> config
      root -> Map.put(config, :storage, {Amarula.Storage.File, root: root})
    end
  end

  defp connection_connect_opts(ingress) do
    ingress
    |> get_map_value([:connect_opts, "connect_opts"])
    |> case do
      opts when is_list(opts) -> opts
      _ -> []
    end
  end

  defp configured_profile(bridge_id, ingress, opts) do
    settings = Keyword.get(opts, :settings, %{}) |> ensure_map()

    get_map_value(ingress, [:profile, "profile"]) ||
      get_map_value(settings, [:profile, "profile", :whatsapp_profile, "whatsapp_profile"]) ||
      "jido_chat_whatsapp_#{bridge_id}"
  end

  defp normalize_ingress_opts(opts) do
    ingress = Keyword.get(opts, :ingress, %{}) |> ensure_map()
    settings = Keyword.get(opts, :settings, %{}) |> ensure_map()
    settings_ingress = get_map_value(settings, [:ingress, "ingress"]) |> ensure_map()
    Map.merge(settings_ingress, ingress)
  end

  defp ingress_mode(ingress) do
    case get_map_value(ingress, [:mode, "mode"]) do
      nil -> :manual
      :manual -> :manual
      "manual" -> :manual
      :linked_device -> :linked_device
      "linked_device" -> :linked_device
      :amarula -> :linked_device
      "amarula" -> :linked_device
      _ -> :invalid
    end
  end

  defp validate_sink_mfa({module, function, args})
       when is_atom(module) and is_atom(function) and is_list(args),
       do: {:ok, {module, function, args}}

  defp validate_sink_mfa(_), do: {:error, :invalid_sink_mfa}

  defp event_envelope_shape?(map) when is_map(map) do
    Map.has_key?(map, :event_type) or Map.has_key?(map, "event_type")
  end

  defp payload_type(payload) when is_map(payload) do
    payload
    |> map_get([:type, "type"])
    |> normalize_type()
  end

  defp normalize_type(type) when is_atom(type), do: type

  defp normalize_type(type) when is_binary(type) do
    type
    |> String.trim()
    |> String.downcase()
    |> String.to_atom()
  end

  defp normalize_type(_), do: :other

  defp transport(%SendOptions{transport: transport}), do: transport
  defp transport(_opts), do: AmarulaClient

  defp to_jid(%Amarula.Address{} = address), do: Amarula.Address.to_jid!(address)

  defp to_jid(value) when is_binary(value) do
    if String.contains?(value, "@") do
      value
    else
      value |> Amarula.Address.pn() |> Amarula.Address.to_jid!()
    end
  end

  defp to_jid(value), do: to_string(value)

  defp ensure_map(%{} = map), do: map
  defp ensure_map(_), do: %{}

  defp map_get(map, keys), do: get_map_value(map, keys)

  defp get_map_value(map, keys) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, fn key -> Map.get(map, key) end)
  end

  defp get_map_value(_other, _keys), do: nil

  defp stringify(nil), do: nil
  defp stringify(value) when is_binary(value), do: value
  defp stringify(value), do: to_string(value)
end
