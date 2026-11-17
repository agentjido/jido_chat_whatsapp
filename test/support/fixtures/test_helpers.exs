defmodule Jido.Chat.WhatsApp.TestHelpers do
  @moduledoc false
  import ExUnit.Assertions
  alias Jido.Chat.Client
  alias Jido.Chat.WhatsApp.{Adapter, ConnectionWorker}

  # Called in the test process: children and mutable state belong to ExUnit's
  # per-test supervisor, and observers are explicit MFA arguments.
  def start_listener(profile, ingress, opts) do
    transport =
      value(ingress, [:transport, "transport"]) ||
        Jido.Chat.WhatsApp.Transport.AmarulaClient

    config = value(ingress, [:config, "config"]) || %{}

    config =
      config
      |> Map.put(:profile, value(ingress, [:profile, "profile"]) || profile)
      |> Map.put(:sync_history, value(ingress, [:sync_history, "sync_history"]) != false)
      |> Map.put(:sync_full_history, value(ingress, [:sync_full_history, "sync_full_history"]) != false)

    client =
      Client.new!(Adapter,
        id: "whatsapp-test-#{System.unique_integer([:positive])}",
        config: [profile: config.profile],
        transport: transport
      )

    callback = Keyword.fetch!(opts, :sink_mfa)

    start_worker(
      config,
      id: {:whatsapp_connection_worker, profile},
      client: client,
      admission_mfa: callback,
      lifecycle_mfa: callback,
      transport: transport,
      identity_timeout_ms: Keyword.get(opts, :identity_timeout_ms, 2_500)
    )
  end

  def start_worker(config, opts) do
    {id, opts} = Keyword.pop(opts, :id, ConnectionWorker)
    transport = Keyword.get(opts, :transport, Jido.Chat.WhatsApp.Transport.AmarulaClient)

    client =
      Keyword.get_lazy(opts, :client, fn ->
        Client.new!(Adapter,
          id: "whatsapp-worker-#{System.unique_integer([:positive])}",
          config: [profile: to_string(config.profile)],
          transport: transport
        )
      end)

    callback = Keyword.get(opts, :sink_mfa, sink(:signals))

    opts =
      opts
      |> Keyword.delete(:sink_mfa)
      |> Keyword.put_new(:admission_mfa, callback)
      |> Keyword.put_new(:lifecycle_mfa, callback)
      |> Keyword.merge(client: client, config: config, transport: transport)

    ExUnit.Callbacks.start_supervised!(Supervisor.child_spec({ConnectionWorker, opts}, id: id))
  end

  def message(attrs) do
    struct!(Amarula.Msg, Keyword.merge([type: :text, content: "hello", raw: %Amarula.Protocol.Proto.Message{}], attrs))
  end

  def sink(tag, observer \\ self()), do: {__MODULE__, :emit, [observer, tag]}

  def emit(observer, tag, payload, _opts) do
    send(observer, {tag, payload})
    :ok
  end

  def lifecycle_sink(tag, observer \\ self()), do: {__MODULE__, :emit_lifecycle, [observer, tag]}

  def emit_lifecycle(observer, tag, metadata, _) when is_map(metadata) do
    send(observer, {tag, metadata})
    :ok
  end

  defp value(map, keys), do: Enum.find_value(keys, &Map.get(map, &1))

  def eventually(fun, attempts \\ 100, interval \\ 5) do
    case fun.() do
      result when result not in [false, nil] ->
        result

      _ when attempts > 1 ->
        Process.sleep(interval)
        eventually(fun, attempts - 1, interval)

      _ ->
        flunk("condition did not settle after polling")
    end
  end

  def fresh_vm(script, args \\ [], opts \\ []) do
    paths = Keyword.get_lazy(opts, :paths, fn -> Enum.map(:code.get_path(), &List.to_string/1) end)
    paths = Enum.flat_map(paths, &["-pa", &1])

    System.cmd(System.find_executable("elixir"), ["--erl", "+S 2:2"] ++ paths ++ ["-e", script] ++ args,
      stderr_to_stdout: true
    )
  end
end
