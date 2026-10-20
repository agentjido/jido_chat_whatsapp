defmodule Jido.Chat.WhatsApp.Storage.RequestTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Jido.Chat.WhatsApp.Storage.Request

  test "requests use a redacted private envelope and return the host's committed result" do
    binding = %{secret: "binding-secret"}
    request = %{op: :put, namespace: "creds", key: "secret-key", value: "secret-value"}
    assert :ok = Request.call({__MODULE__, :reply, [self(), :ok]}, binding, request)
    assert_receive %Jido.Chat.Storage.Request{binding: ^binding, request: ^request, version: 1, id: id} = event
    assert is_reference(id)
    refute inspect(event) =~ "secret"
  end

  property "absence and sanitized host results retain their meaning" do
    check all(result <- member_of([:error, :ok, {:ok, "record"}, {:error, :credential_revoked}])) do
      assert Request.call({__MODULE__, :reply, [self(), result]}, :binding, %{op: :get}) == result
      assert_receive %Jido.Chat.Storage.Request{}
    end
  end

  test "unknown operations, invalid sinks and callback failures fail closed" do
    assert {:error, :invalid_storage_request} = Request.call(nil, nil, %{op: :get})
    assert {:error, :invalid_storage_request} = Request.call({__MODULE__, :crash, []}, nil, %{op: :unknown})
    assert {:error, :storage_unavailable} = Request.call({__MODULE__, :crash, []}, nil, %{op: :get})

    assert {:error, :storage_unavailable} =
             Request.call({__MODULE__, :reply, [self(), {:error, "secret"}]}, nil, %{op: :get})
  end

  test "a blocked host callback times out without acknowledging a write" do
    caller = self()
    task = Task.async(fn -> Request.call({__MODULE__, :wait, [caller]}, :binding, %{op: :put}) end)
    assert_receive {:waiting, sink}
    monitor = Process.monitor(sink)
    assert {:error, :storage_unavailable} = Task.await(task, 8_000)
    assert_receive {:DOWN, ^monitor, :process, ^sink, :killed}
  end

  def wait(pid, _event, _opts) do
    send(pid, {:waiting, self()})

    receive do
      :release -> :ok
    end
  end

  def reply(pid, result, event, _opts) do
    send(pid, event)
    result
  end

  def crash(_event, _opts), do: raise("secret callback failure")
end
