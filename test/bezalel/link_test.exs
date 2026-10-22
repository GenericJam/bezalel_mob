defmodule Bezalel.LinkTest do
  # Linking computers (Bezalel.Link) against a fake website
  # (Bezalel.Test.LinkServer: core's handshake on the server side, the
  # pairing ops, the session list): pairing, the pinned key, log-outs
  # online and offline, reconnects, the background.
  use ExUnit.Case, async: false

  alias Bezalel.Library.Transcript
  alias Bezalel.Link

  alias Bezalel.Link.{
    Creds,
    Dialer,
    Handshake,
    Identity,
    Index,
    Mailbox,
    Pairing,
    Serve,
    Store,
    Turns,
    Wire
  }

  alias Bezalel.Test.{LinkServer, MemoryStore}

  @origin "https://study.example"
  @browser %{
    "browser" => "Firefox on Linux",
    "ip" => "203.0.113.7",
    "place" => "Toronto, CA",
    "requested_at" => "2026-10-19T12:00:00Z"
  }

  defmodule LockedStore do
    @moduledoc false
    # The iOS Keychain before the first unlock: nothing can be read.
    def get(_key), do: {:error, :locked}
    def put(_key, _value), do: {:error, :locked}
    def delete(_key), do: {:error, :locked}
  end

  setup do
    stop_dialers()
    Store.clear()
    MemoryStore.delete("bezalel.link.device_key")
    MemoryStore.delete("bezalel.link.mailbox_key")
    :ok = Mob.State.put(:bezalel_link_mailbox_created, false)
    :ok = Link.subscribe()

    on_exit(fn ->
      stop_dialers()
      Store.clear()
      Application.delete_env(:bezalel, Link)
    end)

    :ok
  end

  defp stop_dialers do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(Link.Dialers),
        do: DynamicSupervisor.terminate_child(Link.Dialers, pid)
  end

  defp dialer(origin \\ @origin), do: GenServer.whereis(Link.via(origin))

  defp eventually(fun, tries \\ 100) do
    if fun.() do
      true
    else
      if tries == 0, do: flunk("never happened")
      Process.sleep(20)
      eventually(fun, tries - 1)
    end
  end

  defp seal_for_phone(account_id, provider, creds, at) do
    {:ok, phone_public} = Mailbox.public_key()
    {ephemeral, private} = :crypto.generate_key(:ecdh, :x25519)
    shared = :crypto.compute_key(:ecdh, phone_public, private, :x25519)

    key =
      :crypto.hash(:sha256, ["bezalel credential mailbox v1", shared, ephemeral, phone_public])

    nonce = :crypto.strong_rand_bytes(12)
    plain = Jason.encode!(%{provider: provider, action: "set", creds: creds, updated_at: at})

    {cipher, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, plain, account_id, 16, true)

    Wire.frame("cred.envelope", %{
      ephemeral: Wire.b64(ephemeral),
      nonce: Wire.b64(nonce),
      ciphertext: Wire.b64(cipher),
      tag: Wire.b64(tag),
      id: "box:#{provider}:#{at}:#{Wire.b64(:crypto.strong_rand_bytes(12))}"
    })
  end

  # A computer linked through the whole pairing: the offer's parsed QR
  # code and the website's session. The events so far are dropped.
  defp link(server, info \\ @browser) do
    {pair_id, secret} = LinkServer.offer(server, info)
    {:ok, offer} = Link.parse(LinkServer.qr(server, pair_id, secret))
    {:ok, _info} = Link.claim(offer)
    {:ok, session} = Link.approve(offer)
    drain()
    {offer, session}
  end

  defp drain do
    receive do
      {:bezalel_link, _, _} -> drain()
    after
      0 -> :ok
    end
  end

  test "a public origin is dialled over wss; a loopback development origin over plain ws" do
    assert Link.dial_url("https://study.genericjam.com") ==
             "wss://study.genericjam.com/link/phone"

    assert Link.dial_url("https://study.example:8443") == "wss://study.example:8443/link/phone"
    assert Link.dial_url("http://localhost:8031") == "ws://localhost:8031/link/phone"
  end

  test "pairing: the claim proves the scan without the secret, shows who asked, and approving links it with the key pinned" do
    server = LinkServer.start(@origin)
    {pair_id, secret} = LinkServer.offer(server, @browser)
    {:ok, offer} = Link.parse(LinkServer.qr(server, pair_id, secret))
    assert offer.origin == @origin

    assert {:ok, info} = Link.claim(offer)

    assert Map.take(info, ["browser", "ip", "place"]) ==
             Map.take(@browser, ["browser", "ip", "place"])

    # The phone signed in with its device key; the claim is the HMAC for
    # that key and never carries the secret.
    {:ok, {device, _}} = Identity.keypair()
    assert LinkServer.device(server) == device
    [auth, claim] = Enum.filter(LinkServer.frames(server), &(&1["op"] in ["auth", "pair.claim"]))
    assert auth["op"] == "auth"
    assert auth["app"] =~ "Bezalel"
    assert claim["op"] == "pair.claim"
    refute Enum.any?(Map.values(claim), &(&1 == Base.url_encode64(secret, padding: false)))

    assert Pairing.valid_claim?(
             secret,
             pair_id,
             device,
             Base.url_decode64!(claim["proof"], padding: false)
           )

    # Nothing is pinned or linked before the user confirms.
    assert Store.server_key(@origin) == nil
    assert Link.count() == 0

    assert {:ok, %{"id" => id} = session} = Link.approve(offer)
    assert session["browser"] == "Firefox on Linux"
    assert Store.server_key(@origin) == LinkServer.key(server)
    assert [%{"id" => ^id, "place" => "Toronto, CA"}] = Store.sessions(@origin)
    assert [%{origin: @origin, status: :connected, sessions: [_]}] = Link.linked()
    assert_received {:bezalel_link, @origin, {:status, :connected}}
    assert_received {:bezalel_link, @origin, {:sessions, [%{"id" => ^id}]}}
  end

  test "a code whose key isn't the website's is refused before the phone signs anything" do
    server = LinkServer.start(@origin)
    {pair_id, secret} = LinkServer.offer(server, @browser)
    {other, _} = Handshake.keypair()
    qr = Pairing.qr(@origin, pair_id, secret, other)
    {:ok, offer} = Link.parse(qr)

    assert Link.claim(offer) == {:error, :key_changed}
    assert LinkServer.frames(server) == []
    assert Store.server_key(@origin) == nil
    assert_received {:bezalel_link, @origin, {:status, {:error, :key_changed}}}
  end

  test "the website's codes come back as they are: a claim on an offer it doesn't have is expired" do
    server = LinkServer.start(@origin)
    {pair_id, secret} = Pairing.offer()
    {:ok, offer} = Link.parse(LinkServer.qr(server, pair_id, secret))

    assert Link.claim(offer) == {:error, "expired"}
    # Pairing never linked anything: the phone leaves once it gives up.
    :ok = Link.cancel(@origin)
    assert eventually(fn -> dialer() == nil end)
    assert Link.linked() == []
  end

  test "a pairing the website closes as idle (4408) is over: with nothing linked the phone stops dialling" do
    server = LinkServer.start(@origin)
    {pair_id, secret} = LinkServer.offer(server, @browser)
    {:ok, offer} = Link.parse(LinkServer.qr(server, pair_id, secret))
    {:ok, _info} = Link.claim(offer)
    pid = dialer()
    ref = Process.monitor(pid)

    LinkServer.close(server, 4408)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
    Process.sleep(1_200)
    assert LinkServer.connects(server) == 1
  end

  test "a hello sent in the same packet as the 101 isn't lost: the phone answers it" do
    # A bare server writing the upgrade and its hello in one send, as
    # Bandit can behind a busy tunnel.
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listen)
    Application.put_env(:bezalel, Link, urls: %{@origin => "ws://127.0.0.1:#{port}/link/phone"})
    {key, _} = keypair = Handshake.keypair()
    test = self()

    spawn_link(fn ->
      {:ok, socket} = :gen_tcp.accept(listen)
      {:ok, request} = :gen_tcp.recv(socket, 0, 5_000)

      [ws_key] =
        for line <- String.split(request, "\r\n"),
            [name, value] <- [String.split(line, ": ", parts: 2)],
            String.downcase(name) == "sec-websocket-key",
            do: value

      accept = Base.encode64(:crypto.hash(:sha, ws_key <> "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
      {hello, _pending} = Handshake.hello(keypair)
      json = Wire.encode(hello)

      :ok =
        :gen_tcp.send(socket, [
          "HTTP/1.1 101 Switching Protocols\r\nupgrade: websocket\r\nconnection: Upgrade\r\n",
          "sec-websocket-accept: #{accept}\r\n\r\n",
          <<0x81, 126, byte_size(json)::16>>,
          json
        ])

      send(test, {:phone_sent, :gen_tcp.recv(socket, 0, 5_000)})
    end)

    {pair_id, secret} = Pairing.offer()
    {:ok, offer} = Link.parse(Pairing.qr(@origin, pair_id, secret, key))
    claim = Task.async(fn -> Link.claim(offer) end)

    # A masked text frame: the phone's auth.
    assert_receive {:phone_sent, {:ok, <<0x81, _::binary>>}}, 5_000
    Task.shutdown(claim, :brutal_kill)
  end

  test "a linked website whose key changes isn't trusted: the phone stops and won't pair with the new key" do
    server = LinkServer.start(@origin)
    {_offer, _session} = link(server)
    stop_dialers()

    # The same origin now answers with another key.
    impostor = LinkServer.start(@origin)
    :ok = Link.resume()
    assert_receive {:bezalel_link, @origin, {:status, {:error, :key_changed}}}, 2_000
    assert LinkServer.frames(impostor) == []
    assert Link.status(@origin) == {:error, :key_changed}

    {pair_id, secret} = LinkServer.offer(impostor, @browser)
    {:ok, offer} = Link.parse(LinkServer.qr(impostor, pair_id, secret))
    assert Link.claim(offer) == {:error, :key_changed}
    assert LinkServer.frames(impostor) == []
    assert Store.server_key(@origin) == LinkServer.key(server)
  end

  test "with nothing linked there any more, a new key from a scanned code replaces the old pin" do
    server = LinkServer.start(@origin)
    {_offer, %{"id" => id}} = link(server)
    :ok = Link.revoke(@origin, id)
    assert eventually(fn -> dialer() == nil end)

    fresh = LinkServer.start(@origin)
    {_offer, _session} = link(fresh)
    assert Store.server_key(@origin) == LinkServer.key(fresh)
  end

  test "logging out a computer while connected: sent at once; with none left the phone stops dialling" do
    server = LinkServer.start(@origin)
    {_offer, %{"id" => id}} = link(server)
    pid = dialer()
    ref = Process.monitor(pid)

    :ok = Link.revoke(@origin, id)
    assert Store.sessions(@origin) == []
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
    assert %{"op" => "sessions.revoke", "session" => ^id} = List.last(LinkServer.frames(server))
    assert LinkServer.sessions(server) == []
    assert Store.revokes(@origin) == []
    refute Store.dial?(@origin)
  end

  test "a log-out made offline drops the computer at once and is sent on the next connect" do
    server = LinkServer.start(@origin)
    {_offer, %{"id" => id}} = link(server)
    {_offer, %{"id" => other}} = link(server, %{@browser | "browser" => "Safari on macOS"})

    LinkServer.refuse(server, true)
    LinkServer.close(server, 1001)
    assert_receive {:bezalel_link, @origin, {:status, :offline}}, 2_000

    :ok = Link.revoke(@origin, id)
    assert [%{"id" => ^other}] = Store.sessions(@origin)
    assert Store.revokes(@origin) == [id]
    refute Enum.any?(LinkServer.frames(server), &(&1["op"] == "sessions.revoke"))

    # Back online: connects at once, without waiting out the backoff.
    LinkServer.refuse(server, false)
    send(dialer(), {:mob_device, :connectivity_changed, %{online: true}})
    assert eventually(fn -> Store.revokes(@origin) == [] end)
    assert [%{"id" => ^other}] = LinkServer.sessions(server)
    assert [%{"id" => ^other}] = Store.sessions(@origin)
  end

  test "the website's list wins on every connect and change; an empty one stops the dialer" do
    server = LinkServer.start(@origin)
    {_offer, %{"id" => id}} = link(server)
    renamed = %{"id" => id, "browser" => "Firefox on Linux", "place" => "Ottawa, CA"}

    LinkServer.push(server, %{
      "op" => "sessions.changed",
      "sessions" => [renamed, %{"no" => "id"}]
    })

    assert_receive {:bezalel_link, @origin, {:sessions, [%{"place" => "Ottawa, CA"}]}}
    assert [%{"id" => ^id, "place" => "Ottawa, CA"}] = Store.sessions(@origin)

    pid = dialer()
    ref = Process.monitor(pid)
    LinkServer.push(server, %{"op" => "sessions.changed", "sessions" => []})
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
    assert Link.linked() == []
  end

  test "dropped by the website, the phone reconnects; it answers an op it doesn't know" do
    server = LinkServer.start(@origin)
    {_offer, _session} = link(server)
    assert LinkServer.connects(server) == 1

    LinkServer.close(server, 1001)
    assert_receive {:bezalel_link, @origin, {:status, :offline}}, 2_000
    assert_receive {:bezalel_link, @origin, {:status, :connected}}, 3_000
    assert LinkServer.connects(server) == 2

    LinkServer.push(server, %{"op" => "unrecognized.operation", "id" => 7})
    assert eventually(fn -> List.last(LinkServer.frames(server))["op"] == "error" end)
    assert %{"re" => 7, "code" => "unknown_op"} = List.last(LinkServer.frames(server))
  end

  test "web hold blocks phone turns; phone hold blocks web append and survives reconnect only while active" do
    alias Bezalel.Library
    alias Bezalel.Library.Conversation
    alias Bezalel.Repo

    Repo.delete_all(Conversation)
    on_exit(fn -> Repo.delete_all(Conversation) end)
    server = LinkServer.start(@origin)
    {_offer, _session} = link(server)

    {:ok, conversation} =
      Library.create_conversation(%{name: "Held study", kicker: "STUDY", kind: "Study"})

    {:ok, session, _} = Library.session(conversation.id, "anthropic/claude-sonnet-4-5")
    uid = session.id
    path = Library.session_path(conversation.id)
    on_exit(fn -> File.rm(path) end)
    assert eventually(fn -> "index.snapshot" in LinkServer.ops(server) end)

    LinkServer.push(server, Wire.frame("conv.hold", %{uid: uid}, "web-hold"))
    assert_receive {:bezalel_link, @origin, {:conversation_hold, ^uid, true}}
    assert Turns.held?(uid)
    assert {:error, :held_by_web} = Turns.phone_turn(uid, :start)
    refute Enum.any?(LinkServer.frames(server), &(&1["op"] == "conv.hold" and &1["uid"] == uid))
    LinkServer.push(server, Wire.frame("conv.release", %{uid: uid}, "web-release"))
    assert_receive {:bezalel_link, @origin, {:conversation_hold, ^uid, false}}
    refute Turns.held?(uid)

    assert :ok = Turns.phone_turn(uid, :start)

    assert eventually(fn ->
             Enum.count(
               LinkServer.frames(server),
               &(&1["op"] == "conv.hold" and &1["uid"] == uid)
             ) == 1
           end)

    LinkServer.push(server, Wire.frame("conv.hold", %{uid: uid}, "web-conflict"))

    assert eventually(fn ->
             Enum.any?(
               LinkServer.frames(server),
               &(&1["re"] == "web-conflict" and &1["code"] == "held_by_phone")
             )
           end)

    refute Turns.held?(uid)

    LinkServer.push(
      server,
      Wire.frame("conv.append", %{uid: uid, from: 0, bytes: Wire.b64("bad")}, "web-append")
    )

    assert eventually(fn ->
             Enum.any?(
               LinkServer.frames(server),
               &(&1["re"] == "web-append" and &1["code"] == "held_by_phone")
             )
           end)

    assert Library.messages(conversation.id) == []

    LinkServer.close(server, 1001)
    assert_receive {:bezalel_link, @origin, {:status, :offline}}, 2_000
    assert_receive {:bezalel_link, @origin, {:status, :connected}}, 3_000

    assert eventually(fn ->
             Enum.count(
               LinkServer.frames(server),
               &(&1["op"] == "conv.hold" and &1["uid"] == uid)
             ) == 2
           end)

    assert :ok = Turns.phone_turn(uid, :finish)

    assert eventually(fn ->
             Enum.count(
               LinkServer.frames(server),
               &(&1["op"] == "conv.release" and &1["uid"] == uid)
             ) == 1
           end)

    assert :ok = Turns.phone_turn(uid, :finish)
    LinkServer.close(server, 1001)
    assert_receive {:bezalel_link, @origin, {:status, :offline}}, 2_000
    assert_receive {:bezalel_link, @origin, {:status, :connected}}, 3_000

    assert Enum.count(LinkServer.frames(server), &(&1["op"] == "conv.hold" and &1["uid"] == uid)) ==
             2

    assert :ok = Turns.phone_turn(uid, :start)

    assert eventually(fn ->
             Enum.count(
               LinkServer.frames(server),
               &(&1["op"] == "conv.hold" and &1["uid"] == uid)
             ) == 3
           end)

    LinkServer.refuse(server, true)
    LinkServer.close(server, 1001)
    assert_receive {:bezalel_link, @origin, {:status, :offline}}, 2_000
    assert :ok = Turns.phone_turn(uid, :finish)
    LinkServer.refuse(server, false)
    send(dialer(), {:mob_device, :connectivity_changed, %{online: true}})
    assert_receive {:bezalel_link, @origin, {:status, :connected}}, 3_000

    assert Enum.count(LinkServer.frames(server), &(&1["op"] == "conv.hold" and &1["uid"] == uid)) ==
             3
  end

  test "disconnect clears web hold, and an abandoned phone turn releases its hold" do
    server = LinkServer.start(@origin)
    {_offer, _session} = link(server)
    uid = "123e4567-e89b-42d3-a456-426614174000"
    LinkServer.push(server, Wire.frame("conv.hold", %{uid: uid}, "web-hold"))
    assert_receive {:bezalel_link, @origin, {:conversation_hold, ^uid, true}}
    LinkServer.close(server, 1001)
    assert_receive {:bezalel_link, @origin, {:conversation_hold, ^uid, false}}, 2_000
    refute Turns.held?(uid)
    assert_receive {:bezalel_link, @origin, {:status, :connected}}, 3_000

    parent = self()

    worker =
      spawn(fn ->
        send(parent, {:turn, Turns.phone_turn(uid, :start)})

        receive do
          :finish -> :ok
        end
      end)

    assert_receive {:turn, :ok}

    assert eventually(fn ->
             Enum.any?(LinkServer.frames(server), &(&1["op"] == "conv.hold" and &1["uid"] == uid))
           end)

    Process.exit(worker, :kill)

    assert eventually(fn ->
             Enum.any?(
               LinkServer.frames(server),
               &(&1["op"] == "conv.release" and &1["uid"] == uid)
             )
           end)
  end

  test "a linked computer pulls byte-identical JSONL in bounded chunks, never by path or off-shelf uid" do
    alias Bezalel.Library
    alias Bezalel.Library.Conversation
    alias Bezalel.Repo

    Repo.delete_all(Conversation)
    on_exit(fn -> Repo.delete_all(Conversation) end)

    server = LinkServer.start(@origin)
    {_offer, _session} = link(server)
    assert eventually(fn -> "index.snapshot" in LinkServer.ops(server) end)

    {:ok, conversation} =
      Library.create_conversation(%{name: "Long study", kicker: "STUDY", kind: "Study"})

    {:ok, _} =
      Library.add_message(conversation, %{
        role: :user,
        text: String.duplicate("JSONL contains escaped \"quotes\" and literal bytes.\n", 7_000)
      })

    uid = Library.get_conversation(conversation.id).session_id
    path = Library.session_path(conversation.id)
    on_exit(fn -> File.rm(path) end)
    original = File.read!(path)
    chunk_size = Wire.chunk_size()
    assert byte_size(original) > chunk_size
    assert byte_size(original) < 2 * chunk_size

    LinkServer.push(server, Wire.frame("conv.pull", %{uid: uid, from: 0}, "first"))

    assert eventually(fn ->
             Enum.any?(LinkServer.frames(server), &(&1["re"] == "first"))
           end)

    first = Enum.find(LinkServer.frames(server), &(&1["re"] == "first"))
    assert %{"op" => "conv.data", "uid" => ^uid, "offset" => 0, "eof" => false} = first
    assert {:ok, first_bytes} = Wire.unb64(first["bytes"])
    assert byte_size(first_bytes) == chunk_size

    LinkServer.push(server, Wire.frame("conv.pull", %{uid: uid, from: chunk_size}, "second"))

    assert eventually(fn ->
             Enum.any?(LinkServer.frames(server), &(&1["re"] == "second"))
           end)

    second = Enum.find(LinkServer.frames(server), &(&1["re"] == "second"))

    assert %{"op" => "conv.data", "uid" => ^uid, "offset" => ^chunk_size, "eof" => true} =
             second

    assert {:ok, second_bytes} = Wire.unb64(second["bytes"])
    assert first_bytes <> second_bytes == original

    LinkServer.push(server, Wire.frame("conv.pull", %{uid: "../" <> uid, from: 0}, "path"))
    LinkServer.push(server, Wire.frame("conv.pull", %{uid: uid, from: -1}, "negative"))

    LinkServer.push(
      server,
      Wire.frame("conv.pull", %{uid: uid, from: byte_size(original) + 1}, "past")
    )

    LinkServer.push(
      server,
      Wire.frame("conv.pull", %{uid: "00000000-0000-0000-0000-000000000000", from: 0}, "missing")
    )

    LinkServer.push(server, Wire.frame("conv.pull", %{uid: uid, from: 0, id: %{"bad" => "id"}}))
    {:ok, _deleted} = Library.delete_conversation(conversation.id)
    LinkServer.push(server, Wire.frame("conv.pull", %{uid: uid, from: 0}, "off-shelf"))

    assert eventually(fn ->
             Enum.count(
               LinkServer.frames(server),
               &(&1["re"] in ~w(path negative past missing off-shelf))
             ) == 5 and
               Enum.any?(LinkServer.frames(server), &(&1["re"] == %{"bad" => "id"}))
           end)

    responses = Map.new(LinkServer.frames(server), &{&1["re"], &1})
    assert %{"code" => "bad_request"} = responses["path"]
    assert %{"code" => "bad_request"} = responses["negative"]
    assert %{"code" => "bad_request"} = responses["past"]
    assert %{"code" => "not_found"} = responses["missing"]
    assert %{"code" => "not_found"} = responses["off-shelf"]

    assert %{"op" => "error", "code" => "bad_request"} =
             Enum.find(LinkServer.frames(server), &(&1["re"] == %{"bad" => "id"}))
  end

  test "phone preferences arrive on connect, accept newer web edits, and broadcast local edits" do
    alias Bezalel.Settings

    original = Settings.link_preferences()

    on_exit(fn ->
      Settings.apply_link_preferences(
        original["model"],
        original["study"],
        original["updated_at"]
      )
    end)

    server = LinkServer.start(@origin)
    {_offer, _session} = link(server)
    assert eventually(fn -> "prefs.snapshot" in LinkServer.ops(server) end)
    at = DateTime.to_iso8601(DateTime.utc_now())
    study = Map.put(original["study"], "limit", 6)

    LinkServer.push(
      server,
      Wire.frame(
        "prefs.set",
        %{
          model: original["model"],
          study: study,
          updated_at: at
        },
        "web-pref"
      )
    )

    assert eventually(fn -> Enum.any?(LinkServer.frames(server), &(&1["re"] == "web-pref")) end)

    assert %{"op" => "ack", "updated_at" => ^at} =
             Enum.find(LinkServer.frames(server), &(&1["re"] == "web-pref"))

    assert Settings.study_preferences().limit == 6

    Settings.put_study_preferences(%{limit: 7})

    assert eventually(fn ->
             Enum.any?(
               LinkServer.frames(server),
               &(&1["op"] == "prefs.snapshot" and get_in(&1, ["study", "limit"]) == 7)
             )
           end)
  end

  test "a linked computer imports a SHA-verified material in bounded chunks, links it, then deletes it" do
    alias Bezalel.{Library, Materials, MaterialStore}

    server = LinkServer.start(@origin)
    {_offer, _session} = link(server)
    {:ok, c} = Library.create_conversation(%{name: "Attached", kicker: "STUDY", kind: "Study"})
    {:ok, _} = Library.add_message(c, %{role: :user, text: "Attached a note"})
    uid = Library.get_conversation(c.id).session_id
    bytes = String.duplicate("portable material", 18_000)
    material = Materials.new(bytes, name: "attached.txt", mime: "text/plain")
    record = Materials.to_map(material)
    first = binary_part(bytes, 0, Wire.chunk_size())
    rest = binary_part(bytes, Wire.chunk_size(), byte_size(bytes) - Wire.chunk_size())

    LinkServer.push(
      server,
      Wire.frame(
        "mat.put",
        %{
          uid: uid,
          record: record,
          from: 0,
          bytes: Wire.b64(first)
        },
        "upload-first"
      )
    )

    assert eventually(fn ->
             Enum.any?(LinkServer.frames(server), &(&1["re"] == "upload-first"))
           end)

    assert %{"op" => "ack", "sha" => id, "size" => size} =
             Enum.find(LinkServer.frames(server), &(&1["re"] == "upload-first"))

    assert id == material.id
    assert size == Wire.chunk_size()
    assert MaterialStore.fetch(id, %{}) == :error

    LinkServer.push(
      server,
      Wire.frame(
        "mat.put",
        %{
          uid: uid,
          record: record,
          from: size,
          bytes: Wire.b64(rest)
        },
        "upload-last"
      )
    )

    assert eventually(fn ->
             Enum.any?(LinkServer.frames(server), &(&1["re"] == "upload-last"))
           end)

    assert %{"op" => "ack", "sha" => ^id, "size" => total} =
             Enum.find(LinkServer.frames(server), &(&1["re"] == "upload-last"))

    assert total == byte_size(bytes)
    assert {:ok, ^material} = MaterialStore.fetch(id, %{})
    assert {:ok, ^bytes} = MaterialStore.read(material, %{})
    assert uid in MaterialStore.sessions(id)

    LinkServer.push(server, Wire.frame("mat.delete", %{sha: id}, "remove-material"))

    assert eventually(fn ->
             Enum.any?(LinkServer.frames(server), &(&1["re"] == "remove-material"))
           end)

    assert %{"op" => "ack", "sha" => ^id} =
             Enum.find(LinkServer.frames(server), &(&1["re"] == "remove-material"))

    assert MaterialStore.fetch(id, %{}) == :error
    refute File.exists?(MaterialStore.path(material))
  end

  test "a linked computer receives bounded SHA material chunks and cannot follow a symlink" do
    alias Bezalel.{Materials, MaterialStore}

    raw = String.duplicate("material-content-", 17_000)
    material = Materials.new(raw, name: "recording.txt")
    {:ok, _} = MaterialStore.put(material, raw, %{})
    path = MaterialStore.path(material)
    on_exit(fn -> MaterialStore.delete(material.id) end)

    server = LinkServer.start(@origin)
    {_offer, _session} = link(server)
    assert eventually(fn -> "index.snapshot" in LinkServer.ops(server) end)

    LinkServer.push(server, Wire.frame("mat.get", %{sha: material.id, from: 0}, "mat-first"))
    assert eventually(fn -> Enum.any?(LinkServer.frames(server), &(&1["re"] == "mat-first")) end)
    first = Enum.find(LinkServer.frames(server), &(&1["re"] == "mat-first"))
    assert %{"op" => "mat.data", "sha" => sha, "offset" => 0, "eof" => false} = first
    assert sha == material.id
    assert first["record"] == Materials.to_map(material)
    assert {:ok, part} = Wire.unb64(first["bytes"])
    assert byte_size(part) == Wire.chunk_size()

    LinkServer.push(
      server,
      Wire.frame("mat.get", %{sha: material.id, from: Wire.chunk_size()}, "mat-second")
    )

    assert eventually(fn -> Enum.any?(LinkServer.frames(server), &(&1["re"] == "mat-second")) end)
    second = Enum.find(LinkServer.frames(server), &(&1["re"] == "mat-second"))
    assert %{"op" => "mat.data", "eof" => true} = second
    assert second["record"] == first["record"]
    assert {:ok, rest} = Wire.unb64(second["bytes"])
    assert part <> rest == raw

    LinkServer.push(server, Wire.frame("mat.get", %{sha: "../" <> sha, from: 0}, "mat-path"))
    LinkServer.push(server, Wire.frame("mat.get", %{sha: sha, from: -1}, "mat-negative"))

    assert eventually(fn ->
             Enum.count(LinkServer.frames(server), &(&1["re"] in ~w(mat-path mat-negative))) == 2
           end)

    frames = Map.new(LinkServer.frames(server), &{&1["re"], &1})
    assert frames["mat-path"]["code"] == "bad_request"
    assert frames["mat-negative"]["code"] == "bad_request"

    secret = Path.join(System.tmp_dir!(), "material-secret-#{System.unique_integer([:positive])}")
    File.write!(secret, "not the material")
    File.rm!(path)
    File.ln_s!(secret, path)
    on_exit(fn -> File.rm(secret) end)
    LinkServer.push(server, Wire.frame("mat.get", %{sha: sha, from: 0}, "mat-symlink"))

    assert eventually(fn ->
             Enum.any?(LinkServer.frames(server), &(&1["re"] == "mat-symlink"))
           end)

    assert %{"op" => "error"} =
             Enum.find(LinkServer.frames(server), &(&1["re"] == "mat-symlink"))
  end

  test "a computer creates its session once, appends raw JSONL at exact offsets, and cannot revive a deletion" do
    alias Bezalel.{Library, Repo}
    alias Bezalel.Library.Conversation

    Repo.delete_all(Conversation)
    on_exit(fn -> Repo.delete_all(Conversation) end)
    server = LinkServer.start(@origin)
    {_offer, _session} = link(server)
    assert eventually(fn -> "index.snapshot" in LinkServer.ops(server) end)

    uid = Ecto.UUID.generate()
    file = "2026-10-20T12-00-00-000Z_#{uid}.jsonl"
    path = Path.join(Rho.Session.dir(), file)
    on_exit(fn -> File.rm(path) end)

    fields = %{
      uid: uid,
      session_file: file,
      name: "From computer",
      kicker: "STUDY",
      kind: "Study",
      pushback: true
    }

    LinkServer.push(
      server,
      Wire.frame("conv.create", %{fields | session_file: "../" <> file}, "bad-file")
    )

    LinkServer.push(server, Wire.frame("conv.create", fields, "created"))

    assert eventually(fn ->
             Enum.count(LinkServer.frames(server), &(&1["re"] in ~w(created bad-file))) == 2
           end)

    frames = Map.new(LinkServer.frames(server), &{&1["re"], &1})
    assert frames["bad-file"]["code"] == "bad_request"
    assert %{"op" => "ack", "uid" => ^uid} = frames["created"]

    assert [%Conversation{session_id: ^uid, pushback: true} = imported] =
             Library.conversations_by_session([uid])

    assert File.read!(path) == ""
    assert_receive {:bezalel_link, @origin, {:conversation_changed, imported_id}}, 1_000
    assert imported_id == imported.id
    LinkServer.push(server, Wire.frame("conv.create", fields, "created-again"))

    assert eventually(fn ->
             Enum.any?(LinkServer.frames(server), &(&1["re"] == "created-again"))
           end)

    assert %{"op" => "ack", "uid" => ^uid} =
             Enum.find(LinkServer.frames(server), &(&1["re"] == "created-again"))

    assert Repo.aggregate(Conversation, :count) == 1
    refute_receive {:bezalel_link, @origin, {:conversation_changed, ^imported_id}}, 50

    header =
      Jason.encode!(%{
        type: "session",
        version: 3,
        id: uid,
        timestamp: "2026-10-20T12:00:00Z",
        cwd: "/",
        title: "From computer"
      }) <> "\n"

    line =
      Jason.encode!(%{
        type: "custom",
        id: "abcd1234",
        parentId: nil,
        timestamp: "2026-10-20T12:00:01Z",
        customType: "sync.notes",
        content: String.duplicate("m", Wire.chunk_size())
      }) <> "\n"

    original = header <> line
    first = binary_part(original, 0, Wire.chunk_size())
    second = binary_part(original, Wire.chunk_size(), byte_size(original) - Wire.chunk_size())

    LinkServer.push(
      server,
      Wire.frame("conv.append", %{uid: uid, from: 0, bytes: Wire.b64(first)}, "append-1")
    )

    assert eventually(fn -> Enum.any?(LinkServer.frames(server), &(&1["re"] == "append-1")) end)

    assert %{"op" => "ack", "size" => size} =
             Enum.find(LinkServer.frames(server), &(&1["re"] == "append-1"))

    assert size == Wire.chunk_size()
    refute_receive {:bezalel_link, @origin, {:conversation_changed, ^imported_id}}, 50

    LinkServer.push(
      server,
      Wire.frame("conv.append", %{uid: uid, from: size, bytes: Wire.b64(second)}, "append-2")
    )

    LinkServer.push(
      server,
      Wire.frame("conv.append", %{uid: uid, from: 0, bytes: Wire.b64(first)}, "duplicate")
    )

    LinkServer.push(
      server,
      Wire.frame("conv.append", %{uid: uid, from: 0, bytes: Wire.b64("changed")}, "conflict")
    )

    assert eventually(fn ->
             Enum.count(LinkServer.frames(server), &(&1["re"] in ~w(append-2 duplicate conflict))) ==
               3
           end)

    frames = Map.new(LinkServer.frames(server), &{&1["re"], &1})
    assert frames["append-2"]["size"] == byte_size(original)
    assert frames["duplicate"]["size"] == byte_size(original)
    assert frames["conflict"]["code"] == "conflict"
    assert File.read!(path) == original
    assert %{size: size} = Index.entry(imported.id)
    assert size == byte_size(original)

    assert eventually(fn ->
             Enum.any?(LinkServer.frames(server), fn
               %{"op" => "index.upsert", "entry" => %{"uid" => ^uid, "size" => ^size}} -> true
               _ -> false
             end)
           end)

    assert_receive {:bezalel_link, @origin, {:conversation_changed, ^imported_id}}, 1_000
    refute_receive {:bezalel_link, @origin, {:conversation_changed, ^imported_id}}, 50

    other_uid = Ecto.UUID.generate()
    other_file = "2026-10-20T12-01-00-000Z_#{other_uid}.jsonl"
    other_path = Path.join(Rho.Session.dir(), other_file)
    on_exit(fn -> File.rm(other_path) end)

    LinkServer.push(
      server,
      Wire.frame("conv.create", %{fields | uid: other_uid, session_file: other_file}, "other")
    )

    assert eventually(fn -> Enum.any?(LinkServer.frames(server), &(&1["re"] == "other")) end)
    assert %{"op" => "ack"} = Enum.find(LinkServer.frames(server), &(&1["re"] == "other"))

    LinkServer.push(
      server,
      Wire.frame(
        "conv.append",
        %{uid: other_uid, from: 0, bytes: Wire.b64("not JSONL")},
        "bad-header"
      )
    )

    assert eventually(fn -> Enum.any?(LinkServer.frames(server), &(&1["re"] == "bad-header")) end)

    assert %{"code" => "bad_request"} =
             Enum.find(LinkServer.frames(server), &(&1["re"] == "bad-header"))

    assert File.read!(other_path) == ""

    secret = Path.join(System.tmp_dir!(), "session-secret-#{System.unique_integer([:positive])}")
    File.write!(secret, "unaltered")
    on_exit(fn -> File.rm(secret) end)
    File.rm!(other_path)
    File.ln_s!(secret, other_path)

    LinkServer.push(
      server,
      Wire.frame("conv.append", %{uid: other_uid, from: 0, bytes: Wire.b64(header)}, "symlink")
    )

    assert eventually(fn -> Enum.any?(LinkServer.frames(server), &(&1["re"] == "symlink")) end)
    assert %{"op" => "error"} = Enum.find(LinkServer.frames(server), &(&1["re"] == "symlink"))
    assert File.read!(secret) == "unaltered"

    assert {:ok, _} = Library.delete_conversation(imported.id)
    LinkServer.push(server, Wire.frame("conv.create", fields, "revival"))

    LinkServer.push(
      server,
      Wire.frame("conv.append", %{uid: uid, from: size, bytes: Wire.b64("x")}, "deleted")
    )

    assert eventually(fn ->
             Enum.count(LinkServer.frames(server), &(&1["re"] in ~w(revival deleted))) == 2
           end)

    frames = Map.new(LinkServer.frames(server), &{&1["re"], &1})
    assert frames["revival"]["code"] == "conflict"
    assert frames["deleted"]["code"] == "not_found"
    assert File.read!(path) == original
  end

  test "an authenticated pairing without a linked computer cannot read the phone's shelf" do
    alias Bezalel.Library
    alias Bezalel.Library.Conversation
    alias Bezalel.Repo

    Repo.delete_all(Conversation)
    on_exit(fn -> Repo.delete_all(Conversation) end)

    {:ok, conversation} =
      Library.create_conversation(%{name: "Private study", kicker: "STUDY", kind: "Study"})

    {:ok, _} = Library.add_message(conversation, %{role: :user, text: "Private text"})
    uid = Library.get_conversation(conversation.id).session_id
    path = Library.session_path(conversation.id)
    on_exit(fn -> File.rm(path) end)
    material = Bezalel.Materials.new("private material", name: "secret.txt")
    {:ok, _} = Bezalel.MaterialStore.put(material, "private material", %{})
    on_exit(fn -> Bezalel.MaterialStore.delete(material.id) end)

    server = LinkServer.start(@origin)
    {pair_id, secret} = LinkServer.offer(server, @browser)
    {:ok, offer} = Link.parse(LinkServer.qr(server, pair_id, secret))
    assert {:ok, _info} = Link.claim(offer)
    assert Store.sessions(@origin) == []

    LinkServer.push(server, Wire.frame("conv.pull", %{uid: uid, from: 0}, "not-linked"))
    LinkServer.push(server, Wire.frame("mat.get", %{sha: material.id, from: 0}, "no-material"))

    LinkServer.push(
      server,
      Wire.frame("conv.append", %{uid: uid, from: 0, bytes: Wire.b64("tampered")}, "no-append")
    )

    assert eventually(fn ->
             Enum.count(
               LinkServer.frames(server),
               &(&1["re"] in ~w(not-linked no-material no-append))
             ) == 3
           end)

    assert %{"op" => "error", "code" => "forbidden"} =
             Enum.find(LinkServer.frames(server), &(&1["re"] == "not-linked"))

    for id <- ~w(no-material no-append) do
      assert %{"op" => "error", "code" => "forbidden"} =
               Enum.find(LinkServer.frames(server), &(&1["re"] == id))
    end

    assert File.read!(path) =~ "Private text"
  end

  test "in the background the socket closes after the grace; nothing is dialled until the foreground" do
    Application.put_env(:bezalel, Link, background_grace: 50)
    server = LinkServer.start(@origin)
    {_offer, _session} = link(server)
    pid = dialer()

    send(pid, {:mob_device, :did_enter_background})
    assert_receive {:bezalel_link, @origin, {:status, :offline}}, 1_000
    Process.sleep(1_500)
    assert LinkServer.connects(server) == 1
    assert Link.status(@origin) == :offline

    send(pid, {:mob_device, :did_become_active})
    assert_receive {:bezalel_link, @origin, {:status, :connected}}, 2_000
    assert LinkServer.connects(server) == 2
  end

  test "backing to the foreground within the grace keeps the socket" do
    Application.put_env(:bezalel, Link, background_grace: 300)
    server = LinkServer.start(@origin)
    {_offer, _session} = link(server)
    pid = dialer()

    send(pid, {:mob_device, :did_enter_background})
    send(pid, {:mob_device, :did_become_active})
    Process.sleep(500)
    assert Link.status(@origin) == :connected
    assert LinkServer.connects(server) == 1
  end

  test "resume/0 dials only the websites with linked computers or log-outs to send" do
    server = LinkServer.start(@origin)
    {_offer, _session} = link(server)
    stop_dialers()
    Store.put_sessions("https://nothing.example", [])

    :ok = Link.resume()
    assert_receive {:bezalel_link, @origin, {:status, :connected}}, 2_000
    assert dialer("https://nothing.example") == nil
  end

  test "equivalent HTTPS spellings share one canonical origin" do
    {pair_id, secret} = Pairing.offer()
    {server_key, _} = Handshake.keypair()

    assert {:ok, %{origin: @origin}} =
             "https://STUDY.EXAMPLE.:443"
             |> Pairing.qr(pair_id, secret, server_key)
             |> Link.parse()
  end

  test "a queued offline revocation prevents replacing that origin's pinned key" do
    {old_key, _} = Handshake.keypair()
    Store.pin(@origin, old_key)
    Store.queue_revoke(@origin, "old-session")

    replacement = LinkServer.start(@origin)
    {pair_id, secret} = LinkServer.offer(replacement, @browser)
    {:ok, offer} = Link.parse(LinkServer.qr(replacement, pair_id, secret))

    assert Link.claim(offer) == {:error, :key_changed}
    assert Store.server_key(@origin) == old_key
    assert Store.revokes(@origin) == ["old-session"]
    assert LinkServer.frames(replacement) == []
  end

  test "a website error does not erase a queued revocation" do
    server = LinkServer.start(@origin, revoke_error: "not_found")
    {_offer, %{"id" => id}} = link(server)

    :ok = Link.revoke(@origin, id)
    assert eventually(fn -> "sessions.revoke" in LinkServer.ops(server) end)
    assert Store.revokes(@origin) == [id]
    assert Store.sessions(@origin) == []
  end

  test "malformed and oversized authenticated frames close safely and reconnect" do
    server = LinkServer.start(@origin)
    {_offer, %{"id" => id}} = link(server)

    LinkServer.push(server, %{"op" => "sessions.changed", "sessions" => %{}})
    assert eventually(fn -> LinkServer.connects(server) == 2 end)
    assert [%{"id" => ^id}] = Store.sessions(@origin)

    LinkServer.push(server, %{
      "op" => "sessions.changed",
      "sessions" => [],
      "padding" => String.duplicate("x", 1_100_000)
    })

    assert eventually(fn -> LinkServer.connects(server) == 3 end)
    assert [%{"id" => ^id}] = Store.sessions(@origin)
  end

  test "a timed-out request no longer keeps an otherwise idle dialer alive" do
    server = LinkServer.start(@origin)
    {_offer, _session} = link(server)
    pid = dialer()

    request = Task.async(fn -> Dialer.request(pid, "test.ignore", %{}, 50) end)
    assert eventually(fn -> "test.ignore" in LinkServer.ops(server) end)
    Store.put_sessions(@origin, [])
    ref = Process.monitor(pid)

    assert Task.await(request) == {:error, :timeout}
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
  end

  test "reconnects back off from about a second to a minute, with jitter" do
    for _ <- 1..50 do
      assert Dialer.backoff(0) in 500..1_000
      assert Dialer.backoff(3) in 4_000..8_000
      assert Dialer.backoff(20) in 30_000..60_000
    end
  end

  # A website conversation the phone hasn't seen: its uid, file name, path
  # and two chunks of transcript (header plus one long line).
  defp web_conversation do
    uid = Ecto.UUID.generate()
    file = "2026-10-20T12-00-00-000Z_#{uid}.jsonl"
    path = Path.join(Rho.Session.dir(), file)
    on_exit(fn -> File.rm(path) end)

    header =
      Jason.encode!(%{
        type: "session",
        version: 3,
        id: uid,
        timestamp: "2026-10-20T12:00:00Z",
        cwd: "/",
        title: "From computer"
      }) <> "\n"

    line =
      Jason.encode!(%{
        type: "custom",
        id: "abcd1234",
        parentId: nil,
        timestamp: "2026-10-20T12:00:01Z",
        customType: "sync.notes",
        content: String.duplicate("m", Wire.chunk_size())
      }) <> "\n"

    %{uid: uid, file: file, path: path, transcript: header <> line}
  end

  # The website's unsent work for `c`, in the Outbox's order: a material
  # (two chunks), the conversation, its transcript (two chunks), a rename.
  defp unsent_work(c, material, bytes) do
    alias Bezalel.Materials

    record = Materials.to_map(material)
    size = Wire.chunk_size()
    [m1, m2] = [binary_part(bytes, 0, size), binary_part(bytes, size, byte_size(bytes) - size)]
    t = c.transcript
    [t1, t2] = [binary_part(t, 0, size), binary_part(t, size, byte_size(t) - size)]

    [
      Wire.frame("mat.put", %{uid: c.uid, record: record, from: 0, bytes: Wire.b64(m1)}, "o-m1"),
      Wire.frame(
        "mat.put",
        %{uid: c.uid, record: record, from: size, bytes: Wire.b64(m2)},
        "o-m2"
      ),
      Wire.frame(
        "conv.create",
        %{
          uid: c.uid,
          session_file: c.file,
          name: "From computer",
          kicker: "STUDY",
          kind: "Study",
          pushback: true
        },
        "o-create"
      ),
      Wire.frame(
        "conv.append",
        %{uid: c.uid, from: 0, bytes: Wire.b64(t1), total: byte_size(t)},
        "o-a1"
      ),
      Wire.frame(
        "conv.append",
        %{uid: c.uid, from: size, bytes: Wire.b64(t2), total: byte_size(t)},
        "o-a2"
      ),
      Wire.frame(
        "conv.meta",
        %{uid: c.uid, fields: %{name: "Renamed on the web"}, updated_at: "2099-01-01T00:00:00Z"},
        "o-meta"
      )
    ]
  end

  defp seal_work(inner) do
    {:ok, {device, _}} = Identity.keypair()
    {:ok, phone_public} = Mailbox.public_key()
    LinkServer.seal_work(Pairing.account_id(device), phone_public, inner)
  end

  defp replies(server, id), do: Enum.filter(LinkServer.frames(server), &(&1["re"] == id))

  describe "work parcels" do
    setup do
      alias Bezalel.Library.Conversation
      alias Bezalel.Repo

      Repo.delete_all(Conversation)
      on_exit(fn -> Repo.delete_all(Conversation) end)
      :ok
    end

    test "with every session expired, the phone stays to apply its parcel, then stops" do
      alias Bezalel.{Library, Materials, MaterialStore}

      bytes = String.duplicate("portable material", 18_000)
      material = Materials.new(bytes, name: "parcel-notes.txt", mime: "text/plain")
      on_exit(fn -> MaterialStore.delete(material.id) end)
      c = web_conversation()
      :ok = Rho.Auth.put(:google, %{"type" => "api_key", "key" => "phone-only-secret"})
      on_exit(fn -> Rho.Auth.delete(:google) end)

      server = LinkServer.start(@origin)
      {_offer, _session} = link(server)
      LinkServer.refuse(server, true)
      LinkServer.close(server, 1001)
      assert_receive {:bezalel_link, @origin, {:status, :offline}}, 2_000

      # Meanwhile the website expired the last session and sealed what the
      # phone hadn't acknowledged.
      LinkServer.put_sessions(server, [])
      records = seal_work(unsent_work(c, material, bytes))
      refute String.contains?(Jason.encode!(records), "parcel-notes")
      LinkServer.put_work(server, records)
      seen = length(LinkServer.frames(server))

      pid = dialer()
      ref = Process.monitor(pid)
      LinkServer.refuse(server, false)
      send(pid, {:mob_device, :connectivity_changed, %{online: true}})
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000

      durable = for %{"id" => id} <- records, do: hd(replies(server, id))
      assert Enum.all?(durable, &(&1["op"] == "ack"))
      # Only the material's first chunk is still staged when acknowledged.
      assert Enum.map(durable, & &1["durable"]) == [false, true, true, true, true, true]
      assert Store.sessions(@origin) == []
      refute Store.dial?(@origin)

      assert [%{name: "Renamed on the web"} = imported] =
               Library.conversations_by_session([c.uid])

      assert File.read!(Library.session_path(imported.id)) == c.transcript
      assert File.read!(c.path) == c.transcript
      assert {:ok, ^material} = MaterialStore.fetch(material.id, %{})
      assert {:ok, ^bytes} = MaterialStore.read(material, %{})
      assert c.uid in MaterialStore.sessions(material.id)

      # Nothing of the phone's went to the account with no computer left.
      sent = Enum.drop(LinkServer.frames(server), seen)

      refute Enum.any?(
               sent,
               &(&1["op"] in ~w(cred.mailbox cred.set cred.delete cred.snapshot index.snapshot
                   index.upsert index.remove prefs.snapshot))
             )

      refute String.contains?(Jason.encode!(sent), "phone-only-secret")
    end

    test "a parcel cut short survives the app's restart; the next launch dials for the rest" do
      alias Bezalel.{Library, Materials, MaterialStore}

      bytes = String.duplicate("portable material", 18_000)
      material = Materials.new(bytes, name: "restart.txt", mime: "text/plain")
      on_exit(fn -> MaterialStore.delete(material.id) end)
      c = web_conversation()

      server = LinkServer.start(@origin)
      {_offer, _session} = link(server)
      LinkServer.refuse(server, true)
      LinkServer.close(server, 1001)
      assert_receive {:bezalel_link, @origin, {:status, :offline}}, 2_000

      LinkServer.put_sessions(server, [])
      records = seal_work(unsent_work(c, material, bytes))
      LinkServer.put_work(server, records)
      # The material's two chunks arrive, then the app is killed.
      LinkServer.limit_work(server, 2)
      LinkServer.refuse(server, false)
      send(dialer(), {:mob_device, :connectivity_changed, %{online: true}})
      [_, second | rest] = records
      assert eventually(fn -> replies(server, second["id"]) != [] end)
      assert eventually(fn -> LinkServer.work(server) == rest end)
      stop_dialers()

      assert Store.sessions(@origin) == []
      assert Store.dial?(@origin)
      assert Library.conversations_by_session([c.uid]) == []

      # The next launch.
      LinkServer.limit_work(server, nil)
      :ok = Link.resume()
      pid = dialer()
      assert is_pid(pid)
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000

      for %{"id" => id} <- records, do: assert([%{"op" => "ack"}] = replies(server, id))
      assert LinkServer.work(server) == []
      refute Store.dial?(@origin)
      assert [imported] = Library.conversations_by_session([c.uid])
      assert File.read!(Library.session_path(imported.id)) == c.transcript
      assert {:ok, ^bytes} = MaterialStore.read(material, %{})
    end

    test "a parcel delivered again (its ACKs lost) applies nothing twice" do
      alias Bezalel.{Library, Materials, MaterialStore}

      bytes = String.duplicate("portable material", 18_000)
      material = Materials.new(bytes, name: "again.txt", mime: "text/plain")
      on_exit(fn -> MaterialStore.delete(material.id) end)
      c = web_conversation()

      server = LinkServer.start(@origin)
      {_offer, _session} = link(server)
      records = seal_work(unsent_work(c, material, bytes))
      last = List.last(records)["id"]

      for round <- 1..2 do
        LinkServer.put_work(server, records)
        LinkServer.close(server, 1001)
        assert_receive {:bezalel_link, @origin, {:status, :offline}}, 2_000
        assert_receive {:bezalel_link, @origin, {:status, :connected}}, 3_000
        assert eventually(fn -> length(replies(server, last)) == round end, 250)
      end

      for %{"id" => id} <- records,
          do: assert([%{"op" => "ack"}, %{"op" => "ack"}] = replies(server, id))

      assert [imported] = Library.conversations_by_session([c.uid])
      assert File.read!(Library.session_path(imported.id)) == c.transcript
      assert {:ok, ^bytes} = MaterialStore.read(material, %{})
      assert MaterialStore.sessions(material.id) == [c.uid]
      assert dialer() != nil
    end

    test "a tampered record, another account's or a disallowed op is refused and applies nothing" do
      alias Bezalel.Library

      server = LinkServer.start(@origin)
      {_offer, _session} = link(server)
      assert eventually(fn -> "index.snapshot" in LinkServer.ops(server) end)
      c = web_conversation()
      other = web_conversation()
      {:ok, {device, _}} = Identity.keypair()
      {:ok, phone_public} = Mailbox.public_key()

      create = fn conversation, id ->
        Wire.frame(
          "conv.create",
          %{
            uid: conversation.uid,
            session_file: conversation.file,
            name: "Should not appear",
            kicker: "STUDY",
            kind: "Study",
            pushback: false
          },
          id
        )
      end

      [tampered] = seal_work([create.(c, "o-tampered")])
      {:ok, tag} = Wire.unb64(tampered["tag"])
      <<first, tag_rest::binary>> = tag
      tampered = %{tampered | "tag" => Wire.b64(<<Bitwise.bxor(first, 1), tag_rest::binary>>)}

      [elsewhere] =
        LinkServer.seal_work(
          "acct_" <> Pairing.account_id(device),
          phone_public,
          [create.(other, "o-elsewhere")]
        )

      [pull] = seal_work([Wire.frame("conv.pull", %{uid: c.uid, from: 0}, "o-pull")])

      for record <- [tampered, elsewhere, pull], do: LinkServer.push(server, record)

      assert eventually(fn ->
               Enum.all?([tampered, elsewhere, pull], &(replies(server, &1["id"]) != []))
             end)

      for record <- [tampered, elsewhere, pull] do
        assert [%{"op" => "error", "code" => "bad_envelope"}] = replies(server, record["id"])
      end

      assert Library.conversations_by_session([c.uid, other.uid]) == []
      refute File.exists?(c.path)
      refute File.exists?(other.path)
      refute Enum.any?(LinkServer.frames(server), &(&1["op"] == "conv.data"))
    end

    test "a conversation the phone is answering in refuses the parcel's append: held_by_phone" do
      alias Bezalel.Library

      server = LinkServer.start(@origin)
      {_offer, _session} = link(server)

      {:ok, conversation} =
        Library.create_conversation(%{name: "Busy", kicker: "STUDY", kind: "Study"})

      {:ok, _} = Library.add_message(conversation, %{role: :user, text: "Phone turn"})
      uid = Library.get_conversation(conversation.id).session_id
      path = Library.session_path(conversation.id)
      on_exit(fn -> File.rm(path) end)
      before = File.read!(path)

      assert :ok = Turns.phone_turn(uid, :start)

      [append] =
        seal_work([
          Wire.frame(
            "conv.append",
            %{
              uid: uid,
              from: byte_size(before),
              bytes: Wire.b64("{}\n"),
              total: byte_size(before) + 3
            },
            "o-held"
          )
        ])

      LinkServer.push(server, append)
      assert eventually(fn -> replies(server, append["id"]) != [] end)

      assert [%{"op" => "error", "code" => "held_by_phone"}] = replies(server, append["id"])
      assert File.read!(path) == before
      assert :ok = Turns.phone_turn(uid, :finish)
    end
  end

  describe "sealed credential exchange" do
    setup do
      for provider <- Rho.Auth.providers() do
        :ok = Rho.Auth.delete(provider)
        Creds.current(provider)
      end

      on_exit(fn ->
        for provider <- Rho.Auth.providers(), do: Rho.Auth.delete(provider)
      end)

      :ok
    end

    test "a scanned code cannot disclose credentials before the user's approval" do
      :ok = Rho.Auth.put_api_key(:google, "private-key")
      server = LinkServer.start(@origin)
      {pair_id, secret} = LinkServer.offer(server, @browser)
      {:ok, offer} = Link.parse(LinkServer.qr(server, pair_id, secret))

      assert {:ok, _info} = Link.claim(offer)
      refute Enum.any?(LinkServer.ops(server), &String.starts_with?(&1, "cred."))

      assert {:ok, _session} = Link.approve(offer)

      assert eventually(fn ->
               Enum.any?(LinkServer.frames(server), fn
                 %{"op" => "cred.snapshot", "creds" => %{"google" => %{"key" => "private-key"}}} ->
                   true

                 _ ->
                   false
               end)
             end)
    end

    test "reconnect sends the phone snapshot and offline deletion before it" do
      :ok = Rho.Auth.put_api_key(:google, "phone-key")
      server = LinkServer.start(@origin)
      {_offer, _session} = link(server)

      assert eventually(fn ->
               Enum.any?(LinkServer.frames(server), fn
                 %{"op" => "cred.snapshot", "creds" => %{"google" => %{"key" => "phone-key"}}} ->
                   true

                 _ ->
                   false
               end)
             end)

      :ok = Rho.Auth.put_api_key(:google, "new-key")

      assert eventually(fn ->
               Enum.any?(LinkServer.frames(server), fn
                 %{"op" => "cred.set", "provider" => "google", "creds" => %{"key" => "new-key"}} ->
                   true

                 _ ->
                   false
               end)
             end)

      old = Creds.current(:google) |> elem(1) |> Map.fetch!(:at)
      LinkServer.refuse(server, true)
      LinkServer.close(server, 1001)
      assert_receive {:bezalel_link, @origin, {:status, :offline}}, 2_000
      :ok = Rho.Auth.delete(:google)

      assert eventually(fn ->
               {_, %{at: at, present: false}} = Creds.current(:google)
               at > old
             end)

      # The server's queued stale key arrives before cred.sync, but cannot
      # undo the phone's later offline sign-out.
      LinkServer.on_connect(server, [
        Wire.frame("cred.set", %{
          provider: "google",
          creds: %{"type" => "api_key", "key" => "new-key"},
          updated_at: old
        })
      ])

      LinkServer.refuse(server, false)
      send(dialer(), {:mob_device, :connectivity_changed, %{online: true}})
      assert eventually(fn -> LinkServer.connects(server) == 2 end)

      assert eventually(fn ->
               Enum.any?(
                 LinkServer.frames(server),
                 &(&1["op"] == "cred.delete" and &1["provider"] == "google")
               )
             end)

      assert Rho.Auth.get(:google) == :error

      assert eventually(fn ->
               snapshots = Enum.filter(LinkServer.frames(server), &(&1["op"] == "cred.snapshot"))

               Enum.count_until(snapshots, 2) == 2 and
                 not Map.has_key?(List.last(snapshots)["creds"], "google")
             end)
    end

    test "offline final logout stores and acknowledges a rotation before revoking" do
      now = System.os_time(:millisecond)

      old = %{
        "type" => "oauth",
        "access" => "old",
        "refresh" => "spent",
        "expires" => now + 3_600_000
      }

      rotated = %{old | "access" => "new", "refresh" => "rotated", "expires" => now + 7_200_000}
      :ok = Rho.Auth.put(:anthropic, old)
      server = LinkServer.start(@origin)
      {_offer, %{"id" => id}} = link(server)
      old_at = Creds.current(:anthropic) |> elem(1) |> Map.fetch!(:at)

      LinkServer.refuse(server, true)
      LinkServer.close(server, 1001)
      assert_receive {:bezalel_link, @origin, {:status, :offline}}, 2_000
      :ok = Link.revoke(@origin, id)
      assert Store.sessions(@origin) == []
      assert Store.revokes(@origin) == [id]

      LinkServer.on_connect(server, [
        Wire.frame(
          "cred.rotated",
          %{
            provider: "anthropic",
            creds: rotated,
            updated_at: old_at + 1
          },
          812
        )
      ])

      LinkServer.refuse(server, false)
      send(dialer(), {:mob_device, :connectivity_changed, %{online: true}})

      assert eventually(fn ->
               frames = LinkServer.frames(server)

               Enum.any?(frames, &(&1["op"] == "ack" and &1["re"] == 812)) and
                 Enum.any?(frames, &(&1["op"] == "sessions.revoke" and &1["session"] == id))
             end)

      frames = LinkServer.frames(server)
      ack = Enum.find_index(frames, &(&1["op"] == "ack" and &1["re"] == 812))
      revoke = Enum.find_index(frames, &(&1["op"] == "sessions.revoke" and &1["session"] == id))
      assert ack < revoke
      assert Rho.Auth.get(:anthropic) == {:ok, rotated}
      assert eventually(fn -> Store.revokes(@origin) == [] end)
      assert LinkServer.sessions(server) == []
    end

    test "sealed offline rotation is decrypted and ACKed before the final revoke" do
      now = System.os_time(:millisecond)

      old = %{
        "type" => "oauth",
        "access" => "old",
        "refresh" => "spent",
        "expires" => now + 3_600_000
      }

      rotated = %{
        old
        | "access" => "fresh",
          "refresh" => "new-grant",
          "expires" => now + 7_200_000
      }

      :ok = Rho.Auth.put(:anthropic, old)
      server = LinkServer.start(@origin)
      {_offer, %{"id" => id}} = link(server)
      old_at = Creds.current(:anthropic) |> elem(1) |> Map.fetch!(:at)

      LinkServer.refuse(server, true)
      LinkServer.close(server, 1001)
      assert_receive {:bezalel_link, @origin, {:status, :offline}}, 2_000
      :ok = Link.revoke(@origin, id)
      {:ok, {device, _}} = Identity.keypair()
      envelope = seal_for_phone(Pairing.account_id(device), "anthropic", rotated, old_at + 1)
      refute String.contains?(Jason.encode!(envelope), "new-grant")
      LinkServer.on_connect(server, [envelope])

      LinkServer.refuse(server, false)
      send(dialer(), {:mob_device, :connectivity_changed, %{online: true}})

      assert eventually(fn ->
               frames = LinkServer.frames(server)

               Enum.any?(frames, &(&1["op"] == "ack" and &1["re"] == envelope["id"])) and
                 Enum.any?(frames, &(&1["op"] == "sessions.revoke" and &1["session"] == id))
             end)

      frames = LinkServer.frames(server)
      ack = Enum.find_index(frames, &(&1["op"] == "ack" and &1["re"] == envelope["id"]))
      revoke = Enum.find_index(frames, &(&1["op"] == "sessions.revoke" and &1["session"] == id))
      assert ack < revoke
      assert Rho.Auth.get(:anthropic) == {:ok, rotated}
      assert eventually(fn -> Store.revokes(@origin) == [] end)
    end

    test "queued rotation wins before snapshot; older OAuth grant never replaces it" do
      now = System.os_time(:millisecond)

      old = %{
        "type" => "oauth",
        "access" => "old",
        "refresh" => "spent",
        "expires" => now + 3_600_000
      }

      rotated = %{old | "access" => "new", "refresh" => "rotated", "expires" => now + 7_200_000}
      :ok = Rho.Auth.put(:anthropic, old)
      server = LinkServer.start(@origin)
      {_offer, _session} = link(server)
      stop_dialers()
      old_at = Creds.current(:anthropic) |> elem(1) |> Map.fetch!(:at)

      LinkServer.on_connect(server, [
        Wire.frame("cred.rotated", %{
          provider: "anthropic",
          creds: rotated,
          updated_at: old_at + 1
        }),
        Wire.frame("cred.set", %{provider: "anthropic", creds: old, updated_at: old_at + 2})
      ])

      :ok = Link.resume()
      assert eventually(fn -> LinkServer.connects(server) == 2 end)

      assert eventually(fn ->
               Enum.any?(LinkServer.frames(server), fn
                 %{
                   "op" => "cred.snapshot",
                   "creds" => %{"anthropic" => %{"refresh" => "rotated"}}
                 } ->
                   true

                 _ ->
                   false
               end)
             end)

      assert Rho.Auth.get(:anthropic) == {:ok, rotated}

      # A web-origin key is stored through rho without affecting another
      # provider; an unlisted provider cannot create an atom or credential.
      version = Creds.current(:openai) |> elem(1)
      previous_at = if version, do: version.at, else: 0
      web_at = max(now + 10_000, previous_at + 1)

      LinkServer.push(
        server,
        Wire.frame(
          "cred.set",
          %{
            provider: "openai",
            creds: %{"type" => "api_key", "key" => "web-key"},
            updated_at: web_at
          },
          81
        )
      )

      assert eventually(fn ->
               Rho.Auth.get(:openai) == {:ok, %{"type" => "api_key", "key" => "web-key"}}
             end)

      assert Rho.Auth.get(:anthropic) == {:ok, rotated}

      LinkServer.push(
        server,
        Wire.frame(
          "cred.set",
          %{
            provider: "other-account",
            creds: %{"type" => "api_key", "key" => "not-ours"},
            updated_at: now + 20_000
          },
          82
        )
      )

      assert eventually(fn ->
               Enum.any?(LinkServer.frames(server), &(&1["re"] == 82 and &1["op"] == "error"))
             end)

      assert Rho.Auth.get(:anthropic) == {:ok, rotated}
    end

    test "a welcome for an unrelated account cannot receive or change this phone's credentials" do
      :ok = Rho.Auth.put_api_key(:google, "ours")
      server = LinkServer.start(@origin)
      {_offer, _session} = link(server)
      assert eventually(fn -> "cred.snapshot" in LinkServer.ops(server) end)
      stop_dialers()
      before = length(LinkServer.frames(server))

      LinkServer.claim_account(server, "acct_another_device")

      LinkServer.on_connect(server, [
        Wire.frame("cred.set", %{
          provider: "google",
          creds: %{"type" => "api_key", "key" => "theirs"},
          updated_at: System.os_time(:millisecond) + 1_000_000
        })
      ])

      :ok = Link.resume()
      assert_receive {:bezalel_link, @origin, {:status, {:error, :wrong_account}}}, 2_000
      assert Rho.Auth.get(:google) == {:ok, %{"type" => "api_key", "key" => "ours"}}

      refute Enum.any?(
               Enum.drop(LinkServer.frames(server), before),
               &(&1["op"] in ["cred.set", "cred.snapshot"])
             )
    end

    test "a server refresh request answers with a credential from the phone's secure store" do
      now = System.os_time(:millisecond)

      oauth = %{
        "type" => "oauth",
        "access" => "usable",
        "refresh" => "grant",
        "expires" => now + 3_600_000
      }

      :ok = Rho.Auth.put(:anthropic, oauth)
      server = LinkServer.start(@origin)
      {_offer, _session} = link(server)
      before = length(LinkServer.frames(server))

      LinkServer.push(server, Wire.frame("cred.refresh", %{provider: "anthropic"}))

      assert eventually(fn ->
               LinkServer.frames(server)
               |> Enum.drop(before)
               |> Enum.any?(fn
                 %{
                   "op" => "cred.set",
                   "provider" => "anthropic",
                   "creds" => %{"access" => "usable"},
                   "updated_at" => at
                 }
                 when is_integer(at) ->
                   true

                 _ ->
                   false
               end)
             end)

      assert Rho.Auth.get(:anthropic) == {:ok, oauth}
    end

    test "before cred.sync no credential leaves the phone: a refresh is forbidden, a stale update only acknowledged" do
      :ok = Rho.Auth.put_api_key(:google, "phone-key")
      server = LinkServer.start(@origin)
      {_offer, _session} = link(server)
      assert eventually(fn -> "cred.snapshot" in LinkServer.ops(server) end)

      # Queued by the website, delivered between welcome and cred.sync.
      LinkServer.on_connect(server, [
        Wire.frame("cred.refresh", %{provider: "google"}, "early-refresh"),
        Wire.frame(
          "cred.set",
          %{provider: "google", creds: %{"type" => "api_key", "key" => "older"}, updated_at: 1},
          "early-stale"
        )
      ])

      seen = length(LinkServer.frames(server))
      LinkServer.close(server, 1001)
      assert_receive {:bezalel_link, @origin, {:status, :offline}}, 2_000
      assert_receive {:bezalel_link, @origin, {:status, :connected}}, 3_000
      sent = fn -> Enum.drop(LinkServer.frames(server), seen) end

      assert eventually(fn ->
               ops = Enum.map(sent.(), & &1["op"])

               "cred.snapshot" in ops and
                 Enum.all?(~w(early-refresh early-stale), fn id ->
                   Enum.any?(sent.(), &(&1["re"] == id))
                 end)
             end)

      assert %{"op" => "error", "code" => "forbidden"} =
               Enum.find(sent.(), &(&1["re"] == "early-refresh"))

      assert %{"op" => "ack"} = Enum.find(sent.(), &(&1["re"] == "early-stale"))
      {before_sync, _} = Enum.split_while(sent.(), &(&1["op"] != "cred.mailbox"))
      refute Enum.any?(before_sync, &(&1["op"] in ["cred.set", "cred.delete"]))
      assert {:ok, %{"key" => "phone-key"}} = Rho.Auth.get(:google)
    end
  end

  describe "canonical conversation index" do
    setup do
      alias Bezalel.Library.Conversation
      alias Bezalel.Repo

      Repo.delete_all(Conversation)
      on_exit(fn -> Repo.delete_all(Conversation) end)
      :ok
    end

    test "the credential barrier precedes the snapshot; shelf changes send one-conversation deltas and reconnect reconciles offline edits" do
      alias Bezalel.Library
      alias Bezalel.Link.Index

      {:ok, blank} =
        Library.create_conversation(%{name: "No session", kicker: "STUDY", kind: "Study"})

      server = LinkServer.start(@origin)
      {pair_id, secret} = LinkServer.offer(server, @browser)
      {:ok, offer} = Link.parse(LinkServer.qr(server, pair_id, secret))
      assert {:ok, _} = Link.claim(offer)
      refute "index.snapshot" in LinkServer.ops(server)
      assert {:ok, _} = Link.approve(offer)
      assert eventually(fn -> "index.snapshot" in LinkServer.ops(server) end)

      frames = LinkServer.frames(server)

      assert Enum.find_index(frames, &(&1["op"] == "cred.snapshot")) <
               Enum.find_index(frames, &(&1["op"] == "index.snapshot"))

      assert %{"entries" => []} = Enum.find(frames, &(&1["op"] == "index.snapshot"))
      assert Index.entry(blank.id) == nil

      {:ok, written} =
        Library.create_conversation(%{name: "New study", kicker: "STUDY", kind: "Study"})

      {:ok, _} =
        Library.add_message(written, %{role: :user, text: "Private question not indexed"})

      assert %{name: named} = Library.name_after(written.id, "Why is the passage significant?")
      assert named != "New study"

      assert eventually(fn ->
               Enum.any?(LinkServer.frames(server), fn
                 %{"op" => "index.upsert", "entry" => %{"name" => ^named}} -> true
                 _ -> false
               end)
             end)

      {:ok, _} =
        Library.add_message(written, %{
          role: :agent,
          blocks: [
            %{"id" => "sum", "type" => "SUMMARY", "first" => "A visible answer.", "rest" => ""}
          ]
        })

      assert eventually(fn ->
               Enum.any?(LinkServer.frames(server), fn
                 %{"op" => "index.upsert", "entry" => %{"preview" => "A visible answer."}} ->
                   true

                 _ ->
                   false
               end)
             end)

      uid = Library.get_conversation(written.id).session_id
      entry = Index.entry(written.id)
      assert entry.uid == uid
      assert entry.size == File.stat!(Library.session_path(written.id)).size
      assert entry.message_count == 2

      assert Map.keys(entry) |> Enum.sort() ==
               ~w(kicker kind message_count name preview pushback session_file size summary uid updated_at)a
               |> Enum.sort()

      refute Jason.encode!(entry) =~ "Private question"

      assert Library.put_title(
               written.id,
               %{title: "Named study", summary: "The short synopsis"},
               2
             )

      assert Library.put_pushback(written.id, true).pushback

      assert eventually(fn ->
               Enum.any?(LinkServer.frames(server), fn
                 %{
                   "op" => "index.upsert",
                   "entry" => %{
                     "uid" => ^uid,
                     "name" => "Named study",
                     "summary" => "The short synopsis",
                     "pushback" => true
                   }
                 } ->
                   true

                 _ ->
                   false
               end)
             end)

      assert {:ok, deleted} = Library.delete_conversation(written.id)

      assert eventually(fn ->
               Enum.any?(
                 LinkServer.frames(server),
                 &(&1["op"] == "index.remove" and &1["uid"] == uid)
               )
             end)

      assert :ok = Library.undelete(deleted)

      assert eventually(fn ->
               Enum.count(LinkServer.frames(server), fn
                 %{"op" => "index.upsert", "entry" => %{"uid" => ^uid}} -> true
                 _ -> false
               end) >= 3
             end)

      LinkServer.refuse(server, true)
      LinkServer.close(server, 1001)
      assert_receive {:bezalel_link, @origin, {:status, :offline}}, 2_000
      assert Library.put_title(written.id, %{title: "Changed offline", summary: "Reconciled"}, 2)
      LinkServer.refuse(server, false)
      send(dialer(), {:mob_device, :connectivity_changed, %{online: true}})

      assert eventually(fn ->
               Enum.any?(LinkServer.frames(server), fn
                 %{"op" => "index.snapshot", "entries" => entries} ->
                   Enum.any?(entries, &(&1["uid"] == uid and &1["name"] == "Changed offline"))

                 _ ->
                   false
               end)
             end)
    end

    test "unwritten sessions stay off the index and public metadata is bounded" do
      alias Bezalel.Library
      alias Bezalel.Link.Index

      {:ok, c} =
        Library.create_conversation(%{
          name: "Untitled",
          kicker: String.duplicate("k", 80),
          kind: String.duplicate("t", 80)
        })

      assert {:ok, _, []} = Library.session(c.id, "anthropic/claude-sonnet-4-5")
      assert Index.entry(c.id) == nil
      assert Index.snapshot() == []

      {:ok, _} = Library.add_message(c, %{role: :user, text: "Private full transcript"})

      {:ok, _} =
        Library.add_message(c, %{
          role: :agent,
          blocks: [
            %{
              "id" => "sum",
              "type" => "SUMMARY",
              "first" => String.duplicate("p", 200),
              "rest" => ""
            }
          ]
        })

      Library.put_title(
        c.id,
        %{
          title: String.duplicate("n", 300),
          summary: String.duplicate("s", 600)
        },
        2
      )

      entry = Index.entry(c.id)
      assert String.length(entry.name) == 256
      assert String.length(entry.summary) == 500
      assert String.length(entry.kicker) == 64
      assert String.length(entry.kind) == 64
      assert String.length(entry.preview) == 140
      refute Jason.encode!(entry) =~ "Private full transcript"
    end
  end

  # The phone's own conversation with a written session.
  defp phone_conversation(text) do
    alias Bezalel.Library

    {:ok, c} =
      Library.create_conversation(%{name: "Phone study", kicker: "STUDY", kind: "Study"})

    {:ok, _} = Library.add_message(c, %{role: :user, text: text})
    c = Library.get_conversation(c.id)
    path = Library.session_path(c.id)
    on_exit(fn -> File.rm(path) end)
    %{id: c.id, uid: c.session_id, file: c.session_file, path: path}
  end

  defp leaf_id(path) do
    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> List.last()
    |> Jason.decode!()
    |> Map.fetch!("id")
  end

  # A question asked on the computer, as its session line.
  defp web_line(id, parent, text) do
    text
    |> Transcript.user()
    |> Map.merge(%{"id" => id, "parentId" => parent, "timestamp" => "2026-10-20T12:00:01Z"})
    |> Jason.encode!()
    |> Kernel.<>("\n")
  end

  defp every_line_parses?(path) do
    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.all?(&match?({:ok, %{}}, Jason.decode(&1)))
  end

  defp texts_of(id), do: for(m <- Bezalel.Library.messages(id), do: m.text)

  defp answer(server, id) do
    assert eventually(fn -> replies(server, id) != [] end)
    hd(replies(server, id))
  end

  defp create_frame(c, id, extra \\ %{}) do
    Wire.frame(
      "conv.create",
      Map.merge(
        %{
          uid: c.uid,
          session_file: c.file,
          name: "From computer",
          kicker: "STUDY",
          kind: "Study",
          pushback: false
        },
        extra
      ),
      id
    )
  end

  test "a conversation's lock excludes the same uid across processes and leaves other uids free" do
    [a, b] = [Ecto.UUID.generate(), Ecto.UUID.generate()]
    parent = self()

    holder =
      spawn(fn ->
        Serve.locked(a, fn ->
          send(parent, :held)

          receive do
            :go -> :ok
          end
        end)
      end)

    assert_receive :held
    {micro, :free} = :timer.tc(fn -> Serve.locked(b, fn -> :free end) end)
    assert micro < 200_000

    second = Task.async(fn -> Serve.locked(a, fn -> :second end) end)
    refute Task.yield(second, 300)
    send(holder, :go)
    assert Task.await(second) == :second
  end

  test "uploads staged when the app was killed are swept at start; set-aside lines stay" do
    alias Bezalel.MaterialStore

    uid = Ecto.UUID.generate()
    artifacts = Path.join([Rho.Config.data_dir(), "artifacts", uid])
    for dir <- [artifacts, Rho.Session.dir(), MaterialStore.dir()], do: File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(artifacts) end)

    staged = [
      Path.join(MaterialStore.dir(), ".link-mat-killed"),
      Path.join(Rho.Session.dir(), ".link-conflict-killed"),
      Path.join(artifacts, ".link-art-killed")
    ]

    kept = [Path.join(Rho.Session.dir(), ".link-torn-" <> uid), Path.join(artifacts, "call.txt")]
    for path <- staged ++ kept, do: File.write!(path, "x")
    on_exit(fn -> Enum.each(staged ++ kept, &File.rm/1) end)

    assert :ok = Serve.sweep()
    refute Enum.any?(staged, &File.exists?/1)
    assert Enum.all?(kept, &File.exists?/1)
  end

  describe "conversation writes from a linked computer" do
    setup do
      alias Bezalel.Library.Conversation
      alias Bezalel.Repo

      Repo.delete_all(Conversation)
      on_exit(fn -> Repo.delete_all(Conversation) end)
      server = LinkServer.start(@origin)
      {_offer, _session} = link(server)
      assert eventually(fn -> "index.snapshot" in LinkServer.ops(server) end)
      %{server: server}
    end

    test "a website's delete, live or from a work parcel, removes the conversation for good", %{
      server: server
    } do
      alias Bezalel.Library

      c = web_conversation()
      LinkServer.push(server, create_frame(c, "create"))
      assert %{"op" => "ack"} = answer(server, "create")
      assert_receive {:bezalel_link, @origin, {:conversation_changed, id}}
      LinkServer.push(server, Wire.frame("conv.delete", %{uid: c.uid}, "delete"))
      assert %{"op" => "ack"} = answer(server, "delete")
      assert_receive {:bezalel_link, @origin, {:conversation_removed, ^id}}
      assert Library.conversations_by_session([c.uid]) == []
      refute File.exists?(c.path)
      LinkServer.push(server, create_frame(c, "revive"))
      assert %{"code" => "conflict"} = answer(server, "revive")

      other = web_conversation()
      LinkServer.push(server, create_frame(other, "create-other"))
      assert %{"op" => "ack"} = answer(server, "create-other")
      assert_receive {:bezalel_link, @origin, {:conversation_changed, other_id}}
      [record] = seal_work([Wire.frame("conv.delete", %{uid: other.uid}, "o-delete")])
      LinkServer.push(server, record)
      assert %{"op" => "ack", "durable" => true} = answer(server, record["id"])
      assert_receive {:bezalel_link, @origin, {:conversation_removed, ^other_id}}
      assert Library.conversations_by_session([other.uid]) == []

      # A uid the phone never had leaves no tombstone behind.
      never = web_conversation()
      LinkServer.push(server, Wire.frame("conv.delete", %{uid: never.uid}, "delete-unknown"))
      assert %{"op" => "ack"} = answer(server, "delete-unknown")
      refute_receive {:bezalel_link, @origin, {:conversation_removed, _}}, 50
      LinkServer.push(server, create_frame(never, "create-unknown"))
      assert %{"op" => "ack"} = answer(server, "create-unknown")

      # The dialer still answers.
      LinkServer.push(server, Wire.frame("conv.hold", %{uid: never.uid}, "still-there"))
      assert %{"op" => "ack"} = answer(server, "still-there")
    end

    test "a conversation deleted on the phone can't be created again by a computer", %{
      server: server
    } do
      alias Bezalel.Library

      c = phone_conversation("Phone question")
      {:ok, deleted} = Library.delete_conversation(c.id)
      :ok = Library.purge(deleted)

      LinkServer.push(server, create_frame(c, "revive"))
      assert %{"code" => "conflict"} = answer(server, "revive")
      assert Library.conversations_by_session([c.uid]) == []
      refute File.exists?(c.path)
    end

    test "a phone write after a website's torn last line keeps both: the line is set aside, its resend merged",
         %{server: server} do
      alias Bezalel.Library

      c = phone_conversation("Phone question")
      size = File.stat!(c.path).size
      line = web_line("web00001", leaf_id(c.path), "From the computer")
      total = size + byte_size(line)
      cut = 20

      LinkServer.push(
        server,
        Wire.frame(
          "conv.append",
          %{uid: c.uid, from: size, bytes: Wire.b64(binary_part(line, 0, cut)), total: total},
          "torn"
        )
      )

      assert %{"op" => "ack", "size" => torn} = answer(server, "torn")
      assert torn == size + cut

      {:ok, _} =
        Library.add_message(Library.get_conversation(c.id), %{role: :user, text: "Again"})

      assert every_line_parses?(c.path)
      assert texts_of(c.id) == ["Phone question", "Again"]

      rest = binary_part(line, cut, byte_size(line) - cut)

      LinkServer.push(
        server,
        Wire.frame(
          "conv.append",
          %{uid: c.uid, from: size + cut, bytes: Wire.b64(rest), total: total},
          "resend"
        )
      )

      assert %{"op" => "conv.reset"} = answer(server, "resend")
      assert every_line_parses?(c.path)
      assert "From the computer" in texts_of(c.id)
      assert "Again" in texts_of(c.id)
    end

    test "a torn line the phone wrote nothing after goes back for its resend: the file ends as the website's",
         %{server: server} do
      c = phone_conversation("Phone question")
      before = File.read!(c.path)
      size = byte_size(before)
      line = web_line("web00001", leaf_id(c.path), "From the computer")
      total = size + byte_size(line)
      cut = 20

      LinkServer.push(
        server,
        Wire.frame(
          "conv.append",
          %{uid: c.uid, from: size, bytes: Wire.b64(binary_part(line, 0, cut)), total: total},
          "torn"
        )
      )

      assert %{"op" => "ack"} = answer(server, "torn")
      # A phone turn sets the torn line aside before anything is written.
      assert :ok = Turns.phone_turn(c.uid, :start)
      assert File.read!(c.path) == before
      assert :ok = Turns.phone_turn(c.uid, :finish)

      rest = binary_part(line, cut, byte_size(line) - cut)

      LinkServer.push(
        server,
        Wire.frame(
          "conv.append",
          %{uid: c.uid, from: size + cut, bytes: Wire.b64(rest), total: total},
          "resend"
        )
      )

      assert %{"op" => "ack", "size" => ^total} = answer(server, "resend")
      assert File.read!(c.path) == before <> line
    end

    test "a resend from inside a torn line (its last ack lost) finishes it, whether or not the phone wrote since",
         %{server: server} do
      alias Bezalel.Library

      append = fn c, from, bytes, total, id ->
        LinkServer.push(
          server,
          Wire.frame(
            "conv.append",
            %{uid: c.uid, from: from, bytes: Wire.b64(bytes), total: total},
            id
          )
        )

        answer(server, id)
      end

      for phone_writes? <- [false, true] do
        c = phone_conversation("Phone question")
        before = File.read!(c.path)
        size = byte_size(before)
        line = web_line("web00001", leaf_id(c.path), "From the computer")
        total = size + byte_size(line)
        tag = "#{phone_writes?}"

        # Two chunks are written; the second's ack is lost with the socket.
        assert %{"op" => "ack"} = append.(c, size, binary_part(line, 0, 10), total, "a1" <> tag)

        assert %{"op" => "ack"} =
                 append.(c, size + 10, binary_part(line, 10, 10), total, "a2" <> tag)

        assert :ok = Turns.phone_turn(c.uid, :start)
        assert :ok = Turns.phone_turn(c.uid, :finish)

        if phone_writes?,
          do:
            {:ok, _} =
              Library.add_message(Library.get_conversation(c.id), %{role: :user, text: "Again"})

        # The website resends from the last offset it heard acknowledged.
        rest = binary_part(line, 10, byte_size(line) - 10)
        answer = append.(c, size + 10, rest, total, "resend" <> tag)
        assert every_line_parses?(c.path)
        assert "From the computer" in texts_of(c.id)

        if phone_writes? do
          assert %{"op" => "conv.reset"} = answer
          assert "Again" in texts_of(c.id)
        else
          assert %{"op" => "ack", "size" => ^total} = answer
          assert File.read!(c.path) == before <> line
        end
      end
    end

    test "a merge never appends after a torn last line of the phone's file", %{server: server} do
      alias Bezalel.Library

      c = phone_conversation("Phone question")
      size = File.stat!(c.path).size
      line = web_line("web00003", leaf_id(c.path), "From the computer")

      {:ok, _} =
        Library.add_message(Library.get_conversation(c.id), %{role: :user, text: "Again"})

      # A write cut short (the app killed mid-append).
      File.write!(c.path, ~s({"type":"mess), [:append])

      LinkServer.push(
        server,
        Wire.frame(
          "conv.append",
          %{uid: c.uid, from: size, bytes: Wire.b64(line), total: size + byte_size(line)},
          "diverged"
        )
      )

      assert %{"op" => "conv.reset"} = answer(server, "diverged")
      assert every_line_parses?(c.path)
      assert ["Phone question", "Again", "From the computer"] -- texts_of(c.id) == []
    end

    test "a phone turn never waits on a busy dialer, and a dialer started mid-turn holds it at welcome",
         %{server: server} do
      c = phone_conversation("Phone question")

      holds = fn ->
        Enum.count(LinkServer.frames(server), &(&1["op"] == "conv.hold" and &1["uid"] == c.uid))
      end

      pid = dialer()
      :ok = :sys.suspend(pid)

      try do
        {micro, result} = :timer.tc(fn -> Turns.phone_turn(c.uid, :start) end)
        assert result == :ok
        assert micro < 1_000_000
        refute Turns.held?(c.uid)
      after
        :sys.resume(pid)
      end

      assert eventually(fn -> holds.() == 1 end)

      stop_dialers()
      :ok = Link.resume()
      assert eventually(fn -> holds.() == 2 end)

      size = File.stat!(c.path).size

      LinkServer.push(
        server,
        Wire.frame("conv.append", %{uid: c.uid, from: size, bytes: Wire.b64("{}\n")}, "late")
      )

      assert %{"code" => "held_by_phone"} = answer(server, "late")
      assert :ok = Turns.phone_turn(c.uid, :finish)

      assert eventually(fn ->
               Enum.any?(
                 LinkServer.frames(server),
                 &(&1["op"] == "conv.release" and &1["uid"] == c.uid)
               )
             end)
    end

    test "a website's artifact goes only into a conversation on the shelf, never while the phone answers in it",
         %{server: server} do
      c = phone_conversation("Phone question")
      bytes = "artifact text"
      sha = Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
      folder = &Path.join([Rho.Config.data_dir(), "artifacts", &1])
      gone = Ecto.UUID.generate()
      on_exit(fn -> Enum.each([c.uid, gone], &File.rm_rf(folder.(&1))) end)

      put = fn uid, id ->
        Wire.frame(
          "artifact.put",
          %{
            uid: uid,
            name: "call1.txt",
            sha: sha,
            total: byte_size(bytes),
            from: 0,
            bytes: Wire.b64(bytes)
          },
          id
        )
      end

      assert :ok = Turns.phone_turn(c.uid, :start)
      LinkServer.push(server, put.(c.uid, "during-turn"))
      assert %{"code" => "held_by_phone"} = answer(server, "during-turn")
      refute File.exists?(Path.join(folder.(c.uid), "call1.txt"))
      assert :ok = Turns.phone_turn(c.uid, :finish)

      LinkServer.push(server, put.(c.uid, "after-turn"))
      assert %{"op" => "ack"} = answer(server, "after-turn")
      assert File.read!(Path.join(folder.(c.uid), "call1.txt")) == bytes

      LinkServer.push(server, put.(gone, "unknown"))
      assert %{"code" => "not_found"} = answer(server, "unknown")
      refute File.exists?(folder.(gone))
    end

    test "a divergent tail longer than a phone can decode is refused as too_large", %{
      server: server
    } do
      c = phone_conversation("Phone question")

      LinkServer.push(
        server,
        Wire.frame(
          "conv.append",
          %{uid: c.uid, from: 0, bytes: Wire.b64("different\n"), total: 16 * 1_048_576 + 1},
          "huge"
        )
      )

      assert %{"code" => "too_large"} = answer(server, "huge")

      assert Path.wildcard(Path.join(Rho.Session.dir(), ".link-conflict-*"), match_dot: true) ==
               []
    end

    test "a divergent tail whose merge fails leaves nothing staged" do
      alias Bezalel.Library

      c = phone_conversation("Phone question")
      size = File.stat!(c.path).size
      line = web_line("web00002", leaf_id(c.path), "From the computer")

      {:ok, _} =
        Library.add_message(Library.get_conversation(c.id), %{role: :user, text: "Again"})

      # The merge's write fails (as on a full disk).
      File.chmod!(c.path, 0o444)
      on_exit(fn -> File.chmod(c.path, 0o644) end)

      stages = fn ->
        Path.wildcard(Path.join(Rho.Session.dir(), ".link-conflict-*"), match_dot: true)
      end

      before = stages.()

      request = %{
        "uid" => c.uid,
        "from" => size,
        "total" => size + byte_size(line),
        "bytes" => Wire.b64(line)
      }

      assert_raise File.Error, fn -> Serve.conflict(request, nil) end
      assert stages.() == before
    end

    test "an exported conversation keeps its own dates; its entries' times move it, never back",
         %{
           server: server
         } do
      alias Bezalel.Library

      c = web_conversation()

      LinkServer.push(
        server,
        create_frame(c, "bad-dates", %{
          updated_at: "2026-10-20T12:00:01Z",
          inserted_at: "2026-10-21T00:00:00Z"
        })
      )

      assert %{"code" => "bad_request"} = answer(server, "bad-dates")

      LinkServer.push(
        server,
        create_frame(c, "create", %{
          updated_at: "2026-10-20T12:00:01Z",
          inserted_at: "2026-10-19T08:00:00Z"
        })
      )

      assert %{"op" => "ack"} = answer(server, "create")
      size = Wire.chunk_size()

      for {from, id} <- [{0, "a1"}, {size, "a2"}] do
        bytes = binary_part(c.transcript, from, min(size, byte_size(c.transcript) - from))

        LinkServer.push(
          server,
          Wire.frame("conv.append", %{uid: c.uid, from: from, bytes: Wire.b64(bytes)}, id)
        )

        assert %{"op" => "ack"} = answer(server, id)
      end

      dates = fn ->
        [row] = Library.conversations_by_session([c.uid])
        {DateTime.to_iso8601(row.inserted_at), DateTime.to_iso8601(row.updated_at)}
      end

      assert dates.() == {"2026-10-19T08:00:00.000000Z", "2026-10-20T12:00:01.000000Z"}

      append_at = fn stamp, id ->
        line =
          Jason.encode!(%{
            type: "custom",
            id: id,
            parentId: "abcd1234",
            timestamp: stamp,
            customType: "sync.notes",
            content: "x"
          }) <> "\n"

        from = File.stat!(c.path).size

        LinkServer.push(
          server,
          Wire.frame("conv.append", %{uid: c.uid, from: from, bytes: Wire.b64(line)}, id)
        )

        assert %{"op" => "ack"} = answer(server, id)
      end

      append_at.("2026-10-21T09:00:00Z", "later001")
      assert dates.() == {"2026-10-19T08:00:00.000000Z", "2026-10-21T09:00:00.000000Z"}
      append_at.("2026-10-01T00:00:00Z", "older001")
      assert dates.() == {"2026-10-19T08:00:00.000000Z", "2026-10-21T09:00:00.000000Z"}
    end
  end

  describe "the device key" do
    test "is made once and kept: the same account every time" do
      assert {:ok, {pub, _} = pair} = Identity.keypair()
      assert Identity.keypair() == {:ok, pair}
      assert Identity.fingerprint() == Pairing.fingerprint(pub)
    end

    test "missing key material never creates a new account over persisted link state" do
      {server_key, _} = Handshake.keypair()
      Store.pin(@origin, server_key)

      assert Identity.keypair() == {:error, :device_key_missing}
      assert MemoryStore.get("bezalel.link.device_key") == :error
    end

    test "an unreadable secure store is an error, never a new key (a new account)" do
      {:ok, pair} = Identity.keypair()
      store = Application.get_env(:rho, :credential_store)
      Application.put_env(:rho, :credential_store, LockedStore)

      try do
        assert Identity.keypair() == {:error, :locked}
        assert Identity.fingerprint() == nil

        server = LinkServer.start(@origin)
        {pair_id, secret} = LinkServer.offer(server, @browser)
        {:ok, offer} = Link.parse(LinkServer.qr(server, pair_id, secret))
        assert Link.claim(offer) == {:error, :secure_store}
      after
        Application.put_env(:rho, :credential_store, store)
      end

      assert Identity.keypair() == {:ok, pair}
    end
  end
end
