defmodule Jido.Chat.WhatsApp.Application do
  @moduledoc """
  Owns the adapter's shared transport infrastructure, without opening profiles.

  Hosts supervise Sensors or linked-device workers. This application owns one
  Amarula runtime generation. It does not adopt an external runtime.
  """

  use Application

  alias Jido.Chat.WhatsApp.Transport.AmarulaRuntime

  @impl true
  def start(_type, _args) do
    Supervisor.start_link([AmarulaRuntime], strategy: :one_for_one, name: Jido.Chat.WhatsApp.Supervisor)
  end
end
