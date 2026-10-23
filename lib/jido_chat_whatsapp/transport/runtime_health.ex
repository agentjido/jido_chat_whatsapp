defmodule Jido.Chat.WhatsApp.Transport.RuntimeHealth do
  @moduledoc """
  Watches the shared Amarula infrastructure for a single runtime generation.

  A child replacement invalidates the generation, forcing the owning supervisor
  to rebuild the whole tree before listeners reconnect. No credentials are held.
  """

  use GenServer

  @doc "Starts the runtime generation sentinel after Amarula's tree is ready."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    children = Supervisor.which_children(Amarula.Supervisor)
    monitors = Map.new(children, fn {_, pid, _, _} -> {Process.monitor(pid), pid} end)
    {:ok, monitors}
  end

  @impl true
  def handle_call(:ready, _from, monitors) do
    ready = if Enum.all?(monitors, fn {_, pid} -> Process.alive?(pid) end), do: {:ok, self()}, else: :unavailable
    {:reply, ready, monitors}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, monitors) when is_map_key(monitors, ref) do
    {:stop, {:shutdown, :infrastructure_down}, monitors}
  end
end
