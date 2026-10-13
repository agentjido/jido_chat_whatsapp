defmodule Jido.Chat.WhatsApp.Application do
  @moduledoc """
  Owns the adapter's shared transport infrastructure, without opening profiles.

  Hosts supervise listener child specs. During migration, hosts that already own
  Amarula may set `config :jido_chat_whatsapp, start_runtime: false` before boot.
  """

  use Application

  alias Jido.Chat.WhatsApp.Transport.AmarulaRuntime

  @impl true
  def start(_type, _args) do
    children = if Application.get_env(:jido_chat_whatsapp, :start_runtime, true), do: [AmarulaRuntime], else: []
    Supervisor.start_link(children, strategy: :one_for_one, name: Jido.Chat.WhatsApp.Supervisor)
  end
end
