defmodule Jido.Chat.WhatsApp.LiveIntegrationTest do
  use ExUnit.Case, async: false

  alias Jido.Chat.WhatsApp.Adapter

  @moduletag :live

  test "send text through an already paired Amarula profile" do
    profile = System.fetch_env!("WHATSAPP_PROFILE")
    jid = System.fetch_env!("WHATSAPP_TEST_JID")

    assert {:ok, response} =
             Adapter.send_message(jid, "jido_chat_whatsapp live test", profile: profile)

    assert response.external_message_id
  end
end
