defmodule Jido.Chat.WhatsApp.LiveValidation do
  @moduledoc "Helpers for the excluded WhatsApp live validation suite."

  @minimum_no_reconnect_observation_ms 30_000

  @doc "Creates the one-reconnect budget for a full live suite run."
  @spec new_reconnect_budget() :: :atomics.atomics_ref()
  def new_reconnect_budget, do: :atomics.new(1, signed: false)

  @doc "Runs a reconnect function only when the suite budget is unused."
  @spec reconnect_once(:atomics.atomics_ref(), (-> term())) ::
          {:ok, term()} | {:error, :reconnect_budget_exhausted}
  def reconnect_once(budget, reconnect) when is_function(reconnect, 0) do
    case :atomics.compare_exchange(budget, 1, 0, 1) do
      :ok -> {:ok, reconnect.()}
      _used -> {:error, :reconnect_budget_exhausted}
    end
  end

  @doc "Returns a safe no-reconnect observation window for the rejected-session gate."
  @spec no_reconnect_observation_ms(integer()) :: pos_integer()
  def no_reconnect_observation_ms(configured_ms) when is_integer(configured_ms) do
    max(configured_ms, @minimum_no_reconnect_observation_ms)
  end

  @doc "Creates a diagnostic event summary without active QR data."
  @spec summarize_event(term()) :: term()
  def summarize_event({:amarula, event, data}), do: {event, summarize_data(data)}
  def summarize_event(event), do: event

  defp summarize_data(%{connection: connection} = data) do
    %{connection: connection}
    |> maybe_mark_qr(data)
  end

  defp summarize_data(%{message_ids: message_ids, status: status}) do
    %{message_ids: message_ids, status: status}
  end

  defp summarize_data(%{messages: messages}) when is_list(messages), do: %{messages: length(messages)}
  defp summarize_data({:stream_error, code, _reason}), do: {:stream_error, code, :redacted}
  defp summarize_data(data) when is_map(data), do: %{keys: Map.keys(data)}
  defp summarize_data(reason) when is_atom(reason) or is_binary(reason), do: reason
  defp summarize_data(reason), do: inspect(reason)

  defp maybe_mark_qr(summary, %{qr: qr}) when not is_nil(qr), do: Map.put(summary, :qr, :redacted)
  defp maybe_mark_qr(summary, _data), do: summary
end
