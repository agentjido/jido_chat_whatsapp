defmodule Jido.Chat.WhatsApp.TemporaryStorageTest do
  use ExUnit.Case, async: true
  alias Jido.Chat.WhatsApp.Storage.Temporary

  test "freezes an isolated snapshot and never accepts later writes" do
    pid = start_supervised!({Temporary, profile: "one", max_bytes: 200})
    assert :ok = Temporary.put(pid, "one", :creds, :self, %{secret: "value"})
    assert {:error, :invalid_profile} = Temporary.get(pid, "two", :creds, :self)
    assert %{{"creds", :self} => %{secret: "value"}} = Temporary.freeze(pid)
    assert {:error, :storage_frozen} = Temporary.put(pid, "one", :creds, :self, "late")
    assert :ok = Temporary.discard(pid)
    assert %{} = Temporary.freeze(pid)
    refute inspect(:sys.get_status(pid)) =~ "value"
  end

  test "rejected writes leave the previous record intact" do
    pid = start_supervised!({Temporary, profile: "one", max_bytes: 100})
    assert :ok = Temporary.put(pid, "one", :session, "key", "small")
    assert {:error, :storage_full} = Temporary.put(pid, "one", :session, "key", String.duplicate("x", 200))
    assert {:ok, "small"} = Temporary.get(pid, "one", :session, "key")
  end
end
