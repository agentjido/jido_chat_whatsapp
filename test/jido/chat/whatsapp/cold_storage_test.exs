defmodule Jido.Chat.WhatsApp.ColdStorageTest do
  use ExUnit.Case, async: true

  alias Amarula.Protocol.Auth.AuthUtils
  alias Amarula.Protocol.Signal.Group.{SenderKeyRecord, SenderKeyState}
  alias Amarula.Protocol.Signal.SessionRecord

  test "a fresh VM can safely restore protocol records at the first storage read" do
    sender_state = SenderKeyState.new(1, 0, <<0::256>>, %{public: <<1::256>>, private: nil})

    records = [
      AuthUtils.init_auth_creds(),
      SessionRecord.new(),
      SenderKeyRecord.add_sender_key_state(SenderKeyRecord.new(), sender_state)
    ]

    for record <- records do
      assert {output, 0} = probe(:erlang.term_to_binary(record))
      assert output =~ "storage_read=ok"
    end
  end

  test "initialization does not allow unknown persisted atoms" do
    name = "untrusted_persisted_atom_#{System.unique_integer([:positive])}"
    bytes = <<131, 119, byte_size(name), name::binary>>

    assert {output, 0} = probe(bytes)
    assert output =~ "storage_read=invalid"
  end

  defp probe(bytes) do
    script = ~S"""
    defmodule ColdStorage do
      def new(opts), do: Keyword.fetch!(opts, :bytes)

      def get(bytes, _, _, _) do
        result =
          try do
            :erlang.binary_to_term(bytes, [:safe])
            :ok
          rescue
            ArgumentError -> :invalid
          end

        IO.puts("storage_read=#{result}")
        throw(:stop_before_network)
      end
    end

    [encoded] = System.argv()
    {:ok, _apps} = Application.ensure_all_started(:jido_chat_whatsapp)
    config = %{profile: "cold_storage_test", storage: {ColdStorage, bytes: Base.decode64!(encoded)}}
    {:error, :connection_failed} = Jido.Chat.WhatsApp.Transport.AmarulaClient.connect(config, [])
    """

    paths = Enum.flat_map(:code.get_path(), &["-pa", List.to_string(&1)])

    System.cmd(System.find_executable("elixir"), paths ++ ["-e", script, Base.encode64(bytes)],
      stderr_to_stdout: true,
      env: [{"ERL_FLAGS", "+S 2:2"}]
    )
  end
end
