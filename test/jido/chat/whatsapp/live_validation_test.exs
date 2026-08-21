defmodule Jido.Chat.WhatsApp.LiveValidationTest do
  use ExUnit.Case, async: true

  alias Jido.Chat.WhatsApp.LiveValidation

  test "failure summaries replace an active QR with a marker" do
    sentinel = "SECRET-QR-SENTINEL"

    summary =
      LiveValidation.summarize_event({:amarula, :connection_update, %{connection: :connecting, qr: sentinel}})

    assert summary == {:connection_update, %{connection: :connecting, qr: :redacted}}
    refute inspect(summary) =~ sentinel
  end

  test "one suite-wide reconnect budget rejects a second reconnect" do
    budget = LiveValidation.new_reconnect_budget()

    assert {:ok, :reconnected} = LiveValidation.reconnect_once(budget, fn -> :reconnected end)

    assert {:error, :reconnect_budget_exhausted} =
             LiveValidation.reconnect_once(budget, fn -> flunk("second reconnect ran") end)
  end

  test "rejected-session observation window is at least 30 seconds" do
    assert LiveValidation.no_reconnect_observation_ms(0) == 30_000
    assert LiveValidation.no_reconnect_observation_ms(-1) == 30_000
    assert LiveValidation.no_reconnect_observation_ms(15_000) == 30_000
    assert LiveValidation.no_reconnect_observation_ms(45_000) == 45_000
  end
end
