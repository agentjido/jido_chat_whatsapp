defmodule Jido.Chat.WhatsApp do
  @moduledoc """
  WhatsApp linked-device adapter package for `Jido.Chat`.

  This package uses `Amarula` as the WhatsApp Web client.
  """

  alias Jido.Chat.WhatsApp.Adapter

  @doc "Returns the canonical WhatsApp adapter module."
  @spec adapter() :: module()
  def adapter, do: Adapter
end
