defmodule Jido.Chat.WhatsApp.ProtocolStub do
  @moduledoc false
  use GenServer

  def start_link(state), do: GenServer.start_link(__MODULE__, state)
  def init(state), do: {:ok, state}
  def handle_call(:conn, _, state), do: {:reply, %{profile: state.profile}, state}
  def handle_call(:get_connection_state, _, state), do: {:reply, Map.get(state, :connection, :connected), state}
  def handle_call(:get_auth_creds, _, %{blocked: true} = state), do: {:noreply, state}
  def handle_call(:get_auth_creds, _, state), do: {:reply, state.creds, state}
  def handle_call(:identity, _, state), do: {:reply, state.identity, state}
  def handle_call({:set, values}, _, state), do: {:reply, :ok, Map.merge(state, values)}

  def start_supervised!(state) do
    ExUnit.Callbacks.start_supervised!(%{id: make_ref(), start: {__MODULE__, :start_link, [state]}})
  end
end
