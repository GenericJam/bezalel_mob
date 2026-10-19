defmodule Bezalel.Link.Dialer do
  @moduledoc """
  The phone's connection to one website (`wss://<host>/link/phone`), one
  process per origin under `Bezalel.Link`'s supervisor. Built on
  `Mint.WebSocket` with sloppy_joe's dial-out fixes (decisions/2026-10-19-phone-link.md):
  HTTP/1.1 only (Cloudflare's ALPN offers h2), no permessage-deflate (the
  iOS BEAM lacks its atom), the host resolved through the platform
  (`Mob.DNS.resolve/1`) before each connect, a WebSocket ping every 30 s
  (Cloudflare reaps idle sockets at about 100 s).

  The handshake and sealing are bezalel_core's `Bezalel.Link.Handshake`:
  the server's `hello` and the phone's `auth` are text frames; everything
  after is a binary frame sealed per connection (Cloudflare terminates
  TLS, so it never sees a frame's content). The server key is pinned per
  origin (`Bezalel.Link.Store`); while pairing, the key must match the QR
  code's fingerprint instead, and a mismatch on either is
  `{:error, :key_changed}`: the dialer stops trying (until the app comes
  back to the foreground) and the screen says so.

  Reconnects back off from 1 s to 60 s with jitter, reset by a `welcome`;
  coming to the foreground or back online connects at once. In the
  background the socket is closed after `:background_grace` (30 s) and
  nothing is dialled until the app is in the foreground again: iOS
  suspends the app within seconds anyway, Android freezes its network a
  minute later, and the website shows the phone offline either way.

  Requests (`request/4`) wait for the connection (up to their timeout) and
  are answered by the frame whose `"re"` is their id. The dialer keeps
  running while `Bezalel.Link.Store.dial?/1` holds or a pairing is under
  way, and stops (`:normal`) once the website lists no computer for it.
  Events go to `Bezalel.Link.subscribe/0`rs: `{:bezalel_link, origin,
  {:status, status}}` and `{:bezalel_link, origin, {:sessions, list}}`.
  """
  use GenServer, restart: :transient

  require Logger

  alias Bezalel.Link
  alias Bezalel.Link.{Handshake, Identity, Pairing, Store, Wire}

  @keepalive_ms 30_000
  @handshake_ms 15_000
  @backoff_min 1_000
  @backoff_max 60_000
  @background_grace 30_000
  # A pairing that never links anything gives up after this (the website
  # closes such a socket, 4408, after 3 minutes without pairing frames).
  @pairing_ms 180_000

  @type status :: :connecting | :connected | :offline | {:error, term()}

  # ── API ──

  def start_link(opts) do
    origin = Keyword.fetch!(opts, :origin)
    GenServer.start_link(__MODULE__, opts, name: Link.via(origin))
  end

  @doc """
  Sends `op` with `fields` and waits for its answer: `{:ok, frame}`, or
  `{:error, reason}`: the website's error code (`"expired"`, …) as a
  string, `:timeout`, `:key_changed`, `:stopped`.
  """
  @spec request(GenServer.server(), String.t(), map(), timeout()) ::
          {:ok, map()} | {:error, term()}
  def request(dialer, op, fields, timeout \\ 15_000) do
    GenServer.call(dialer, {:request, op, fields, timeout}, timeout + 1_000)
  catch
    :exit, _ -> {:error, :stopped}
  end

  @doc "The connection's status."
  @spec status(GenServer.server()) :: status()
  def status(dialer), do: GenServer.call(dialer, :status)

  @doc "Sends the queued log-outs now (when connected; otherwise on connect)."
  @spec flush(GenServer.server()) :: :ok
  def flush(dialer), do: GenServer.cast(dialer, :flush)

  @doc "Starts or ends pairing mode, `fingerprint` being the QR code's server fingerprint."
  @spec pairing(GenServer.server(), String.t() | nil) :: :ok
  def pairing(dialer, fingerprint), do: GenServer.call(dialer, {:pairing, fingerprint})

  # ── GenServer ──

  @impl true
  def init(opts) do
    origin = Keyword.fetch!(opts, :origin)
    _ = subscribe_device()

    state =
      %{
        origin: origin,
        url: Link.dial_url(origin),
        pinned: Store.server_key(origin),
        expect: opts[:expect],
        foreground: foreground?(),
        grace: Keyword.get(opts, :background_grace, config(:background_grace, @background_grace)),
        status: :offline,
        attempt: 0,
        next_id: 1,
        pending: %{},
        waiting: [],
        timers: %{}
      }
      |> fresh()
      |> start_pairing(opts[:expect])

    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state), do: {:noreply, connect(state)}

  @impl true
  def handle_call({:request, op, fields, timeout}, from, state) do
    ref = Process.send_after(self(), {:request_timeout, from}, timeout)
    request = %{from: from, op: op, fields: fields, timer: ref}

    case state.status do
      :connected ->
        {:noreply, send_request(state, request)}

      {:error, reason} ->
        Process.cancel_timer(ref)
        {:reply, {:error, reason}, state}

      _connecting_or_offline ->
        {:noreply, %{state | waiting: state.waiting ++ [request]} |> connect_if_idle()}
    end
  end

  def handle_call(:status, _from, state), do: {:reply, state.status, state}

  # A pairing for the QR code's server `fingerprint` (nil: ends it). The
  # pin is read again (`Bezalel.Link.pair/1` may have dropped one with
  # nothing linked); a connection already up must be to that key.
  def handle_call({:pairing, nil}, _from, state),
    do: {:reply, :ok, maybe_stop_check(cancel(%{state | expect: nil}, :pairing))}

  def handle_call({:pairing, fingerprint}, _from, state) do
    if state.server_key != nil and not Pairing.server_key?(state.server_key, fingerprint) do
      {:reply, {:error, :key_changed}, state}
    else
      state = start_pairing(%{state | pinned: Store.server_key(state.origin)}, fingerprint)

      state =
        if match?({:error, _}, state.status),
          do: connect(%{state | status: :offline, attempt: 0}),
          else: state

      {:reply, :ok, state}
    end
  end

  @impl true
  def handle_cast(:flush, state), do: {:noreply, state |> connect_if_idle() |> send_revokes()}

  @impl true
  def handle_info(:reconnect, state) do
    state = put_in(state.timers[:retry], nil)
    {:noreply, connect(state)}
  end

  def handle_info(:keepalive, %{ws: ws} = state) when ws != nil,
    do: {:noreply, state |> send_ws({:ping, ""}) |> schedule(:keepalive, @keepalive_ms)}

  def handle_info(:keepalive, state), do: {:noreply, state}

  def handle_info(:handshake_timeout, %{status: :connecting} = state) do
    Logger.info("[link] #{state.origin}: no welcome in time")
    {:noreply, retry(state)}
  end

  def handle_info(:handshake_timeout, state), do: {:noreply, state}

  def handle_info(:background_close, state) do
    Logger.info("[link] #{state.origin}: in the background, closing")
    state = put_in(state.timers[:background], nil)
    {:noreply, state |> close() |> set_status(:offline)}
  end

  def handle_info(:pairing_timeout, state) do
    state = put_in(state.timers[:pairing], nil)
    {:noreply, maybe_stop_check(%{state | expect: nil})}
  end

  def handle_info(:stop, state) do
    if stop?(state), do: {:stop, :normal, state}, else: {:noreply, state}
  end

  def handle_info({:request_timeout, from}, state) do
    GenServer.reply(from, {:error, :timeout})

    {:noreply,
     %{
       state
       | waiting: Enum.reject(state.waiting, &(&1.from == from)),
         pending: Map.reject(state.pending, fn {_id, r} -> r.from == from end)
     }}
  end

  def handle_info({:mob_device, event}, state)
      when event in [:did_become_active, :will_enter_foreground],
      do: {:noreply, foreground(state)}

  def handle_info({:mob_device, :did_enter_background}, state) do
    state = %{state | foreground: false}
    {:noreply, schedule(state, :background, state.grace, :background_close)}
  end

  def handle_info({:mob_device, :connectivity_changed, %{online: true}}, state),
    do: {:noreply, wake(state)}

  def handle_info({:mob_device, _event}, state), do: {:noreply, state}
  def handle_info({:mob_device, _event, _payload}, state), do: {:noreply, state}

  def handle_info(message, %{conn: conn} = state) when conn != nil do
    case Mint.WebSocket.stream(conn, message) do
      {:ok, conn, responses} ->
        {:noreply, Enum.reduce(responses, %{state | conn: conn}, &response/2)}

      {:error, conn, reason, _responses} ->
        Logger.info("[link] #{state.origin}: connection lost: #{inspect(reason)}")
        {:noreply, retry(%{state | conn: conn})}

      :unknown ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    for r <- state.waiting, do: reply(r, {:error, :stopped})
    close(state)
  end

  # ── connecting ──

  defp connect_if_idle(%{conn: nil, status: status} = state) when status != :connecting,
    do: state |> cancel(:retry) |> connect()

  defp connect_if_idle(state), do: state

  defp connect(%{conn: conn} = state) when conn != nil, do: state
  defp connect(%{foreground: false} = state), do: set_status(state, :offline)
  defp connect(%{status: {:error, _}} = state), do: state

  defp connect(state) do
    uri = URI.parse(state.url)
    {http, ws} = if uri.scheme == "wss", do: {:https, :wss}, else: {:http, :ws}
    _ = resolve(uri.host)

    tls =
      if http == :https,
        do: [transport_opts: [cacerts: :public_key.cacerts_get(), timeout: 10_000]],
        else: [transport_opts: [timeout: 10_000]]

    state = set_status(state, :connecting)

    with {:ok, conn} <- Mint.HTTP.connect(http, uri.host, uri.port, [protocols: [:http1]] ++ tls),
         {:ok, conn, ref} <-
           Mint.WebSocket.upgrade(ws, conn, uri.path || "/", [], extensions: []) do
      %{state | conn: conn, ref: ref}
      |> schedule(:handshake, @handshake_ms, :handshake_timeout)
    else
      {:error, reason} ->
        Logger.info("[link] #{state.origin}: can't connect: #{inspect(reason)}")
        retry(state)

      {:error, conn, reason} ->
        Logger.info("[link] #{state.origin}: upgrade refused: #{inspect(reason)}")
        retry(%{state | conn: conn})
    end
  end

  # Close, then try again after the backoff (not in the background, not
  # after a fatal error, not once there's nothing to dial for).
  defp retry(state) do
    state = close(state)

    cond do
      match?({:error, _}, state.status) ->
        state

      not state.foreground ->
        set_status(state, :offline)

      true ->
        delay = backoff(state.attempt)
        Logger.debug("[link] #{state.origin}: retry in #{delay} ms")

        %{state | attempt: state.attempt + 1}
        |> set_status(:offline)
        |> schedule(:retry, delay, :reconnect)
    end
  end

  @doc false
  # Jittered exponential backoff: 1 s, 2 s, 4 s … 60 s, each between half
  # and all of it.
  def backoff(attempt) do
    ceiling = min(@backoff_max, @backoff_min * Integer.pow(2, min(attempt, 6)))
    div(ceiling, 2) + :rand.uniform(div(ceiling, 2))
  end

  defp foreground(state) do
    state = cancel(%{state | foreground: true}, :background)

    case state.status do
      {:error, _} -> connect(%{state | status: :offline, attempt: 0})
      _ -> wake(state)
    end
  end

  # Skip the backoff's wait: connect now if not connected.
  defp wake(%{conn: nil, foreground: true} = state),
    do: state |> cancel(:retry) |> Map.put(:attempt, 0) |> connect()

  defp wake(state), do: state

  defp close(state) do
    if state.conn, do: Mint.HTTP.close(state.conn)

    state
    |> cancel(:keepalive)
    |> cancel(:handshake)
    |> fail_pending(:disconnected)
    |> fresh()
  end

  defp fresh(state),
    do:
      Map.merge(state, %{
        conn: nil,
        ref: nil,
        ws: nil,
        http_status: nil,
        headers: [],
        session: nil,
        server_key: nil,
        early: []
      })

  # ── Mint responses ──

  defp response({:status, ref, status}, %{ref: ref} = state), do: %{state | http_status: status}
  defp response({:headers, ref, headers}, %{ref: ref} = state), do: %{state | headers: headers}

  # The server speaks first, so its hello can come in the same packet as
  # the 101: Mint gives those bytes as the response's data before `:done`
  # (`early`); they are the first WebSocket frames.
  defp response({:done, ref}, %{ref: ref, ws: nil, conn: conn} = state) when conn != nil do
    case Mint.WebSocket.new(conn, ref, state.http_status, state.headers) do
      {:ok, conn, ws} ->
        early = state.early |> Enum.reverse() |> IO.iodata_to_binary()
        state = %{state | conn: conn, ws: ws, early: []}
        if early == "", do: state, else: decode(state, early)

      {:error, conn, reason} ->
        Logger.info("[link] #{state.origin}: upgrade refused: #{inspect(reason)}")
        retry(%{state | conn: conn})
    end
  end

  defp response({:data, ref, data}, %{ref: ref, ws: nil} = state),
    do: %{state | early: [data | state.early]}

  defp response({:data, ref, data}, %{ref: ref} = state), do: decode(state, data)

  defp response(_other, state), do: state

  defp decode(state, data) do
    case Mint.WebSocket.decode(state.ws, data) do
      {:ok, ws, frames} -> Enum.reduce(frames, %{state | ws: ws}, &ws_frame/2)
      {:error, _ws, reason} -> retry_after(state, {:bad_ws, reason})
    end
  end

  # A frame for a connection that has since closed is dropped.
  defp ws_frame(_frame, %{conn: nil} = state), do: state

  defp ws_frame({:ping, data}, state), do: send_ws(state, {:pong, data})

  defp ws_frame({:close, code, reason}, state) do
    Logger.info("[link] #{state.origin}: closed by the website: #{code} #{reason}")

    case code do
      # Too many connects: wait the longest.
      4429 ->
        retry(%{state | attempt: 6})

      # A pairing that went quiet with nothing linked: it's over.
      4408 ->
        %{state | expect: nil} |> cancel(:pairing) |> retry() |> maybe_stop_check()

      _ ->
        retry(state)
    end
  end

  defp ws_frame({:text, text}, %{session: nil} = state), do: hello(state, text)

  defp ws_frame({:binary, sealed}, %{session: session} = state) when session != nil,
    do: sealed(state, sealed)

  defp ws_frame(_other, state), do: state

  # ── handshake ──

  defp hello(state, text) do
    with {:ok, frame} <- Wire.decode(text),
         {:ok, device} <- Identity.keypair(),
         {:ok, auth, session, server_key} <-
           Handshake.auth(frame,
             device_key: device,
             origin: state.origin,
             pinned: state.pinned,
             app: app_label(),
             platform: platform_label()
           ),
         :ok <- expected(state, server_key) do
      %{state | session: session, server_key: server_key}
      |> send_ws({:text, Wire.encode(auth)})
    else
      {:error, :key_changed} -> fatal(state, :key_changed)
      {:error, reason} -> retry_after(state, reason)
    end
  end

  # While pairing with nothing pinned, the key must be the QR code's.
  defp expected(%{pinned: nil, expect: fp}, server_key) when is_binary(fp),
    do: if(Pairing.server_key?(server_key, fp), do: :ok, else: {:error, :key_changed})

  defp expected(_state, _server_key), do: :ok

  defp sealed(state, bytes) do
    with {:ok, plain, session} <- Handshake.open(state.session, bytes),
         {:ok, frame} <- Wire.decode(plain) do
      frame(%{state | session: session}, frame)
    else
      {:error, reason} -> retry_after(state, reason)
    end
  end

  defp retry_after(state, reason) do
    Logger.info("[link] #{state.origin}: #{inspect(reason)}")
    retry(state)
  end

  # The website's key no longer matches: say so and stop trying.
  defp fatal(state, reason) do
    Logger.warning("[link] #{state.origin}: #{inspect(reason)}")
    state = close(state)
    for r <- state.waiting, do: reply(r, {:error, reason})

    %{state | waiting: []}
    |> cancel(:retry)
    |> set_status({:error, reason})
  end

  # ── frames ──

  defp frame(state, %{"op" => "welcome"} = frame) do
    Logger.info("[link] #{state.origin}: linked as #{frame["fingerprint"]}")

    # The key is the QR code's (or the pinned one): hold it for this
    # dialer's reconnects; it is stored when a computer is linked.
    state =
      %{state | pinned: state.server_key, attempt: 0}
      |> cancel(:handshake)
      |> schedule(:keepalive, @keepalive_ms)
      |> set_status(:connected)
      |> sessions(frame["sessions"])
      |> send_revokes()

    waiting = state.waiting
    state = Enum.reduce(waiting, %{state | waiting: []}, &send_request(&2, &1))
    maybe_stop_check(state)
  end

  defp frame(state, %{"op" => "sessions.changed"} = frame),
    do: state |> sessions(frame["sessions"]) |> maybe_stop_check()

  defp frame(state, %{"re" => id} = frame) do
    case Map.pop(state.pending, id) do
      {nil, _} ->
        state

      {request, pending} ->
        state = %{state | pending: pending}
        answered(state, request, frame)
    end
  end

  defp frame(state, %{"id" => _} = request),
    do: send_frame(state, Wire.error(request, "unknown_op", request["op"]))

  defp frame(state, _frame), do: state

  # Done, or refused (the website no longer has that session): gone either way.
  defp answered(state, %{from: {:revoke, id}}, _frame) do
    Store.revoked(state.origin, id)
    maybe_stop_check(state)
  end

  defp answered(state, request, %{"op" => "error"} = frame) do
    reply(request, {:error, frame["code"] || "error"})
    state
  end

  defp answered(state, %{op: "pair.approve"} = request, %{"session" => session} = frame)
       when is_map(session) do
    Store.pin(state.origin, state.server_key)
    Store.add_session(state.origin, session)
    reply(request, {:ok, frame})
    state = %{state | expect: nil} |> cancel(:pairing)
    broadcast(state, {:sessions, Store.sessions(state.origin)})
    state
  end

  defp answered(state, request, frame) do
    reply(request, {:ok, frame})
    state
  end

  defp sessions(state, list) when is_list(list) do
    Store.put_sessions(state.origin, list)
    broadcast(state, {:sessions, Store.sessions(state.origin)})
    state
  end

  defp sessions(state, _missing), do: state

  defp send_revokes(%{status: :connected} = state) do
    already = for {_id, %{from: {:revoke, r}}} <- state.pending, do: r

    state.origin
    |> Store.revokes()
    |> Enum.reject(&(&1 in already))
    |> Enum.reduce(state, fn id, state ->
      send_request(state, %{from: {:revoke, id}, op: "sessions.revoke", fields: %{session: id}})
    end)
  end

  defp send_revokes(state), do: state

  defp send_request(state, request) do
    id = state.next_id
    state = %{state | next_id: id + 1, pending: Map.put(state.pending, id, request)}
    send_frame(state, Wire.frame(request.op, request.fields, id))
  end

  defp send_frame(%{session: session} = state, frame) when session != nil do
    {sealed, session} = Handshake.seal(session, Wire.encode(frame))
    send_ws(%{state | session: session}, {:binary, sealed})
  end

  defp send_frame(state, _frame), do: state

  defp send_ws(%{ws: ws, conn: conn, ref: ref} = state, frame) when ws != nil do
    with {:ok, ws, data} <- Mint.WebSocket.encode(ws, frame),
         {:ok, conn} <- Mint.WebSocket.stream_request_body(conn, ref, data) do
      %{state | ws: ws, conn: conn}
    else
      error -> retry_after(state, {:send_failed, error})
    end
  end

  defp send_ws(state, _frame), do: state

  # Requests in flight when the connection drops: their answer is lost.
  # The caller hears `:disconnected`; a queued log-out is sent again.
  defp fail_pending(state, reason) do
    for {_id, %{from: from} = r} <- state.pending,
        not match?({:revoke, _}, from),
        do: reply(r, {:error, reason})

    %{state | pending: %{}}
  end

  defp reply(%{from: {:revoke, _}}, _answer), do: :ok

  defp reply(%{from: from, timer: timer}, answer) do
    Process.cancel_timer(timer)
    GenServer.reply(from, answer)
  end

  # ── staying or going ──

  defp start_pairing(state, nil), do: state

  defp start_pairing(state, fingerprint) do
    %{state | expect: fingerprint}
    |> schedule(:pairing, @pairing_ms, :pairing_timeout)
  end

  # Nothing linked, nothing to send, not pairing, no one waiting: stop
  # (checked again when the message arrives).
  defp maybe_stop_check(state) do
    if stop?(state), do: send(self(), :stop)
    state
  end

  defp stop?(state) do
    state.expect == nil and state.waiting == [] and map_size(state.pending) == 0 and
      not Store.dial?(state.origin)
  end

  # ── helpers ──

  defp set_status(%{status: status} = state, status), do: state

  defp set_status(state, status) do
    broadcast(state, {:status, status})
    %{state | status: status}
  end

  defp broadcast(state, event), do: Link.broadcast(state.origin, event)

  defp schedule(state, name, ms, message \\ nil) do
    state = cancel(state, name)
    ref = Process.send_after(self(), message || name, ms)
    put_in(state.timers[name], ref)
  end

  defp cancel(state, name) do
    case state.timers[name] do
      nil ->
        state

      ref ->
        Process.cancel_timer(ref)
        put_in(state.timers[name], nil)
    end
  end

  defp config(key, default),
    do: Keyword.get(Application.get_env(:bezalel, Bezalel.Link, []), key, default)

  defp subscribe_device do
    Mob.Device.subscribe([:app, :network])
  catch
    :exit, _ -> :ok
  end

  # The native layer is loaded at boot on a phone; a host run has none.
  defp native?, do: :erlang.module_loaded(:mob_nif)

  defp foreground?, do: not native?() or Mob.Device.foreground?()

  defp resolve(host), do: if(native?(), do: Mob.DNS.resolve(host))

  defp app_label, do: "Bezalel " <> (native(&Mob.Device.app_version/0) || "dev")

  # "Android", "iOS 27.0 · iPhone": what the platform gives (Android's
  # os_version is empty and its model "Android" on some builds).
  defp platform_label do
    platform =
      case native?() && :mob_nif.platform() do
        :ios -> "iOS"
        :android -> "Android"
        _ -> "unknown"
      end

    system = Enum.join(Enum.reject([platform, native(&Mob.Device.os_version/0)], &is_nil/1), " ")

    case native(&Mob.Device.model/0) do
      model when model in [nil, platform] -> system
      model -> String.slice("#{system} · #{model}", 0, 200)
    end
  end

  defp native(fun) do
    with true <- native?(),
         text when is_binary(text) and text != "" <- fun.() do
      text
    else
      _ -> nil
    end
  end
end
