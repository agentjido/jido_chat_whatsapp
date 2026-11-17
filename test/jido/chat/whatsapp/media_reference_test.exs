defmodule Jido.Chat.WhatsApp.MediaReferenceTest do
  use ExUnit.Case, async: true

  alias Jido.Chat.WhatsApp.Transport.MediaReference

  defp media do
    struct(Amarula.Content.Media,
      kind: :image,
      mimetype: "image/jpeg",
      media_key: :binary.copy(<<1>>, 32),
      direct_path: "/media/private",
      file_sha256: :binary.copy(<<2>>, 32),
      file_enc_sha256: :binary.copy(<<3>>, 32)
    )
  end

  test "a reference round trips only for the same secret and profile" do
    secret = :crypto.strong_rand_bytes(32)
    assert {:ok, reference} = MediaReference.seal(media(), secret, "primary")
    assert String.starts_with?(reference, "whatsapp://media/v1/")
    assert {:ok, restored} = MediaReference.open(reference, secret, "primary")
    assert restored.kind == :image
    assert restored.media_key == media().media_key

    assert {:error, :invalid_media_reference} =
             MediaReference.open(reference, :crypto.strong_rand_bytes(32), "primary")

    assert {:error, :invalid_media_reference} = MediaReference.open(reference, secret, "other")
  end

  test "tampered, malformed, and oversized references fail closed" do
    secret = :crypto.strong_rand_bytes(32)
    assert {:ok, "whatsapp://media/v1/" <> encoded} = MediaReference.seal(media(), secret, "primary")
    bytes = Base.url_decode64!(encoded, padding: false)
    tampered = "whatsapp://media/v1/" <> Base.url_encode64(bytes <> <<0>>, padding: false)

    for reference <- [
          tampered,
          "invalid",
          "whatsapp://media/v1/not-base64",
          "whatsapp://media/v1/" <> String.duplicate("a", 24_001)
        ] do
      assert {:error, :invalid_media_reference} = MediaReference.open(reference, secret, "primary")
    end
  end

  test "oversized descriptors are rejected before encryption" do
    descriptor = %{media() | direct_path: "/" <> String.duplicate("x", 17_000)}

    assert {:error, :invalid_media_reference} =
             MediaReference.seal(descriptor, :crypto.strong_rand_bytes(32), "primary")
  end
end
