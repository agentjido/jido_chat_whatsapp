defmodule Jido.Chat.WhatsApp.TransportStub do
  @moduledoc false

  # Only required callbacks are supplied. Optional callbacks must remain absent
  # unless a test explicitly implements them, since the worker checks exports.
  defmacro __using__(_) do
    quote do
      @behaviour Jido.Chat.WhatsApp.Transport
      def connect(_, _), do: {:error, :not_used}
      def resolve_conn(_), do: {:error, :not_used}
      def send_text(_, _, _, _), do: {:error, :not_used}
      def send_media(_, _, _, _, _), do: {:error, :not_used}
      def download_media(_), do: {:error, :not_used}
      def send_reaction(_, _, _), do: {:error, :not_used}
      def send_edit(_, _, _), do: {:error, :not_used}
      def send_revoke(_, _), do: {:error, :not_used}
      def send_chatstate(_, _, _), do: {:error, :not_used}
      def request_pairing_code(_, _, _), do: {:error, :not_used}
      defoverridable Jido.Chat.WhatsApp.Transport
    end
  end
end
