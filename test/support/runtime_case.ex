defmodule Jido.Chat.WhatsApp.RuntimeCase do
  @moduledoc false
  use ExUnit.CaseTemplate

  alias Jido.Chat.WhatsApp.Transport.AmarulaRuntime

  setup do
    # Tests sharing the registered runtime are synchronous. Resetting its child
    # under the application preserves production ownership and bounds leaked
    # offline connections to one test, just like the previous per-test tree.
    reset_runtime()
    on_exit(&reset_runtime/0)
    :ok
  end

  defp reset_runtime do
    :ok = Supervisor.terminate_child(Jido.Chat.WhatsApp.Supervisor, AmarulaRuntime)
    {:ok, _} = Supervisor.restart_child(Jido.Chat.WhatsApp.Supervisor, AmarulaRuntime)
    :ok
  end
end
