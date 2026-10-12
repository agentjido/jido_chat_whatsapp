defmodule Jido.Chat.WhatsApp.HistoryContractTest do
  use ExUnit.Case, async: true
  alias Jido.Chat.WhatsApp.{Adapter, ConnectionWorker}

  defmodule Transport do
    def connect(config, opts) do
      send(config.test_pid, {:connect, config, opts[:parent]})
      {:ok, self()}
    end

    def stop(_, _), do: :ok
    def account_jids(_), do: {:ok, ["123@s.whatsapp.net"]}
  end

  defmodule Sink do
    def emit(pid, payload, _opts), do: send(pid, {:payload, payload})
  end

  for history <- [false, true], full <- [false, true] do
    test "history=#{history} full=#{full} survive reconnect and preserve queued messages" do
      history = unquote(history)
      full = unquote(full)

      {:ok, [spec]} =
        Adapter.listener_child_specs("history",
          sink_mfa: {Sink, :emit, [self()]},
          ingress: %{
            "mode" => "linked_device",
            "profile" => "profile",
            "transport" => Transport,
            "sync_history" => history,
            "sync_full_history" => full,
            "config" => %{test_pid: self()}
          }
        )

      worker = start_supervised!(spec)
      assert_receive {:connect, config, parent}
      assert config.sync_history == history
      assert config.sync_full_history == full

      msg = %Amarula.Msg{
        id: "queued",
        channel: Amarula.Address.pn("456"),
        from_me: true,
        type: :text,
        content: "old but queued",
        timestamp: 1,
        raw: %Amarula.Protocol.Proto.Message{}
      }

      send(parent, {:amarula, :messages_upsert, %{messages: [msg]}})
      assert_receive {:payload, %{id: "queued"} = payload}
      assert {:ok, incoming} = Adapter.transform_incoming(payload)
      assert incoming.author.is_me
      send(parent, {:amarula, :history_sync, %{messages: [%{msg | id: "historical"}], status_messages: [msg]}})

      if history do
        assert_receive {:payload, %{id: "historical", metadata: %{history: true}}}
      else
        refute_receive {:payload, _}
      end

      assert :ok = ConnectionWorker.reconnect(worker)
      assert_receive {:connect, ^config, new_parent}
      send(new_parent, {:amarula, :messages_upsert, %{messages: [msg]}})
      assert_receive {:payload, %{id: "queued"}}
    end
  end
end
