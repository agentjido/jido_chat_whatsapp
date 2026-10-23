defmodule Jido.Chat.WhatsApp.AccountIdentity do
  @moduledoc """
  Allowlisted identity of an authenticated WhatsApp account.

  Only trusted transport output belongs here. A phone number is derived from a
  phone-number JID, never from a LID or a supplied phone field. Missing names
  remain nil. Alias normalization is shared with incoming message normalization.
  """

  alias Jido.Chat.WhatsApp.Message

  @type t :: %{
          phone_number: String.t() | nil,
          display_name: String.t() | nil,
          account_jids: [String.t()]
        }

  @doc "Normalizes trusted identity fields and discards every other field."
  @spec normalize(term()) :: {:ok, t()} | {:error, :unavailable}
  def normalize(%{account_jids: jids} = identity) when is_list(jids) do
    aliases = jids |> Message.normalize_jids() |> Enum.filter(&account_jid?/1)

    case aliases do
      [] ->
        {:error, :unavailable}

      _ ->
        {:ok,
         %{
           phone_number: Enum.find_value(aliases, &phone_number/1),
           display_name: name(Map.get(identity, :display_name)),
           account_jids: aliases
         }}
    end
  end

  def normalize(_), do: {:error, :unavailable}

  defp account_jid?(jid), do: Regex.match?(~r/^(?:[0-9]+@s\.whatsapp\.net|[^@:\s]+@lid)$/, jid)

  defp phone_number(jid) do
    case String.split(jid, "@") do
      [number, "s.whatsapp.net"] -> "+" <> number
      _ -> nil
    end
  end

  defp name(value) when is_binary(value) do
    case String.trim(value) do
      value when value in ["", "~"] -> nil
      value -> value
    end
  end

  defp name(_), do: nil
end
