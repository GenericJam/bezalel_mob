defmodule Bezalel.Link.Mailbox do
  @moduledoc """
  The phone's X25519 key for server changes waiting while it is offline.
  Its private half lives only in Keychain/Keystore; the server keeps only
  encrypted envelopes and the public half. Losing this key is an error, not
  permission to silently replace it and strand a rotated refresh token.

  Two kinds of envelope are sealed to it: credential changes
  (`cred.envelope`, `open/2`) and the records of a work parcel
  (`work.envelope`, `open_work/2`): web work the website hadn't delivered
  when the account's last session expired, kept for the phone only
  (decisions/2026-10-19-phone-link.md).
  """

  alias Bezalel.Link.{Serve, Wire}

  @key "bezalel.link.mailbox_key"
  @created :bezalel_link_mailbox_created
  @context "bezalel credential mailbox v1"
  @max_cipher 65_536
  @work_context "bezalel work mailbox v1"
  @max_work 524_288
  @max_records 1_000_000
  @work_ops ~w(mat.put mat.delete artifact.put conv.create conv.append conv.meta conv.delete
    prefs.set)

  @doc "The mailbox public key to pin for an authenticated website."
  def public_key do
    with {:ok, private} <- private_key(), do: {:ok, public(private)}
  end

  @doc "The most records a welcome's `work_count` or a parcel's `count` may claim."
  def max_records, do: @max_records

  @doc "Open a phone-sealed change for this authenticated account."
  def open(account_id, %{"op" => "cred.envelope"} = request) do
    with {:ok, plain} <- unseal(@context, account_id, @max_cipher, request),
         {:ok, %{"provider" => _, "action" => _, "updated_at" => _} = payload} <-
           Jason.decode(plain) do
      {:ok, payload}
    else
      {:error, _} = error -> error
      _ -> {:error, :bad_envelope}
    end
  rescue
    _ -> {:error, :bad_envelope}
  end

  def open(_, _), do: {:error, :bad_envelope}

  @doc """
  Opens record `seq` of a work parcel for this authenticated account: the
  one request frame inside (`mat.put`, `conv.append`, …) exactly as the
  website would have sent it live. The parcel, its position and the account
  are the cipher's associated data, so a record can't be replayed into
  another account or parcel. Anything else is `{:error, :bad_envelope}`.
  """
  def open_work(
        account_id,
        %{
          "op" => "work.envelope",
          "id" => id,
          "parcel" => parcel,
          "seq" => seq,
          "count" => count
        } = request
      )
      when is_binary(account_id) and is_binary(parcel) and byte_size(parcel) == 22 and
             is_integer(seq) and is_integer(count) and seq >= 0 and seq < count and
             count <= @max_records do
    position = parcel <> ":" <> Integer.to_string(seq)

    with true <- id == "work:" <> position,
         {:ok, <<_::binary-16>> = raw} <- decode(parcel),
         true <- Wire.b64(raw) == parcel,
         {:ok, plain} <- unseal(@work_context, account_id <> ":" <> position, @max_work, request),
         {:ok, %{"op" => op, "id" => inner_id} = inner} when op in @work_ops <-
           Jason.decode(plain),
         true <- Serve.valid_request_id?(inner_id) do
      {:ok, inner}
    else
      _ -> {:error, :bad_envelope}
    end
  rescue
    _ -> {:error, :bad_envelope}
  end

  def open_work(_, _), do: {:error, :bad_envelope}

  defp unseal(context, aad, max, %{
         "ephemeral" => ephemeral,
         "nonce" => nonce,
         "ciphertext" => ciphertext,
         "tag" => tag
       }) do
    with {:ok, private} <- private_key(),
         {:ok, <<_::binary-32>> = ephemeral} <- decode(ephemeral),
         {:ok, <<_::binary-12>> = nonce} <- decode(nonce),
         {:ok, cipher} <- decode(ciphertext),
         true <- byte_size(cipher) <= max,
         {:ok, <<_::binary-16>> = tag} <- decode(tag),
         shared <- :crypto.compute_key(:ecdh, ephemeral, private, :x25519),
         key <- :crypto.hash(:sha256, [context, shared, ephemeral, public(private)]),
         plain when is_binary(plain) <-
           :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, cipher, aad, tag, false) do
      {:ok, plain}
    else
      {:error, _} = error -> error
      _ -> {:error, :bad_envelope}
    end
  end

  defp unseal(_, _, _, _), do: {:error, :bad_envelope}

  defp public(private) do
    {pub, ^private} = :crypto.generate_key(:ecdh, :x25519, private)
    pub
  end

  defp private_key, do: :global.trans({__MODULE__, self()}, &read_or_make/0, [node()])

  defp read_or_make do
    store = Rho.Config.credential_store()

    case store.get(@key) do
      {:ok, encoded} ->
        case Base.decode64(encoded) do
          {:ok, <<_::binary-32>> = private} -> {:ok, private}
          _ -> {:error, :bad_mailbox_key}
        end

      :error ->
        if Mob.State.get(@created, false), do: {:error, :mailbox_key_missing}, else: make(store)

      {:error, _} = error ->
        error
    end
  end

  defp make(store) do
    {_pub, private} = :crypto.generate_key(:ecdh, :x25519)

    with :ok <- store.put(@key, Base.encode64(private)),
         :ok <- Mob.State.put(@created, true),
         do: {:ok, private}
  end

  defp decode(value) when is_binary(value), do: Base.url_decode64(value, padding: false)
  defp decode(_), do: :error
end
