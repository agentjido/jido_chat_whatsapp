defmodule Jido.Chat.WhatsApp.UserProfileTest do
  use Jido.Chat.WhatsApp.RuntimeCase, async: false

  alias Amarula.Protocol.Signal.LidMappingFileStore
  alias Jido.Chat.AdapterTestKit.Factories
  alias Jido.Chat.Client
  alias Jido.Chat.WhatsApp.{Adapter, Transport.AmarulaClient}

  setup do
    {:ok, first} = Amarula.Testing.start_offline(profile: "profile_first")
    {:ok, second} = Amarula.Testing.start_offline(profile: "profile_second")

    %{first: first, second: second}
  end

  test "get_user exposes a phone-number JID through the V3 operation", %{first: conn} do
    client = client("profile_first")

    assert {:ok, result} = get_user(client, "15551234567:4@s.whatsapp.net", conn)
    assert result.data["result"] == %{"id" => "15551234567:4@s.whatsapp.net", "username" => "+15551234567"}
  end

  test "LIDs use only the selected connection's mapping and never become phone numbers", %{first: first, second: second} do
    lid = "1234567890@lid"
    first_client = client("profile_first")
    second_client = client("profile_second")

    assert {:ok, initial} = get_user(first_client, lid, first)
    assert initial.data["result"] == %{"id" => lid}

    assert {1, _} =
             LidMappingFileStore.store_mappings(Amarula.Connection.get_conn(first), [
               {lid, "15551234567@s.whatsapp.net"}
             ])

    assert {:ok, mapped} = get_user(first_client, lid, first)
    assert mapped.data["result"] == %{"id" => lid, "username" => "+15551234567"}
    assert {:ok, isolated} = get_user(second_client, lid, second)
    assert isolated.data["result"] == %{"id" => lid}
  end

  test "a missing connection reports an error without selecting another account" do
    assert {:error, %Jido.Chat.Error{code: :provider_failure}} =
             get_user(client("missing_profile"), "1234567890@lid", nil, profile: "missing_profile")
  end

  defp client(profile) do
    Client.new!(Adapter,
      id: "user-#{profile}",
      config: [profile: profile],
      transport: AmarulaClient
    )
  end

  defp get_user(client, id, conn, options \\ []) do
    request = Factories.operation_request(client, :get_user, %{"user_id" => id})
    private = if is_nil(conn), do: options, else: Keyword.put(options, :conn, conn)
    Jido.Chat.execute(client, request, options: private)
  end
end
