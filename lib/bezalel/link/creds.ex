defmodule Bezalel.Link.Creds do
  @moduledoc """
  The phone's credential exchange bookkeeping. Only hashes and change times live
  in Mob.State; credential values stay in rho's configured secure store. A
  successful local rho change is broadcast to every origin's dialer, including
  while its socket is offline. Incoming changes are compared before writing to
  rho, so a delayed server frame cannot undo a refreshed OAuth grant.
  """
  use GenServer

  alias Rho.Auth
  alias Rho.Auth.Keeper
  alias Rho.CredentialStore

  @key :bezalel_link_credential_versions
  @subscribers Bezalel.Link.CredSubscribers

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @doc "Subscribes the calling dialer to changes to the phone's credentials."
  def subscribe do
    {:ok, _} = Registry.register(@subscribers, :changed, nil)
    :ok
  end

  @doc "Current secure-store credentials, keyed by rho's provider names."
  def snapshot do
    for provider <- Auth.providers(), {:ok, creds} <- [safe_get(provider)], into: %{} do
      {Atom.to_string(provider), creds}
    end
  end

  @doc "The credential and non-secret version to send to a linked website."
  def current(provider), do: GenServer.call(__MODULE__, {:current, provider})
  @doc "Applies a sealed server update; never replaces a newer phone credential."
  def apply_set(name, creds, updated_at) do
    with {:ok, provider} <- provider(name),
         true <- is_integer(updated_at) and updated_at >= 0 and Keeper.valid?(provider, creds) do
      GenServer.call(__MODULE__, {:set, provider, creds, updated_at})
    else
      _ -> {:error, :invalid_credentials}
    end
  end

  def apply_delete(name, updated_at) do
    with {:ok, provider} <- provider(name),
         true <- is_integer(updated_at) and updated_at >= 0 do
      GenServer.call(__MODULE__, {:delete, provider, updated_at})
    else
      _ -> {:error, :invalid_credentials}
    end
  end

  def provider(name) when is_binary(name) do
    case Enum.find(Auth.providers(), &(Atom.to_string(&1) == name)) do
      nil -> {:error, :unknown_provider}
      provider -> {:ok, provider}
    end
  end

  def provider(_name), do: {:error, :unknown_provider}

  @impl true
  def init(_) do
    Process.flag(:sensitive, true)
    :ok = Auth.subscribe()
    {:ok, reconcile(%{versions: Mob.State.get(@key, %{})})}
  end

  @impl true
  def handle_call({:current, provider}, _from, state) do
    result = safe_get(provider)
    state = reconcile_provider(state, provider, result)
    {:reply, {result, state.versions[provider]}, state}
  end

  def handle_call({:set, provider, creds, at}, _from, state) do
    previous = safe_get(provider)
    state = reconcile_provider(state, provider, previous)
    version = state.versions[provider]

    cond do
      previous == :unavailable ->
        {:reply, {:error, :secure_store}, state}

      newer?(previous, version, creds, at) ->
        case Auth.put(provider, creds) do
          :ok ->
            {:reply, :ok, remember(state, provider, creds, max(at, version_at(version)))}

          {:error, _} = error ->
            {:reply, error, state}
        end

      previous == {:ok, creds} ->
        {:reply, :ok, state}

      true ->
        {:reply, :stale, state}
    end
  end

  def handle_call({:delete, provider, at}, _from, state) do
    previous = safe_get(provider)
    state = reconcile_provider(state, provider, previous)
    {reply, state} = delete_credential(state, provider, at, previous)
    {:reply, reply, state}
  end

  defp delete_credential(state, _provider, _at, :unavailable),
    do: {{:error, :secure_store}, state}

  defp delete_credential(state, provider, at, previous) do
    version = state.versions[provider]

    if version != nil and at <= version.at do
      {if(previous == :missing, do: :ok, else: :stale), state}
    else
      do_delete(state, provider, at, previous)
    end
  end

  defp do_delete(state, provider, at, {:ok, _}) do
    case Auth.delete(provider) do
      :ok -> {:ok, remember(state, provider, nil, at)}
      {:error, _} = error -> {error, state}
    end
  end

  defp do_delete(state, provider, at, :missing),
    do: {:ok, remember(state, provider, nil, at)}

  @impl true
  def handle_info({:rho_auth, :changed}, state), do: {:noreply, reconcile(state)}

  # GenServer crash reports must not print an incoming credential call.
  @impl true
  def format_status(status) do
    Map.update(status, :message, nil, fn
      {:set, provider, _creds, at} -> {:set, provider, :redacted, at}
      other -> other
    end)
  end

  defp reconcile(state) do
    Enum.reduce(Auth.providers(), state, fn provider, state ->
      reconcile_provider(state, provider, safe_get(provider))
    end)
  end

  defp reconcile_provider(state, _provider, :unavailable), do: state

  defp reconcile_provider(state, provider, result) do
    current = if match?({:ok, _}, result), do: elem(result, 1), else: nil
    existing = state.versions[provider]
    hash = fingerprint(current)

    if (existing == nil and current == nil) or (existing != nil and existing.hash == hash) do
      state
    else
      now = System.os_time(:millisecond)
      at = if existing, do: max(now, existing.at + 1), else: now
      remember(state, provider, current, at)
    end
  end

  defp remember(state, provider, creds, at) do
    versions =
      Map.put(state.versions, provider, %{hash: fingerprint(creds), at: at, present: creds != nil})

    :ok = Mob.State.put(@key, versions)

    Registry.dispatch(@subscribers, :changed, fn entries ->
      Enum.each(entries, fn {pid, _} -> send(pid, {:link_credentials_changed, provider}) end)
    end)

    %{state | versions: versions}
  end

  # OAuth refresh tokens rotate: later expiry is the decisive version. When
  # expiry ties, the updated_at breaks ties; for keys/type changes only the
  # timestamp orders writes. A tombstone is never replaced by an older set.
  defp newer?(
         {:ok, %{"type" => "oauth", "expires" => previous}},
         _version,
         %{"type" => "oauth", "expires" => incoming},
         _at
       )
       when incoming > previous, do: true

  defp newer?(
         {:ok, %{"type" => "oauth", "expires" => previous}},
         _version,
         %{"type" => "oauth", "expires" => incoming},
         _at
       )
       when incoming < previous, do: false

  defp newer?(_previous, nil, _creds, _at), do: true
  defp newer?(_previous, version, _creds, at), do: at > version.at

  defp version_at(nil), do: 0
  defp version_at(%{at: at}), do: at

  defp fingerprint(nil), do: nil
  defp fingerprint(creds), do: :crypto.hash(:sha256, Jason.encode!(creds))

  # Rho.Auth.get/1 intentionally collapses an unreadable secure store into
  # :error. Do not interpret that as a sign-out and send a deletion.
  defp safe_get(provider) do
    case Auth.get(provider) do
      {:ok, creds} ->
        {:ok, creds}

      :error ->
        case CredentialStore.get("auth:#{provider}") do
          :error -> :missing
          _ -> :unavailable
        end
    end
  end
end
