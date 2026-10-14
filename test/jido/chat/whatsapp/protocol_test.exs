defmodule Jido.Chat.WhatsApp.ProtocolTest do
  use ExUnit.Case, async: true
  alias Jido.Chat.WhatsApp.{Adapter, ConnectionWorker}
  alias Jido.Chat.AdapterTestKit.Factories

  defmodule Transport do
    @behaviour Jido.Chat.WhatsApp.Transport
    @methods [
      connect: 2,
      resolve_conn: 1,
      send_text: 4,
      send_media: 5,
      download_media: 1,
      send_reaction: 3,
      send_edit: 3,
      send_revoke: 2,
      send_chatstate: 3,
      request_pairing_code: 3
    ]
    for {name, arity} <- @methods do
      args = Macro.generate_arguments(arity, __MODULE__)
      @impl true
      def unquote(name)(unquote_splicing(args)) do
        send(self(), {:provider, unquote(name)})
        if Process.get(:provider_failure), do: {:error, :timeout}, else: result(unquote(name))
      end
    end

    defp result(name) when name in [:connect, :resolve_conn], do: {:ok, self()}
    defp result(:download_media), do: {:ok, "private-bytes"}
    defp result(:send_chatstate), do: :ok
    defp result(:request_pairing_code), do: {:ok, "private-pairing-code"}
    defp result(_), do: {:ok, "m1"}
  end

  defmodule Sink do
    def emit(pid, mode, delivery, opts) do
      send(pid, {:sink, delivery, opts})

      case mode do
        :ok -> {:ok, :accepted}
        :error -> {:error, :rejected}
        :raise -> raise "private-token"
        :throw -> throw(:private_token)
        :exit -> exit(:private_token)
        :invalid -> :invalid
      end
    end
  end

  @matrix Path.join(Mix.Project.deps_paths()[:jido_chat], "docs/migration/adapter-matrix.json")
          |> File.read!()
          |> Jason.decode!()
  @row Enum.find(@matrix["adapters"], &(&1["package"] == "jido_chat_whatsapp"))
  @calls %{
    send_message: [:resolve_conn, :send_text],
    send_file: [:resolve_conn, :send_media],
    post_message: [:resolve_conn, :send_text],
    edit_message: [:resolve_conn, :send_edit],
    delete_message: [:resolve_conn, :send_revoke],
    start_typing: [:resolve_conn, :send_chatstate],
    fetch_media: [:download_media],
    add_reaction: [:resolve_conn, :send_reaction],
    remove_reaction: [:resolve_conn, :send_reaction],
    post_channel_message: [:resolve_conn, :send_text],
    stream: [:resolve_conn, :send_text, :resolve_conn, :send_edit, :resolve_conn, :send_edit]
  }
  setup do
    {:ok, binding} =
      Jido.Chat.bind(Adapter, id: "wa-contract", transport: Transport, conn: self(), profile: "private-profile")

    %{binding: binding}
  end

  defp request(binding, operation, extra \\ %{}) do
    extra =
      if operation == :fetch_media do
        {:ok, ref} =
          Jido.Chat.put_resource(
            binding,
            "media",
            Jido.Chat.Media.new(%{
              kind: :image,
              metadata: %{direct_path: "/private/media", media_key: String.duplicate("k", 32)}
            })
          )

        Map.put(extra, "media_ref", ref)
      else
        extra
      end

    Factories.operation_request(binding, operation, extra)
  end

  defp calls do
    receive do
      {:provider, name} -> [name | calls()]
    after
      0 -> []
    end
  end

  defp portable(fact) do
    {:ok, json} = Jido.Signal.Serialization.serialize(fact)
    assert {:ok, ^fact} = Jido.Signal.Catalog.decode(Jido.Signal.Catalog.new!(Jido.Chat.signal_definitions()), json)

    for private <- ["private-token", "private-profile", "private-pairing-code", "private-bytes", "/private/media"] do
      refute json =~ private
    end
  end

  for {name, support} <- @row["operation_support"] do
    operation = String.to_atom(name)

    test "#{name} matches frozen #{support} with exact calls and a cached native result", %{binding: binding} do
      operation = unquote(operation)
      assert Jido.Chat.Adapter.capabilities(Adapter)[operation] == unquote(String.to_atom(support))
      parent = request(binding, operation)
      before = Jido.Signal.to_map(parent)
      assert {:ok, result} = Jido.Chat.execute(binding, parent)

      if unquote(support) == "unsupported" do
        assert result.type == "jido.chat.operation.failed" and result.data["code"] == "unsupported"
      else
        assert result.type == "jido.chat.operation.completed"
      end

      assert calls() == unquote(Map.get(@calls, operation, []))
      assert {:ok, ^result} = Jido.Chat.execute(binding, parent)
      assert calls() == []
      assert Jido.Signal.to_map(parent) == before
      assert Jido.Signal.Context.get(result, "causationid") == parent.id
      assert Jido.Signal.Trace.get(result).trace_id == Jido.Signal.Trace.get(parent).trace_id
      portable(result)
    end
  end

  defp message(type \\ "text", id \\ "m1", content \\ "body") do
    %{
      "id" => id,
      "channel_jid" => "room@g.us",
      "from_jid" => "user@s.whatsapp.net",
      "type" => type,
      "content" => content
    }
  end

  defp event("MessageReceived"), do: message()

  defp event("MessageUpdated"),
    do: message("edit", "edit-1", %{"key" => %{"jid" => "room@g.us", "id" => "m1"}, "text" => "edited"})

  defp event("MessageDeleted"), do: message("revoke", "revoke-1", %{"key" => {"room@g.us", "m1", false}})

  defp event("ReactionAdded"),
    do: message("reaction", "reaction-1", %{"key" => %{"jid" => "room@g.us", "id" => "m1"}, "emoji" => "👍"})

  defp event("ReactionRemoved"),
    do: message("reaction", "reaction-2", %{"key" => %{"jid" => "room@g.us", "id" => "m1"}, "emoji" => ""})

  defp event(name), do: message(name)

  for {name, support} <- @row["event_support"] do
    test "#{name} matches frozen #{support} including a cold reaction clear", %{binding: binding} do
      input = event(unquote(name))
      assert {:ok, %{signals: [fact]}} = Jido.Chat.normalize_event(binding, input)

      expected =
        if unquote(support) == "unsupported",
          do: "jido.chat.normalization.failed",
          else: Module.concat(Jido.Chat.Signal, unquote(name)).type()

      assert fact.type == expected
      assert {:ok, %{signals: [repeated]}} = Jido.Chat.normalize_event(binding, input)
      assert repeated.data["item_id"] == fact.data["item_id"]
      portable(fact)
      assert calls() == []
    end
  end

  test "complete upsert order and batch identity survive repeat acquisition", %{binding: binding} do
    batch =
      {:amarula, :messages_upsert,
       %{id: "batch", messages: [message("text", "first"), event("MessageUpdated"), event("ReactionRemoved")]}}

    assert {:ok, unit} = Jido.Chat.normalize_event(binding, batch)

    assert Enum.map(unit.signals, & &1.type) == [
             "jido.chat.message.received",
             "jido.chat.message.updated",
             "jido.chat.reaction.removed"
           ]

    assert List.last(unit.signals).data["reaction"] == nil
    assert {:ok, repeated} = Jido.Chat.normalize_event(binding, batch)

    assert repeated.id == unit.id and
             Enum.map(repeated.signals, & &1.data["item_id"]) == Enum.map(unit.signals, & &1.data["item_id"])

    assert {:ok, %{signals: []}} = Jido.Chat.normalize_event(binding, [])
    assert {:ok, %{signals: []}} = Jido.Chat.normalize_event(binding, {:amarula, :messages_upsert, %{messages: []}})
    Enum.each(unit.signals, &portable/1)
  end

  defp state(binding, mode \\ :ok) do
    %{binding: binding, sink_mfa: {Sink, :emit, [self(), mode]}, sink_opts: [], last_result: nil}
  end

  for mode <- [:ok, :error, :raise, :throw, :exit, :invalid] do
    test "one complete upsert has exactly one sink call for #{mode}", %{binding: binding} do
      unit =
        {:amarula, :messages_upsert, %{id: "batch", messages: [message("text", "first"), message("text", "second")]}}

      assert {:noreply, after_batch} = ConnectionWorker.handle_info(unit, state(binding, unquote(mode)))
      assert_receive {:sink, %{signals: [first, second]}, opts}
      assert first.data["message_id"] == "first" and second.data["message_id"] == "second"
      assert opts[:path] == "/whatsapp/messages_upsert"
      refute_receive {:sink, _, _}
      assert_result(unquote(mode), after_batch.last_result)
      refute Map.has_key?(after_batch, :checkpoint)
    end
  end

  defp assert_result(:ok, result), do: assert(result == {:ok, :accepted})
  defp assert_result(_, result), do: assert(match?({:error, _}, result))

  test "all four limits and malformed upsert reject before every sink call", %{binding: binding} do
    cases = [
      message("text", "big", String.duplicate("x", 262_145)),
      List.duplicate(message(), 101),
      List.duplicate(message("unknown"), 21),
      Enum.map(1..6, &message("text", "#{&1}", String.duplicate("x", 200_000)))
    ]

    for input <- cases do
      messages = List.wrap(input)
      unit = {:amarula, :messages_upsert, %{id: "batch", messages: messages}}

      assert {:noreply, %{last_result: {:error, %Jido.Chat.Errors.Contract{}}}} =
               ConnectionWorker.handle_info(unit, state(binding))

      refute_receive {:sink, _, _}
    end

    assert {:noreply, %{last_result: {:error, _}}} =
             ConnectionWorker.handle_info({:amarula, :messages_upsert, %{messages: :invalid}}, state(binding))

    refute_receive {:sink, _, _}
  end

  test "controls, pairing and QR data never enter the public sink", %{binding: binding} do
    state =
      %{state(binding) | last_result: nil}
      |> Map.merge(%{
        profile: "private-profile",
        control_mfa: nil,
        control_opts: [],
        last_control: nil,
        last_control_result: nil
      })

    for {type, data} <- [
          {:connection_update, %{qr: "private-token"}},
          {:pairing_code, %{code: "private-pairing-code"}},
          {:pairing_success, %{}},
          {:pairing_failure, %{}},
          {:history_sync, %{}},
          {:call_update, %{}},
          {:error, :private_error}
        ] do
      assert {:noreply, next} = ConnectionWorker.handle_info({:amarula, type, data}, state)
      assert next.last_control.data == data and next.last_control.event == type
      assert next.last_result == nil
      assert {:ok, %{signals: []}} = Jido.Chat.normalize_event(binding, {:amarula, type, data})
      refute_receive {:sink, _, _}
    end
  end

  test "encrypted media remains scoped and failures cancel unaccepted resources", %{binding: binding} do
    content = %{
      "kind" => "image",
      "mimetype" => "image/png",
      "direct_path" => "/private/media",
      "media_key" => String.duplicate("k", 32)
    }

    assert {:ok, %{signals: [fact]}} = Jido.Chat.normalize_event(binding, message("media", "media-1", content))
    [media] = fact.data["media"]
    ref = media["resource_ref"]
    assert {:ok, value} = Jido.Chat.resolve_resource(binding, ref)
    assert value.metadata["media_key"] == String.duplicate("k", 32)

    assert {:error, %{code: :resource_owner_mismatch}} =
             Task.async(fn -> Jido.Chat.resolve_resource(binding, ref) end) |> Task.await()

    {:ok, other} = Jido.Chat.bind(Adapter, id: "other")
    assert {:error, %{code: :invalid_resource}} = Jido.Chat.resolve_resource(other, ref)
    :ok = Jido.Chat.cancel_resource(binding, ref)
    assert {:error, %{code: :resource_cancelled}} = Jido.Chat.resolve_resource(binding, ref)
    {:ok, expired} = Jido.Chat.put_resource(binding, "media", value, ttl_ms: 0)
    assert {:error, %{code: :resource_expired}} = Jido.Chat.resolve_resource(binding, expired)
    portable(fact)
    bad = message("media", "bad", Map.put(content, "caption", String.duplicate("x", 262_145)))
    assert {:error, %{code: :signal_too_large}} = Jido.Chat.normalize_event(binding, bad)

    refute Enum.any?(:ets.tab2list(binding.resources), fn
             {{:resource, _}, _, _, _, _, :active} -> true
             _ -> false
           end)
  end

  test "provider failure is typed and cached with one call", %{binding: binding} do
    Process.put(:provider_failure, true)
    parent = request(binding, :send_message)
    assert {:ok, result} = Jido.Chat.execute(binding, parent)
    assert result.data["code"] == "provider_failure"
    assert calls() == [:resolve_conn]
    assert {:ok, ^result} = Jido.Chat.execute(binding, parent)
    assert calls() == []
  end

  test "cancelled stream has zero enumeration and provider calls", %{binding: binding} do
    stream =
      Stream.map(["hello"], fn text ->
        send(self(), :enumerated)
        text
      end)

    {:ok, ref} = Jido.Chat.put_resource(binding, "stream", stream)
    :ok = Jido.Chat.cancel_resource(binding, ref)
    parent = request(binding, :stream, %{"resource_ref" => ref})
    assert {:ok, result} = Jido.Chat.execute(binding, parent)
    assert result.data["code"] == "resource_cancelled"
    refute_received :enumerated
    assert calls() == []
  end

  test "actual Amarula edit and revoke references retain their target and order", %{binding: binding} do
    alias Amarula.{Address, Msg}

    attrs = %{
      id: "event",
      channel: Address.pn("15551234567"),
      from: Address.pn("15557654321"),
      to: Address.pn("15551234567"),
      timestamp: 1_706_745_600,
      raw: %Amarula.Protocol.Proto.Message{}
    }

    edit =
      struct(
        Msg,
        Map.merge(attrs, %{
          type: :edit,
          content: %Amarula.Content.Edit{key: {"15551234567@s.whatsapp.net", "target-1", false}, text: "fixed"}
        })
      )

    revoke =
      struct(
        Msg,
        Map.merge(attrs, %{
          id: "revoke",
          type: :revoke,
          content: %Amarula.Content.Revoke{key: {"15551234567@s.whatsapp.net", "target-2", false, "participant"}}
        })
      )

    assert {:ok, %{signals: [updated, deleted]}} =
             Jido.Chat.normalize_event(binding, {:amarula, :messages_upsert, %{id: "sdk", messages: [edit, revoke]}})

    assert updated.type == "jido.chat.message.updated" and updated.data["message_id"] == "target-1" and
             updated.data["text"] == "fixed"

    assert deleted.type == "jido.chat.message.deleted" and deleted.data["message_id"] == "target-2"
    portable(updated)
    portable(deleted)
  end

  test "invalid setup, malformed targets and a failed file cannot call the provider", %{binding: binding} do
    assert {:stop, :invalid_sink_mfa} =
             ConnectionWorker.init(bridge_id: "invalid", sink_mfa: :invalid, config: %{}, transport: Transport)

    assert {:stop, %{code: :invalid_binding}} =
             ConnectionWorker.init(
               bridge_id: "invalid",
               binding: :invalid,
               sink_mfa: {Sink, :emit, [self(), :ok]},
               config: %{},
               transport: Transport
             )

    assert calls() == []
    input = [message("edit", "bad", %{"key" => %{"id" => ""}}), message("text", "last")]
    assert {:ok, %{signals: [failure, valid]}} = Jido.Chat.normalize_event(binding, input)
    assert failure.type == "jido.chat.normalization.failed" and valid.data["message_id"] == "last"

    {:ok, ref} =
      Jido.Chat.put_resource(binding, "file", Jido.Chat.FileUpload.new(%{filename: "file.txt", data: "bytes"}))

    assert :ok = Jido.Chat.Resources.fail(binding, ref)

    assert {:ok, %{type: "jido.chat.operation.failed", data: %{"code" => "resource_failure"}}} =
             Jido.Chat.execute(binding, request(binding, :send_file, %{"resource_ref" => ref}))

    assert calls() == []
  end
end
