defmodule Jido.Chat.WhatsApp.NormalizationContractTest do
  use ExUnit.Case, async: true
  alias Jido.Chat.WhatsApp.Adapter

  test "self and mentions use supplied aliases while replies identify their thread" do
    payload = %{
      id: "m",
      channel_jid: "group@g.us",
      from_jid: "123:4@s.whatsapp.net",
      from_me: true,
      type: :text,
      text: "hello",
      account_jids: ["123@s.whatsapp.net", "456@lid"],
      mentions: ["456:2@lid", "999@s.whatsapp.net"],
      quoted: %{id: "q", from_jid: "123@s.whatsapp.net", text: "previous"}
    }

    assert {:ok, incoming} = Adapter.transform_incoming(payload)
    assert incoming.author.is_me
    assert incoming.was_mentioned
    assert [own, other] = incoming.mentions
    assert own.is_self
    refute other.is_self
    assert incoming.external_thread_id == "q"
    assert incoming.channel_meta.external_thread_id == "q"
    assert incoming.reply_context == nil
    assert incoming.external_reply_to_id == nil
    assert incoming.chat_type == :group
    refute incoming.channel_meta.is_dm

    assert {:ok, isolated} = Adapter.transform_incoming(%{payload | account_jids: ["999@lid"]})
    refute isolated.was_mentioned
  end

  test "recipient alone is not account identity and missing recipient is safe" do
    for recipient <- [nil, "456@lid"] do
      assert {:ok, incoming} =
               Adapter.transform_incoming(%{
                 channel_jid: "123@lid",
                 from_jid: "123@lid",
                 to_jid: recipient,
                 mentions: ["456@lid"],
                 text: "hi"
               })

      refute incoming.was_mentioned
      assert incoming.channel_meta.is_dm
      refute incoming.author.is_me
    end
  end

  test "broadcasts and newsletters are not DMs" do
    for room <- ["status@broadcast", "123@newsletter", "unknown"] do
      assert {:error, :unsupported_chat_type} = Adapter.transform_incoming(%{channel_jid: room})
    end
  end
end
