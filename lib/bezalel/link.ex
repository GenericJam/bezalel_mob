defmodule Bezalel.Link do
  @moduledoc """
  Linking computers to this phone, WhatsApp-style (decisions/2026-10-19-phone-link.md,
  bezalel_core's `Bezalel.Link.*` for the protocol): the website shows a
  QR code, the phone scans it (`Bezalel.LinkedComputersScreen`), claims
  the offer over its own connection to the website, shows which browser
  asked (IP, place) and links it when the user confirms. The phone is the
  account: its device key (`Bezalel.Link.Identity`).

  A supervisor: one `Bezalel.Link.Dialer` per website with linked
  computers (or a pairing under way), named in a registry, plus a registry
  of subscribers. `resume/0` (at start) dials the websites the phone has
  linked. What the phone remembers: `Bezalel.Link.Store`.

  Events for `subscribe/0`rs: `{:bezalel_link, origin, {:status, status}}`
  (`t:Bezalel.Link.Dialer.status/0`) and `{:bezalel_link, origin,
  {:sessions, list}}`.
  """
  use Supervisor

  alias Bezalel.Link.{Dialer, Identity, Pairing, Store, Wire}

  @dialers __MODULE__.Dialers
  @names __MODULE__.Names
  @events __MODULE__.Events

  @type offer :: %{
          origin: String.t(),
          pair_id: binary(),
          secret: binary(),
          server_fingerprint: String.t()
        }

  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Supervisor.init(
      [
        {Registry, keys: :unique, name: @names},
        {Registry, keys: :duplicate, name: @events},
        {DynamicSupervisor, name: @dialers, strategy: :one_for_one}
      ],
      strategy: :one_for_one
    )
  end

  @doc "Dials every website the phone has linked computers on (or log-outs to send)."
  @spec resume() :: :ok
  def resume do
    Enum.each(Store.to_dial(), &dialer/1)
  end

  @doc "The websites with linked computers: `[%{origin, host, sessions, status}]`."
  @spec linked() :: [map()]
  def linked do
    for {origin, entry} <- Store.all(), entry.sessions != [] do
      %{
        origin: origin,
        host: URI.parse(origin).host,
        sessions: entry.sessions,
        status: status(origin)
      }
    end
    |> Enum.sort_by(& &1.origin)
  end

  @doc "How many computers are linked, on every website."
  @spec count() :: non_neg_integer()
  def count, do: Store.all() |> Enum.map(fn {_, e} -> length(e.sessions) end) |> Enum.sum()

  @doc "The connection's status for `origin`; `:offline` when it isn't dialled."
  @spec status(String.t()) :: Dialer.status()
  def status(origin) do
    case whereis(origin) do
      nil -> :offline
      pid -> Dialer.status(pid)
    end
  catch
    :exit, _ -> :offline
  end

  @doc "Events about every website: see the moduledoc."
  @spec subscribe() :: :ok
  def subscribe do
    {:ok, _} = Registry.register(@events, :events, nil)
    :ok
  end

  @doc false
  def broadcast(origin, event) do
    Registry.dispatch(@events, :events, fn entries ->
      for {pid, _} <- entries, do: send(pid, {:bezalel_link, origin, event})
    end)
  end

  @doc "A scanned code's offer (`Bezalel.Link.Pairing.parse_qr/1`)."
  @spec parse(String.t()) :: {:ok, offer()} | {:error, :not_a_link}
  def parse(text), do: Pairing.parse_qr(text)

  @doc """
  Claims a scanned offer: dials its website (the server key must be the
  code's), proves the code was scanned by this phone (the claim HMAC, never
  the secret) and returns what the website knows of the browser that asked:
  `{:ok, %{"browser", "ip", "place", "requested_at"}}`, or `{:error,
  reason}`: the website's code (`"expired"`, `"claimed"`, `"bad_proof"`,
  `"rate_limited"`), `:key_changed` (the website's key isn't the code's,
  or not the one pinned while computers are linked), `:timeout`,
  `:disconnected`, `:secure_store` (the device key can't be read).
  Blocks: call it from `start_async`.
  """
  @spec claim(offer()) :: {:ok, map()} | {:error, term()}
  def claim(%{origin: origin, pair_id: pair_id, secret: secret, server_fingerprint: fp}) do
    pinned = Store.server_key(origin)
    other_key? = pinned != nil and not Pairing.server_key?(pinned, fp)

    if other_key? and Store.sessions(origin) != [] do
      {:error, :key_changed}
    else
      # A new key with nothing linked there (the website was set up
      # again): the code's key replaces the old pin once linked.
      if other_key?, do: Store.unpin(origin)

      with {:ok, {device_pub, _}} <- keypair(),
           {:ok, pid} <- pairing(origin, fp) do
        proof = Pairing.claim_proof(secret, pair_id, device_pub)
        fields = %{p: Wire.b64(pair_id), proof: Wire.b64(proof)}
        info(Dialer.request(pid, "pair.claim", fields, 20_000))
      end
    end
  end

  defp info({:ok, %{"op" => "pair.info"} = info}), do: {:ok, info}
  defp info({:ok, _other}), do: {:error, :bad_answer}
  defp info({:error, _} = error), do: error

  @doc """
  Links the browser that showed `offer`: `{:ok, session}` (the website's
  entry for it, also kept in `Bezalel.Link.Store`, with the server key
  pinned), or `{:error, reason}` as `claim/1`'s (`"expired"`: the browser
  left or the code changed). Blocks.
  """
  @spec approve(offer()) :: {:ok, map()} | {:error, term()}
  def approve(%{origin: origin, pair_id: pair_id}) do
    with {:ok, pid} <- running(origin),
         {:ok, %{"session" => session}} when is_map(session) <-
           Dialer.request(pid, "pair.approve", %{p: Wire.b64(pair_id)}, 20_000) do
      {:ok, session}
    else
      {:ok, _other} -> {:error, :bad_answer}
      {:error, _} = error -> error
    end
  end

  @doc "Refuses the browser that showed `offer`, and ends the pairing. Blocks."
  @spec reject(offer()) :: :ok
  def reject(%{origin: origin, pair_id: pair_id}) do
    with {:ok, pid} <- running(origin) do
      _ = Dialer.request(pid, "pair.reject", %{p: Wire.b64(pair_id)}, 10_000)
      Dialer.pairing(pid, nil)
    end

    :ok
  end

  @doc "Ends a pairing without answering (the screen was left)."
  @spec cancel(String.t()) :: :ok
  def cancel(origin) do
    with {:ok, pid} <- running(origin), do: Dialer.pairing(pid, nil)
    :ok
  catch
    :exit, _ -> :ok
  end

  @doc """
  Logs out a linked computer (`id`, or `"all"` on that website): gone from
  the list at once, sent now if connected, otherwise on the next connect.
  """
  @spec revoke(String.t(), String.t()) :: :ok
  def revoke(origin, id) do
    :ok = Store.queue_revoke(origin, id)
    broadcast(origin, {:sessions, Store.sessions(origin)})

    case dialer(origin) do
      {:ok, pid} -> Dialer.flush(pid)
      _ -> :ok
    end
  end

  @doc false
  def via(origin), do: {:via, Registry, {@names, origin}}

  @doc """
  Where the phone dials `origin`: `wss://<host>/link/phone`
  (`config :bezalel, Bezalel.Link, urls: %{origin => url}` overrides it, for tests).
  """
  @spec dial_url(String.t()) :: String.t()
  def dial_url(origin) do
    urls = Keyword.get(Application.get_env(:bezalel, __MODULE__, []), :urls, %{})

    Map.get_lazy(urls, origin, fn ->
      uri = URI.parse(origin)
      URI.to_string(%URI{scheme: "wss", host: uri.host, port: wss_port(uri), path: "/link/phone"})
    end)
  end

  defp wss_port(%URI{port: 443}), do: nil
  defp wss_port(%URI{port: port}), do: port

  defp whereis(origin) do
    case Registry.lookup(@names, origin) do
      [{pid, _}] -> if Process.alive?(pid), do: pid
      [] -> nil
    end
  end

  defp running(origin) do
    case whereis(origin) do
      nil -> {:error, :disconnected}
      pid -> {:ok, pid}
    end
  end

  # The origin's dialer, started if it isn't running.
  defp dialer(origin, opts \\ []) do
    case DynamicSupervisor.start_child(@dialers, {Dialer, [origin: origin] ++ opts}) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, _} = error -> error
    end
  end

  # The dialer in pairing mode for the code's server fingerprint. A dialer
  # that was just stopping can exit under the call: start one again.
  defp pairing(origin, fp, tries \\ 2) do
    with {:ok, pid} <- dialer(origin, expect: fp),
         :ok <- GenServer.call(pid, {:pairing, fp}, 30_000) do
      {:ok, pid}
    end
  catch
    :exit, _ when tries > 1 -> pairing(origin, fp, tries - 1)
    :exit, _ -> {:error, :disconnected}
  end

  defp keypair do
    case Identity.keypair() do
      {:ok, pair} -> {:ok, pair}
      {:error, _} -> {:error, :secure_store}
    end
  end
end
