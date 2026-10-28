defmodule Jido.Chat.WhatsApp do
  @moduledoc """
  WhatsApp linked-device adapter package for `Jido.Chat`.

  This package uses `Amarula` as the WhatsApp Web client.
  """

  alias Jido.Chat.WhatsApp.Adapter

  @doc "Returns the canonical WhatsApp adapter module."
  @spec adapter() :: module()
  def adapter, do: Adapter

  @doc "Returns the incoming facts normalized by WhatsApp."
  def event_definitions do
    [
      Jido.Chat.Signal.MessageReceived,
      Jido.Chat.Signal.ReactionAdded,
      Jido.Chat.Signal.ReactionRemoved,
      Jido.Chat.Signal.NormalizationFailed
    ]
  end
end
