defmodule Jido.Chat.WhatsApp.ConnectionWorkerTest do
  use ExUnit.Case, async: false

  alias Amarula.Address
  alias Jido.Chat.{Client, Sensor}
  alias Jido.Chat.WhatsApp.{Adapter, ConnectionWorker, Source}

  defmodule Transport do
    @behaviour Jido.Chat.WhatsApp.Transport

    def connect(config, opts) do
      send(config.test_pid, {:transport_connect, opts[:parent]})
      {:ok, self()}
    end

    def stop(_conn, _opts), do: :ok
    def resolve_conn(opts), do: {:ok, opts[:conn] || self()}
    def canonical_user_id(_conn, jid), do: {:ok, jid}
    def account_jids(_conn), do: {:ok, []}
    def send_text(_, _, _, _), do: {:ok, "message"}
    def send_media(_, _, _, _, _), do: {:ok, "message"}
    def download_media(_), do: {:error, :unsupported}
    def send_reaction(_, _, _), do: {:ok, "message"}
    def send_edit(_, _, _), do: {:ok, "message"}
    def send_revoke(_, _), do: {:ok, "message"}
    def send_chatstate(_, _, _), do: :ok
    def request_pairing_code(_, _, _), do: {:ok, "12345678"}
  end

  defmodule DelayedTransport do
    def connect(config, _opts) do
      send(config.test_pid, {:establishing, self()})
      receive do: (:continue -> {:ok, config.test_pid})
    end

    def stop(test_pid, _opts) do
      send(test_pid, :partial_connection_cleaned)
      :ok
    end
  end

  defmodule UnavailableLifetimeTransport do
    def connect(config, _opts), do: {:ok, config.test_pid}
    def connection_processes(_), do: {:error, :runtime_unavailable}

    def stop(pid, _opts) do
      send(pid, :unwatched_connection_cleaned)
      :ok
    end
  end

  defp client(transport, profile) do
    Client.new!(Adapter,
      id: "whatsapp-source-#{System.unique_integer([:positive])}",
      config: [profile: profile],
      transport: transport
    )
  end

  defp callback(test_pid, label), do: {__MODULE__, :capture, [test_pid, label]}
  def capture(test_pid, label, value, _opts), do: send(test_pid, {label, value})

  test "the push Source admits normalized facts and stops with its Sensor" do
    profile = "source-#{System.unique_integer([:positive])}"
    client = client(Transport, profile)

    sensor =
      start_supervised!(
        {Sensor,
         client: client,
         source: Source,
         emit: "jido.chat.**",
         options: [profile: profile, config: %{test_pid: self()}],
         dispatch: {:pid, target: self()}}
      )

    assert_receive {:transport_connect, relay}
    worker = :sys.get_state(sensor).worker
    monitor = Process.monitor(worker)

    message = %Amarula.Msg{
      id: "m-1",
      channel: Address.pn("15550001"),
      from: Address.pn("15550002"),
      type: :text,
      content: "hello",
      raw: %Amarula.Protocol.Proto.Message{}
    }

    send(relay, {:amarula, :messages_upsert, %{messages: [message]}})

    assert_receive {:signal, %Jido.Signal{type: "jido.chat.message.received"} = signal}
    assert signal.data["room_id"] == "15550001@s.whatsapp.net"
    assert signal.data["text"] == "hello"

    stop_supervised!(Sensor)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}
  end

  test "lifecycle control stays in a private callback and never becomes a chat fact" do
    profile = "lifecycle-#{System.unique_integer([:positive])}"
    client = client(Transport, profile)

    {:ok, worker} =
      ConnectionWorker.start_link(
        client: client,
        admission_mfa: callback(self(), :signals),
        lifecycle_mfa: callback(self(), :lifecycle),
        transport: Transport,
        config: %{profile: profile, test_pid: self(), qr_timeout: 50}
      )

    assert_receive {:transport_connect, _relay}
    attempt = ConnectionWorker.status(worker).attempt_id
    send(worker, {:transport_event, attempt, :connection_update, %{qr: "private-qr"}})

    assert_receive {:lifecycle, lifecycle}
    assert lifecycle.event == :qr_available
    assert lifecycle.status == :pairing
    assert lifecycle.qr == "private-qr"
    refute_receive {:signals, _}
    GenServer.stop(worker)
  end

  test "failure to watch a connection lifetime cleans the opened connection" do
    profile = "unavailable-#{System.unique_integer([:positive])}"

    assert {:error, :connection_failed} =
             GenServer.start(ConnectionWorker,
               client: client(UnavailableLifetimeTransport, profile),
               admission_mfa: callback(self(), :signals),
               config: %{profile: profile, test_pid: self()},
               transport: UnavailableLifetimeTransport
             )

    assert_receive :unwatched_connection_cleaned
  end

  test "worker death during startup cleans the eventual connection" do
    test_pid = self()
    profile = "partial-#{System.unique_integer([:positive])}"

    task =
      Task.async(fn ->
        GenServer.start(ConnectionWorker,
          client: client(DelayedTransport, profile),
          admission_mfa: callback(test_pid, :signals),
          transport: DelayedTransport,
          config: %{profile: profile, test_pid: test_pid}
        )
      end)

    assert_receive {:establishing, receiver}
    {:monitors, [{:process, worker}]} = Process.info(receiver, :monitors)
    Process.exit(worker, :kill)
    send(receiver, :continue)
    assert_receive :partial_connection_cleaned
    assert {:error, :killed} = Task.await(task)
  end
end
