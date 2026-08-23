defmodule Mix.Tasks.JidoChatWhatsapp.Pair do
  use Mix.Task

  alias Jido.Chat.WhatsApp.Pairing

  @shortdoc "Safely link a WhatsApp account by QR"

  @moduledoc """
  Links a WhatsApp account to an Amarula profile by QR without logging raw QR
  data if terminal rendering fails.

      mix jido_chat_whatsapp.pair PROFILE

  Options:

    * `--timeout` - stop after this number of seconds (default: 180)

  Phone-code pairing is disabled because the supported Amarula release logs
  phone pairing codes. Use QR pairing until Amarula provides verified safe
  redaction.
  """

  @switches [timeout: :integer]

  @impl Mix.Task
  def run(argv) do
    if Enum.any?(argv, &phone_option?/1) do
      Mix.raise("--phone is disabled. This task is QR-only until Amarula safely redacts phone pairing codes.")
    end

    {opts, args} = OptionParser.parse!(argv, strict: @switches)

    profile =
      case args do
        [profile] -> profile
        _other -> Mix.raise("usage: mix jido_chat_whatsapp.pair PROFILE [--timeout SECONDS]")
      end

    Mix.Task.run("app.start")

    case Pairing.run(profile, opts) do
      :ok -> :ok
      :timeout -> Mix.raise("Timed out before the WhatsApp connection opened.")
      {:error, :connection_failed} -> Mix.raise("Could not start the WhatsApp pairing connection.")
    end
  end

  defp phone_option?("--phone"), do: true
  defp phone_option?("--phone=" <> _value), do: true
  defp phone_option?(_argument), do: false
end
