defmodule Jido.Chat.WhatsApp.Adapter do
  @moduledoc "WhatsApp `Jido.Chat.Adapter` implementation using Amarula.\n"
  use Jido.Chat.Adapter
  alias Jido.Chat.{ChannelInfo, FileUpload, Media, WebhookRequest, WebhookResponse}
  alias Jido.Chat.WhatsApp.{ConnectionWorker, Message, SendOptions}
  alias Jido.Chat.WhatsApp.Transport.AmarulaClient
  @media_type_pattern ~r/^[a-z0-9!#$&^_.+-]+\/[a-z0-9!#$&^_.+-]+$/
  @impl true
  def channel_type do
    :whatsapp
  end

  @impl true
  @spec capabilities() :: map()
  def capabilities do
    %{
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
      normalize_event: :native,
      format_webhook_response: :native
    }
  end

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

  defp provider_message(%Amarula.Msg{} = msg) do
    with {:ok, attrs} <- Message.incoming_attrs(msg) do
      {:ok, attrs}
    end
  end

  defp provider_message(%{message: message}) when is_map(message) do
    provider_message(message)
  end

  defp provider_message(%{"message" => message}) when is_map(message) do
    provider_message(message)
  end

  defp provider_message(%{} = payload) do
    with {:ok, attrs} <- Message.incoming_attrs(payload) do
      {:ok, attrs}
    end
  end

  defp provider_message(_) do
    {:error, :unsupported_message_type}
  end

  @impl true
  def send_message(jid, text, opts \\ []) do
    opts = SendOptions.new(opts)
    jid = to_jid(jid)

    with {:ok, conn} <- transport(opts).resolve_conn(SendOptions.conn_opts(opts)),
         {:ok, msg_id} <-
           transport(opts).send_text(conn, jid, text, SendOptions.text_transport_opts(opts)) do
      {:ok,
       %{
         external_message_id: msg_id,
         external_room_id: jid,
         channel_type: :whatsapp,
         status: :sent,
         raw: %{id: msg_id, jid: jid}
       }}
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
       %{
         external_message_id: msg_id,
         external_room_id: jid,
         channel_type: :whatsapp,
         status: :sent,
         raw: %{id: msg_id, jid: jid, media_type: media_type},
         metadata: %{filename: upload.filename, media_type: upload.media_type}
       }}
    end
  end

  @doc "Fetches and decrypts the bytes behind an inbound WhatsApp media reference.\n\nWhatsApp media needs the CDN path, media key, and encrypted-file hash. These\nvalues are kept in the normalized media metadata and passed to Amarula. A\nreference must contain a 32-byte media key and either a direct CDN path or an\nHTTPS URL on a WhatsApp host.\n"
  @impl true
  def fetch_media(reference, opts \\ []) when is_list(opts) do
    with {:ok, media} <- amarula_media(reference) do
      transport = Keyword.get(opts, :transport, AmarulaClient)
      transport.download_media(media)
    end
  end

  @impl true
  def edit_message(jid, message_id, text, opts \\ []) do
    opts = SendOptions.new(opts)
    jid = to_jid(jid)

    with {:ok, conn} <- transport(opts).resolve_conn(SendOptions.conn_opts(opts)),
         {:ok, msg_id} <-
           transport(opts).send_edit(conn, {jid, to_string(message_id), true}, text) do
      {:ok,
       %{
         external_message_id: msg_id,
         external_room_id: jid,
         channel_type: :whatsapp,
         status: :edited,
         raw: %{id: msg_id, jid: jid, edited_message_id: message_id}
       }}
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
       metadata: %{
         jid: jid,
         chat_type:
           if String.ends_with?(jid, "@g.us") do
             :group
           else
             :dm
           end
       }
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
  def verify_webhook(%WebhookRequest{}, _opts \\ []) do
    :ok
  end

  @impl true
  def format_webhook_response(result, _opts \\ [])

  def format_webhook_response({:ok, %Jido.Chat.Delivery{}}, _opts) do
    WebhookResponse.accepted(%{ok: true})
  end

  def format_webhook_response({:error, %Jido.Chat.Errors.Contract{code: code}}, _opts) do
    WebhookResponse.error(400, %{error: to_string(code)})
  end

  def format_webhook_response(_, _opts) do
    WebhookResponse.error(400, %{error: "rejected"})
  end

  @doc "Requests a WhatsApp link-code pairing code for a running Amarula connection.\n"
  @spec request_pairing_code(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def request_pairing_code(phone, opts \\ []) when is_binary(phone) and is_list(opts) do
    opts = SendOptions.new(opts)

    with {:ok, conn} <- transport(opts).resolve_conn(SendOptions.conn_opts(opts)) do
      transport(opts).request_pairing_code(conn, phone, [])
    end
  end

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

  defp upload_data(%FileUpload{data: data}) when is_binary(data) do
    {:ok, data}
  end

  defp upload_data(%FileUpload{path: path}) when is_binary(path) do
    File.read(path)
  end

  defp upload_data(%FileUpload{url: url}) when is_binary(url) do
    {:error, {:unsupported_remote_upload, url}}
  end

  defp upload_data(_upload) do
    {:error, :missing_upload_data}
  end

  defp upload_caption(%FileUpload{} = upload, %SendOptions{} = opts) do
    opts.caption || upload.metadata[:caption] || upload.metadata["caption"]
  end

  defp amarula_media(%Amarula.Content.Media{} = media) do
    validate_amarula_media(media)
  end

  defp amarula_media(%Media{} = media) do
    build_amarula_media(Map.from_struct(media), media.metadata)
  end

  defp amarula_media(%{} = reference) do
    metadata = map_get(reference, [:metadata, "metadata"])

    build_amarula_media(
      reference,
      if is_map(metadata) do
        metadata
      else
        %{}
      end
    )
  end

  defp amarula_media(_reference) do
    {:error, :invalid_media_reference}
  end

  defp build_amarula_media(reference, metadata) do
    with {:ok, kind} <-
           amarula_media_kind(media_value(reference, metadata, [:kind, "kind", :type, "type"])) do
      media =
        struct(Amarula.Content.Media,
          kind: kind,
          mimetype: media_type_value(reference, metadata),
          caption: media_value(reference, metadata, [:caption, "caption"]),
          file_length:
            media_value(reference, metadata, [
              :file_length,
              "file_length",
              :size_bytes,
              "size_bytes"
            ]),
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

  defp media_value(reference, metadata, keys) do
    map_get(metadata, keys) || map_get(reference, keys)
  end

  defp media_type_value(reference, metadata) do
    keys = [:mimetype, "mimetype", :media_type, "media_type"]

    normalize_media_type(map_get(metadata, keys)) ||
      normalize_media_type(map_get(reference, keys))
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
    if valid_direct_path?(path) do
      %{media | url: nil}
    else
      media
    end
  end

  defp valid_media_kind?(kind) do
    kind in [:image, :video, :audio, :document, :sticker]
  end

  defp valid_media_key?(key) do
    is_binary(key) and byte_size(key) == 32
  end

  defp valid_media_locator?(media) do
    valid_direct_path?(media.direct_path) or valid_media_url?(media.url)
  end

  defp valid_direct_path?(path) do
    is_binary(path) and path != "" and String.starts_with?(path, "/")
  end

  defp valid_media_url?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host} when is_binary(host) ->
        host = String.downcase(host)
        host == "whatsapp.net" or String.ends_with?(host, ".whatsapp.net")

      _other ->
        false
    end
  end

  defp valid_media_url?(_url) do
    false
  end

  defp valid_media_hash?(nil) do
    true
  end

  defp valid_media_hash?(hash) do
    is_binary(hash) and byte_size(hash) == 32
  end

  defp normalize_media_type(value) when is_binary(value) do
    trimmed = String.trim(value)

    if Regex.match?(@media_type_pattern, canonical_media_type(trimmed)) do
      trimmed
    else
      nil
    end
  end

  defp normalize_media_type(_value) do
    nil
  end

  defp canonical_media_type(value) do
    value |> String.split(";", parts: 2) |> hd() |> String.trim() |> String.downcase()
  end

  defp amarula_media_kind(kind) when kind in [:image, :video, :audio, :document, :sticker] do
    {:ok, kind}
  end

  defp amarula_media_kind(:file) do
    {:ok, :document}
  end

  defp amarula_media_kind("image") do
    {:ok, :image}
  end

  defp amarula_media_kind("video") do
    {:ok, :video}
  end

  defp amarula_media_kind("audio") do
    {:ok, :audio}
  end

  defp amarula_media_kind("document") do
    {:ok, :document}
  end

  defp amarula_media_kind("sticker") do
    {:ok, :sticker}
  end

  defp amarula_media_kind("file") do
    {:ok, :document}
  end

  defp amarula_media_kind(_kind) do
    {:error, :invalid_media_reference}
  end

  defp whatsapp_media_type(:image) do
    :image
  end

  defp whatsapp_media_type(:video) do
    :video
  end

  defp whatsapp_media_type(:audio) do
    :audio
  end

  defp whatsapp_media_type(:file) do
    :document
  end

  defp chatstate(nil) do
    :composing
  end

  defp chatstate(:typing) do
    :composing
  end

  defp chatstate("typing") do
    :composing
  end

  defp chatstate(:recording) do
    :recording
  end

  defp chatstate("recording") do
    :recording
  end

  defp chatstate(:paused) do
    :paused
  end

  defp chatstate("paused") do
    :paused
  end

  defp chatstate(:stop) do
    :paused
  end

  defp chatstate("stop") do
    :paused
  end

  defp chatstate(_) do
    :composing
  end

  defp connection_worker_opts(bridge_id, ingress, opts, sink_mfa) do
    profile = configured_profile(bridge_id, ingress, opts)

    [
      bridge_id: bridge_id,
      binding:
        Keyword.get(opts, :binding) ||
          elem(Jido.Chat.bind(__MODULE__, Keyword.put(opts, :id, bridge_id)), 1),
      sink_mfa: sink_mfa,
      control_mfa: Keyword.get(opts, :control_mfa),
      sink_opts: [bridge_id: bridge_id],
      transport:
        get_map_value(ingress, [:transport, "transport"]) ||
          Keyword.get(opts, :transport, AmarulaClient),
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
       when is_atom(module) and is_atom(function) and is_list(args) do
    {:ok, {module, function, args}}
  end

  defp validate_sink_mfa(_) do
    {:error, :invalid_sink_mfa}
  end

  defp transport(%SendOptions{transport: transport}) do
    transport
  end

  defp transport(_opts) do
    AmarulaClient
  end

  defp to_jid(%Amarula.Address{} = address) do
    Amarula.Address.to_jid!(address)
  end

  defp to_jid(value) when is_binary(value) do
    if String.contains?(value, "@") do
      value
    else
      value |> Amarula.Address.pn() |> Amarula.Address.to_jid!()
    end
  end

  defp to_jid(value) do
    to_string(value)
  end

  defp ensure_map(%{} = map) do
    map
  end

  defp ensure_map(_) do
    %{}
  end

  defp map_get(map, keys) do
    get_map_value(map, keys)
  end

  defp get_map_value(map, keys) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, fn key -> Map.get(map, key) end)
  end

  defp get_map_value(_other, _keys) do
    nil
  end

  @impl true
  def signal_protocol do
    1
  end

  @impl true
  def normalize_event(binding, input) do
    tracker = {__MODULE__, make_ref()}
    Process.put(tracker, [])

    result =
      try do
        with {:ok, items} <- native_inputs(binding, input) do
          delivery =
            "whatsapp:delivery:" <> native_digest({binding.id, Enum.map(items, &elem(&1, 2))})

          base = %{binding: binding, delivery: delivery, tracker: tracker}

          with {:ok, facts} <- native_items(base, items) do
            Jido.Chat.Delivery.new(binding, delivery, facts)
          end
        end
      rescue
        _ -> Jido.Chat.Signal.Policy.error(:invalid_delivery)
      catch
        _, _ -> Jido.Chat.Signal.Policy.error(:invalid_delivery)
      end

    if match?({:error, _}, result) do
      Enum.each(Process.get(tracker, []), &Jido.Chat.cancel_resource(binding, &1))
    end

    Process.delete(tracker)
    result
  end

  defp native_items(base, items) do
    items
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {{kind, payload, key}, index}, {:ok, acc} ->
      context = Map.merge(base, %{item: "whatsapp:item:" <> key, index: index})
      existing = Process.get(context.tracker)

      result =
        try do
          native_map(context, kind, payload)
        rescue
          _ -> {:error, :invalid_item}
        catch
          _, _ -> {:error, :invalid_item}
        end

      case result do
        {:ok, facts} ->
          facts = List.wrap(facts)

          if Enum.all?(facts, &(&1.type == "jido.chat.normalization.failed")) do
            Enum.each(
              Process.get(context.tracker) -- existing,
              &Jido.Chat.cancel_resource(base.binding, &1)
            )
          end

          {:cont, {:ok, acc ++ facts}}

        {:error, %Jido.Chat.Errors.Contract{code: code}} = error
        when code in [
               :signal_too_large,
               :delivery_too_large,
               :too_many_signals,
               :too_many_failures
             ] ->
          {:halt, error}

        _ ->
          Enum.each(
            Process.get(context.tracker) -- existing,
            &Jido.Chat.cancel_resource(base.binding, &1)
          )

          case native_failure(context, "invalid_item", kind, nil) do
            {:ok, fact} -> {:cont, {:ok, acc ++ [fact]}}
            error -> {:halt, error}
          end
      end
    end)
  end

  defp native_fact(context, definition, data, ordinal \\ "0") do
    room = data["room_id"]

    data =
      data
      |> Map.merge(%{
        "item_id" => context.item <> ":" <> definition.type() <> ":" <> ordinal,
        "delivery_id" => context.delivery
      })
      |> Map.reject(fn {key, value} ->
        is_nil(value) and key not in ["text", "previous", "current", "actor_id", "reaction"]
      end)

    subject =
      if is_binary(room) and room != "" do
        Jido.Chat.Signal.Identity.conversation_subject(context.binding.id, room)
      end

    definition.new(data, source: context.binding.source, subject: subject)
  end

  defp native_failure(context, code, kind, room) do
    native_fact(context, Jido.Chat.Signal.NormalizationFailed, %{
      "code" => code,
      "provider_kind" => kind,
      "item_index" => context.index,
      "room_id" => room
    })
  end

  defp native_media(context, media) do
    Enum.reduce_while(media, {:ok, []}, fn value, {:ok, acc} ->
      with {:ok, ref} <- Jido.Chat.put_resource(context.binding, "media", value) do
        Process.put(context.tracker, [ref | Process.get(context.tracker)])

        item =
          %{"kind" => to_string(value.kind), "resource_ref" => ref}
          |> native_optional("name", value.filename)
          |> native_optional("media_type", value.media_type)

        {:cont, {:ok, acc ++ [item]}}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp native_get(map, key) when is_map(map) do
    atom =
      try do
        String.to_existing_atom(key)
      rescue
        ArgumentError -> nil
      end

    if Map.has_key?(map, key) do
      Map.get(map, key)
    else
      Map.get(map, atom)
    end
  end

  defp native_get(_, _) do
    nil
  end

  defp native_id(map, key) do
    native_identifier(native_get(map, key))
  end

  defp native_identifier(value) when is_binary(value) and value != "" do
    value
  end

  defp native_identifier(value) when is_integer(value) do
    to_string(value)
  end

  defp native_identifier(_) do
    nil
  end

  defp native_optional(map, _, nil) do
    map
  end

  defp native_optional(map, key, value) do
    Map.put(map, key, value)
  end

  defp native_time(%DateTime{} = value) do
    DateTime.to_iso8601(value)
  end

  defp native_time(value) when is_binary(value) do
    value
  end

  defp native_time(_) do
    nil
  end

  defp native_canonical(%_{} = value) do
    value |> Map.from_struct() |> native_canonical()
  end

  defp native_canonical(value) when is_map(value) do
    value |> Enum.map(fn {k, v} -> {to_string(k), native_canonical(v)} end) |> Enum.sort()
  end

  defp native_canonical(value) when is_list(value) do
    Enum.map(value, &native_canonical/1)
  end

  defp native_canonical(value) do
    value
  end

  defp native_digest(value) do
    :crypto.hash(:sha256, :erlang.term_to_binary(native_canonical(value), [:deterministic]))
    |> Base.url_encode64(padding: false)
  end

  @impl true
  def configure_binding(opts) do
    {:ok,
     opts
     |> Keyword.put_new(:transport, AmarulaClient)
     |> Keyword.put_new(
       :profile,
       Application.get_env(:jido_chat_whatsapp, :profile) ||
         Application.get_env(:jido_chat_whatsapp, :whatsapp_profile) || ""
     )}
  end

  defp native_inputs(binding, %WebhookRequest{} = request) do
    native_inputs(binding, request.payload)
  end

  defp native_inputs(_binding, {:amarula, :messages_upsert, data}) when is_map(data) do
    items = native_get(data, "messages")

    if is_list(items) do
      batch = native_id(data, "id")

      {:ok,
       Enum.with_index(items)
       |> Enum.map(fn {item, index} ->
         {kind, payload, key} = native_input(item)

         identity =
           if batch do
             batch <> ":" <> key <> ":" <> to_string(index)
           else
             key
           end

         {kind, payload, identity}
       end)}
    else
      Jido.Chat.Signal.Policy.error(:invalid_delivery)
    end
  end

  defp native_inputs(_binding, {:amarula, type, _data})
       when type in [
              :connection_update,
              :pairing_code,
              :pairing_success,
              :pairing_failure,
              :call_update,
              :history_sync,
              :error
            ] do
    {:ok, []}
  end

  defp native_inputs(_binding, items) when is_list(items) do
    {:ok, Enum.map(items, &native_input/1)}
  end

  defp native_inputs(_binding, input) do
    {:ok, [native_input(input)]}
  end

  defp native_input(%Amarula.Msg{} = msg) do
    msg |> Message.to_payload() |> native_input()
  end

  defp native_input(%{} = input) do
    input = native_get(input, "message") || input
    kind = native_get(input, "event") || native_get(input, "type") || "other"
    kind = to_string(kind)
    key = native_digest({native_id(input, "channel_jid"), native_id(input, "id"), kind, input})
    {kind, input, key}
  end

  defp native_input(_) do
    {"invalid", nil, "invalid"}
  end

  defp native_map(_context, kind, _payload)
       when kind in [
              "connection_update",
              "pairing_code",
              "pairing_success",
              "pairing_failure",
              "call_update",
              "history_sync",
              "error"
            ] do
    {:ok, []}
  end

  defp native_map(context, kind, payload) when kind in ["text", "media"] do
    with {:ok, incoming} <- provider_message(payload),
         {:ok, media} <- native_media(context, Enum.map(incoming.media, &Media.new/1)) do
      sender =
        %{
          "id" => native_identifier(incoming.external_user_id),
          "is_self" => incoming.metadata.from_me
        }
        |> native_optional("display_name", incoming.display_name)

      native_fact(context, Jido.Chat.Signal.MessageReceived, %{
        "room_id" => incoming.external_room_id,
        "message_id" => native_identifier(incoming.external_message_id),
        "sender" => sender,
        "text" => incoming.text || "",
        "reply_to_id" => native_identifier(incoming.external_reply_to_id),
        "media" => media,
        "timestamp" => native_stamp(incoming.timestamp),
        "conversation_kind" =>
          if incoming.chat_type == :group do
            "group"
          else
            "direct"
          end,
        "mentions" => List.wrap(native_get(payload, "mentions")) |> Enum.map(&Message.address_to_jid/1)
      })
    end
  end

  defp native_map(context, kind, payload) when kind in ["edit", "revoke"] do
    content = native_get(payload, "content") || %{}
    {room, id} = native_target(native_get(content, "key"), payload)
    data = %{"room_id" => room, "message_id" => id, "actor_id" => native_id(payload, "from_jid")}

    if kind == "edit" do
      native_fact(
        context,
        Jido.Chat.Signal.MessageUpdated,
        Map.put(Map.delete(data, "actor_id"), "text", native_get(content, "text"))
      )
    else
      native_fact(context, Jido.Chat.Signal.MessageDeleted, data)
    end
  end

  defp native_map(context, "reaction", payload) do
    content = native_get(payload, "content") || %{}
    {room, id} = native_target(native_get(content, "key"), payload)
    reaction = native_get(content, "emoji") || ""

    definition =
      if reaction == "" do
        Jido.Chat.Signal.ReactionRemoved
      else
        Jido.Chat.Signal.ReactionAdded
      end

    reaction =
      if reaction == "" do
        nil
      else
        reaction
      end

    native_fact(context, definition, %{
      "room_id" => room,
      "message_id" => id,
      "actor_id" => native_id(payload, "from_jid"),
      "reaction" => reaction
    })
  end

  defp native_map(context, kind, _) do
    native_failure(context, "unsupported_item", kind, nil)
  end

  defp native_target({jid, id, _from_me}, _) do
    {Message.address_to_jid(jid), native_identifier(id)}
  end

  defp native_target({jid, id, _from_me, _participant}, _) do
    {Message.address_to_jid(jid), native_identifier(id)}
  end

  defp native_target({jid, id}, _) do
    {Message.address_to_jid(jid), native_identifier(id)}
  end

  defp native_target(%{} = key, payload) do
    {Message.address_to_jid(native_get(key, "jid")) || native_id(payload, "channel_jid"), native_id(key, "id")}
  end

  defp native_target(_, payload) do
    {native_id(payload, "channel_jid"), native_id(payload, "id")}
  end

  defp native_stamp(value) when is_integer(value) do
    case DateTime.from_unix(value) do
      {:ok, date} -> native_time(date)
      _ -> nil
    end
  end

  defp native_stamp(value) do
    native_time(value)
  end
end
