defmodule Jido.Chat.WhatsApp.LiveIntegrationTest do
  use ExUnit.Case, async: false

  alias Jido.Chat.Client
  alias Jido.Chat.WhatsApp.{Adapter, Message}
  alias Jido.Chat.WhatsApp.Transport.AmarulaClient

  @truthy ["1", "true", "TRUE", "yes", "on"]
  @run_live System.get_env("RUN_LIVE_WHATSAPP_TESTS") in @truthy
  @profile System.get_env("WHATSAPP_PROFILE")
  @jid System.get_env("WHATSAPP_TEST_JID")
  @wait_for_reply System.get_env("WHATSAPP_WAIT_FOR_REPLY") in @truthy

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
      {:ok, conn, started?} = start_connection(@profile)
      :ok = wait_until_open(conn, env_integer("WHATSAPP_OPEN_TIMEOUT_MS", 30_000))

      on_exit(fn ->
        if started?, do: Amarula.stop(conn)
      end)

      client =
        Client.new!(Adapter,
          id: "whatsapp-live",
          config: [profile: @profile],
          transport: AmarulaClient
        )

      {:ok, client: client, conn: conn, jid: @jid}
    else
      {:ok, client: nil, conn: nil, jid: @jid}
    end
  end

  setup ctx do
    if ctx.conn do
      :ok = Amarula.set_parent(ctx.conn, self())
      drain_events()
    end

    {:ok, options: [options: [conn: ctx.conn]]}
  end

  @tag :whatsapp_live_outbound
  @tag :whatsapp_live_destructive
  test "V3 message operations use the selected linked device", ctx do
    text = "jido whatsapp live #{System.system_time(:millisecond)}"
    assert {:ok, sent} = Jido.Chat.send_text(ctx.client, ctx.jid, text, ctx.options)
    message_id = sent.data["result"]["id"]

    assert {:ok, edited} =
             Jido.Chat.edit_message(ctx.client, ctx.jid, message_id, text <> " edited", ctx.options)

    assert edited.data["result"]["status"] == "updated"
    assert {:ok, _} = Jido.Chat.delete_message(ctx.client, ctx.jid, message_id, ctx.options)
  end

  @tag :whatsapp_live_outbound
  test "V3 metadata, typing, and reaction operations use the selected linked device", ctx do
    assert {:ok, metadata} = Jido.Chat.fetch_metadata(ctx.client, ctx.jid)
    assert metadata.data["result"]["id"] == ctx.jid
    assert {:ok, _} = Jido.Chat.start_typing(ctx.client, ctx.jid, ctx.options)

    assert {:ok, sent} = Jido.Chat.send_text(ctx.client, ctx.jid, "reaction target", ctx.options)
    message_id = sent.data["result"]["id"]
    assert {:ok, _} = Jido.Chat.add_reaction(ctx.client, ctx.jid, message_id, "👍", ctx.options)
    assert {:ok, _} = Jido.Chat.remove_reaction(ctx.client, ctx.jid, message_id, "👍", ctx.options)
    assert {:ok, _} = Jido.Chat.delete_message(ctx.client, ctx.jid, message_id, ctx.options)
  end

  @tag :whatsapp_live_receive
  test "V3 normalization accepts a manual reply when enabled", ctx do
    if @wait_for_reply do
      prompt = "jido whatsapp receive #{System.system_time(:millisecond)} - please reply"
      assert {:ok, _} = Jido.Chat.send_text(ctx.client, ctx.jid, prompt, ctx.options)
      assert {:ok, message} = receive_reply(ctx.jid, env_integer("WHATSAPP_REPLY_TIMEOUT_MS", 180_000))
      assert {:ok, delivery} = Jido.Chat.normalize(ctx.client, message, conn: ctx.conn)
      assert [signal | _] = delivery.signals
      assert signal.type == "jido.chat.message.received"
      assert signal.data["room_id"] == ctx.jid
    else
      refute @wait_for_reply
    end
  end

  defp start_connection(profile) do
    case Amarula.new(%{profile: profile}) |> Amarula.connect(parent: self()) do
      {:ok, conn} -> {:ok, conn, true}
      {:error, {:already_running, conn}} -> {:ok, conn, false}
      {:error, reason} -> {:error, reason}
    end
  end

  defp wait_until_open(conn, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_until_open(conn, deadline)
  end

  defp do_wait_until_open(conn, deadline) do
    cond do
      Amarula.connection_state(conn) == :connected ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, :connection_timeout}

      true ->
        Process.sleep(100)
        do_wait_until_open(conn, deadline)
    end
  end

  defp receive_reply(jid, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_receive_reply(jid, deadline)
  end

  defp do_receive_reply(jid, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, :reply_timeout}
    else
      receive do
        {:amarula, :messages_upsert, %{messages: messages}} ->
          case Enum.find(messages, &incoming_reply?(&1, jid)) do
            nil -> do_receive_reply(jid, deadline)
            message -> {:ok, message}
          end

        _ ->
          do_receive_reply(jid, deadline)
      after
        min(remaining, 1_000) -> do_receive_reply(jid, deadline)
      end
    end
  end

  defp incoming_reply?(%Amarula.Msg{from_me: true}, _jid), do: false

  defp incoming_reply?(%Amarula.Msg{} = message, jid) do
    Message.address_to_jid(message.channel) == jid or Message.address_to_jid(message.from) == jid
  end

  defp incoming_reply?(_, _), do: false

  defp drain_events do
    receive do
      {:amarula, _, _} -> drain_events()
    after
      0 -> :ok
    end
  end

  defp env_integer(name, default) do
    case Integer.parse(System.get_env(name) || "") do
      {value, ""} -> value
      _ -> default
    end
  end
end
