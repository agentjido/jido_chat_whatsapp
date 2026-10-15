defmodule Jido.Chat.WhatsApp.Storage.Request do
  @moduledoc """
  Private synchronous storage requests to a trusted host's listener sink.

  These requests never enter chat event routing or the lifecycle dispatcher.
  Hosts must accept them only on their explicitly configured runtime sink,
  authorize each operation, and acknowledge writes after commit. Binding data
  is opaque to the package. Timeout is ambiguous; callers must not retry writes
  automatically.
  """

  @derive {Inspect, only: [:version, :id]}
  @enforce_keys [:binding, :request]
  defstruct [:binding, :request, version: 1, id: nil]

  @type t :: %__MODULE__{binding: term(), request: map(), version: 1, id: reference() | nil}
  @operations [:bind, :get, :put, :put_many, :delete, :delete_namespace, :clear, :list_keys]

  @doc "Calls a runtime sink with a bounded request, preserving absence and sanitized failures."
  @spec call({module(), atom(), list()}, term(), map()) :: term()
  def call({module, function, args}, binding, %{op: op} = request)
      when is_atom(module) and is_atom(function) and is_list(args) and op in @operations do
    event = %__MODULE__{binding: binding, request: request, id: make_ref()}

    task = Task.async(fn -> invoke(module, function, args, event) end)

    case Task.yield(task, 7_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _ -> {:error, :storage_unavailable}
    end
  end

  def call(_, _, _), do: {:error, :invalid_storage_request}

  defp invoke(module, function, args, event) do
    case apply(module, function, args ++ [event, []]) do
      result when result in [:ok, :error] -> result
      {:ok, _} = result -> result
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, :storage_unavailable}
    end
  rescue
    _ -> {:error, :storage_unavailable}
  catch
    _, _ -> {:error, :storage_unavailable}
  end
end
