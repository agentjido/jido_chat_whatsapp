defmodule Jido.Chat.WhatsApp.Pairing do
  @moduledoc false

  require Logger

  alias Jido.Chat.WhatsApp.Transport.AmarulaClient

  @doc "Runs the interactive pairing flow for one Amarula profile."
  @spec run(String.t(), keyword()) :: :ok | :timeout | {:error, :connection_failed}
  def run(profile, opts) when is_binary(profile) and is_list(opts) do
    transport = Keyword.get(opts, :transport, AmarulaClient)
    transport_opts = Keyword.get(opts, :transport_opts, [])
    timeout_ms = Keyword.get(opts, :timeout, 180) * 1_000

    with :ok <- transport.ensure_started(transport_opts),
         {:ok, conn} <-
           transport.connect(
             %{profile: profile},
             Keyword.put(transport_opts, :parent_pid, self())
           ) do
      run_connected(transport, conn, profile, transport_opts, timeout_ms)
    else
      {:error, _reason} ->
        Logger.error("Could not start the WhatsApp pairing connection. Error data was redacted.")
        {:error, :connection_failed}
    end
  end

  @doc "Renders a QR in the terminal and redacts all data if rendering fails."
  @spec render_qr(String.t(), module(), keyword()) :: :ok
  def render_qr(qr, transport \\ AmarulaClient, transport_opts \\ []) when is_binary(qr) do
    case safe_render(transport, qr, transport_opts) do
      {:ok, ascii} -> IO.puts("\n" <> ascii <> "\n")
      {:error, _reason} -> Logger.warning("Could not render QR. QR content was redacted.")
    end

    :ok
  end

  defp safe_render(transport, qr, transport_opts) do
    transport.render_qr(qr, transport_opts)
  rescue
    _exception -> {:error, :redacted}
  catch
    _kind, _reason -> {:error, :redacted}
  end

  defp run_connected(transport, conn, profile, transport_opts, timeout_ms) do
    announce_start(profile)
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    try do
      case loop(transport, conn, transport_opts, deadline) do
        :ok ->
          Logger.info("WhatsApp profile linked. Credentials were persisted.")
          Process.sleep(Keyword.get(transport_opts, :success_delay_ms, 1_000))
          :ok

        :timeout ->
          :timeout
      end
    after
      cleanup(transport, conn, transport_opts)
    end
  end

  defp loop(transport, conn, transport_opts, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      :timeout
    else
      receive do
        {:amarula, :connection_update, %{qr: qr}} when is_binary(qr) ->
          :ok = render_qr(qr, transport, transport_opts)
          loop(transport, conn, transport_opts, deadline)

        {:amarula, :pairing_code, _data} ->
          Logger.warning("Ignored a phone pairing-code event. Phone pairing is disabled.")
          loop(transport, conn, transport_opts, deadline)

        {:amarula, :pairing_success, _data} ->
          Logger.info("Pairing succeeded. Completing login.")
          loop(transport, conn, transport_opts, deadline)

        {:amarula, :connection_update, %{connection: :open}} ->
          :ok

        {:amarula, :error, _error} ->
          Logger.error("WhatsApp connection error. Error data was redacted.")
          loop(transport, conn, transport_opts, deadline)

        {:amarula, _type, _data} ->
          loop(transport, conn, transport_opts, deadline)
      after
        remaining -> :timeout
      end
    end
  end

  defp cleanup(transport, conn, transport_opts) do
    case transport.stop(conn, transport_opts) do
      :ok -> :ok
      {:error, _reason} -> Logger.warning("Could not stop the pairing connection. Error data was redacted.")
    end
  rescue
    _exception -> Logger.warning("Could not stop the pairing connection. Error data was redacted.")
  catch
    _kind, _reason -> Logger.warning("Could not stop the pairing connection. Error data was redacted.")
  end

  defp announce_start(profile),
    do: Logger.info("Pairing #{inspect(profile)}. Scan the QR in this terminal.")
end
