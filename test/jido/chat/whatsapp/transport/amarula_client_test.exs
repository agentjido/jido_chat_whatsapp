defmodule Jido.Chat.WhatsApp.Transport.AmarulaClientTest do
  use ExUnit.Case, async: false

  alias Jido.Chat.WhatsApp.Transport.AmarulaClient

  test "resolve_conn/1 handles explicit connections and missing profiles" do
    pid = self()

    assert {:ok, ^pid} = AmarulaClient.resolve_conn(conn: pid)
    assert {:ok, ^pid} = AmarulaClient.resolve_conn(connection: pid)
    assert {:error, :missing_profile} = AmarulaClient.resolve_conn([])

    assert {:error, :connection_not_running} =
             AmarulaClient.resolve_conn(profile: :"missing_#{System.unique_integer()}")
  end

  test "default transport can send through Amarula offline sandbox" do
    profile = :"jido_chat_whatsapp_transport_#{System.unique_integer([:positive])}"
    {:ok, conn} = Amarula.Testing.start_offline(profile: profile, parent_pid: self(), frame_sink: self())

    on_exit(fn -> Amarula.stop(conn) end)

    assert {:ok, _via} = AmarulaClient.resolve_conn(profile: profile)
    assert {:ok, text_id} = AmarulaClient.send_text(conn, "15551234567@s.whatsapp.net", "hello", [])
    assert is_binary(text_id)

    assert {:ok, reaction_id} =
             AmarulaClient.send_reaction(conn, {"15551234567@s.whatsapp.net", "target-1"}, "ok")

    assert is_binary(reaction_id)

    assert {:ok, edit_id} = AmarulaClient.send_edit(conn, {"15551234567@s.whatsapp.net", "target-1"}, "fixed")
    assert is_binary(edit_id)

    assert {:ok, revoke_id} = AmarulaClient.send_revoke(conn, {"15551234567@s.whatsapp.net", "target-1"})
    assert is_binary(revoke_id)

    assert :ok = AmarulaClient.send_chatstate(conn, "15551234567@s.whatsapp.net", :paused)
    assert {:error, _reason} = AmarulaClient.send_media(conn, "15551234567@s.whatsapp.net", :image, "bytes", [])
  end
end
