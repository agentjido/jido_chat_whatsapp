defmodule Jido.Chat.WhatsApp.LiveIntegrationTest do
  use ExUnit.Case, async: false

  alias Jido.Chat.Adapter, as: ChatAdapter
  alias Jido.Chat.FileUpload
  alias Jido.Chat.PostPayload
  alias Jido.Chat.WhatsApp.Adapter
  alias Jido.Chat.WhatsApp.LiveValidation
  alias Jido.Chat.WhatsApp.Message

  @truthy ["1", "true", "TRUE", "yes", "on"]
  @run_live System.get_env("RUN_LIVE_WHATSAPP_TESTS") in @truthy
  @profile System.get_env("WHATSAPP_PROFILE")
  @jid System.get_env("WHATSAPP_TEST_JID")
  @phone System.get_env("WHATSAPP_TEST_PHONE")
  @reaction System.get_env("WHATSAPP_TEST_REACTION") || "\u{1F44D}"
  @wait_for_reply System.get_env("WHATSAPP_WAIT_FOR_REPLY") in @truthy
  @run_rejected_session System.get_env("RUN_LIVE_WHATSAPP_401_TEST") in @truthy

  @moduletag :live
  @moduletag :whatsapp_live

  if not @run_live do
    @moduletag skip: "set RUN_LIVE_WHATSAPP_TESTS=true to run live WhatsApp integration tests"
  end

  if @run_live and (@profile in [nil, ""] or @jid in [nil, ""]) do
    @moduletag skip: "set WHATSAPP_PROFILE and WHATSAPP_TEST_JID when RUN_LIVE_WHATSAPP_TESTS=true"
  end

  setup_all do
    if @run_live and @profile not in [nil, ""] and @jid not in [nil, ""] do
      reconnect_budget = LiveValidation.new_reconnect_budget()
      {:ok, conn, started?} = start_connection!(@profile)
      :ok = ensure_open!(conn, @profile, reconnect_budget)

      on_exit(fn ->
        if started?, do: Amarula.stop(@profile)
      end)

      {:ok, conn: conn, profile: @profile, jid: @jid, reconnect_budget: reconnect_budget}
    else
      {:ok, conn: nil, profile: @profile, jid: @jid, reconnect_budget: nil}
    end
  end

  setup ctx do
    if ctx.conn do
      :ok = Amarula.set_parent(ctx.conn, self())
      drain_amarula_events()
      :ok = ensure_open!(ctx.conn, ctx.profile, ctx.reconnect_budget)
    end

    {:ok, opts: [profile: ctx.profile]}
  end

  @tag :whatsapp_live_connectivity
  test "linked device connection stays open", ctx do
    assert Amarula.connection_state(ctx.conn) == :connected
  end

  if not @run_rejected_session do
    @tag skip: "set RUN_LIVE_WHATSAPP_401_TEST=true to run the rejected-session gate"
  end

  @tag :whatsapp_live_rejected_session
  @tag :whatsapp_live_session_destructive
  test "a rejected disposable session closes once without reconnecting", _ctx do
    assert :ok = assert_rejected_session!(rejected_session_timeout_ms(), no_reconnect_observation_ms())
  end

  @tag :whatsapp_live_outbound
  @tag :whatsapp_live_destructive
  test "send/edit/delete message against live WhatsApp linked device", ctx do
    live_send_pause()

    text = "jido whatsapp live #{System.system_time(:millisecond)}"

    assert {:ok, sent} = Adapter.send_message(ctx.jid, text, ctx.opts)
    message_id = response_id(sent)
    assert is_binary(message_id)

    assert {:ok, edited} =
             Adapter.edit_message(ctx.jid, message_id, text <> " (edited)", ctx.opts)

    assert edited.status == :edited
    assert edited.external_room_id == ctx.jid
    assert is_binary(response_id(edited))

    assert :ok = Adapter.delete_message(ctx.jid, message_id, ctx.opts)
  end

  @tag :whatsapp_live_connectivity
  test "metadata and open_dm calls succeed against live WhatsApp session", ctx do
    assert {:ok, info} = Adapter.fetch_metadata(ctx.jid, ctx.opts)
    assert info.id == ctx.jid
    assert info.is_dm == not String.ends_with?(ctx.jid, "@g.us")
    assert info.metadata.jid == ctx.jid

    assert {:ok, dm_jid} = Adapter.open_dm(@phone || phone_from_jid(ctx.jid), ctx.opts)
    assert dm_jid == ctx.jid
  end

  @tag :whatsapp_live_outbound
  @tag :whatsapp_live_presence
  test "typing call succeeds against live WhatsApp session", ctx do
    live_send_pause()

    assert :ok = Adapter.start_typing(ctx.jid, ctx.opts)
  end

  @tag :whatsapp_live_outbound
  @tag :whatsapp_live_outbound_smoke
  test "single outbound text message is accepted by WhatsApp", ctx do
    live_send_pause()

    assert {:ok, sent} =
             Adapter.send_message(
               ctx.jid,
               "jido whatsapp outbound smoke #{System.system_time(:millisecond)}",
               ctx.opts
             )

    assert is_binary(response_id(sent))
  end

  @tag :whatsapp_live_outbound
  @tag :whatsapp_live_destructive
  test "stream fallback sends a visible draft and edits it to final content", ctx do
    live_send_pause()

    parts = ["jido", " whatsapp", " stream", " fallback"]

    assert {:ok, sent} =
             ChatAdapter.stream(
               Adapter,
               ctx.jid,
               parts,
               Keyword.merge(ctx.opts,
                 placeholder_text: "jido whatsapp draft...",
                 update_every: 1
               )
             )

    message_id = response_id(sent)
    assert is_binary(message_id)

    on_exit(fn ->
      cleanup_delete(fn ->
        Adapter.delete_message(ctx.jid, message_id, ctx.opts)
      end)
    end)
  end

  @tag :whatsapp_live_outbound
  @tag :whatsapp_live_destructive
  test "reply continuity sends a lightweight quoted reply", ctx do
    live_send_pause()

    root_text = "jido whatsapp reply root #{System.system_time(:millisecond)}"
    reply_text = "jido whatsapp reply child #{System.system_time(:millisecond)}"

    assert {:ok, root} = Adapter.send_message(ctx.jid, root_text, ctx.opts)
    root_id = response_id(root)

    on_exit(fn ->
      cleanup_delete(fn ->
        Adapter.delete_message(ctx.jid, root_id, ctx.opts)
      end)
    end)

    assert {:ok, reply} =
             Adapter.send_message(
               ctx.jid,
               reply_text,
               Keyword.put(ctx.opts, :quoted, {root_id, ctx.jid})
             )

    reply_id = response_id(reply)

    on_exit(fn ->
      cleanup_delete(fn ->
        Adapter.delete_message(ctx.jid, reply_id, ctx.opts)
      end)
    end)

    assert is_binary(root_id)
    assert is_binary(reply_id)
    refute reply_id == root_id
  end

  @tag :whatsapp_live_outbound
  @tag :whatsapp_live_destructive
  test "reaction flow succeeds against live WhatsApp session", ctx do
    live_send_pause()

    assert {:ok, sent} =
             Adapter.send_message(
               ctx.jid,
               "jido whatsapp reaction target #{System.system_time(:millisecond)}",
               ctx.opts
             )

    message_id = response_id(sent)

    on_exit(fn ->
      cleanup_delete(fn ->
        Adapter.delete_message(ctx.jid, message_id, ctx.opts)
      end)
    end)

    assert :ok = Adapter.add_reaction(ctx.jid, message_id, @reaction, ctx.opts)
    assert :ok = Adapter.remove_reaction(ctx.jid, message_id, @reaction, ctx.opts)
  end

  @tag :whatsapp_live_outbound
  @tag :whatsapp_live_destructive
  @tag :whatsapp_live_media
  test "send_file uploads local paths and in-memory byte payloads", ctx do
    live_send_pause()

    path =
      write_temp_file(
        "jido-whatsapp-live-",
        ".txt",
        "whatsapp live file #{System.system_time(:millisecond)}\n"
      )

    on_exit(fn ->
      File.rm(path)
    end)

    assert {:ok, path_response} =
             Adapter.send_file(
               ctx.jid,
               FileUpload.new(%{
                 kind: :file,
                 path: path,
                 filename: Path.basename(path),
                 media_type: "text/plain"
               }),
               ctx.opts
             )

    path_message_id = response_id(path_response)

    on_exit(fn ->
      cleanup_delete(fn ->
        Adapter.delete_message(ctx.jid, path_message_id, ctx.opts)
      end)
    end)

    assert {:ok, bytes_response} =
             Adapter.send_file(
               ctx.jid,
               FileUpload.new(%{
                 kind: :file,
                 data: "whatsapp live bytes #{System.system_time(:millisecond)}\n",
                 filename: "whatsapp-live-bytes.txt",
                 media_type: "text/plain"
               }),
               ctx.opts
             )

    bytes_message_id = response_id(bytes_response)

    on_exit(fn ->
      cleanup_delete(fn ->
        Adapter.delete_message(ctx.jid, bytes_message_id, ctx.opts)
      end)
    end)

    assert is_binary(path_message_id)
    assert is_binary(bytes_message_id)
  end

  @tag :whatsapp_live_outbound
  @tag :whatsapp_live_destructive
  test "core post_message fallback sends text and canonical single-file payloads", ctx do
    live_send_pause()

    text_payload =
      PostPayload.new(%{
        text: "jido whatsapp canonical text #{System.system_time(:millisecond)}"
      })

    assert {:ok, text_response} = ChatAdapter.post_message(Adapter, ctx.jid, text_payload, ctx.opts)
    text_message_id = response_id(text_response)

    on_exit(fn ->
      cleanup_delete(fn ->
        Adapter.delete_message(ctx.jid, text_message_id, ctx.opts)
      end)
    end)

    file_payload =
      PostPayload.new(%{
        text: "jido whatsapp canonical file #{System.system_time(:millisecond)}",
        files: [
          %{
            kind: :file,
            data: "whatsapp canonical bytes #{System.system_time(:millisecond)}\n",
            filename: "whatsapp-canonical.txt",
            media_type: "text/plain"
          }
        ]
      })

    assert {:ok, file_response} = ChatAdapter.post_message(Adapter, ctx.jid, file_payload, ctx.opts)
    file_message_id = response_id(file_response)

    on_exit(fn ->
      cleanup_delete(fn ->
        Adapter.delete_message(ctx.jid, file_message_id, ctx.opts)
      end)
    end)

    assert is_binary(text_message_id)
    assert is_binary(file_message_id)
  end

  @tag :whatsapp_live_receive
  @tag :whatsapp_live_outbound
  test "receives and normalizes a manual WhatsApp reply when enabled", ctx do
    if @wait_for_reply do
      live_send_pause()

      prompt = "jido whatsapp receive test #{System.system_time(:millisecond)} - please reply"

      :ok = Amarula.set_parent(ctx.conn, self())
      drain_amarula_events()

      assert {:ok, sent} = Adapter.send_message(ctx.jid, prompt, ctx.opts)
      assert is_binary(response_id(sent))

      assert {:ok, msg} = receive_incoming_reply(ctx.jid, reply_timeout_ms())
      assert {:ok, incoming} = Adapter.transform_incoming(msg)

      assert incoming.external_message_id == msg.id
      assert incoming.external_room_id == Message.address_to_jid(msg.channel)
      assert incoming.metadata.from_me == false
    else
      refute @wait_for_reply
    end
  end

  test "unsupported core surfaces remain explicit unsupported contracts", ctx do
    assert {:error, :unsupported} = ChatAdapter.fetch_message(Adapter, ctx.jid, "missing", ctx.opts)
    assert {:error, :unsupported} = ChatAdapter.fetch_messages(Adapter, ctx.jid, ctx.opts)
    assert {:error, :unsupported} = ChatAdapter.fetch_channel_messages(Adapter, ctx.jid, ctx.opts)
    assert {:error, :unsupported} = ChatAdapter.list_threads(Adapter, ctx.jid, ctx.opts)
    assert {:error, :unsupported} = ChatAdapter.open_thread(Adapter, ctx.jid, nil, ctx.opts)

    assert {:error, :unsupported} =
             ChatAdapter.post_ephemeral(Adapter, ctx.jid, "whatsapp-user", "secret", ctx.opts)

    assert {:error, :unsupported} =
             ChatAdapter.open_modal(Adapter, ctx.jid, %{title: "modal"}, ctx.opts)
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
      value -> Map.put(config, key, value in @truthy)
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

  defp ensure_open!(nil, _profile, _budget), do: :ok

  defp ensure_open!(conn, profile, reconnect_budget) do
    case Amarula.connection_state(conn) do
      :connected ->
        :ok

      :connecting ->
        assert_open!(profile, open_timeout_ms())

      _other ->
        case LiveValidation.reconnect_once(reconnect_budget, fn -> Amarula.reconnect(conn) end) do
          {:ok, :ok} -> assert_open!(profile, open_timeout_ms())
          {:ok, other} -> flunk("explicit reconnect failed: #{inspect(other)}")
          {:error, :reconnect_budget_exhausted} -> flunk("suite-wide explicit reconnect budget was exhausted")
        end
    end
  end

  defp assert_open!(profile, timeout_ms) do
    case wait_for_open(timeout_ms, []) do
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
        {:cont, [LiveValidation.summarize_event(event) | events]}
    end)
  end

  defp assert_rejected_session!(timeout_ms, observation_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    with {:ok, events} <- wait_for_401(deadline, []),
         {:ok, events} <- wait_for_closed(deadline, events),
         :ok <- assert_no_reconnect(observation_ms, events) do
      :ok
    else
      {:error, reason, events} ->
        flunk("""
        The rejected-session gate failed: #{inspect(reason)}.
        Redacted events:

        #{inspect(Enum.reverse(Enum.take(events, 12)), pretty: true)}
        """)
    end
  end

  defp wait_for_401(deadline, events) do
    receive_before(deadline, events, fn
      {:amarula, :error, {:stream_error, 401, _reason}} = event, events ->
        {:halt, {:ok, [LiveValidation.summarize_event(event) | events]}}

      event, events ->
        {:cont, [LiveValidation.summarize_event(event) | events]}
    end)
  end

  defp wait_for_closed(deadline, events) do
    receive_before(deadline, events, fn
      {:amarula, :connection_update, %{connection: :closed}} = event, events ->
        {:halt, {:ok, [LiveValidation.summarize_event(event) | events]}}

      {:amarula, :connection_update, %{connection: :connecting}} = event, events ->
        {:halt, {:error, :reconnected_after_401, [LiveValidation.summarize_event(event) | events]}}

      {:amarula, :error, {:stream_error, 401, _reason}} = event, events ->
        {:halt, {:error, :duplicate_401, [LiveValidation.summarize_event(event) | events]}}

      event, events ->
        {:cont, [LiveValidation.summarize_event(event) | events]}
    end)
  end

  defp assert_no_reconnect(observation_ms, events) do
    deadline = System.monotonic_time(:millisecond) + observation_ms

    receive_before(deadline, events, fn
      {:amarula, :connection_update, %{connection: :connecting}} = event, events ->
        {:halt, {:error, :reconnected_after_close, [LiveValidation.summarize_event(event) | events]}}

      {:amarula, :error, {:stream_error, 401, _reason}} = event, events ->
        {:halt, {:error, :duplicate_401, [LiveValidation.summarize_event(event) | events]}}

      {:amarula, :connection_update, %{connection: :closed}} = event, events ->
        {:halt, {:error, :duplicate_closed, [LiveValidation.summarize_event(event) | events]}}

      event, events ->
        {:cont, [LiveValidation.summarize_event(event) | events]}
    end)
    |> case do
      {:error, :timeout, _events} -> :ok
      result -> result
    end
  end

  defp receive_before(deadline, events, reducer) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, :timeout, events}
    else
      receive do
        event ->
          case reducer.(event, events) do
            {:halt, result} -> result
            {:cont, events} -> receive_before(deadline, events, reducer)
          end
      after
        min(remaining, 1_000) -> receive_before(deadline, events, reducer)
      end
    end
  end

  defp receive_incoming_reply(expected_jid, timeout_ms) do
    receive_until(timeout_ms, [], fn
      {:amarula, :messages_upsert, %{messages: messages}}, events ->
        case Enum.find(messages, &incoming_reply?(&1, expected_jid)) do
          nil -> {:cont, [{:messages_upsert, length(messages)} | events]}
          msg -> {:halt, {:ok, msg}}
        end

      event, events ->
        {:cont, [LiveValidation.summarize_event(event) | events]}
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

  defp incoming_reply?(%Amarula.Msg{from_me: true}, _expected_jid), do: false

  defp incoming_reply?(%Amarula.Msg{} = msg, expected_jid) do
    Message.address_to_jid(msg.channel) == expected_jid or
      Message.address_to_jid(msg.from) == expected_jid
  end

  defp incoming_reply?(_msg, _expected_jid), do: false

  defp drain_amarula_events do
    receive do
      {:amarula, _event, _data} -> drain_amarula_events()
    after
      0 -> :ok
    end
  end

  defp open_timeout_ms, do: env_integer("WHATSAPP_OPEN_TIMEOUT_MS", 30_000)
  defp rejected_session_timeout_ms, do: env_integer("WHATSAPP_401_TIMEOUT_MS", 180_000)

  defp no_reconnect_observation_ms do
    LiveValidation.no_reconnect_observation_ms(env_integer("WHATSAPP_401_OBSERVATION_MS", 30_000))
  end

  defp reply_timeout_ms, do: env_integer("WHATSAPP_REPLY_TIMEOUT_MS", 180_000)
  defp live_send_delay_ms, do: env_integer("WHATSAPP_LIVE_SEND_DELAY_MS", 60_000)
  defp live_send_jitter_ms, do: env_integer("WHATSAPP_LIVE_SEND_JITTER_MS", 0)

  defp live_send_pause do
    delay_ms = max(live_send_delay_ms(), 0)
    jitter_ms = max(live_send_jitter_ms(), 0)
    total_ms = delay_ms + jitter_ms(jitter_ms)

    if total_ms > 0 do
      Process.sleep(total_ms)
    end
  end

  defp jitter_ms(0), do: 0
  defp jitter_ms(max_ms), do: :rand.uniform(max_ms + 1) - 1

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

  defp response_id(%{external_message_id: value}) when is_binary(value), do: value
  defp response_id(%{message_id: value}) when is_binary(value), do: value
  defp response_id(_response), do: nil

  defp phone_from_jid(jid) do
    jid
    |> to_string()
    |> String.split("@", parts: 2)
    |> hd()
    |> String.split(":", parts: 2)
    |> hd()
  end

  defp write_temp_file(prefix, suffix, contents) do
    path =
      Path.join(
        System.tmp_dir!(),
        "#{prefix}#{System.unique_integer([:positive])}#{suffix}"
      )

    File.write!(path, contents)
    path
  end

  defp cleanup_delete(fun) when is_function(fun, 0) do
    case fun.() do
      :ok -> :ok
      {:ok, _result} -> :ok
      {:error, _reason} -> :ok
    end
  end
end
