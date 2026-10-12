defmodule Jido.Chat.WhatsApp.UserProfileTest do
  use ExUnit.Case, async: false

  alias Amarula.Protocol.Signal.LidMappingFileStore
  alias Jido.Chat.{Adapter, UserInfo}
  alias Jido.Chat.WhatsApp.Adapter, as: WhatsApp

  setup do
    start_supervised!(Amarula.Supervisor)
    {:ok, first} = Amarula.Testing.start_offline(profile: "profile_first")
    {:ok, second} = Amarula.Testing.start_offline(profile: "profile_second")

    %{first: first, second: second}
  end

  test "get_user exposes a phone-number JID as profile data through Jido's public callback", %{first: conn} do
    assert {:ok, %UserInfo{id: "15551234567:4@s.whatsapp.net", metadata: %{phone: "+15551234567"}}} =
             Adapter.get_user(WhatsApp, "15551234567:4@s.whatsapp.net", conn: conn)
  end

  test "LIDs use only the selected connection's mapping and never become phone numbers", %{first: first, second: second} do
    lid = "1234567890@lid"
    assert {:ok, %{metadata: %{phone: nil}}} = WhatsApp.get_user(lid, conn: first)

    assert {1, _} =
             LidMappingFileStore.store_mappings(Amarula.Connection.get_conn(first), [
               {lid, "15551234567@s.whatsapp.net"}
             ])

    assert {:ok, %{metadata: %{phone: "+15551234567"}}} = WhatsApp.get_user(lid, conn: first)
    assert {:ok, %{metadata: %{phone: nil}}} = WhatsApp.get_user(lid, conn: second)
  end

  test "a missing connection reports an error without selecting another account" do
    assert {:error, :connection_not_running} = WhatsApp.get_user("1234567890@lid", profile: "missing_profile")
  end
end
