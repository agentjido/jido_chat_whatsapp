defmodule Jido.Chat.WhatsApp.Transport.GuardedStorage do
  @moduledoc false
  @behaviour Amarula.Storage

  # The latch is shared by all protocol tasks for this connection. Once failed,
  # no subsequent successful callback can make the connection healthy again.
  @impl true
  def new(opts) do
    scope = opts |> Keyword.fetch!(:storage) |> Amarula.Storage.scope()
    %{module: scope.adapter, state: scope.state, failed: :atomics.new(1, []), notify: Keyword.get(opts, :notify)}
  end

  def healthy?(state), do: :atomics.get(state.failed, 1) == 0

  @impl true
  def get(state, profile, namespace, key) do
    case invoke(state, :get, [profile, namespace, key]) do
      {:ok, value} when namespace != :creds or is_map(value) -> {:ok, value}
      :error -> :error
      _ -> fail(state)
    end
  end

  @impl true
  def put(state, profile, namespace, key, value),
    do: write(state, :put, [profile, namespace, key, value])

  @impl true
  def delete(state, profile, namespace, key), do: write(state, :delete, [profile, namespace, key])

  @impl true
  def clear(state, profile), do: write(state, :clear, [profile])

  @impl true
  def list_keys(state, profile, namespace), do: optional(state, :list_keys, [profile, namespace])

  @impl true
  def list_profiles(state), do: optional(state, :list_profiles, [])

  defp optional(state, operation, args) do
    if function_exported?(state.module, operation, length(args) + 1),
      do: invoke(state, operation, args),
      else: {:error, :not_supported}
  end

  defp write(state, operation, args) do
    case invoke(state, operation, args) do
      :ok ->
        :ok

      _ ->
        mark_failed(state)
        {:error, :storage_failed}
    end
  rescue
    _ -> {:error, :storage_failed}
  end

  defp invoke(state, operation, args) do
    apply(state.module, operation, [state.state | args])
  rescue
    _ -> fail(state)
  catch
    _, _ -> fail(state)
  end

  defp mark_failed(state) do
    :atomics.put(state.failed, 1, 1)
    if state.notify, do: send(state.notify, {:amarula, :error, :storage_failed})
  end

  defp fail(state) do
    mark_failed(state)
    raise "WhatsApp storage failed (details redacted)"
  end
end
