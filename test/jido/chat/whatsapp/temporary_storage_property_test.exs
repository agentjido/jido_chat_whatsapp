defmodule Jido.Chat.WhatsApp.TemporaryStoragePropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias Jido.Chat.WhatsApp.Storage.Temporary, as: Storage

  test "snapshot rejects late writes and preserves the exact handoff" do
    pid = start_supervised!({Storage, profile: "one"})
    :ok = Storage.put(pid, "one", :creds, :self, "before")
    snapshot = Storage.freeze(pid)
    assert snapshot == %{{"creds", :self} => "before"}
    assert {:error, :storage_frozen} = Storage.put(pid, "one", :creds, :self, "late")
    assert {:error, :storage_frozen} = Storage.delete(pid, "one", :creds, :self)
    assert {:error, :storage_frozen} = Storage.clear(pid, "one")
    assert Storage.freeze(pid) == snapshot
    :ok = Storage.discard(pid)
    assert Storage.freeze(pid) == %{}
  end

  property "records never cross profiles or namespaces" do
    check all(value <- binary(max_length: 1000), key <- string(:alphanumeric)) do
      {:ok, pid} = Storage.start_link(profile: "one")
      assert :ok = Storage.put(pid, "one", :creds, key, value)
      assert {:ok, ^value} = Storage.get(pid, "one", :creds, key)
      assert :error = Storage.get(pid, "one", :keys, key)
      assert {:error, :invalid_profile} = Storage.get(pid, "two", :creds, key)
      assert {:error, :invalid_profile} = Storage.clear(pid, "two")
      assert {:ok, ^value} = Storage.get(pid, "one", :creds, key)
      GenServer.stop(pid)
    end
  end
end
