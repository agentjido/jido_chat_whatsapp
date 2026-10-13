defmodule Jido.Chat.WhatsApp.ConnectionWorkerTest do
  use ExUnit.Case, async: false

  alias Jido.Chat.WhatsApp.ConnectionWorker
  alias Amarula.{Address, Msg}
  alias Amarula.Protocol.Proto

  defmodule Sink do
    def emit(test_pid, payload, opts) do
      send(test_pid, {:sink_emit, payload, opts})
      {:ok, :accepted}
    end
  end

  defmodule MockTransport do
    @behaviour Jido.Chat.WhatsApp.Transport

    @impl true
    def connect(config, opts) do
      send(Map.fetch!(config, :test_pid), {:transport_connect, config, opts})
      {:ok, self()}
    end

    @impl true
    def logout(_conn, _opts), do: :ok

    @impl true
    def resolve_conn(_opts), do: {:ok, self()}

    @impl true
    def send_text(_conn, _jid, _text, _opts), do: {:ok, "msg"}

    @impl true
    def send_media(_conn, _jid, _media_type, _data, _opts), do: {:ok, "msg"}

    @impl true
    def download_media(_media), do: {:error, :unsupported}

    @impl true
    def send_reaction(_conn, _message_ref, _emoji), do: {:ok, "msg"}

    @impl true
    def send_edit(_conn, _message_ref, _text), do: {:ok, "msg"}

    @impl true
    def send_revoke(_conn, _message_ref), do: {:ok, "msg"}

    @impl true
    def send_chatstate(_conn, _jid, _state), do: :ok

    @impl true
    def request_pairing_code(_conn, _phone, _opts), do: {:ok, "12345678"}
  end

  defmodule DelayedTransport do
    def connect(config, _opts) do
      send(config.test_pid, {:establishing, self()})

      receive do
        :continue -> {:ok, config.test_pid}
      end
    end

    def stop(test_pid, _opts) do
      send(test_pid, :partial_connection_cleaned)
      :ok
    end
  end

  test "worker death during startup still cleans the eventual connection" do
    test_pid = self()

    task =
      Task.async(fn ->
        GenServer.start(ConnectionWorker,
          bridge_id: "partial",
          sink_mfa: {Sink, :emit, [test_pid]},
          transport: DelayedTransport,
          config: %{profile: "partial", test_pid: test_pid}
        )
      end)

    assert_receive {:establishing, receiver}
    {:monitors, [{:process, worker}]} = Process.info(receiver, :monitors)
    Process.exit(worker, :kill)
    send(receiver, :continue)
    assert_receive :partial_connection_cleaned
    assert {:error, :killed} = Task.await(task)
  end

  defp worker(extra \\ []) do
    {qr_timeout, extra} = Keyword.pop(extra, :qr_timeout, 10)
    profile = "profile_#{System.unique_integer([:positive])}"

    opts = [
      bridge_id: profile,
      sink_mfa: {Sink, :emit, [self()]},
      lifecycle_sink_mfa: {Sink, :emit, [self()]},
      transport: MockTransport,
      config: %{profile: profile, test_pid: self(), qr_timeout: qr_timeout}
    ]

    pid = start_supervised!(Supervisor.child_spec({ConnectionWorker, Keyword.merge(opts, extra)}, id: profile))
    assert_receive {:transport_connect, config, connect_opts}
    {pid, connect_opts[:parent], config.profile}
  end

  test "chat ingress gets payloads enriched through transport" do
    {_pid, parent, _} = worker()

    msg = %Msg{
      id: "msg-1",
      channel: Address.pn("123"),
      from: Address.pn("456"),
      type: :text,
      content: "hello",
      raw: %Proto.Message{}
    }

    send(parent, {:amarula, :messages_upsert, %{id: "batch-1", messages: [msg]}})
    assert_receive {:sink_emit, %{id: "msg-1", channel_jid: "123@s.whatsapp.net"} = payload, opts}
    assert payload.metadata.batch_id == "batch-1"
    assert opts[:path] == "/whatsapp/messages_upsert"
  end

  test "reaction additions and removals emit envelopes for Amarula direct and group references" do
    {_pid, parent, _profile} = worker()

    for key <- [
          {"123@s.whatsapp.net", "answer-pn", true},
          {"123@lid", "answer-lid", true},
          {"120363@g.us", "answer-group", true, "456@lid"}
        ],
        emoji <- ["👍", ""] do
      msg = %Msg{
        id: "reaction-wire-id",
        channel: Address.pn("999"),
        from: Address.lid("456"),
        from_me: false,
        type: :reaction,
        content: %Amarula.Content.Reaction{key: key, emoji: emoji},
        raw: %Proto.Message{}
      }

      send(parent, {:amarula, :messages_upsert, %{messages: [msg]}})

      assert_receive {:sink_emit, %Jido.Chat.EventEnvelope{event_type: :reaction} = envelope, _opts}
      assert envelope.channel_id == elem(key, 0)
      assert envelope.message_id == elem(key, 1)
      assert envelope.payload.message_id != msg.id
      assert envelope.payload.user.user_id == "456@lid"
      assert envelope.payload.added == (emoji != "")
      assert envelope.payload.metadata.from_me == false
    end
  end

  test "malformed reaction targets are rejected instead of emitted as text payloads" do
    {pid, parent, _profile} = worker()

    msg = %Msg{
      id: "reaction-wire-id",
      channel: Address.pn("123"),
      from: Address.lid("456"),
      type: :reaction,
      content: %Amarula.Content.Reaction{key: nil, emoji: "👍"},
      raw: %Proto.Message{}
    }

    send(parent, {:amarula, :messages_upsert, %{messages: [msg]}})
    refute_receive {:sink_emit, _, _}
    assert Process.alive?(pid)
  end

  test "lifecycle is correlated, sanitized, and connected only after socket open" do
    {pid, parent, profile} = worker()
    send(parent, {:amarula, :pairing_success, %{secret: "redact-me"}})
    assert_receive {:sink_emit, %{status: :authenticating, profile: ^profile, attempt_id: attempt, qr: nil}, _}
    send(parent, {:amarula, :connection_update, %{connection: :open}})
    assert_receive {:sink_emit, %{status: :connected, attempt_id: ^attempt}, _}
    send(parent, {:amarula, :error, %{secret: "redact-me"}})
    assert_receive {:sink_emit, %{status: :failed} = event, _}
    refute inspect(event) =~ "redact-me"
    send(pid, {:transport_event, make_ref(), :connection_update, %{connection: :open}})
    assert ConnectionWorker.status(pid).status == :failed
    refute_receive {:sink_emit, _, _}
  end

  test "QR expires, refresh supersedes old timer and completion clears it" do
    {pid, parent, _} = worker()
    send(parent, {:amarula, :connection_update, %{qr: "sensitive"}})
    assert_receive {:sink_emit, %{event: :qr_available, qr: "sensitive"}, _}
    assert_receive {:sink_emit, %{event: :qr_expired, qr: nil}, _}
    send(parent, {:amarula, :connection_update, %{qr: "replacement"}})
    assert_receive {:sink_emit, %{qr: "replacement"}, _}
    state = :sys.get_state(pid)
    send(pid, {:qr_expired, state.attempt_id, make_ref()})
    assert ConnectionWorker.status(pid).qr == "replacement"
    send(parent, {:amarula, :pairing_success, %{}})
    assert_receive {:sink_emit, %{qr: nil, status: :authenticating}, _}
  end

  defp expire_qr(pid, parent, profile) do
    send(parent, {:amarula, :connection_update, %{qr: "test-only"}})
    assert_receive {:sink_emit, %{event: :qr_available, profile: ^profile, attempt_id: attempt}, _}
    assert_receive {:sink_emit, %{event: :qr_expired, profile: ^profile} = expired, _}, 500
    snapshot = ConnectionWorker.status(pid)
    assert %{status: :expired, qr: nil, attempt_id: ^attempt} = snapshot
    assert %{status: :expired, qr: nil, attempt_id: ^attempt} = expired
    assert snapshot.event == :status
    attempt
  end

  test "expiry remains queryable until a replacement QR restores pairing" do
    {pid, parent, profile} = worker()
    attempt = expire_qr(pid, parent, profile)
    send(parent, {:amarula, :connection_update, %{qr: "replacement"}})
    assert_receive {:sink_emit, %{event: :qr_available, status: :pairing, attempt_id: ^attempt}, _}
    assert %{status: :pairing, qr: "replacement"} = ConnectionWorker.status(pid)
  end

  test "old QR tokens and foreign attempts cannot expire a replacement QR" do
    {pid, parent, _} = worker(qr_timeout: 60_000)
    send(parent, {:amarula, :connection_update, %{qr: "first"}})
    assert_receive {:sink_emit, %{event: :qr_available, qr: "first"}, _}
    old = :sys.get_state(pid)
    send(parent, {:amarula, :connection_update, %{qr: "replacement"}})
    assert_receive {:sink_emit, %{event: :qr_available, qr: "replacement"}, _}
    current = :sys.get_state(pid)
    send(pid, {:qr_expired, old.attempt_id, old.qr_token})
    send(pid, {:qr_expired, make_ref(), current.qr_token})
    assert %{status: :pairing, qr: "replacement"} = ConnectionWorker.status(pid)
    refute_receive {:sink_emit, %{event: :qr_expired}, _}
  end

  test "expiry transitions distinctly to connected, disconnected and logged out" do
    for status <- [:connected, :disconnected, :logged_out] do
      {pid, parent, profile} = worker()
      expire_qr(pid, parent, profile)

      case status do
        :connected -> send(parent, {:amarula, :connection_update, %{connection: :open}})
        :disconnected -> send(parent, {:amarula, :connection_update, %{connection: :closed}})
        :logged_out -> assert :ok = ConnectionWorker.logout(pid)
      end

      assert_receive {:sink_emit, %{status: ^status, qr: nil, profile: ^profile}, _}
      assert %{status: ^status, qr: nil} = ConnectionWorker.status(pid)
    end
  end

  test "reconnect resets expiry and isolates old attempts and separate profiles" do
    {pid, parent, profile} = worker()
    {other, other_parent, other_profile} = worker(qr_timeout: 60_000)
    send(other_parent, {:amarula, :connection_update, %{qr: "other-profile"}})
    assert_receive {:sink_emit, %{event: :qr_available, profile: ^other_profile}, _}
    old_attempt = expire_qr(pid, parent, profile)
    assert %{status: :pairing, qr: "other-profile"} = ConnectionWorker.status(other)

    assert :ok = ConnectionWorker.reconnect(pid)
    assert_receive {:transport_connect, %{profile: ^profile}, opts}
    assert_receive {:sink_emit, %{status: :connecting, qr: nil, attempt_id: attempt}, _}
    refute attempt == old_attempt
    assert %{status: :connecting, qr: nil, attempt_id: ^attempt} = ConnectionWorker.status(pid)
    send(opts[:parent], {:amarula, :connection_update, %{qr: "initial-new-attempt"}})
    assert_receive {:sink_emit, %{event: :qr_available, qr: "initial-new-attempt", profile: ^profile}, _}
    send(opts[:parent], {:amarula, :connection_update, %{qr: "new-attempt"}})
    assert_receive {:sink_emit, %{event: :qr_available, qr: "new-attempt", profile: ^profile}, _}
    current = :sys.get_state(pid)
    send(pid, {:qr_expired, old_attempt, current.qr_token})
    assert %{status: :pairing, qr: "new-attempt"} = ConnectionWorker.status(pid)
    send(other, {:qr_expired, attempt, current.qr_token})
    assert %{status: :pairing, qr: "other-profile"} = ConnectionWorker.status(other)
  end

  test "omitting lifecycle sink never leaks controls into chat and profiles are isolated" do
    {pid, parent, profile} = worker(lifecycle_sink_mfa: nil)
    {other, other_parent, other_profile} = worker(lifecycle_sink_mfa: nil)

    for target <- [parent, other_parent] do
      send(target, {:amarula, :connection_update, %{qr: "secret"}})
      send(target, {:amarula, :pairing_code, %{code: "secret"}})
      send(target, {:amarula, :error, "secret"})
    end

    refute_receive {:sink_emit, _, _}
    assert ConnectionWorker.status(pid).profile == profile
    assert ConnectionWorker.status(other).profile == other_profile
    refute ConnectionWorker.status(pid).attempt_id == ConnectionWorker.status(other).attempt_id
  end
end
