defmodule Jido.Chat.WhatsApp.Pairing.Request do
  @moduledoc "Private host request used inside the package's bounded pairing task."

  @derive {Inspect, only: [:version, :id]}
  @enforce_keys [:context, :request]
  defstruct [:context, :request, version: 1, id: nil]

  @type t :: %__MODULE__{context: term(), request: map(), version: 1, id: reference() | nil}

  @doc "Invokes the configured private host callback."
  @spec call(tuple(), term(), map()) :: term()
  def call({module, function, args}, context, %{op: op} = request)
      when is_atom(module) and is_atom(function) and is_list(args) and op in [:persist, :start] do
    event = %__MODULE__{context: context, request: request, id: make_ref()}

    case apply(module, function, args ++ [event, []]) do
      :ok -> :ok
      {:ok, _} = result -> result
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, :callback_failed}
    end
  rescue
    _ -> {:error, :callback_failed}
  catch
    _, _ -> {:error, :callback_failed}
  end

  def call(_, _, _), do: {:error, :invalid_pairing_request}
end
