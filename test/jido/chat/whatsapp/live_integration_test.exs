defmodule Jido.Chat.WhatsApp.LiveIntegrationTest do
  use ExUnit.Case, async: false

  alias Jido.Chat.WhatsApp.Adapter
  alias Jido.Chat.WhatsApp.Message

  @default_open_timeout_ms 30_000
  @default_reply_timeout_ms 180_000

  setup do
    profile = fetch_env!("WHATSAPP_PROFILE")
    jid = fetch_env!("WHATSAPP_TEST_JID")

    {:ok, _conn, started?} = start_connection!(profile)

    on_exit(fn ->
      if started?, do: Amarula.stop(profile)
    end)

    assert_open!(profile)

    {:ok, profile: profile, jid: jid}
  end

  @tag :live
  test "send text through a paired Amarula profile", %{profile: profile, jid: jid} do
    text = "jido_chat_whatsapp live smoke #{timestamp()}"

    assert {:ok, response} =
             Adapter.send_message(jid, text, profile: profile)

    assert response.external_message_id
    assert response.external_room_id == jid
    assert response.status == :sent
  end

  @tag :live_receive
  test "receives a reply from WhatsApp", %{profile: profile, jid: jid} do
    text = "jido_chat_whatsapp reply test #{timestamp()} - please reply to this message"

    assert {:ok, response} = Adapter.send_message(jid, text, profile: profile)
    assert response.external_message_id

    assert {:ok, msg} = receive_incoming_reply(reply_timeout_ms())
    assert {:ok, incoming} = Adapter.transform_incoming(msg)

    assert incoming.external_message_id == msg.id
    assert incoming.external_room_id == Message.address_to_jid(msg.channel)
    assert incoming.metadata.from_me == false
  end

  defp start_connection!(profile) do
    case Amarula.new(amarula_config(profile)) |> Amarula.connect(parent: self()) do
      {:ok, conn} ->
        {:ok, conn, true}

      {:error, {:already_running, conn}} ->
        :ok = Amarula.set_parent(conn, self())
        {:ok, conn, false}

      {:error, reason} ->
        flunk("failed to start WhatsApp profile #{inspect(profile)}: #{inspect(reason)}")
    end
  end

  defp amarula_config(profile) do
    %{profile: profile}
    |> maybe_put_storage()
    |> maybe_put_bool(:sync_full_history, "WHATSAPP_SYNC_FULL_HISTORY")
    |> maybe_put_bool(:mark_online_on_connect, "WHATSAPP_MARK_ONLINE_ON_CONNECT")
    |> maybe_put_integer(:max_retries, "WHATSAPP_MAX_RETRIES")
    |> maybe_put_integer(:keep_alive_interval_ms, "WHATSAPP_KEEP_ALIVE_INTERVAL_MS")
  end

  defp maybe_put_storage(config) do
    case System.get_env("WHATSAPP_STORAGE_ROOT") do
      nil -> config
      "" -> config
      root -> Map.put(config, :storage, {Amarula.Storage.File, root: root})
    end
  end

  defp maybe_put_bool(config, key, env_name) do
    case System.get_env(env_name) do
      nil -> config
      "" -> config
      value -> Map.put(config, key, value in ["1", "true", "TRUE", "yes", "YES"])
    end
  end

  defp maybe_put_integer(config, key, env_name) do
    case System.get_env(env_name) do
      nil ->
        config

      "" ->
        config

      value ->
        case Integer.parse(value) do
          {integer, ""} -> Map.put(config, key, integer)
          _invalid -> config
        end
    end
  end

  defp assert_open!(profile) do
    case wait_for_open(open_timeout_ms(), []) do
      :ok ->
        :ok

      {:error, events} ->
        flunk("""
        WhatsApp profile #{inspect(profile)} did not open before the timeout.
        Last events:

        #{inspect(events, pretty: true)}
        """)
    end
  end

  defp wait_for_open(timeout_ms, events) do
    receive_until(timeout_ms, events, fn
      {:amarula, :connection_update, %{connection: :open}}, _events ->
        {:halt, :ok}

      event, events ->
        {:cont, [summarize_event(event) | events]}
    end)
  end

  defp receive_incoming_reply(timeout_ms) do
    receive_until(timeout_ms, [], fn
      {:amarula, :messages_upsert, %{messages: messages}}, events ->
        case Enum.find(messages, &incoming_reply?/1) do
          nil -> {:cont, [{:messages_upsert, length(messages)} | events]}
          msg -> {:halt, {:ok, msg}}
        end

      event, events ->
        {:cont, [summarize_event(event) | events]}
    end)
  end

  defp receive_until(timeout_ms, events, reducer) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_receive_until(deadline, events, reducer)
  end

  defp do_receive_until(deadline, events, reducer) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, Enum.reverse(Enum.take(events, 12))}
    else
      receive do
        event ->
          case reducer.(event, events) do
            {:halt, result} -> result
            {:cont, events} -> do_receive_until(deadline, events, reducer)
          end
      after
        min(remaining, 1_000) ->
          do_receive_until(deadline, events, reducer)
      end
    end
  end

  defp incoming_reply?(%Amarula.Msg{from_me: false, type: type}) when type in [:text, "text"], do: true
  defp incoming_reply?(%Amarula.Msg{from_me: false}), do: true
  defp incoming_reply?(_msg), do: false

  defp summarize_event({:amarula, event, data}), do: {event, summarize_data(data)}
  defp summarize_event(event), do: event

  defp summarize_data(%{connection: _connection} = data), do: Map.take(data, [:connection, :qr])
  defp summarize_data(%{message_ids: message_ids, status: status}), do: %{message_ids: message_ids, status: status}
  defp summarize_data(%{messages: messages}) when is_list(messages), do: %{messages: length(messages)}
  defp summarize_data(data) when is_map(data), do: %{keys: Map.keys(data)}
  defp summarize_data(reason) when is_atom(reason) or is_binary(reason), do: reason
  defp summarize_data(reason), do: inspect(reason)

  defp fetch_env!(name) do
    case System.fetch_env(name) do
      {:ok, value} when value != "" -> value
      _missing -> raise "missing required live test env var #{name}"
    end
  end

  defp open_timeout_ms, do: env_integer("WHATSAPP_OPEN_TIMEOUT_MS", @default_open_timeout_ms)
  defp reply_timeout_ms, do: env_integer("WHATSAPP_REPLY_TIMEOUT_MS", @default_reply_timeout_ms)

  defp env_integer(name, default) do
    case System.get_env(name) do
      nil ->
        default

      "" ->
        default

      value ->
        case Integer.parse(value) do
          {int, ""} -> int
          _invalid -> default
        end
    end
  end

  defp timestamp do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end
end
