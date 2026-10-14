defmodule Jido.Chat.WhatsApp.PairingPresentationTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias Jido.Chat.WhatsApp.Pairing

  property "shared receipts and account projection never carry arbitrary host or provider fields" do
    check all(secret <- string(:alphanumeric, min_length: 1), id <- integer()) do
      saved = %{id: id, name: "Account", credentials: secret, context: %{secret: secret}, runtime_pending: true}

      assert Pairing.authentication_presentation(%{phase: :saved, saved: saved}, :opaque) ==
               %{phase: :saved, session: :opaque, receipt: %{id: id, name: "Account"}, runtime_pending: true}

      assert Pairing.account(%{phone_number: "+15550001", display_name: %{secret: secret}, raw: secret}) ==
               %{external_id: "+15550001", display_name: nil}

      assert Pairing.public_receipt(%{id: %{secret: secret}, name: [secret]}) == %{}
    end
  end

  property "only pairing snapshots expose QR material; provider details never escape" do
    check all(
            qr <- string(:alphanumeric, min_length: 1),
            status <-
              member_of([
                :connecting,
                :authenticating,
                :reconnecting,
                :pairing,
                :connected,
                :expired,
                :failed,
                :disconnected,
                :logged_out
              ])
          ) do
      snapshot =
        Pairing.presentation(%{
          status: status,
          attempt_id: make_ref(),
          qr: qr,
          secret: "never"
        })

      assert snapshot.mode == "linked_device"
      assert snapshot.qr == if(status == :pairing, do: qr, else: nil)
      refute Map.has_key?(snapshot, :secret)
      if status == :expired, do: assert(snapshot.phase == :expired)
      if status == :connected, do: assert(snapshot.phase == :connected)

      if status in [:authenticating, :reconnecting], do: assert(snapshot.phase == :pending)
    end
  end
end
