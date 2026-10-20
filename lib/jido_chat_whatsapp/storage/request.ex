defmodule Jido.Chat.WhatsApp.Storage.Request do
  @moduledoc """
  Private synchronous storage requests to a trusted host's listener sink.

  These requests never enter chat event routing or the lifecycle dispatcher.
  Hosts must accept them only on their explicitly configured runtime sink,
  authorize each operation, and acknowledge writes after commit. Binding data
  is opaque to the package. Timeout is ambiguous; callers must not retry writes
  automatically.
  """

  @doc "Calls a runtime sink with a bounded request, preserving absence and sanitized failures."
  @spec call({module(), atom(), list()}, term(), map()) :: term()
  def call(sink, binding, request) do
    task = Task.async(fn -> Jido.Chat.Storage.Request.call(sink, binding, request) end)

    case Task.yield(task, 7_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _ -> {:error, :storage_unavailable}
    end
  end
end
