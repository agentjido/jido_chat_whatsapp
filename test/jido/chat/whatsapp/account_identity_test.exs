defmodule Jido.Chat.WhatsApp.AccountIdentityTest do
  use ExUnit.Case, async: true

  alias Jido.Chat.WhatsApp.AccountIdentity

  test "allowlists identity and derives phone only from normalized PN" do
    assert {:ok, identity} =
             AccountIdentity.normalize(%{
               account_jids: ["15551234567:12@s.whatsapp.net", "opaque:3@lid", "opaque@lid"],
               display_name: "  Alice  ",
               phone_number: "invented",
               creds: %{secret: "sentinel"},
               qr: "secret"
             })

    assert identity == %{
             phone_number: "+15551234567",
             display_name: "Alice",
             account_jids: ["15551234567@s.whatsapp.net", "opaque@lid"]
           }

    assert {:ok, ^identity} = AccountIdentity.normalize(identity)
  end

  test "missing, blank and placeholder names remain unknown" do
    for name <- [nil, "", "  ", "~", " ~ ", %{}, 1] do
      assert {:ok, %{display_name: nil}} = AccountIdentity.normalize(%{account_jids: ["123@lid"], display_name: name})
    end

    assert {:ok, %{display_name: nil}} = AccountIdentity.normalize(%{account_jids: ["123@lid"]})
    assert {:error, :unavailable} = AccountIdentity.normalize(%{display_name: "Alice"})
  end

  test "generated PN/LID/device combinations preserve normalization properties" do
    for user <- ["1", "1234567890", "15551234567"], device <- 0..25 do
      pn = "#{user}:#{device}@s.whatsapp.net"
      lid = "#{user}:#{device}@lid"
      assert {:ok, identity} = AccountIdentity.normalize(%{account_jids: [pn, lid, pn]})
      assert identity.phone_number == "+#{user}"
      assert identity.account_jids == ["#{user}@s.whatsapp.net", "#{user}@lid"]
      assert {:ok, ^identity} = AccountIdentity.normalize(identity)
      assert {:ok, %{phone_number: nil}} = AccountIdentity.normalize(%{account_jids: [lid], phone_number: user})
    end
  end

  test "invalid or unrelated aliases never invent a phone identity" do
    for jid <- ["", "abc@s.whatsapp.net", "123@g.us", "status@broadcast", "123", "123:bad@s.whatsapp.net", nil] do
      assert {:error, :unavailable} = AccountIdentity.normalize(%{account_jids: [jid], phone_number: "+123"})
    end

    assert {:error, :unavailable} = AccountIdentity.normalize(:invalid)
  end
end
