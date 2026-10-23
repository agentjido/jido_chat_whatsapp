defmodule Jido.Chat.WhatsApp.TestHelpers do
  @moduledoc false
  import ExUnit.Assertions
  alias Jido.Chat.WhatsApp.{Adapter, ConnectionWorker}

  # Called in the test process: children and mutable state belong to ExUnit's
  # per-test supervisor, and observers are explicit MFA arguments.
  def start_listener(profile, ingress, opts) do
    assert {:ok, [spec]} = Adapter.listener_child_specs(profile, Keyword.put(opts, :ingress, ingress))
    ExUnit.Callbacks.start_supervised!(spec)
  end

  def start_worker(config, opts) do
    {id, opts} = Keyword.pop(opts, :id, ConnectionWorker)
    opts = Keyword.merge([bridge_id: config.profile, config: config], opts)
    ExUnit.Callbacks.start_supervised!(Supervisor.child_spec({ConnectionWorker, opts}, id: id))
  end

  def message(attrs) do
    struct!(Amarula.Msg, Keyword.merge([type: :text, content: "hello", raw: %Amarula.Protocol.Proto.Message{}], attrs))
  end

  def sink(tag, observer \\ self()), do: {__MODULE__, :emit, [observer, tag]}
  def emit(observer, tag, payload, _opts), do: send(observer, {tag, payload})

  def lifecycle_sink(tag, observer \\ self()), do: {__MODULE__, :emit_lifecycle, [observer, tag]}

  def emit_lifecycle(observer, tag, %Jido.Chat.EventEnvelope{event_type: :action, payload: %{metadata: metadata}}, _),
    do: send(observer, {tag, metadata})

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
