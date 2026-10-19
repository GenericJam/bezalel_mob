defmodule Bezalel.Link.Identity do
  @moduledoc """
  The phone's device key: an Ed25519 key pair made the first time the
  phone links a computer, kept in the secure store (Keychain / Keystore,
  `MobSecureStore`, the store rho keeps sign-ins in:
  `Rho.Config.credential_store/0`) under `"bezalel.link.device_key"` as its
  32-byte seed, base64. **This key is the account** on the website
  (`Bezalel.Link.Pairing.account_id/1`); its `fingerprint/0` is what the
  phone and the website show.

  A store that can't be read (the iOS Keychain before the first unlock
  after a restart answers -25308, a missing NIF) is an error, never "no
  key": making a new one then would be a new account.
  """

  alias Bezalel.Link.Handshake
  alias Bezalel.Link.Pairing

  @key "bezalel.link.device_key"

  @doc """
  The device key pair, made and stored the first time. `{:ok, {public,
  private}}` or `{:error, reason}` when the secure store can't be read or
  written. Callers are serialised, so two dialers starting at once can't
  each make a key.
  """
  @spec keypair() :: {:ok, Handshake.keypair()} | {:error, term()}
  def keypair, do: :global.trans({__MODULE__, self()}, &read_or_make/0, [node()])

  defp read_or_make do
    store = Rho.Config.credential_store()

    case store.get(@key) do
      {:ok, encoded} ->
        decode(encoded)

      :error ->
        {_pub, priv} = pair = Handshake.keypair()

        case store.put(@key, Base.encode64(priv)) do
          :ok -> {:ok, pair}
          {:error, _} = error -> error
        end

      {:error, _} = error ->
        error
    end
  end

  @doc "The device key's fingerprint (`\"ABCD-EFGH\"`), or nil when there is no key yet or it can't be read."
  @spec fingerprint() :: String.t() | nil
  def fingerprint do
    case Rho.Config.credential_store().get(@key) do
      {:ok, encoded} ->
        case decode(encoded) do
          {:ok, {pub, _}} -> Pairing.fingerprint(pub)
          {:error, _} -> nil
        end

      _none_or_error ->
        nil
    end
  end

  defp decode(encoded) do
    case Base.decode64(encoded) do
      {:ok, <<_::binary-32>> = priv} -> {:ok, Handshake.keypair(priv)}
      _ -> {:error, :bad_device_key}
    end
  end
end
