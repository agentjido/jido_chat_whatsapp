defmodule Jido.Chat.WhatsApp.PairingTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Jido.Chat.WhatsApp.Pairing
  alias Jido.Chat.WhatsApp.Transport.AmarulaClient

  defmodule FakeTransport do
    use Jido.Chat.WhatsApp.TransportStub

    def ensure_started(opts) do
      send(owner(opts), {:transport, :ensure_started})
      :ok
    end

    def connect(config, opts) do
      send(owner(opts), {:transport, :connect, config, opts})

      Enum.each(Keyword.get(opts, :events, []), fn event ->
        send(Keyword.fetch!(opts, :parent_pid), event)
      end)

      {:ok, {:fake_connection, make_ref()}}
    end

    def stop(conn, opts) do
      send(owner(opts), {:transport, :stop, conn})
      :ok
    end

    def render_qr(qr, opts) do
      send(owner(opts), {:transport, :render_qr, qr})

      case Keyword.get(opts, :render_result, {:ok, "rendered QR"}) do
        :raise -> raise "renderer included SECRET-QR-SENTINEL"
        result -> result
      end
    end

    defp owner(opts), do: Keyword.fetch!(opts, :test_pid)
  end

  test "the Amarula transport starts or reuses the shared supervisor" do
    assert :ok = AmarulaClient.ensure_started([])
    supervisor = Process.whereis(Amarula.Supervisor)
    assert is_pid(supervisor)

    assert :ok = AmarulaClient.ensure_started([])
    assert Process.whereis(Amarula.Supervisor) == supervisor
    assert Process.alive?(supervisor)
  end

  test "pairing starts the transport before connect and cleans up on timeout" do
    assert :timeout =
             Pairing.run("new-string-profile",
               transport: FakeTransport,
               transport_opts: [test_pid: self()],
               timeout: 0
             )

    assert_receive {:transport, :ensure_started}

    assert_receive {:transport, :connect, %{profile: "new-string-profile"}, connect_opts}
    assert connect_opts[:parent_pid] == self()

    assert_receive {:transport, :stop, {:fake_connection, _ref}}
  end

  test "pairing redacts a QR renderer exception and cleans up on task exit" do
    qr = "SECRET-QR-SENTINEL"

    log =
      capture_log(fn ->
        assert :ok =
                 Pairing.run("renderer-failure",
                   transport: FakeTransport,
                   transport_opts: [
                     test_pid: self(),
                     render_result: :raise,
                     success_delay_ms: 0,
                     events: [
                       {:amarula, :connection_update, %{qr: qr}},
                       {:amarula, :connection_update, %{connection: :open}}
                     ]
                   ],
                   timeout: 1
                 )
      end)

    assert_receive {:transport, :stop, {:fake_connection, _ref}}
    assert log =~ "QR content was redacted"
    refute log =~ qr
  end

  test "a QR renderer failure does not log the QR or renderer error data" do
    sentinel = "SECRET-QR-SENTINEL"

    log =
      capture_log(fn ->
        assert :ok =
                 Pairing.render_qr(sentinel, FakeTransport,
                   test_pid: self(),
                   render_result: {:error, sentinel}
                 )
      end)

    assert_receive {:transport, :render_qr, ^sentinel}
    assert log =~ "QR content was redacted"
    refute log =~ sentinel
  end

  test "the Mix task rejects phone pairing without exposing the phone value" do
    phone = "15551234567"

    error =
      assert_raise Mix.Error, fn ->
        Mix.Tasks.JidoChatWhatsapp.Pair.run(["safe-profile", "--phone", phone])
      end

    assert Exception.message(error) =~ "QR-only"
    refute Exception.message(error) =~ phone
  end
end
