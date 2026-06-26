defmodule Jido.Chat.WhatsAppTest do
  use ExUnit.Case, async: true

  test "adapter/0 returns the whatsapp adapter module" do
    assert Jido.Chat.WhatsApp.adapter() == Jido.Chat.WhatsApp.Adapter
  end
end
