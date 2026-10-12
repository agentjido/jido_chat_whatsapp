defmodule Jido.Chat.WhatsApp.TransportIdentityTest do
  use ExUnit.Case, async: true

  alias Jido.Chat.WhatsApp.Transport.AmarulaClient

  # Simulated external protocol endpoint; exercise the real transport boundary.
  defmodule Protocol do
    use GenServer
    def start_link(state), do: GenServer.start_link(__MODULE__, state)
    def init(state), do: {:ok, state}

    def handle_call(:get_connection_state, _from, state),
      do: {:reply, Map.get(state, :connection, :connected), state}

    def handle_call(:get_auth_creds, _from, %{blocked: true} = state), do: {:noreply, state}
    def handle_call(:get_auth_creds, _from, state), do: {:reply, state.creds, state}
  end

  defp protocol(state), do: start_supervised!(%{id: make_ref(), start: {Protocol, :start_link, [state]}})

  test "authenticated PN and LID normalize through the real boundary with only public fields" do
    conn =
      protocol(%{
        creds: %{
          me: %{id: "123:8@s.whatsapp.net", lid: "opaque:3@lid", name: " Alice ", token: "secret"},
          keys: "secret"
        }
      })

    assert {:ok, identity} = AmarulaClient.account_identity(conn)

    assert identity == %{
             phone_number: "+123",
             display_name: "Alice",
             account_jids: ["123@s.whatsapp.net", "opaque@lid"]
           }

    assert {:ok, identity.account_jids} == AmarulaClient.account_jids(conn)
    refute inspect(identity) =~ "secret"
  end

  test "LID-only identity has no phone and unknown names remain nil" do
    for name <- [nil, "", " ", "~", " ~ "] do
      conn = protocol(%{creds: %{me: %{lid: "123456:7@lid", name: name}}})

      assert {:ok, %{phone_number: nil, display_name: nil, account_jids: ["123456@lid"]}} =
               AmarulaClient.account_identity(conn)
    end
  end

  test "not authenticated, absent or malformed credentials and stopped connections are unavailable" do
    for state <- [
          %{connection: :disconnected, creds: %{me: %{id: "123@s.whatsapp.net"}}},
          %{creds: %{}},
          %{creds: %{me: nil}},
          %{creds: %{me: "secret"}},
          %{creds: "secret"}
        ] do
      assert {:error, :unavailable} = state |> protocol() |> AmarulaClient.account_identity()
    end

    conn = protocol(%{creds: %{}})
    GenServer.stop(conn)
    assert {:error, :unavailable} = AmarulaClient.account_identity(conn)
  end

  test "credential reads are bounded and expose only a fixed timeout category" do
    conn = protocol(%{blocked: true})
    assert {:error, :timeout} = AmarulaClient.account_identity(conn)
  end
end
