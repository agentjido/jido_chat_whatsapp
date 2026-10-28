defmodule Jido.Chat.WhatsApp.LiveIntegrationTest do
  use ExUnit.Case, async: false
  @moduletag :live
  @run_live System.get_env("RUN_LIVE_WHATSAPP_TESTS") in ["1", "true", "TRUE", "yes", "on"]

  if not @run_live do
    @moduletag skip: "set RUN_LIVE_WHATSAPP_TESTS=true to run live WhatsApp tests"
  end

  if @run_live and
       Enum.any?(~w(WHATSAPP_PROFILE WHATSAPP_TEST_JID), &(System.get_env(&1) in [nil, ""])) do
    raise "live WhatsApp tests require WHATSAPP_PROFILE and WHATSAPP_TEST_JID"
  end

  test "sends, edits, and deletes one live WhatsApp message" do
    profile = System.fetch_env!("WHATSAPP_PROFILE")
    room = System.fetch_env!("WHATSAPP_TEST_JID")

    client =
      Jido.Chat.Client.new!(Jido.Chat.WhatsApp.Adapter,
        id: "whatsapp-live",
        config: [profile: profile]
      )

    text = "jido whatsapp live #{System.system_time(:millisecond)}"
    assert {:ok, sent} = Jido.Chat.send_text(client, room, text)
    id = sent.data["result"]["id"]
    assert {:ok, _} = Jido.Chat.edit_message(client, room, id, text <> " edited")
    assert {:ok, _} = Jido.Chat.delete_message(client, room, id)
  end
end
