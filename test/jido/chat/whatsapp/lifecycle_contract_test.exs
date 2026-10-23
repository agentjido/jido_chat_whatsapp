defmodule Jido.Chat.WhatsApp.LifecycleContractTest do
  use ExUnit.Case, async: true

  alias Jido.Chat
  alias Jido.Chat.{ActionEvent, EventEnvelope}
  alias Jido.Chat.WhatsApp.Adapter

  defp envelope do
    EventEnvelope.new(%{
      adapter_name: :whatsapp,
      event_type: :action,
      raw: %{},
      payload:
        ActionEvent.new(%{
          adapter: Adapter,
          adapter_name: :whatsapp,
          action_id: "connection_update",
          value: "qr_available",
          raw: %{},
          metadata: %{
            category: :connection_lifecycle,
            source: self(),
            profile: "contract",
            attempt_id: make_ref(),
            event: :qr_available,
            status: :pairing,
            qr: "synthetic-test-qr",
            identity: nil,
            identity_status: :unavailable,
            identity_error: :not_connected
          }
        })
    })
  end

  test "real action routing preserves lifecycle metadata without invoking message handlers" do
    owner = self()

    chat =
      Chat.new(adapters: %{whatsapp: Adapter})
      |> Chat.on_new_message(~r/.*/, fn _, _ -> flunk("lifecycle reached message handler") end)
      |> Chat.on_action("connection_update", fn
        %ActionEvent{adapter: Adapter, adapter_name: :whatsapp, metadata: %{category: :connection_lifecycle}} = action ->
          send(owner, {:lifecycle, action})

        _ ->
          :ok
      end)

    envelope = envelope()
    # Exercise map normalization as well as the typed public envelope path.
    for payload <- [envelope.payload, Map.from_struct(envelope.payload)] do
      assert {:ok, %{event: %{payload: action}}} = Chat.route_event(chat, :whatsapp, %{envelope | payload: payload})
      assert_receive {:lifecycle, ^action}
      assert action.metadata == envelope.payload.metadata
      assert action.raw == %{}
    end

    for action <- [
          %{envelope.payload | action_id: "button"},
          %{envelope.payload | metadata: %{category: :thread}},
          %{envelope.payload | adapter_name: :other}
        ] do
      assert {:ok, _} = Chat.route_event(chat, :whatsapp, %{envelope | payload: action})
      refute_received {:lifecycle, _}
    end
  end

  test "a host without an action handler safely ignores lifecycle" do
    chat =
      Chat.new(adapters: %{whatsapp: Adapter})
      |> Chat.on_new_message(~r/.*/, fn _, _ -> flunk("unexpected message") end)

    assert {:ok, %{chat: ^chat, event: %{payload: %ActionEvent{}}}} = Chat.route_event(chat, :whatsapp, envelope())
  end
end
