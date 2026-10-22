defmodule Bezalel.Link.Store do
  @moduledoc """
  What the phone remembers about the websites it linked, in `Mob.State`
  under `:bezalel_link` (nothing secret: the device key is in the secure
  store, `Bezalel.Link.Identity`). Per origin (`"https://study.genericjam.com"`):

    * `:server_key`: the website's link key, pinned when the first
      computer was linked (the QR code's fingerprint, checked against the
      handshake); a different one later is "this website's identity
      changed"
    * `:sessions`: the website's list of linked computers as it last sent
      it (`welcome`, `sessions.changed`), shown offline
    * `:revokes`: log-outs made while offline (a session id, or `"all"`),
      sent on the next connect
    * `:work`: the website announced a work parcel (`work_count` in
      `welcome`) not yet delivered in full (`work.done`); only for a
      pinned key, and forgotten with the pin

  The phone dials an origin while it has sessions, log-outs to send or a
  work parcel to receive (`dial?/1`).
  """

  @key :bezalel_link

  @type session :: %{String.t() => term()}
  @type entry :: %{
          :server_key => binary() | nil,
          :sessions => [session()],
          :revokes => [String.t()],
          optional(:work) => boolean()
        }

  @doc "Every origin the phone knows, with its entry."
  @spec all() :: %{String.t() => entry()}
  def all, do: Mob.State.get(@key, %{})

  @doc "One origin's entry, or nil."
  @spec get(String.t()) :: entry() | nil
  def get(origin), do: Map.get(all(), origin)

  @doc "The pinned server key of `origin`, or nil."
  @spec server_key(String.t()) :: binary() | nil
  def server_key(origin), do: (get(origin) || %{})[:server_key]

  @doc "The cached sessions of `origin` (`[]` when none)."
  @spec sessions(String.t()) :: [session()]
  def sessions(origin), do: (get(origin) || %{})[:sessions] || []

  @doc "The log-outs of `origin` not yet sent."
  @spec revokes(String.t()) :: [String.t()]
  def revokes(origin), do: (get(origin) || %{})[:revokes] || []

  @doc "Is a work parcel from `origin` still to be received?"
  @spec work?(String.t()) :: boolean()
  def work?(origin), do: (get(origin) || %{})[:work] == true

  @doc """
  Does the phone dial `origin`? While it has linked computers, log-outs to
  send or a work parcel to receive.
  """
  @spec dial?(String.t()) :: boolean()
  def dial?(origin), do: sessions(origin) != [] or revokes(origin) != [] or work?(origin)

  @doc "The origins to dial (`dial?/1`)."
  @spec to_dial() :: [String.t()]
  def to_dial, do: for({origin, _} <- all(), dial?(origin), do: origin)

  @doc """
  Pins `server_key` for `origin` (the first link, or a re-link with nothing
  linked). A work parcel announced under another key is forgotten.
  """
  @spec pin(String.t(), binary()) :: :ok
  def pin(origin, server_key) do
    update(origin, fn entry ->
      work = entry.server_key == server_key and Map.get(entry, :work, false)
      Map.merge(entry, %{server_key: server_key, work: work})
    end)
  end

  @doc "Drops `origin`'s pinned key (a re-link after the website's key changed, with nothing linked there)."
  @spec unpin(String.t()) :: :ok
  def unpin(origin), do: update(origin, &Map.merge(&1, %{server_key: nil, work: false}))

  @doc """
  Records whether the website pinned for `origin` has a work parcel still to
  deliver. Ignored for an origin with no pinned key: a parcel is only
  dialled for under the key it was announced by.
  """
  @spec put_work(String.t(), boolean()) :: :ok
  def put_work(origin, pending?) when is_boolean(pending?) do
    cond do
      work?(origin) == pending? -> :ok
      server_key(origin) == nil -> :ok
      true -> update(origin, &Map.put(&1, :work, pending?))
    end
  end

  @doc """
  The website's list for `origin`, as it sent it, less any log-out not yet
  sent (so a computer logged out offline doesn't come back until the
  website has it).
  """
  @spec put_sessions(String.t(), [session()]) :: :ok
  def put_sessions(origin, sessions) do
    update(origin, fn entry ->
      %{entry | sessions: without(clean(sessions), entry.revokes)}
    end)
  end

  @doc "Adds `session` (the one just linked) to `origin`'s list."
  @spec add_session(String.t(), session()) :: :ok
  def add_session(origin, %{"id" => id} = session) do
    update(origin, fn entry ->
      %{entry | sessions: Enum.reject(entry.sessions, &(&1["id"] == id)) ++ clean([session])}
    end)
  end

  @doc "Queues a log-out (a session id, or `\"all\"`) and drops it from the list at once."
  @spec queue_revoke(String.t(), String.t()) :: :ok
  def queue_revoke(origin, id) do
    update(origin, fn entry ->
      revokes = if id in entry.revokes, do: entry.revokes, else: entry.revokes ++ [id]
      %{entry | revokes: revokes, sessions: without(entry.sessions, [id])}
    end)
  end

  @doc "A log-out the website has acknowledged."
  @spec revoked(String.t(), String.t()) :: :ok
  def revoked(origin, id), do: update(origin, &%{&1 | revokes: List.delete(&1.revokes, id)})

  @doc "Forgets everything (tests; a reinstall does this too)."
  @spec clear() :: :ok
  def clear, do: Mob.State.delete(@key)

  # Read-modify-write of one Mob.State value: serialised, since each
  # origin's dialer and the screen write it.
  defp update(origin, fun) do
    :global.trans(
      {__MODULE__, self()},
      fn ->
        all = all()
        entry = Map.get(all, origin, %{server_key: nil, sessions: [], revokes: []})
        Mob.State.put(@key, Map.put(all, origin, fun.(entry)))
      end,
      [node()]
    )
  end

  defp without(sessions, revokes) do
    if "all" in revokes,
      do: [],
      else: Enum.reject(sessions, &(&1["id"] in revokes))
  end

  # Only what the list shows, as strings: a malformed entry is dropped.
  @fields ~w(id browser ip place linked_at last_seen_at)
  defp clean(sessions) when is_list(sessions) do
    for %{"id" => id} = s <- sessions, is_binary(id) do
      for {k, v} <- Map.take(s, @fields), is_binary(v), into: %{}, do: {k, v}
    end
  end

  defp clean(_other), do: []
end
