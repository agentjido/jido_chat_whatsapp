defmodule Jido.Chat.WhatsApp do
  @moduledoc """
  WhatsApp linked-device adapter package for `Jido.Chat`.

  This package uses `Amarula` as the WhatsApp Web client.
  """

  alias Jido.Chat.WhatsApp.{Adapter, Connection, PairingSession, Source}

  @doc "Returns the canonical WhatsApp adapter module."
  @spec adapter() :: module()
  def adapter, do: Adapter

  @doc "Returns the WhatsApp push Source module."
  @spec source() :: module()
  def source, do: Source

  @doc "Starts or continues owner-scoped linked-device pairing."
  @spec authenticate(map(), term(), keyword()) :: term()
  def authenticate(request, owner_id, opts), do: PairingSession.authenticate(request, owner_id, opts)

  @doc "Clears one linked-device profile through its selected transport."
  @spec cleanup_connection(term(), keyword()) :: :ok | {:error, atom()}
  def cleanup_connection(binding, opts), do: Connection.cleanup(binding, opts)
end
