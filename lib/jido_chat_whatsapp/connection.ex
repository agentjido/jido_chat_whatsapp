defmodule Jido.Chat.WhatsApp.Connection do
  @moduledoc "Private linked-device configuration and cleanup helpers."

  alias Jido.Chat.WhatsApp.Storage.Split
  alias Jido.Chat.WhatsApp.Transport.AmarulaClient

  @doc "Builds transport configuration from an optional opaque host binding."
  @spec options(term(), keyword()) :: map() | {:error, term()}
  def options(nil, opts) when is_list(opts) do
    case opts[:profile] do
      profile when is_binary(profile) and profile != "" -> Map.new(opts)
      _ -> {:error, :missing_linked_device_profile}
    end
  end

  def options(binding, opts) when is_list(opts) do
    with true <- Keyword.keyword?(opts),
         true <- valid_callback?(opts[:sink_mfa]) do
      storage = Split.binding_options(binding, opts)
      %{profile: Keyword.fetch!(storage, :profile), storage: {Split, storage}}
    else
      _ -> {:error, :invalid_linked_device_binding}
    end
  end

  def options(_, _), do: {:error, :invalid_linked_device_binding}

  @doc "Clears one trusted profile's configured storage without starting a connection."
  @spec cleanup(term(), keyword()) :: :ok | {:error, atom()}
  def cleanup(binding, opts) when is_list(opts) do
    with true <- Keyword.keyword?(opts),
         timeout when is_integer(timeout) and timeout in 1..10_000 <-
           Keyword.get(opts, :cleanup_timeout_ms, 10_000),
         {:ok, transport} <- cleanup_transport(opts),
         %{} = config <- options(binding, opts) do
      task = Task.async(fn -> invoke_cleanup(transport, config, opts) end)

      case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} -> result
        _ -> {:error, :cleanup_timeout}
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_cleanup_request}
    end
  end

  def cleanup(_, _), do: {:error, :invalid_cleanup_request}

  defp cleanup_transport(opts) do
    transport = Keyword.get(opts, :transport, AmarulaClient)

    if is_atom(transport) and Code.ensure_loaded?(transport) and
         function_exported?(transport, :cleanup, 2),
       do: {:ok, transport},
       else: {:error, :unsupported}
  end

  defp valid_callback?({module, function, args}),
    do: is_atom(module) and not is_nil(module) and is_atom(function) and is_list(args)

  defp valid_callback?(_), do: false

  defp invoke_cleanup(transport, config, opts) do
    case transport.cleanup(config, opts) do
      :ok -> :ok
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, :cleanup_failed}
    end
  rescue
    _ -> {:error, :cleanup_failed}
  catch
    _, _ -> {:error, :cleanup_failed}
  end
end
