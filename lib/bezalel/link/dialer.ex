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
  running while `Bezalel.Link.Store.dial?/1` holds (linked computers,
  log-outs to send, or a work parcel announced by `welcome`'s `work_count`
  and not yet finished with `work.done`, kept across restarts), a pairing
  is under way or the website has sealed mail for the phone
  (`mailbox_count`), and stops (`:normal`) once none does. A work parcel's
  records (`work.envelope`) are opened with
  `Bezalel.Link.Mailbox.open_work/2` and served like the website's live
  requests, each answered `ack` with whether it is now durable here. With
  no linked computer, nothing of the phone's (credentials, its mailbox
  key, index, preferences) is sent. The phone's turns and the websites'
  holds are `Bezalel.Link.Turns`': a dialer hears of a turn by message and
  sends `conv.hold` for every turn at each `welcome`.
  Events go to `Bezalel.Link.subscribe/0`rs: `{:bezalel_link, origin,
  {:status, status}}` and `{:bezalel_link, origin, {:sessions, list}}`.
  """
  use GenServer, restart: :transient

  require Logger

  alias Bezalel.Link

  alias Bezalel.Link.{
    Artifacts,
    Creds,
    Handshake,
    Identity,
    Index,
    Mailbox,
    Pairing,
    Serve,
    Shapes,
    Store,
    Transcripts,
    Turns,
    Wire
  }

  @keepalive_ms 30_000
  @handshake_ms 15_000
  @stable_ms 10_000
  @backoff_min 1_000
  @backoff_max 60_000
  @background_grace 30_000
  @max_upgrade_body 16 * 1_024
  @max_inbound_bytes 1_048_576
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

  @doc "Broadcast locally changed model and study preferences to connected computers."
  def preferences_changed do
    if Process.whereis(Link.Dialers) do
      for {_, pid, _, _} <- DynamicSupervisor.which_children(Link.Dialers),
          do: send(pid, :link_preferences_changed)
    end

    :ok
  end

  @doc "Starts or ends pairing mode, `fingerprint` being the QR code's server fingerprint."
  @spec pairing(GenServer.server(), String.t() | nil) :: :ok
  def pairing(dialer, fingerprint), do: GenServer.call(dialer, {:pairing, fingerprint})

  # ── GenServer ──

  @impl true
  def init(opts) do
    Process.flag(:sensitive, true)
    origin = Keyword.fetch!(opts, :origin)
    _ = subscribe_device()
    :ok = Creds.subscribe()

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
        held: MapSet.new(),
        conflicts: %{},
        materials: %{},
        artifacts: %{},
        timers: %{},
        capture: nil
      }
      |> fresh()
      |> start_pairing(opts[:expect])

    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state), do: {:noreply, connect(state)}

  @impl true
  def handle_call({:request, op, fields, timeout}, from, state) do
    token = make_ref()
    ref = Process.send_after(self(), {:request_timeout, from, token}, timeout)
    request = %{from: from, op: op, fields: fields, timer: ref, timeout_token: token}

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
  def handle_info({:reconnect, token}, state) do
    case take_timer(state, :retry, token) do
      {:ok, state} -> {:noreply, connect(state)}
      :stale -> {:noreply, state}
    end
  end

  def handle_info({:keepalive, token}, state) do
    case take_timer(state, :keepalive, token) do
      {:ok, %{ws: ws} = state} when ws != nil ->
        {:noreply, state |> send_ws({:ping, ""}) |> schedule(:keepalive, @keepalive_ms)}

      {:ok, state} ->
        {:noreply, state}

      :stale ->
        {:noreply, state}
    end
  end

  def handle_info({:handshake_timeout, token}, state) do
    case take_timer(state, :handshake, token) do
      {:ok, %{status: :connecting} = state} ->
        Logger.info("[link] #{state.origin}: no welcome in time")
        {:noreply, retry(state)}

      {:ok, state} ->
        {:noreply, state}

      :stale ->
        {:noreply, state}
    end
  end

  def handle_info({:stable, token}, state) do
    case take_timer(state, :stable, token) do
      {:ok, %{status: :connected} = state} -> {:noreply, %{state | attempt: 0}}
      {:ok, state} -> {:noreply, state}
      :stale -> {:noreply, state}
    end
  end

  def handle_info({:background_close, token}, state) do
    case take_timer(state, :background, token) do
      {:ok, state} ->
        Logger.info("[link] #{state.origin}: in the background, closing")
        {:noreply, state |> close() |> set_status(:offline)}

      :stale ->
        {:noreply, state}
    end
  end

  def handle_info({:pairing_timeout, token}, state) do
    case take_timer(state, :pairing, token) do
      {:ok, state} -> {:noreply, maybe_stop_check(%{state | expect: nil})}
      :stale -> {:noreply, state}
    end
  end

  def handle_info(:stop, state) do
    if stop?(state), do: {:stop, :normal, state}, else: {:noreply, state}
  end

  def handle_info({:request_timeout, from, token}, state) do
    waiting? = Enum.any?(state.waiting, &request?(&1, from, token))
    pending? = Enum.any?(state.pending, fn {_id, request} -> request?(request, from, token) end)

    if waiting? or pending? do
      GenServer.reply(from, {:error, :timeout})

      state = %{
        state
        | waiting: Enum.reject(state.waiting, &request?(&1, from, token)),
          pending:
            Map.reject(state.pending, fn {_id, request} -> request?(request, from, token) end)
      }

      {:noreply, maybe_stop_check(state)}
    else
      {:noreply, state}
    end
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

  def handle_info({:link_credentials_changed, provider}, state) do
    state =
      if state.status == :connected and state.synced and state.credential_ready,
        do: send_credential(state, provider),
        else: state

    {:noreply, state}
  end

  def handle_info(:link_preferences_changed, state) do
    state =
      if shares?(state),
        do: send_frame(state, Wire.frame("prefs.snapshot", Bezalel.Settings.link_preferences())),
        else: state

    {:noreply, state}
  end

  def handle_info({:link_index_changed, id}, state) do
    state =
      case shares?(state) && Index.entry(id) do
        entry when is_map(entry) -> send_frame(state, Wire.frame("index.upsert", %{entry: entry}))
        _ -> state
      end

    {:noreply, state}
  end

  def handle_info({:link_index_removed, uid}, state) do
    state =
      if shares?(state),
        do: send_frame(state, Wire.frame("index.remove", %{uid: uid})),
        else: state

    {:noreply, state}
  end

  def handle_info({:link_credential_refreshed, connection, request, result}, state) do
    state =
      if state.status == :connected and state.synced and state.credential_ready and
           state.connection == connection do
        case result do
          {:ok, provider} -> send_credential(state, provider, request)
          {:error, _} -> refresh_error(state, request)
        end
      else
        state
      end

    {:noreply, state}
  end

  def handle_info({:mob_device, _event, _payload}, state), do: {:noreply, state}

  # A phone turn started or ended (`Bezalel.Link.Turns`): the website hears
  # it on this connection, if it shares in the phone's conversations.
  def handle_info({:phone_turn, uid, :start}, state) do
    state =
      if state.status == :connected and Store.sessions(state.origin) != [] and
           Turns.phone?(uid),
         do: announce_turn(state, uid),
         else: state

    {:noreply, state}
  end

  def handle_info({:phone_turn, uid, :finish}, state) do
    state =
      if MapSet.member?(state.announced, uid) do
        state = %{state | announced: MapSet.delete(state.announced, uid)}

        if state.status == :connected and Store.sessions(state.origin) != [],
          do: send_frame(state, Wire.frame("conv.release", %{uid: uid})),
          else: state
      else
        state
      end

    {:noreply, state}
  end

  def handle_info(message, %{conn: conn} = state) when conn != nil do
    case Mint.WebSocket.stream(conn, message) do
      {:ok, conn, responses} ->
        {:noreply, Enum.reduce(responses, %{state | conn: conn}, &response/2)}

      {:error, conn, reason, responses} ->
        Logger.info("[link] #{state.origin}: connection lost: #{inspect(reason)}")
        state = Enum.reduce(responses, %{state | conn: conn}, &response/2)
        {:noreply, if(state.conn, do: retry(state), else: state)}

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
    :ok = Turns.web_release_all()
    for uid <- state.held, do: broadcast(state, {:conversation_hold, uid, false})
    for {_uid, staged} <- state.conflicts, do: File.rm(staged.path)
    for {_sha, staged} <- state.materials, do: File.rm(staged.path)
    for {_key, staged} <- state.artifacts, do: File.rm(staged.path)

    state
    |> cancel(:keepalive)
    |> cancel(:handshake)
    |> cancel(:stable)
    |> fail_pending(:disconnected)
    |> Map.put(:held, MapSet.new())
    |> Map.put(:conflicts, %{})
    |> Map.put(:materials, %{})
    |> Map.put(:artifacts, %{})
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
        connection: nil,
        device_key: nil,
        account_id: nil,
        mailbox_pending: false,
        synced: false,
        credential_ready: false,
        early: [],
        early_bytes: 0,
        # The phone turns this connection was told of (`conv.hold`).
        announced: MapSet.new()
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
        state = %{state | conn: conn, ws: ws, early: [], early_bytes: 0}
        if early == "", do: state, else: decode(state, early)

      {:error, conn, reason} ->
        Logger.info("[link] #{state.origin}: upgrade refused: #{inspect(reason)}")
        retry(%{state | conn: conn})
    end
  end

  defp response({:data, ref, data}, %{ref: ref, ws: nil} = state) do
    bytes = state.early_bytes + byte_size(data)

    if bytes <= @max_upgrade_body do
      %{state | early: [data | state.early], early_bytes: bytes}
    else
      retry_after(state, :upgrade_body_too_large)
    end
  end

  defp response({:data, ref, data}, %{ref: ref} = state), do: decode(state, data)

  defp response(_other, state), do: state

  defp decode(state, data) do
    if websocket_pending_bytes(state.ws) + byte_size(data) > @max_inbound_bytes do
      retry_after(state, :frame_too_large)
    else
      case Mint.WebSocket.decode(state.ws, data) do
        {:ok, ws, frames} ->
          decoded_frames(%{state | ws: ws}, frames)

        {:error, _ws, reason} ->
          retry_after(state, {:bad_ws, reason})
      end
    end
  end

  defp decoded_frames(state, frames) do
    if websocket_pending_bytes(state.ws) > @max_inbound_bytes do
      retry_after(state, :frame_too_large)
    else
      reduce_frames(frames, state)
    end
  end

  # A frame for a connection that has since closed is dropped.
  defp ws_frame(_frame, %{conn: nil} = state), do: state

  defp ws_frame({:error, reason}, state), do: retry_after(state, {:bad_ws, reason})

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
      %{state | session: session, server_key: server_key, device_key: elem(device, 0)}
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

  defp frame(
         state,
         %{
           "op" => "welcome",
           "fingerprint" => fingerprint,
           "account_id" => account_id,
           "sessions" => sessions
         } = welcome
       )
       when is_binary(fingerprint) and is_binary(account_id) and is_list(sessions) do
    if state.device_key != nil and fingerprint == Pairing.fingerprint(state.device_key) and
         account_id == Pairing.account_id(state.device_key) do
      case waiting_counts(welcome) do
        {:ok, mailbox, work} ->
          Store.put_work(state.origin, work > 0)

          state
          |> Map.put(:account_id, account_id)
          |> Map.put(:mailbox_pending, mailbox > 0)
          |> welcomed(sessions)

        :error ->
          retry_after(state, :bad_welcome)
      end
    else
      fatal(state, :wrong_account)
    end
  end

  defp frame(state, %{"op" => "welcome"}), do: retry_after(state, :bad_welcome)

  # The server sends its queued rotations before cred.sync. No credential
  # leaves the phone before welcome and this barrier, even on reconnect.
  # With no computer linked (the phone is here only for a log-out, sealed
  # mail or a work parcel) nothing of the phone's is sent at all.
  defp frame(%{status: :connected, credential_ready: true} = state, %{"op" => "cred.sync"}) do
    state = %{state | synced: true, mailbox_pending: false}

    if Store.sessions(state.origin) == [],
      do: state |> send_revokes() |> maybe_stop_check(),
      else: share_all(state)
  end

  defp frame(
         %{status: :connected, credential_ready: true, account_id: id} = state,
         %{"op" => "cred.envelope"} = request
       ) do
    with {:ok, payload} <- Mailbox.open(id, request),
         {:ok, provider, result} <- apply_envelope(payload, request) do
      credential_result(state, request, provider, result)
    else
      _ -> maybe_error(state, request)
    end
  end

  defp frame(
         %{status: :connected, credential_ready: true} = state,
         %{
           "op" => op,
           "provider" => provider,
           "creds" => creds,
           "updated_at" => at
         } = request
       )
       when op in ["cred.set", "cred.rotated"] do
    case Creds.provider(provider) do
      {:ok, known} ->
        credential_result(state, request, known, Creds.apply_set(provider, creds, at))

      _ ->
        maybe_error(state, request)
    end
  end

  defp frame(
         %{status: :connected, credential_ready: true} = state,
         %{
           "op" => "cred.delete",
           "provider" => provider,
           "updated_at" => at
         } = request
       ) do
    case Creds.provider(provider) do
      {:ok, known} -> credential_result(state, request, known, Creds.apply_delete(provider, at))
      _ -> maybe_error(state, request)
    end
  end

  # A refresh can rotate the sign-in's token: only after the sync barrier,
  # and only for an account with a linked computer.
  defp frame(
         %{status: :connected, credential_ready: true} = state,
         %{
           "op" => "cred.refresh",
           "provider" => name
         } = request
       ) do
    with true <- state.synced and Store.sessions(state.origin) != [],
         {:ok, provider} <- Creds.provider(name) do
      owner = self()
      connection = state.connection
      Task.start(fn -> refresh_phone_credential(owner, connection, request, provider) end)
      state
    else
      false -> forbidden(state, request)
      {:error, _} -> maybe_error(state, request)
    end
  end

  defp frame(state, %{"op" => "cred." <> _}), do: state

  defp frame(%{status: status} = state, _frame) when status != :connected, do: state

  defp frame(state, %{"op" => "sessions.changed", "sessions" => sessions})
       when is_list(sessions),
       do: state |> sessions(sessions) |> maybe_stop_check()

  defp frame(state, %{"op" => "sessions.changed"}),
    do: retry_after(state, :bad_sessions)

  # A record of a work parcel: web work the website sealed to this phone
  # when the account's last session expired. The envelope is its
  # authorization (no linked session is needed): its inner request is
  # served exactly as a live one, its answer captured and turned into an
  # `ack` saying whether the item is now durable here (applied, nothing of
  # it left staged) or an error the website retries on the next connect.
  defp frame(%{account_id: account_id} = state, %{"op" => "work.envelope", "id" => _} = request)
       when is_binary(account_id) do
    Store.put_work(state.origin, true)

    case Mailbox.open_work(account_id, request) do
      {:ok, inner} ->
        state = serve(%{state | capture: {inner["id"], nil}}, inner)
        {_id, answer} = state.capture
        send_frame(%{state | capture: nil}, work_answer(state, request, inner, answer))

      {:error, _} ->
        send_frame(state, Wire.error(request, "bad_envelope"))
    end
  end

  defp frame(state, %{"op" => "work.done"}) do
    Store.put_work(state.origin, false)
    state |> readiness() |> maybe_stop_check()
  end

  defp frame(state, %{"op" => "conv.pull", "id" => id} = request) do
    cond do
      not Serve.valid_request_id?(id) ->
        send_frame(state, Wire.error(request, "bad_request"))

      not state.synced or Store.sessions(state.origin) == [] ->
        send_frame(state, Wire.error(request, "forbidden"))

      true ->
        case Transcripts.pull(request["uid"], request["from"]) do
          {:ok, chunk} -> send_frame(state, Wire.reply(request, "conv.data", chunk))
          {:error, code} -> send_frame(state, Wire.error(request, Atom.to_string(code)))
        end
    end
  end

  defp frame(state, %{"op" => "conv.pull"}), do: state

  defp frame(state, %{"op" => op, "id" => id} = request)
       when op in [
              "mat.get",
              "mat.put",
              "mat.delete",
              "artifact.list",
              "artifact.get",
              "artifact.put",
              "prefs.set",
              "conv.create",
              "conv.append",
              "conv.meta",
              "conv.delete",
              "conv.hold",
              "conv.release"
            ] do
    cond do
      not Serve.valid_request_id?(id) ->
        send_frame(state, Wire.error(request, "bad_request"))

      not state.synced or Store.sessions(state.origin) == [] ->
        send_frame(state, Wire.error(request, "forbidden"))

      true ->
        serve(state, request)
    end
  end

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

  defp serve(state, %{"op" => "artifact.list", "uid" => uid} = request) do
    if Bezalel.Library.conversations_by_session([uid]) != [] do
      case Artifacts.list(uid) do
        {:ok, entries} ->
          send_frame(state, Wire.reply(request, "artifact.index", %{uid: uid, entries: entries}))

        {:error, code} ->
          send_frame(state, Wire.error(request, Atom.to_string(code)))
      end
    else
      send_frame(state, Wire.error(request, "not_found"))
    end
  end

  defp serve(state, %{"op" => "artifact.get", "uid" => uid, "name" => name} = request) do
    if Bezalel.Library.conversations_by_session([uid]) != [] do
      case Artifacts.chunk(uid, name, request["from"]) do
        {:ok, chunk} -> send_frame(state, Wire.reply(request, "artifact.data", chunk))
        {:error, code} -> send_frame(state, Wire.error(request, Atom.to_string(code)))
      end
    else
      send_frame(state, Wire.error(request, "not_found"))
    end
  end

  # Like the other writes: only into a conversation on the shelf, and not
  # while the phone answers in it (its loop writes artifacts too).
  defp serve(state, %{"op" => "artifact.put", "uid" => uid, "name" => name} = request)
       when is_binary(uid) and is_binary(name) do
    cond do
      Turns.phone?(uid) ->
        artifact_refused(state, request, {uid, name}, "held_by_phone")

      Bezalel.Library.conversations_by_session([uid]) == [] ->
        artifact_refused(state, request, {uid, name}, "not_found")

      true ->
        put_artifact(state, request, uid, name)
    end
  end

  defp serve(state, %{"op" => "mat.get"} = request) do
    case Serve.material(request["sha"], request["from"]) do
      {:ok, chunk} -> send_frame(state, Wire.reply(request, "mat.data", chunk))
      {:error, code} -> send_frame(state, Wire.error(request, Atom.to_string(code)))
    end
  end

  defp serve(state, %{"op" => "mat.put", "record" => %{"id" => sha}} = request) do
    staged = Map.get(state.materials, sha)

    case Serve.put_material(request, staged) do
      {:more, stage, next} ->
        state
        |> Map.put(:materials, Map.put(state.materials, sha, stage))
        |> send_frame(Wire.reply(request, "ack", %{sha: sha, size: next}))

      {:ok, _material, size} ->
        if staged, do: File.rm(staged.path)

        state
        |> Map.put(:materials, Map.delete(state.materials, sha))
        |> send_frame(Wire.reply(request, "ack", %{sha: sha, size: size}))

      {:error, code} ->
        if staged, do: File.rm(staged.path)

        state
        |> Map.put(:materials, Map.delete(state.materials, sha))
        |> send_frame(Wire.error(request, Atom.to_string(code)))
    end
  end

  defp serve(state, %{"op" => "mat.put"} = request),
    do: send_frame(state, Wire.error(request, "bad_request"))

  defp serve(state, %{"op" => "mat.delete"} = request) do
    case Serve.delete_material(request) do
      {:ok, sha} ->
        if staged = state.materials[sha], do: File.rm(staged.path)

        state
        |> Map.put(:materials, Map.delete(state.materials, sha))
        |> send_frame(Wire.reply(request, "ack", %{sha: sha}))

      {:error, code} ->
        send_frame(state, Wire.error(request, Atom.to_string(code)))
    end
  end

  defp serve(state, %{"op" => "prefs.set"} = request) do
    case Serve.preferences(request) do
      {:ok, changed?} ->
        snapshot = Bezalel.Settings.link_preferences()

        state =
          if changed?,
            do: state,
            else: send_frame(state, Wire.frame("prefs.snapshot", snapshot))

        send_frame(state, Wire.reply(request, "ack", %{updated_at: snapshot["updated_at"]}))

      {:error, code} ->
        send_frame(state, Wire.error(request, Atom.to_string(code)))
    end
  end

  defp serve(state, %{"op" => "conv.create"} = request) do
    case Serve.create(request) do
      {:ok, conversation, changed?} ->
        if changed?, do: broadcast(state, {:conversation_changed, conversation.id})
        send_frame(state, Wire.reply(request, "ack", %{uid: conversation.session_id}))

      {:error, code} ->
        send_frame(state, Wire.error(request, Atom.to_string(code)))
    end
  end

  defp serve(state, %{"op" => "conv.append", "uid" => uid} = request) do
    staged = Map.get(state.conflicts, uid)
    total = request["total"]
    result = if staged, do: {:error, :conflict}, else: Serve.append(request)

    case result do
      {:ok, conversation, size, changed?} ->
        if changed?, do: broadcast(state, {:conversation_changed, conversation.id})
        send_frame(state, Wire.reply(request, "ack", %{uid: uid, size: size}))

      # A divergent tail (the website sends the transcript's `total`).
      {:error, :conflict} when is_integer(total) ->
        diverged(state, request, uid, staged)

      {:error, code} ->
        send_frame(state, Wire.error(request, Atom.to_string(code)))
    end
  end

  defp serve(state, %{"op" => "conv.meta"} = request) do
    case Serve.meta(request) do
      {:ok, id, changed?} ->
        if changed?, do: broadcast(state, {:conversation_changed, id})

        state =
          case Index.entry(id) do
            nil -> state
            entry -> send_frame(state, Wire.frame("index.upsert", %{entry: entry}))
          end

        send_frame(state, Wire.reply(request, "ack", %{uid: request["uid"]}))

      {:error, code} ->
        send_frame(state, Wire.error(request, Atom.to_string(code)))
    end
  end

  # The screen hears of a purge so it lets go of the conversation's loop
  # and stops showing it.
  defp serve(state, %{"op" => "conv.delete"} = request) do
    uid = request["uid"]

    case Serve.delete(request) do
      {:ok, id} ->
        if id, do: broadcast(state, {:conversation_removed, id})
        if staged = state.conflicts[uid], do: File.rm(staged.path)
        state = %{state | conflicts: Map.delete(state.conflicts, uid)}
        state = send_frame(state, Wire.frame("index.remove", %{uid: uid}))
        send_frame(state, Wire.reply(request, "ack", %{uid: uid}))

      {:error, code} ->
        send_frame(state, Wire.error(request, Atom.to_string(code)))
    end
  end

  defp serve(state, %{"op" => "conv.hold", "uid" => uid} = request)
       when is_binary(uid) do
    if Shapes.uid?(uid),
      do: hold(state, request, uid),
      else: send_frame(state, Wire.error(request, "bad_request"))
  end

  defp serve(state, %{"op" => "conv.release", "uid" => uid} = request)
       when is_binary(uid) do
    if Shapes.uid?(uid) do
      :ok = Turns.web_release(uid)
      if MapSet.member?(state.held, uid), do: broadcast(state, {:conversation_hold, uid, false})

      state
      |> Map.put(:held, MapSet.delete(state.held, uid))
      |> send_frame(Wire.reply(request, "ack", %{uid: uid}))
    else
      send_frame(state, Wire.error(request, "bad_request"))
    end
  end

  defp serve(state, request), do: send_frame(state, Wire.error(request, "bad_request"))

  defp diverged(state, request, uid, staged) do
    case Serve.conflict(request, staged) do
      {:more, stage, next} ->
        state
        |> Map.put(:conflicts, Map.put(state.conflicts, uid, stage))
        |> send_frame(Wire.reply(request, "conv.conflict", %{uid: uid, size: next}))

      {:reset, size} ->
        if staged, do: File.rm(staged.path)
        state = %{state | conflicts: Map.delete(state.conflicts, uid)}
        broadcast(state, {:conversation_changed, conversation_id(uid)})
        send_frame(state, Wire.reply(request, "conv.reset", %{uid: uid, size: size}))

      {:error, code} ->
        if staged, do: File.rm(staged.path)

        state
        |> Map.put(:conflicts, Map.delete(state.conflicts, uid))
        |> send_frame(Wire.error(request, Atom.to_string(code)))
    end
  end

  defp hold(state, request, uid) do
    case Turns.web_hold(uid, state.origin) do
      :ok ->
        unless MapSet.member?(state.held, uid),
          do: broadcast(state, {:conversation_hold, uid, true})

        state
        |> Map.put(:held, MapSet.put(state.held, uid))
        |> send_frame(Wire.reply(request, "ack", %{uid: uid}))

      {:error, :held_by_phone} ->
        send_frame(state, Wire.error(request, "held_by_phone"))
    end
  end

  defp artifact_refused(state, request, key, code) do
    if staged = state.artifacts[key], do: File.rm(staged.path)

    state
    |> Map.put(:artifacts, Map.delete(state.artifacts, key))
    |> send_frame(Wire.error(request, code))
  end

  defp put_artifact(state, request, uid, name) do
    key = {uid, name}
    staged = state.artifacts[key]

    case Artifacts.put(request, staged) do
      {:more, stage, next} ->
        state
        |> Map.put(:artifacts, Map.put(state.artifacts, key, stage))
        |> send_frame(
          Wire.reply(request, "ack", %{uid: uid, name: name, sha: request["sha"], size: next})
        )

      {:ok, total} ->
        state
        |> Map.put(:artifacts, Map.delete(state.artifacts, key))
        |> send_frame(
          Wire.reply(request, "ack", %{uid: uid, name: name, sha: request["sha"], size: total})
        )

      {:error, code} ->
        if staged, do: File.rm(staged.path)

        state
        |> Map.put(:artifacts, Map.delete(state.artifacts, key))
        |> send_frame(Wire.error(request, Atom.to_string(code)))
    end
  end

  defp announce_turn(state, uid) do
    if MapSet.member?(state.announced, uid) do
      state
    else
      state
      |> Map.put(:announced, MapSet.put(state.announced, uid))
      |> send_frame(Wire.frame("conv.hold", %{uid: uid}))
    end
  end

  defp conversation_id(uid) do
    case Bezalel.Library.conversations_by_session([uid]) do
      [conversation] -> conversation.id
      _ -> nil
    end
  end

  defp work_answer(_state, request, _inner, %{"op" => "error", "code" => code}),
    do: Wire.error(request, code)

  defp work_answer(state, request, inner, %{"op" => _}),
    do: Wire.reply(request, "ack", %{durable: not staged?(state, inner)})

  defp work_answer(_state, request, _inner, nil), do: Wire.error(request, "bad_request")

  # Whether part of this item is still only staged (an upload or a
  # divergent tail waiting for more chunks).
  defp staged?(state, %{"op" => "mat.put", "record" => %{"id" => sha}}),
    do: Map.has_key?(state.materials, sha)

  defp staged?(state, %{"op" => "artifact.put", "uid" => uid, "name" => name}),
    do: Map.has_key?(state.artifacts, {uid, name})

  defp staged?(state, %{"op" => "conv.append", "uid" => uid}),
    do: Map.has_key?(state.conflicts, uid)

  defp staged?(_state, _inner), do: false

  # What the website holds for the phone: sealed credential changes (at
  # most one per provider) and work-parcel records not yet acknowledged.
  defp waiting_counts(welcome) do
    mailbox = Map.get(welcome, "mailbox_count", 0)
    work = Map.get(welcome, "work_count", 0)

    if is_integer(mailbox) and mailbox in 0..length(Rho.Auth.providers()) and is_integer(work) and
         work in 0..Mailbox.max_records(),
       do: {:ok, mailbox, work},
       else: :error
  end

  defp welcomed(state, sessions) do
    Logger.info("[link] #{state.origin}: authenticated welcome")

    # Reset reconnect backoff only after a stable connection. A peer that
    # sends one valid welcome and immediately closes must not hold the phone
    # in a tight one-second reconnect loop.
    state =
      %{state | pinned: state.server_key}
      |> cancel(:handshake)
      |> schedule(:stable, @stable_ms)
      |> schedule(:keepalive, @keepalive_ms)
      |> set_status(:connected)
      |> Map.put(:connection, make_ref())
      |> sessions(sessions)

    state =
      if Store.sessions(state.origin) != [] do
        Enum.reduce(Turns.phone_turns(), state, &announce_turn(&2, &1))
      else
        state
      end

    waiting = state.waiting
    state = Enum.reduce(waiting, %{state | waiting: []}, &send_request(&2, &1))
    maybe_stop_check(state)
  end

  defp refresh_phone_credential(owner, connection, request, provider) do
    Process.flag(:sensitive, true)

    result =
      case Rho.Auth.credential(provider) do
        {:ok, _} -> {:ok, provider}
        {:error, _} -> {:error, :refresh_failed}
      end

    send(owner, {:link_credential_refreshed, connection, request, result})
  end

  # A queued revocation is durable until the website positively
  # acknowledges it. Errors and malformed replies leave it queued.
  defp answered(state, %{from: {:revoke, id}}, %{"op" => "ack"}) do
    Store.revoked(state.origin, id)
    maybe_stop_check(state)
  end

  defp answered(state, %{from: {:revoke, _id}}, _frame), do: state

  defp answered(state, request, %{"op" => "error"} = frame) do
    reply(request, {:error, frame["code"] || "error"})
    state
  end

  defp answered(
         state,
         %{op: "pair.approve"} = request,
         %{"session" => %{"id" => id} = session} = frame
       )
       when is_binary(id) do
    previously_linked? = Store.sessions(state.origin) != []
    Store.pin(state.origin, state.server_key)
    Store.add_session(state.origin, session)
    reply(request, {:ok, frame})
    state = %{state | expect: nil, credential_ready: true} |> cancel(:pairing)
    broadcast(state, {:sessions, Store.sessions(state.origin)})

    if previously_linked? do
      state
    else
      Enum.reduce(Turns.phone_turns(), state, &announce_turn(&2, &1))
    end
  end

  defp answered(state, request, frame) do
    reply(request, {:ok, frame})
    state
  end

  defp sessions(state, list) when is_list(list) do
    Store.put_sessions(state.origin, list)
    broadcast(state, {:sessions, Store.sessions(state.origin)})
    readiness(state)
  end

  # Credentials move only while something links the phone to this website:
  # a computer, a log-out to send, or mail or work waiting for it.
  defp readiness(state) do
    ready? =
      Store.server_key(state.origin) != nil and
        (Store.dial?(state.origin) or state.mailbox_pending)

    %{state | credential_ready: ready?, synced: state.synced and ready?}
  end

  # Whether the phone's own changes go to this website now: only to an
  # account with a linked computer.
  defp shares?(state),
    do: state.status == :connected and state.synced and Store.sessions(state.origin) != []

  # The sync barrier's answer to an account with a linked computer: the
  # mailbox key, every credential, the index and preferences, the log-outs.
  defp share_all(state) do
    case Mailbox.public_key() do
      {:ok, public} ->
        state = send_frame(state, Wire.frame("cred.mailbox", %{public_key: Wire.b64(public)}))
        state = Enum.reduce(Rho.Auth.providers(), state, &send_credential(&2, &1))

        state
        |> send_frame(Wire.frame("cred.snapshot", %{creds: Creds.snapshot()}))
        |> send_frame(Wire.frame("index.snapshot", %{entries: Index.snapshot()}))
        |> send_frame(Wire.frame("prefs.snapshot", Bezalel.Settings.link_preferences()))
        |> send_revokes()
        |> maybe_stop_check()

      {:error, reason} ->
        fatal(state, reason)
    end
  end

  defp send_revokes(%{status: :connected, synced: true} = state) do
    already = for {_id, %{from: {:revoke, r}}} <- state.pending, do: r

    state.origin
    |> Store.revokes()
    |> Enum.reject(&(&1 in already))
    |> Enum.reduce_while(state, fn id, state ->
      if state.status == :connected and state.session != nil do
        {:cont,
         send_request(state, %{from: {:revoke, id}, op: "sessions.revoke", fields: %{session: id}})}
      else
        {:halt, state}
      end
    end)
  end

  defp send_revokes(state), do: state

  defp apply_envelope(
         %{"provider" => name, "action" => action, "updated_at" => at} = payload,
         %{"id" => id}
       )
       when is_binary(name) and is_integer(at) and at >= 0 do
    with true <- is_binary(id),
         ["box", ^name, timestamp, nonce] <- String.split(id, ":"),
         true <- timestamp == Integer.to_string(at) and byte_size(nonce) == 16,
         {:ok, decoded} <- Wire.unb64(nonce),
         true <- byte_size(decoded) == 12 and Wire.b64(decoded) == nonce,
         {:ok, provider} <- Creds.provider(name) do
      case {action, payload["creds"]} do
        {"set", creds} when is_map(creds) ->
          {:ok, provider, Creds.apply_set(name, creds, at)}

        {"delete", _} ->
          {:ok, provider, Creds.apply_delete(name, at)}

        _ ->
          {:error, :bad_envelope}
      end
    else
      _ -> {:error, :bad_envelope}
    end
  end

  defp apply_envelope(_, _), do: {:error, :bad_envelope}

  defp credential_result(state, request, _provider, :ok), do: maybe_ack(state, request)
  # The phone's newer value answers a stale update, but only past the sync
  # barrier; before it, cred.sync's snapshot carries that value anyway.
  defp credential_result(%{synced: true} = state, _request, provider, :stale),
    do: send_credential(state, provider)

  defp credential_result(state, request, _provider, :stale), do: maybe_ack(state, request)
  defp credential_result(state, request, _provider, _error), do: maybe_error(state, request)

  # Nothing of the phone's goes to an account with no linked computer.
  defp send_credential(state, provider, request \\ nil) do
    if Store.sessions(state.origin) == [] do
      forbidden(state, request)
    else
      case Creds.current(provider) do
        {{:ok, creds}, %{at: at}} ->
          fields = %{provider: Atom.to_string(provider), creds: creds, updated_at: at}
          send_frame(state, credential_frame("cred.set", fields, request))

        {:missing, %{at: at, present: false}} ->
          fields = %{provider: Atom.to_string(provider), updated_at: at}
          send_frame(state, credential_frame("cred.delete", fields, request))

        _ ->
          refresh_error(state, request)
      end
    end
  end

  defp forbidden(state, %{"id" => _} = request),
    do: send_frame(state, Wire.error(request, "forbidden"))

  defp forbidden(state, _request), do: state

  defp credential_frame(op, fields, %{"id" => id}),
    do: Map.put(Wire.frame(op, fields), "re", id)

  defp credential_frame(op, fields, _request), do: Wire.frame(op, fields)

  defp maybe_ack(state, %{"id" => _} = request),
    do: send_frame(state, Wire.reply(request, "ack"))

  defp maybe_ack(state, _request), do: state

  defp maybe_error(state, %{"id" => _} = request),
    do: send_frame(state, Wire.error(request, "bad_request"))

  defp maybe_error(state, _request), do: state

  defp refresh_error(state, %{"id" => _} = request),
    do: send_frame(state, Wire.error(request, "refresh_failed"))

  defp refresh_error(state, _request), do: state

  defp send_request(state, request) do
    id = state.next_id
    state = %{state | next_id: id + 1, pending: Map.put(state.pending, id, request)}
    send_frame(state, Wire.frame(request.op, request.fields, id))
  end

  # While a work record is being served its answer is kept, not sent; what
  # serving it would also announce (an index entry, the preferences) goes
  # only to an account with a linked computer.
  defp send_frame(%{capture: {id, nil}} = state, %{"re" => id} = frame),
    do: %{state | capture: {id, frame}}

  defp send_frame(%{capture: {_id, _answer}} = state, frame) do
    if Store.sessions(state.origin) == [], do: state, else: transmit(state, frame)
  end

  defp send_frame(state, frame), do: transmit(state, frame)

  defp transmit(%{session: session} = state, frame) when session != nil do
    {sealed, session} = Handshake.seal(session, Wire.encode(frame))
    send_ws(%{state | session: session}, {:binary, sealed})
  end

  defp transmit(state, _frame), do: state

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
      not state.mailbox_pending and not Store.dial?(state.origin)
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
    token = make_ref()
    ref = Process.send_after(self(), {message || name, token}, ms)
    put_in(state.timers[name], {ref, token})
  end

  defp cancel(state, name) do
    case state.timers[name] do
      nil ->
        state

      {ref, _token} ->
        Process.cancel_timer(ref)
        put_in(state.timers[name], nil)
    end
  end

  defp take_timer(state, name, token) do
    case state.timers[name] do
      {_ref, ^token} -> {:ok, put_in(state.timers[name], nil)}
      _other -> :stale
    end
  end

  defp request?(request, from, token),
    do: request.from == from and request.timeout_token == token

  defp reduce_frames(frames, state) do
    Enum.reduce(frames, state, fn frame, state ->
      try do
        ws_frame(frame, state)
      rescue
        _error -> retry_after(state, :bad_frame)
      catch
        _kind, _reason -> retry_after(state, :bad_frame)
      end
    end)
  end

  defp websocket_pending_bytes(ws) do
    buffer = Map.get(ws, :buffer, <<>>)

    fragment_bytes =
      case Map.get(ws, :fragment) do
        {kind, _reserved, _mask, data, _fin?}
        when kind in [:text, :binary, :continuation] and is_binary(data) ->
          byte_size(data)

        _other ->
          0
      end

    byte_size(buffer) + fragment_bytes
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
