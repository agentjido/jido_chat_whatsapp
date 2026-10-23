defmodule Jido.Chat.WhatsApp.LifecycleDeliveryTest do
  use ExUnit.Case, async: true

  import Jido.Chat.WhatsApp.TestHelpers
  alias Jido.Chat
  alias Jido.Chat.{ActionEvent, EventEnvelope}
  alias Jido.Chat.WhatsApp.{Adapter, ConnectionWorker}

  defmodule Transport do
    def connect(config, opts) do
      send(config.observer, {:connection, config.profile, opts[:parent]})
      send(opts[:parent], {:amarula, :pairing_success, %{credentials: "synthetic-secret"}})
      {:ok, self()}
    end

    def stop(_, _), do: :ok
  end

  defmodule Host do
    use GenServer

    def start_link(observer), do: GenServer.start_link(__MODULE__, observer)

    def init(observer) do
      chat =
        Chat.new(adapters: %{whatsapp: Adapter})
        |> Chat.on_new_message(~r/.*/, fn _, _ -> send(observer, :unexpected_message) end)
        |> Chat.on_action("connection_update", fn
          chat,
          %ActionEvent{
            adapter: Adapter,
            adapter_name: :whatsapp,
            metadata: %{category: :connection_lifecycle} = metadata
          } ->
            %{chat | metadata: Map.put(chat.metadata, :lifecycle, metadata)}

          chat, _ ->
            chat
        end)

      {:ok, %{chat: chat, source: nil}}
    end

    def handle_call({:register, source}, _, state), do: {:reply, :ok, %{state | source: source}}
    def handle_call(:status, _, state), do: {:reply, state.chat.metadata[:lifecycle], state}

    def handle_call({:event, _}, _, %{source: nil} = state),
      do: {:reply, {:error, :runtime_not_ready}, state}

    def handle_call({:event, %EventEnvelope{payload: %{metadata: %{source: source}}} = envelope}, _, state) do
      if source == state.source do
        {:ok, result} = Chat.route_event(state.chat, :whatsapp, envelope)
        {:reply, :ok, %{state | chat: result.chat}}
      else
        {:reply, {:error, :retired_source}, state}
      end
    end
  end

  # A controlled synchronous sink exercises blocking, failure and host readiness
  # without sleeps or mocking the worker/router.
  def emit(observer, host, envelope, opts) do
    send(observer, {:delivery, self(), envelope, opts})

    result =
      receive do
        :continue -> GenServer.call(host, {:event, envelope})
        :raise -> raise "synthetic-private-error"
        :throw -> throw(:synthetic_private_error)
        :exit -> exit(:synthetic_private_error)
        {:return, result} -> result
      end

    send(observer, {:returned, envelope.id, result})
    result
  end

  defp listener(host, profile) do
    worker =
      start_listener(
        profile,
        %{mode: :linked_device, profile: profile, transport: Transport, config: %{observer: self()}},
        sink_mfa: {__MODULE__, :emit, [self(), host]}
      )

    assert_receive {:connection, ^profile, relay}
    {worker, relay}
  end

  test "early events retry unchanged until registration, then update host synchronously in order" do
    host = start_supervised!({Host, self()})
    {worker, _relay} = listener(host, "startup")
    assert_receive {:delivery, dispatcher, first, opts}
    assert opts == [bridge_id: "startup"]
    assert first.event_type == :action
    assert first.raw == %{}
    assert first.payload.raw == %{}
    assert first.payload.action_id == "connection_update"
    assert first.payload.value == "pairing_success"
    assert first.payload.metadata.source == worker
    assert first.payload.metadata.event == :pairing_success
    assert first.payload.metadata.presentation == Jido.Chat.WhatsApp.Pairing.presentation(first.payload.metadata)
    refute inspect(first) =~ "synthetic-secret"
    send(dispatcher, :continue)
    assert_receive {:returned, id, {:error, :runtime_not_ready}}
    assert id == first.id
    assert_receive {:delivery, ^dispatcher, ^first, ^opts}, 500

    # A blocked callback cannot block worker status or subsequent transitions.
    send(worker, {:transport_event, first.payload.metadata.attempt_id, :connection_update, %{connection: :closed}})
    # Same sender barrier through the worker uses the observed attempt.
    send(worker, {:transport_event, first.payload.metadata.attempt_id, :error, %{}})
    assert ConnectionWorker.status(worker).status == :failed
    assert :ok = GenServer.call(host, {:register, worker})
    send(dispatcher, :continue)
    assert_receive {:returned, ^id, :ok}
    assert %{event: :pairing_success, status: :authenticating} = GenServer.call(host, :status)

    # All queued notifications are processed serially, including the later close.
    for _ <- 1..2 do
      assert_receive {:delivery, ^dispatcher, next, _}
      send(dispatcher, :continue)
      assert_receive {:returned, next_id, :ok}
      assert next_id == next.id
      assert GenServer.call(host, :status) == next.payload.metadata
    end

    refute_received :unexpected_message
  end

  test "sink errors, exceptions, throws and exits discard one notification and retain responsiveness" do
    host = start_supervised!({Host, self()})
    {worker, _} = listener(host, "errors")
    :ok = GenServer.call(host, {:register, worker})
    attempt = ConnectionWorker.status(worker).attempt_id

    for failure <- [:raise, :throw, :exit, {:return, {:error, :failed}}] do
      assert_receive {:delivery, dispatcher, _, _}
      send(dispatcher, failure)
      send(worker, {:transport_event, attempt, :error, %{}})
      assert ConnectionWorker.status(worker).status == :failed
    end

    assert_receive {:delivery, dispatcher, last, _}
    send(dispatcher, :continue)
    assert_receive {:returned, id, :ok}
    assert id == last.id
    assert GenServer.call(host, :status) == last.payload.metadata
  end

  test "replacement workers retain distinct source identity and stop queued delivery" do
    host = start_supervised!({Host, self()})
    {old_worker, _} = listener(host, "replace")
    assert_receive {:delivery, old_dispatcher, old, _}
    ref = Process.monitor(old_dispatcher)
    stop_supervised!({:whatsapp_connection_worker, "replace"})
    assert_receive {:DOWN, ^ref, :process, ^old_dispatcher, :shutdown}

    {worker, _} = listener(host, "replace")
    refute worker == old_worker
    :ok = GenServer.call(host, {:register, worker})
    assert {:error, :retired_source} = GenServer.call(host, {:event, old})
    assert_receive {:delivery, dispatcher, fresh, _}
    assert fresh.payload.metadata.source == worker
    refute fresh.payload.metadata.attempt_id == old.payload.metadata.attempt_id
    send(dispatcher, :continue)
    assert_receive {:returned, _, :ok}
    assert GenServer.call(host, :status) == fresh.payload.metadata
  end
end
