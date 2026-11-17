defmodule Jido.Chat.WhatsApp.SendOptions do
  @moduledoc """
  Typed options for WhatsApp send and edit operations.

  Canonical `format: :markdown` (or `"markdown"`) renders text and media captions.
  Absent, plain-text, HTML, and unknown formats preserve source text; HTML
  rendering is unsupported. See `Jido.Chat.WhatsApp.MessageFormatter`.
  """

  alias Jido.Chat.WhatsApp.MessageFormatter
  alias Jido.Chat.WhatsApp.Transport.AmarulaClient

  @schema Jido.Joi.struct(
            __MODULE__,
            %{
              transport: Jido.Joi.any() |> Jido.Joi.default(AmarulaClient),
              format: Jido.Joi.enum([:markdown, :plain_text]) |> Jido.Joi.default(:plain_text),
              conn: Jido.Joi.any() |> Jido.Joi.nullable() |> Jido.Joi.optional(),
              connection: Jido.Joi.any() |> Jido.Joi.nullable() |> Jido.Joi.optional(),
              profile: Jido.Joi.any() |> Jido.Joi.nullable() |> Jido.Joi.optional(),
              quoted: Jido.Joi.any() |> Jido.Joi.nullable() |> Jido.Joi.optional(),
              mentions: Jido.Joi.any() |> Jido.Joi.nullable() |> Jido.Joi.optional(),
              caption: Jido.Joi.string() |> Jido.Joi.nullable() |> Jido.Joi.optional(),
              seconds: Jido.Joi.integer() |> Jido.Joi.nullable() |> Jido.Joi.optional(),
              ptt: Jido.Joi.boolean() |> Jido.Joi.nullable() |> Jido.Joi.optional(),
              ptv: Jido.Joi.boolean() |> Jido.Joi.nullable() |> Jido.Joi.optional(),
              view_once: Jido.Joi.boolean() |> Jido.Joi.nullable() |> Jido.Joi.optional(),
              file_name: Jido.Joi.string() |> Jido.Joi.nullable() |> Jido.Joi.optional(),
              filename: Jido.Joi.string() |> Jido.Joi.nullable() |> Jido.Joi.optional(),
              title: Jido.Joi.string() |> Jido.Joi.nullable() |> Jido.Joi.optional(),
              status: Jido.Joi.any() |> Jido.Joi.nullable() |> Jido.Joi.optional(),
              action: Jido.Joi.any() |> Jido.Joi.nullable() |> Jido.Joi.optional()
            },
            coerce: true
          )

  @type t :: unquote(Jido.Joi.type_spec(@schema))

  @enforce_keys Jido.Joi.enforce_keys(@schema)
  defstruct Jido.Joi.struct_fields(@schema)

  @doc "Returns the Joi schema for send options."
  def schema, do: @schema

  @doc "Builds typed send options from keyword, map, or struct input."
  def new(%__MODULE__{} = opts), do: opts
  def new(opts) when is_list(opts), do: opts |> Map.new() |> new()

  def new(opts) when is_map(opts) do
    format = MessageFormatter.normalize_format(Map.get(opts, :format) || Map.get(opts, "format"))

    opts
    |> Map.delete("format")
    |> Map.put(:format, format)
    |> then(&Jido.Chat.Schema.parse!(__MODULE__, @schema, &1))
  end

  @doc "Builds connection-level options consumed by the transport client."
  @spec conn_opts(t()) :: keyword()
  def conn_opts(%__MODULE__{} = opts) do
    []
    |> maybe_kw(:conn, opts.conn)
    |> maybe_kw(:connection, opts.connection)
    |> maybe_kw(:profile, opts.profile)
  end

  @doc "Builds Amarula options for text sends."
  @spec text_transport_opts(t()) :: keyword()
  def text_transport_opts(%__MODULE__{} = opts) do
    []
    |> maybe_kw(:quoted, opts.quoted)
    |> maybe_kw(:mentions, opts.mentions)
  end

  @doc "Builds Amarula options for media sends."
  @spec media_transport_opts(t()) :: keyword()
  def media_transport_opts(%__MODULE__{} = opts) do
    []
    |> maybe_kw(:caption, opts.caption)
    |> maybe_kw(:seconds, opts.seconds)
    |> maybe_kw(:ptt, opts.ptt)
    |> maybe_kw(:ptv, opts.ptv)
    |> maybe_kw(:view_once, opts.view_once)
    |> maybe_kw(:file_name, opts.file_name || opts.filename)
    |> maybe_kw(:title, opts.title)
    |> maybe_kw(:quoted, opts.quoted)
    |> maybe_kw(:mentions, opts.mentions)
  end

  defp maybe_kw(keyword, _key, nil), do: keyword
  defp maybe_kw(keyword, key, value), do: Keyword.put(keyword, key, value)
end
