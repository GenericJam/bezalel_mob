defmodule Bezalel.Test.LinkServer do
  @moduledoc """
  A website's `/link/phone` for the link tests (Bandit on a free port):
  the server side of bezalel_core's handshake, `welcome`, the pairing ops
  and the session list, as the website answers them. It records every
  frame the phone sent (`frames/1`) and can push a frame or close the
  socket (`push/2`, `close/2`).

  A work parcel (`seal_work/3`, `put_work/2`) is announced in `welcome`
  (`work_count`, the records not yet durably acknowledged) and delivered
  after `cred.sync` one record at a time, the next after the phone's `ack`;
  an `ack` with `durable: true` moves the cursor past that record, so the
  next connection resumes there. An error stops delivery until the next
  connection, as does `limit_work/2`'s count of records per connection.
  After the last `ack`, `work.done` is sent.

      server = LinkServer.start(origin)
      {pair_id, secret} = LinkServer.offer(server, %{"browser" => "Firefox on Linux", ...})
      qr = LinkServer.qr(server, pair_id, secret)
  """

  alias Bezalel.Link.{Handshake, Pairing, Wire}

  defmodule Socket do
    @moduledoc false
    @behaviour WebSock

    alias Bezalel.Link.{Handshake, Pairing, Wire}

    @impl true
    def init(server) do
      %{key: key, origin: origin} = Agent.get(server, & &1)
      {hello, pending} = Handshake.hello(key)
      socket = self()
      Agent.update(server, &%{&1 | socket: socket, connects: &1.connects + 1})

      {:push, {:text, Wire.encode(hello)},
       %{
         server: server,
         origin: origin,
         pending: pending,
         session: nil,
         device: nil,
         work: [],
         budget: nil
       }}
    catch
      # The test that started the server has ended.
      :exit, _ -> {:stop, :normal, %{}}
    end

    @impl true
    def handle_in(frame, state) do
      receive_in(frame, state)
    catch
      :exit, _ -> {:stop, :normal, state}
    end

    defp receive_in({text, opcode: :text}, %{session: nil} = state) do
      with {:ok, frame} <- Wire.decode(text),
           {:ok, session, device} <- Handshake.accept(state.pending, frame, state.origin) do
        record(state.server, frame)
        Agent.update(state.server, &%{&1 | device: device})

        %{
          sessions: sessions,
          incoming: incoming,
          account_id: account_id,
          work: work,
          work_limit: limit
        } = Agent.get(state.server, & &1)

        Agent.update(state.server, &%{&1 | incoming: []})

        welcome =
          Wire.frame("welcome", %{
            account: "known",
            sessions: sessions,
            fingerprint: Pairing.fingerprint(device),
            account_id: account_id || Pairing.account_id(device),
            vault: "empty",
            work_count: length(work)
          })

        push(
          %{state | session: session, device: device, work: work, budget: limit && limit - 1},
          [welcome | incoming] ++ [Wire.frame("cred.sync")] ++ Enum.take(work, 1)
        )
      else
        _ -> {:stop, :normal, {4401, "bad auth"}, state}
      end
    end

    defp receive_in({bytes, opcode: :binary}, %{session: session} = state)
         when session != nil do
      {:ok, plain, session} = Handshake.open(session, bytes)
      {:ok, frame} = Wire.decode(plain)
      record(state.server, frame)
      answer(%{state | session: session}, frame)
    end

    @impl true
    def handle_info({:push, frame}, state), do: push(state, frame)
    def handle_info({:close, code}, state), do: {:stop, :normal, {code, "test"}, state}
    def handle_info(_other, state), do: {:ok, state}

    defp answer(state, %{"op" => "test.ignore"}), do: {:ok, state}

    # The record being delivered: the next one after an ack, none after an
    # error or once this connection's limit is reached.
    defp answer(%{work: [%{"id" => id} | rest]} = state, %{"re" => id, "op" => op} = reply) do
      if op == "ack" and reply["durable"] == true,
        do: Agent.update(state.server, &%{&1 | work: rest})

      cond do
        op != "ack" or state.budget == 0 ->
          {:ok, %{state | work: []}}

        rest == [] ->
          push(%{state | work: []}, Wire.frame("work.done"))

        true ->
          push(%{state | work: rest, budget: state.budget && state.budget - 1}, hd(rest))
      end
    end

    defp answer(state, %{"op" => "pair.claim", "p" => p, "proof" => proof} = req) do
      {:ok, pair_id} = Wire.unb64(p)
      {:ok, proof} = Wire.unb64(proof)
      offer = Agent.get(state.server, &Map.get(&1.offers, pair_id))

      cond do
        offer == nil ->
          push(state, Wire.error(req, "expired"))

        offer.claimed_by not in [nil, state.device] ->
          push(state, Wire.error(req, "claimed"))

        not Pairing.valid_claim?(offer.secret, pair_id, state.device, proof) ->
          push(state, Wire.error(req, "bad_proof"))

        true ->
          Agent.update(state.server, &put_in(&1.offers[pair_id].claimed_by, state.device))
          push(state, Wire.reply(req, "pair.info", offer.info))
      end
    end

    defp answer(state, %{"op" => "pair.approve", "p" => p} = req) do
      {:ok, pair_id} = Wire.unb64(p)
      offer = Agent.get(state.server, &Map.get(&1.offers, pair_id))

      if offer && offer.claimed_by == state.device do
        session =
          offer.info
          |> Map.take(["browser", "ip", "place"])
          |> Map.merge(%{
            "id" => "ws_" <> Base.encode16(pair_id, case: :lower),
            "linked_at" => "2026-10-19T12:00:00Z",
            "last_seen_at" => "2026-10-19T12:00:00Z"
          })

        Agent.update(state.server, fn s ->
          %{s | offers: Map.delete(s.offers, pair_id), sessions: s.sessions ++ [session]}
        end)

        push(state, [Wire.reply(req, "ack", %{session: session}), Wire.frame("cred.sync")])
      else
        push(state, Wire.error(req, "not_claimed"))
      end
    end

    defp answer(state, %{"op" => "pair.reject", "p" => p} = req) do
      {:ok, pair_id} = Wire.unb64(p)
      Agent.update(state.server, &%{&1 | offers: Map.delete(&1.offers, pair_id)})
      push(state, Wire.reply(req, "ack"))
    end

    defp answer(state, %{"op" => "sessions.revoke", "session" => id} = req) do
      case Agent.get(state.server, & &1.revoke_error) do
        nil ->
          sessions = Agent.get_and_update(state.server, &remove_session(&1, id))

          push(state, [
            Wire.reply(req, "ack"),
            Wire.frame("sessions.changed", %{sessions: sessions})
          ])

        code ->
          push(state, Wire.error(req, code))
      end
    end

    defp answer(state, %{"op" => "sessions.list"} = req),
      do:
        push(
          state,
          Wire.reply(req, "sessions.list", %{sessions: Agent.get(state.server, & &1.sessions)})
        )

    defp answer(state, %{"id" => _} = req), do: push(state, Wire.error(req, "unknown_op"))
    defp answer(state, _frame), do: {:ok, state}

    defp remove_session(state, id) do
      kept = if id == "all", do: [], else: Enum.reject(state.sessions, &(&1["id"] == id))
      {kept, %{state | sessions: kept}}
    end

    # One frame or several, sealed in order.
    defp push(state, frames) when is_list(frames) do
      {sealed, session} =
        Enum.map_reduce(frames, state.session, fn frame, session ->
          {bytes, session} = Handshake.seal(session, Wire.encode(frame))
          {{:binary, bytes}, session}
        end)

      {:push, sealed, %{state | session: session}}
    end

    defp push(state, frame), do: push(state, [frame])

    defp record(server, frame), do: Agent.update(server, &%{&1 | frames: &1.frames ++ [frame]})
  end

  defmodule Router do
    @moduledoc false
    @behaviour Plug

    alias Plug.Conn

    @impl true
    def init(server), do: server

    @impl true
    def call(%{request_path: "/link/phone"} = conn, server) do
      if Agent.get(server, & &1.refuse),
        do: Conn.send_resp(conn, 503, "down"),
        else: Conn.upgrade_adapter(conn, :websocket, {Socket, server, timeout: 120_000})
    end

    def call(conn, _server), do: Conn.send_resp(conn, 404, "")
  end

  @doc """
  Starts a server for `origin` (its own key, or `key:`) on a free port
  and points the phone at it (`config :bezalel, Bezalel.Link, urls:`).
  """
  def start(origin, opts \\ []) do
    {:ok, server} =
      Agent.start_link(fn ->
        %{
          origin: origin,
          key: opts[:key] || Handshake.keypair(),
          offers: %{},
          sessions: opts[:sessions] || [],
          frames: [],
          socket: nil,
          device: nil,
          connects: 0,
          incoming: [],
          account_id: nil,
          refuse: false,
          revoke_error: opts[:revoke_error],
          work: [],
          work_limit: nil
        }
      end)

    {:ok, bandit} =
      Bandit.start_link(
        plug: {__MODULE__.Router, server},
        ip: {127, 0, 0, 1},
        port: 0,
        startup_log: false
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit)
    config = Application.get_env(:bezalel, Bezalel.Link, [])
    urls = Map.put(config[:urls] || %{}, origin, "ws://127.0.0.1:#{port}/link/phone")
    Application.put_env(:bezalel, Bezalel.Link, Keyword.put(config, :urls, urls))
    server
  end

  @doc "The server's public key."
  def key(server), do: Agent.get(server, &elem(&1.key, 0))

  @doc "A new offer the browser `info` asked for: `{pair_id, secret}`."
  def offer(server, info) do
    {pair_id, secret} = Pairing.offer()

    Agent.update(server, fn s ->
      put_in(s.offers[pair_id], %{secret: secret, info: info, claimed_by: nil})
    end)

    {pair_id, secret}
  end

  @doc "The QR code's text for an offer."
  def qr(server, pair_id, secret) do
    %{origin: origin, key: {pub, _}} = Agent.get(server, & &1)
    Pairing.qr(origin, pair_id, secret, pub)
  end

  @doc "The frames the phone sent, oldest first (the `auth` one included)."
  def frames(server), do: Agent.get(server, & &1.frames)

  @doc "The ops the phone sent, oldest first."
  def ops(server), do: Enum.map(frames(server), & &1["op"])

  @doc "The server's list of linked sessions."
  def sessions(server), do: Agent.get(server, & &1.sessions)

  @doc "How many times the phone connected."
  def connects(server), do: Agent.get(server, & &1.connects)

  @doc "The device key the phone authenticated with."
  def device(server), do: Agent.get(server, & &1.device)

  @doc "Sets the session list (as the website would after a change)."
  def put_sessions(server, sessions), do: Agent.update(server, &%{&1 | sessions: sessions})

  @doc "Refuses (503) new connections, or takes them again."
  def refuse(server, refuse?), do: Agent.update(server, &%{&1 | refuse: refuse?})

  @doc "Sends these credential changes before the next connection's sync barrier."
  def on_connect(server, frames), do: Agent.update(server, &%{&1 | incoming: frames})

  @doc "Sets the claimed account for the next welcome (a mismatched-account test)."
  def claim_account(server, id), do: Agent.update(server, &%{&1 | account_id: id})

  @doc "Sends `frame` (sealed) to the phone on the current socket."
  def push(server, frame), do: send(Agent.get(server, & &1.socket), {:push, frame})

  @doc "Closes the current socket with `code`."
  def close(server, code \\ 1000), do: send(Agent.get(server, & &1.socket), {:close, code})

  @doc "Announces these sealed work records (`seal_work/3`) on the next connection."
  def put_work(server, records), do: Agent.update(server, &%{&1 | work: records})

  @doc "Delivers at most `count` work records per connection (nil: all)."
  def limit_work(server, count), do: Agent.update(server, &%{&1 | work_limit: count})

  @doc "The work records not yet durably acknowledged (the website's cursor)."
  def work(server), do: Agent.get(server, & &1.work)

  @doc """
  Seals `inner` request frames to the phone's mailbox key `phone_public`
  as one work parcel of `account_id`, as the website does when the
  account's last session expires: one `work.envelope` per frame, in order.
  """
  def seal_work(account_id, phone_public, inner, parcel \\ nil) do
    parcel = parcel || Wire.b64(:crypto.strong_rand_bytes(16))
    count = length(inner)

    inner
    |> Enum.with_index()
    |> Enum.map(fn {frame, seq} ->
      {ephemeral, private} = :crypto.generate_key(:ecdh, :x25519)
      shared = :crypto.compute_key(:ecdh, phone_public, private, :x25519)

      key =
        :crypto.hash(:sha256, ["bezalel work mailbox v1", shared, ephemeral, phone_public])

      nonce = :crypto.strong_rand_bytes(12)
      aad = "#{account_id}:#{parcel}:#{seq}"

      {cipher, tag} =
        :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, Wire.encode(frame), aad, 16, true)

      Wire.frame(
        "work.envelope",
        %{
          parcel: parcel,
          seq: seq,
          count: count,
          ephemeral: Wire.b64(ephemeral),
          nonce: Wire.b64(nonce),
          ciphertext: Wire.b64(cipher),
          tag: Wire.b64(tag)
        },
        "work:#{parcel}:#{seq}"
      )
    end)
  end
end
