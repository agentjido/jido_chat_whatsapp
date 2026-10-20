defmodule Jido.Chat.WhatsApp.Pairing.RequestTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Jido.Chat.WhatsApp.Pairing.Request

  test "private requests redact actor context and credentials from inspection" do
    context = %{actor: "private-actor"}
    request = %{op: :persist, credentials: "private-credentials"}
    assert {:ok, :saved} = Request.call({__MODULE__, :reply, [self(), {:ok, :saved}]}, context, request)
    assert_receive %Jido.Chat.Authentication.Request{context: ^context, request: ^request, id: id} = event
    assert is_reference(id)
    refute inspect(event) =~ "private"
  end

  property "both operations preserve success and sanitized error results" do
    check all(
            op <- member_of([:persist, :start]),
            result <- member_of([:ok, {:ok, %{receipt: %{id: 1}}}, {:error, :unauthorized}])
          ) do
      assert Request.call({__MODULE__, :reply, [self(), result]}, :actor, %{op: op}) == result
      assert_receive %Jido.Chat.Authentication.Request{request: %{op: ^op}}
    end
  end

  test "invalid requests and callback failures never expose host details" do
    assert {:error, :invalid_pairing_request} = Request.call(nil, nil, %{op: :persist})
    assert {:error, :invalid_pairing_request} = Request.call({__MODULE__, :crash, []}, nil, %{op: :unknown})
    assert {:error, :callback_failed} = Request.call({__MODULE__, :crash, []}, nil, %{op: :persist})

    for result <- [:error, {:error, "private"}, %{credentials: "private"}] do
      assert {:error, :callback_failed} =
               Request.call({__MODULE__, :reply, [self(), result]}, nil, %{op: :start})
    end
  end

  def reply(observer, result, event, _opts) do
    send(observer, event)
    result
  end

  def crash(_, _), do: raise("private host error")
end
