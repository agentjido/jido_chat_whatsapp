defmodule Jido.Chat.WhatsApp.SendOptions do
  @moduledoc """
  Typed options for WhatsApp send operations.
  """

  alias Jido.Chat.WhatsApp.Transport.AmarulaClient

  @schema Zoi.struct(
            __MODULE__,
            %{
              transport: Zoi.any() |> Zoi.default(AmarulaClient),
              conn: Zoi.any() |> Zoi.nullish(),
              connection: Zoi.any() |> Zoi.nullish(),
              profile: Zoi.any() |> Zoi.nullish(),
              quoted: Zoi.any() |> Zoi.nullish(),
              mentions: Zoi.any() |> Zoi.nullish(),
              caption: Zoi.string() |> Zoi.nullish(),
              seconds: Zoi.integer() |> Zoi.nullish(),
              ptt: Zoi.boolean() |> Zoi.nullish(),
              ptv: Zoi.boolean() |> Zoi.nullish(),
              view_once: Zoi.boolean() |> Zoi.nullish(),
              file_name: Zoi.string() |> Zoi.nullish(),
              filename: Zoi.string() |> Zoi.nullish(),
              title: Zoi.string() |> Zoi.nullish(),
              status: Zoi.any() |> Zoi.nullish(),
              action: Zoi.any() |> Zoi.nullish()
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for send options."
  def schema, do: @schema

  @doc "Builds typed send options from keyword, map, or struct input."
  def new(%__MODULE__{} = opts), do: opts
  def new(opts) when is_list(opts), do: opts |> Map.new() |> new()

  def new(opts) when is_map(opts) do
    Jido.Chat.Schema.parse!(__MODULE__, @schema, opts)
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
