defmodule Jido.Chat.WhatsApp.StorageEncodingTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Jido.Chat.WhatsApp.Storage.Split

  property "batch encoding preserves protocol keys and values in the durable format" do
    check all(records <- map_of(binary(max_length: 32), term(), max_length: 12)) do
      snapshot = Map.new(records, fn {key, value} -> {{:creds, key}, value} end)
      encoded = Split.encode_records(snapshot)

      decoded =
        Map.new(encoded, fn {{"creds", key}, value} ->
          {key |> Base.decode64!() |> :erlang.binary_to_term([:safe]),
           value |> Base.decode64!() |> :erlang.binary_to_term([:safe])}
        end)

      assert decoded === records
    end
  end
end
