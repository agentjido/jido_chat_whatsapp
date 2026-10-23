defmodule Jido.Chat.WhatsApp.Transport.MediaReference do
  @moduledoc false

  # Private, versioned codec. Neither identity secrets nor download keys leave
  # Transport. Separate the encryption key from WhatsApp protocol key usages.
  @prefix "whatsapp://media/v1/"
  @max_plaintext 16_384
  @max_reference 24_000

  @doc "Seals a bounded descriptor under a profile-specific, domain-separated key."
  @spec seal(Amarula.Content.Media.t(), binary(), String.t()) :: {:ok, String.t()} | {:error, atom()}
  def seal(%Amarula.Content.Media{} = media, secret, profile) do
    plaintext = :erlang.term_to_binary(media)

    if byte_size(plaintext) <= @max_plaintext do
      nonce = :crypto.strong_rand_bytes(12)

      {ciphertext, tag} =
        :crypto.crypto_one_time_aead(:aes_256_gcm, key(secret, profile), nonce, plaintext, @prefix, true)

      {:ok, @prefix <> Base.url_encode64(nonce <> tag <> ciphertext, padding: false)}
    else
      {:error, :invalid_media_reference}
    end
  end

  @doc "Authenticates a versioned reference before decoding its bounded descriptor."
  @spec open(String.t(), binary(), String.t()) :: {:ok, Amarula.Content.Media.t()} | {:error, atom()}
  def open(@prefix <> encoded = reference, secret, profile) when byte_size(reference) <= @max_reference do
    with {:ok, <<nonce::binary-size(12), tag::binary-size(16), ciphertext::binary>>} <-
           Base.url_decode64(encoded, padding: false),
         plaintext when is_binary(plaintext) and byte_size(plaintext) <= @max_plaintext <-
           :crypto.crypto_one_time_aead(:aes_256_gcm, key(secret, profile), nonce, ciphertext, @prefix, tag, false),
         # Never accept compressed ETF, even after authentication: bound decoding
         # work as well as token size. Safe decoding cannot create atoms.
         <<131, format, _::binary>> when format != 80 <- plaintext,
         {%Amarula.Content.Media{} = media, used} <- :erlang.binary_to_term(plaintext, [:safe, :used]),
         true <- used == byte_size(plaintext) do
      {:ok, media}
    else
      _ -> {:error, :invalid_media_reference}
    end
  rescue
    _ -> {:error, :invalid_media_reference}
  end

  def open(_, _, _), do: {:error, :invalid_media_reference}

  defp key(secret, profile),
    do: :crypto.mac(:hmac, :sha256, secret, "jido_chat_whatsapp/media-reference/v1/" <> profile)
end
