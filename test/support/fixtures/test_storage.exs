defmodule Jido.Chat.WhatsApp.TestStorage do
  @moduledoc false
  def new(opts), do: Keyword.fetch!(opts, :table)

  def get(table, profile, namespace, key) do
    if :ets.member(table, :fail_second_read) and :ets.update_counter(table, :reads, 1, {:reads, 0}) > 1,
      do: raise("private read failure")

    case :ets.lookup(table, {profile, namespace, key}) do
      [{_, value}] -> value
      [] -> :error
    end
  end

  def put(table, profile, namespace, key, value) do
    if :ets.member(table, :fail_write) do
      {:error, "private details"}
    else
      :ets.insert(table, {{profile, namespace, key}, {:ok, value}})
      :ok
    end
  end

  def delete(table, profile, namespace, key) do
    :ets.delete(table, {profile, namespace, key})
    :ok
  end

  def clear(table, profile) do
    if :ets.member(table, :fail_clear), do: throw(:failure)
    :ets.match_delete(table, {{profile, :_, :_}, :_})
    :ok
  end

  def list_keys(_, _, _), do: {:ok, []}
  def list_profiles(_), do: {:ok, []}
end
