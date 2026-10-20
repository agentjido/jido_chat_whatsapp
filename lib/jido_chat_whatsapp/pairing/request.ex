defmodule Jido.Chat.WhatsApp.Pairing.Request do
  @moduledoc "Dispatches shared authentication requests inside the package's bounded pairing task."

  @doc "Invokes the configured sink using the shared authentication envelope."
  @spec call(tuple(), term(), map()) :: term()
  defdelegate call(sink, context, request), to: Jido.Chat.Authentication.Request
end
