defmodule Jido.Chat.WhatsApp.PairingRecoveryTest do
  use ExUnit.Case, async: true
  alias Jido.Chat.WhatsApp.{ConnectionWorker, PairingSession}
  alias Jido.Chat.WhatsApp.Transport.AmarulaClient

  defmodule Control do
    use GenServer
    def start_link(owner), do: GenServer.start_link(__MODULE__, owner)
    def init(owner), do: {:ok, %{owner: owner, connection: :disconnected, identity: {:error, :unavailable}}}
    def handle_call(:get_connection_state, _, state), do: {:reply, state.connection, state}
    def handle_call(:identity, _, state), do: {:reply, state.identity, state}
    def handle_call({:set, values}, _, state), do: {:reply, :ok, Map.merge(state, values)}
  end

  def connect(config, opts) do
    send(opts[:observer], {:connection, config.profile})
    {:ok, opts[:control]}
  end

  def stop(control, _) do
    send(:sys.get_state(control).owner, :transport_stopped)
    :ok
  end

  def logout(control, _) do
    send(:sys.get_state(control).owner, :transport_logged_out)
    :ok
  end

  def recovery_status(control), do: AmarulaClient.recovery_status(control)
  def account_identity(control), do: GenServer.call(control, :identity)
  def unused(_, _), do: {:error, :unused}

  setup do
    control = start_supervised!({Control, self()})
    supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})

    {:ok, %{session: session}} =
      PairingSession.execute(%{op: :begin, owner: self()}, :owner,
        supervisor: supervisor,
        attempt_id: "recovery_#{System.unique_integer([:positive])}",
        context: nil,
        persist_mfa: {__MODULE__, :unused, []},
        start_mfa: {__MODULE__, :unused, []},
        transport: __MODULE__,
        connect_opts: [observer: self(), control: control]
      )

    assert_receive {:connection, profile}
    worker = :sys.get_state(session).worker

    %{
      session: session,
      worker: worker,
      control: control,
      profile: profile,
      attempt: ConnectionWorker.status(worker).attempt_id
    }
  end

  test "scan succeeds, transport recovers, and retry retains the same session and credentials", c do
    event(c, :pairing_success, %{})
    event(c, :error, :xml_stream_end)
    assert ConnectionWorker.status(c.worker).status == :reconnecting
    assert {:ok, %{phase: :pending, qr: nil}} = command(c, :status)
    assert {:ok, %{phase: :pending}} = command(c, :retry)
    event(c, :connection_update, %{connection: :disconnected})
    assert {:ok, %{phase: :pending}} = command(c, :status)
    connect_identity(c, identity())
    assert {:ok, %{phase: :confirm}} = command(c, :status)
    assert {:ok, %{phase: :confirm}} = command(c, :retry)
    assert ConnectionWorker.status(c.worker).attempt_id == c.attempt
    refute_received {:connection, _}
    refute_received :transport_stopped
    refute_received :transport_logged_out
  end

  test "exhausted transport retries are terminal and explicit retry retains the profile", c do
    :ok = GenServer.call(c.control, {:set, %{connection: :closed}})
    event(c, :error, :timeout)
    assert {:ok, %{phase: :failed, qr: nil}} = command(c, :status)
    assert {:ok, %{phase: :pending}} = command(c, :retry)
    assert_received :transport_stopped
    assert_received {:connection, profile}
    assert profile == c.profile
    refute ConnectionWorker.status(c.worker).attempt_id == c.attempt
    refute_received :transport_logged_out
  end

  test "retry refreshes missing identity without reconnecting an authenticated account", c do
    connect_identity(c, {:error, :unavailable})
    assert {:ok, %{phase: :failed}} = command(c, :status)
    :ok = GenServer.call(c.control, {:set, %{identity: identity()}})
    :erlang.trace(c.worker, true, [:receive])
    assert {:ok, %{phase: phase}} = command(c, :retry)
    assert phase in [:pending, :confirm]
    await_identity(c)
    assert {:ok, %{phase: :confirm}} = command(c, :status)
    refute_received {:connection, _}
    refute_received :transport_stopped
    refute_received :transport_logged_out
  end

  test "unavailable transport cannot claim to be recovering", c do
    assert AmarulaClient.recovery_status(c.control) == :reconnecting
    assert :ok = command(c, :cancel)
    stop_supervised(Control)
    assert AmarulaClient.recovery_status(c.control) == :failed
  end

  defp identity, do: {:ok, %{phone_number: "+15550001", account_jids: ["15550001@s.whatsapp.net"]}}
  defp command(c, op), do: PairingSession.execute(%{op: op, session: c.session}, :owner, [])

  defp event(c, event, payload) do
    send(c.worker, {:transport_event, c.attempt, event, payload})
    ConnectionWorker.status(c.worker)
  end

  defp connect_identity(c, identity) do
    :ok = GenServer.call(c.control, {:set, %{connection: :connected, identity: identity}})
    :erlang.trace(c.worker, true, [:receive])
    event(c, :connection_update, %{connection: :open})
    await_identity(c)
  end

  defp await_identity(c) do
    worker = c.worker
    assert_receive {:trace, ^worker, :receive, {:identity_result, _, _, _}}
    :erlang.trace(worker, false, [:receive])
  end
end
