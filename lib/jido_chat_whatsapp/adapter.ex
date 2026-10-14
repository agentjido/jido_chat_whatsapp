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
    Media,
    Response,
    UserInfo,
    WebhookRequest,
    WebhookResponse
  }

  alias Jido.Chat.WhatsApp.{ConnectionWorker, Message, SendOptions}
  alias Jido.Chat.WhatsApp.Transport.AmarulaClient

  @media_type_pattern ~r/^[a-z0-9!#$&^_.+-]+\/[a-z0-9!#$&^_.+-]+$/

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
      fetch_media: :native,
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
  def transform_incoming(payload), do: transform_incoming(payload, [])

  @doc """
  Normalizes an incoming message with optional connection-scoped media references.

  Supplying `:conn`, `:connection` or `:profile` seals media descriptors through
  the transport. Only public media metadata and an opaque reference leave this
  boundary; raw media payloads are omitted. The listener always uses this mode.
  Without connection options, the legacy structured-reference API is preserved.
  """
  @spec transform_incoming(term(), keyword()) :: {:ok, Incoming.t()} | {:error, term()}
  def transform_incoming(%{message: message}, opts) when is_map(message), do: transform_incoming(message, opts)
  def transform_incoming(%{"message" => message}, opts) when is_map(message), do: transform_incoming(message, opts)

  def transform_incoming(%{} = payload, opts) when is_list(opts) do
    with {:ok, attrs} <- Message.incoming_attrs(payload),
         {:ok, attrs} <- normalize_media_references(attrs, opts) do
      {:ok, Incoming.new(attrs)}
    end
  end

  def transform_incoming(_, _), do: {:error, :unsupported_message_type}

  @impl true
  def get_user(jid, opts \\ []) do
    opts = SendOptions.new(opts)
    client = transport(opts)

    with true <-
           (Code.ensure_loaded?(client) and function_exported?(client, :user_phone, 2)) || {:error, :unsupported},
         {:ok, conn} <- client.resolve_conn(SendOptions.conn_opts(opts)),
         {:ok, phone} <- client.user_phone(conn, jid) do
      {:ok, UserInfo.new(%{id: jid, metadata: %{phone: phone}})}
    end
  end

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

  @doc """
  Fetches and decrypts the bytes behind an inbound WhatsApp media reference.

  Accepts a `whatsapp://media/v1/...` reference or normalized media containing
  it. Supply the originating profile or connection in opts, as for sending.
  The transport resolves the private descriptor using persisted credentials.
  Legacy structured descriptors remain supported for trusted direct callers.
  """
  @impl true
  def fetch_media(reference, opts \\ []) when is_list(opts) do
    transport = Keyword.get(opts, :transport, AmarulaClient)

    with {:ok, descriptor} <- resolve_media_reference(reference, transport, opts),
         {:ok, media} <- amarula_media(descriptor) do
      transport.download_media(media)
    end
  end

  @impl true
  def edit_message(jid, message_id, text, opts \\ []) do
    opts = SendOptions.new(opts)
    jid = to_jid(jid)

    with {:ok, conn} <- transport(opts).resolve_conn(SendOptions.conn_opts(opts)),
         {:ok, msg_id} <- transport(opts).send_edit(conn, {jid, to_string(message_id), true}, text) do
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
         {:ok, _msg_id} <-
           transport(opts).send_revoke(conn, {to_jid(jid), to_string(message_id), true}) do
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
         {:ok, _msg_id} <-
           transport(opts).send_reaction(
             conn,
             {to_jid(jid), to_string(message_id), false},
             emoji
           ) do
      :ok
    end
  end

  @impl true
  def remove_reaction(jid, message_id, _emoji, opts \\ []) do
    opts = SendOptions.new(opts)

    with {:ok, conn} <- transport(opts).resolve_conn(SendOptions.conn_opts(opts)),
         {:ok, _msg_id} <-
           transport(opts).send_reaction(
             conn,
             {to_jid(jid), to_string(message_id), false},
             ""
           ) do
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

  defp parse_payload_event(%{} = payload, opts) do
    case payload_event(payload) do
      {:message, payload} ->
        with {:ok, %Incoming{} = incoming} <- transform_incoming(payload, opts) do
          {:ok,
           EventEnvelope.new(%{
             adapter_name: :whatsapp,
             event_type: :message,
             thread_id: Message.thread_id(to_string(incoming.external_room_id)),
             channel_id: to_string(incoming.external_room_id),
             message_id: stringify(incoming.external_message_id),
             payload: incoming,
             raw: incoming.raw,
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

  defp normalize_media_references(%{media: []} = attrs, _opts), do: {:ok, attrs}

  defp normalize_media_references(attrs, opts) do
    if Enum.any?([:conn, :connection, :profile], &Keyword.get(opts, &1)) do
      client = Keyword.get(opts, :transport, AmarulaClient)

      with {:ok, conn} <- client.resolve_conn(opts),
           {:ok, media} <- seal_media_entries(attrs.media, client, conn) do
        {:ok, %{attrs | media: media, raw: %{}}}
      end
    else
      {:ok, attrs}
    end
  end

  defp seal_media_entries(entries, client, conn) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
      with {:ok, descriptor} <- amarula_media(entry),
           {:ok, reference} when is_binary(reference) <- media_callback(client, :media_reference, conn, descriptor) do
        public = entry |> Map.put(:url, reference) |> Map.put(:metadata, %{file_id: reference})
        {:cont, {:ok, acc ++ [public]}}
      else
        {:error, _} = error -> {:halt, error}
        _ -> {:halt, {:error, :invalid_media_reference}}
      end
    end)
  end

  defp resolve_media_reference(reference, client, opts) do
    case opaque_media_reference(reference) do
      nil ->
        {:ok, reference}

      "whatsapp://media/v1/" <> _ = token when byte_size(token) <= 24_000 ->
        with {:ok, conn} <- client.resolve_conn(opts) do
          media_callback(client, :resolve_media_reference, conn, token)
        end

      _ ->
        {:error, :invalid_media_reference}
    end
  end

  defp opaque_media_reference(reference) when is_binary(reference), do: reference

  defp opaque_media_reference(%{} = reference) do
    metadata = map_get(reference, [:metadata, "metadata"])
    metadata = if is_map(metadata), do: metadata, else: %{}

    [map_get(metadata, [:file_id, "file_id"]), map_get(reference, [:url, "url"])]
    |> Enum.find(fn value -> is_binary(value) and String.starts_with?(value, "whatsapp://media/") end)
  end

  defp opaque_media_reference(_), do: nil

  defp media_callback(client, operation, conn, value) do
    if Code.ensure_loaded?(client) and function_exported?(client, operation, 2),
      do: apply(client, operation, [conn, value]),
      else: {:error, :media_reference_unsupported}
  rescue
    _ -> {:error, :media_reference_unavailable}
  catch
    _, _ -> {:error, :media_reference_unavailable}
  end

  defp amarula_media(%Amarula.Content.Media{} = media), do: validate_amarula_media(media)

  defp amarula_media(%Media{} = media) do
    build_amarula_media(Map.from_struct(media), media.metadata)
  end

  defp amarula_media(%{} = reference) do
    metadata = map_get(reference, [:metadata, "metadata"])
    build_amarula_media(reference, if(is_map(metadata), do: metadata, else: %{}))
  end

  defp amarula_media(_reference), do: {:error, :invalid_media_reference}

  defp build_amarula_media(reference, metadata) do
    with {:ok, kind} <-
           amarula_media_kind(media_value(reference, metadata, [:kind, "kind", :type, "type"])) do
      media =
        struct(Amarula.Content.Media,
          kind: kind,
          mimetype: media_type_value(reference, metadata),
          caption: media_value(reference, metadata, [:caption, "caption"]),
          file_length: media_value(reference, metadata, [:file_length, "file_length", :size_bytes, "size_bytes"]),
          width: media_value(reference, metadata, [:width, "width"]),
          height: media_value(reference, metadata, [:height, "height"]),
          seconds: media_value(reference, metadata, [:seconds, "seconds", :duration, "duration"]),
          file_name: media_value(reference, metadata, [:file_name, "file_name", :filename, "filename"]),
          url: media_value(reference, metadata, [:url, "url"]),
          direct_path: media_value(reference, metadata, [:direct_path, "direct_path"]),
          media_key: media_value(reference, metadata, [:media_key, "media_key"]),
          file_sha256: media_value(reference, metadata, [:file_sha256, "file_sha256"]),
          file_enc_sha256: media_value(reference, metadata, [:file_enc_sha256, "file_enc_sha256"])
        )

      validate_amarula_media(media)
    end
  end

  defp media_value(reference, metadata, keys), do: map_get(metadata, keys) || map_get(reference, keys)

  defp media_type_value(reference, metadata) do
    keys = [:mimetype, "mimetype", :media_type, "media_type"]
    normalize_media_type(map_get(metadata, keys)) || normalize_media_type(map_get(reference, keys))
  end

  defp validate_amarula_media(%Amarula.Content.Media{} = media) do
    media = sanitize_media_locator(media)

    if valid_media_kind?(media.kind) and valid_media_key?(media.media_key) and
         valid_media_locator?(media) and valid_media_hash?(media.file_sha256) and
         valid_media_hash?(media.file_enc_sha256) do
      {:ok, media}
    else
      {:error, :invalid_media_reference}
    end
  end

  defp sanitize_media_locator(%Amarula.Content.Media{direct_path: path} = media) do
    if valid_direct_path?(path), do: %{media | url: nil}, else: media
  end

  defp valid_media_kind?(kind), do: kind in [:image, :video, :audio, :document, :sticker]
  defp valid_media_key?(key), do: is_binary(key) and byte_size(key) == 32

  defp valid_media_locator?(media) do
    valid_direct_path?(media.direct_path) or valid_media_url?(media.url)
  end

  defp valid_direct_path?(path), do: is_binary(path) and path != "" and String.starts_with?(path, "/")

  defp valid_media_url?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host} when is_binary(host) ->
        host = String.downcase(host)
        host == "whatsapp.net" or String.ends_with?(host, ".whatsapp.net")

      _other ->
        false
    end
  end

  defp valid_media_url?(_url), do: false

  defp valid_media_hash?(nil), do: true
  defp valid_media_hash?(hash), do: is_binary(hash) and byte_size(hash) == 32

  defp normalize_media_type(value) when is_binary(value) do
    trimmed = String.trim(value)

    if Regex.match?(@media_type_pattern, canonical_media_type(trimmed)),
      do: trimmed,
      else: nil
  end

  defp normalize_media_type(_value), do: nil

  defp canonical_media_type(value) do
    value
    |> String.split(";", parts: 2)
    |> hd()
    |> String.trim()
    |> String.downcase()
  end

  defp amarula_media_kind(kind) when kind in [:image, :video, :audio, :document, :sticker], do: {:ok, kind}
  defp amarula_media_kind(:file), do: {:ok, :document}
  defp amarula_media_kind("image"), do: {:ok, :image}
  defp amarula_media_kind("video"), do: {:ok, :video}
  defp amarula_media_kind("audio"), do: {:ok, :audio}
  defp amarula_media_kind("document"), do: {:ok, :document}
  defp amarula_media_kind("sticker"), do: {:ok, :sticker}
  defp amarula_media_kind("file"), do: {:ok, :document}
  defp amarula_media_kind(_kind), do: {:error, :invalid_media_reference}

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
      identity_timeout_ms: Keyword.get(opts, :identity_timeout_ms, 2_500),
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
    |> put_history_options(ingress)
    |> maybe_put_storage(ingress)
    |> then(fn config ->
      case get_map_value(ingress, [:storage, "storage"]) do
        nil -> config
        storage -> Map.put(config, :storage, storage)
      end
    end)
  end

  defp put_history_options(config, ingress) do
    Enum.reduce([:sync_history, :sync_full_history], config, fn key, acc ->
      value =
        Map.get(
          ingress,
          key,
          Map.get(ingress, Atom.to_string(key), Map.get(acc, key, Map.get(acc, Atom.to_string(key), true)))
        )

      Map.put(acc, key, value)
    end)
  end

  defp maybe_put_storage(config, ingress) do
    case get_map_value(ingress, [:storage_root, "storage_root"]) do
      nil -> config
      root -> Map.put(config, :storage_root, root)
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
