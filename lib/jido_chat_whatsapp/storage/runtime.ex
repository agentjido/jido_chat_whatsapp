defmodule Jido.Chat.WhatsApp.Storage.Runtime do
  @moduledoc """
  Host-supervised managed storage infrastructure, independent of Amarula startup.

  Start once before pairing and saved listeners. Options are the immutable
  `Jido.Chat.WhatsApp.Storage.Mnesia` options. Backend replacement invalidates
  only subscribing WhatsApp connections; the host bridge supervisor stays alive.
  Stopping this tree never stops shared Mnesia or clears its table.
  """
  use Supervisor
  alias Jido.Chat.WhatsApp.Storage.Mnesia

  @doc "Starts the managed backend under an isolated restart domain."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts), do: Supervisor.init([{Mnesia, opts}], strategy: :one_for_one)
end
