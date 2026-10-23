defmodule Jido.Chat.WhatsApp.Transport.AmarulaRuntime do
  @moduledoc """
  Owns Amarula's shared tree and rebuilds it as one generation on infrastructure loss.

  Amarula's registries and connections supervisor must belong to the same generation.
  The sentinel detects child loss even when Amarula restarts that child internally.
  Listeners monitor the sentinel so they reacquire connections after a rebuild.
  """

  use Supervisor

  alias Jido.Chat.WhatsApp.Transport.RuntimeHealth

  @doc "Starts the package-owned transport supervisor."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    infrastructure =
      Supervisor.child_spec(Amarula.Supervisor,
        start: {__MODULE__, :start_infrastructure, []}
      )

    Supervisor.init([infrastructure, RuntimeHealth], strategy: :one_for_all)
  end

  @doc false
  @spec start_infrastructure() :: Supervisor.on_start()
  def start_infrastructure do
    start_infrastructure(System.monotonic_time(:millisecond) + 5_000)
  end

  # An untrappable kill lets descendants shut down asynchronously. Give the old
  # registered processes time to leave before retrying, without spending the
  # supervisor's restart budget on name collisions or adopting another owner.
  defp start_infrastructure(deadline) do
    case Amarula.Supervisor.start_link() do
      {:ok, _} = started ->
        started

      {:error, _} = error ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(10)
          start_infrastructure(deadline)
        else
          error
        end
    end
  end

  @doc "Waits up to five seconds for a complete runtime generation without starting an application."
  @spec ready() :: {:ok, pid()} | {:error, :runtime_unavailable}
  def ready do
    await_ready(System.monotonic_time(:millisecond) + 5_000)
  end

  defp await_ready(deadline) do
    case current_generation() do
      {:ok, _pid} = ready ->
        ready

      :unavailable ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(10)
          await_ready(deadline)
        else
          {:error, :runtime_unavailable}
        end
    end
  end

  defp current_generation do
    if Application.get_env(:jido_chat_whatsapp, :start_runtime, true) do
      GenServer.call(RuntimeHealth, :ready, 100)
    else
      # Explicit compatibility mode: the host retains infrastructure recovery.
      with pid when is_pid(pid) <- Process.whereis(Amarula.Supervisor),
           children <- Supervisor.which_children(pid),
           true <- Enum.all?(children, fn {_, child, _, _} -> is_pid(child) and Process.alive?(child) end) do
        {:ok, pid}
      else
        _ -> :unavailable
      end
    end
  catch
    :exit, _ -> :unavailable
  end
end
