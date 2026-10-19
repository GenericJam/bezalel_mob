defmodule Bezalel.LinkTest do
  # Linking computers (Bezalel.Link) against a fake website
  # (Bezalel.Test.LinkServer: core's handshake on the server side, the
  # pairing ops, the session list): pairing, the pinned key, log-outs
  # online and offline, reconnects, the background.
  use ExUnit.Case, async: false

  alias Bezalel.Link
  alias Bezalel.Link.{Dialer, Handshake, Identity, Pairing, Store, Wire}
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
    [auth, claim] = LinkServer.frames(server)
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

    LinkServer.push(server, %{"op" => "conv.pull", "id" => 7})
    assert eventually(fn -> List.last(LinkServer.frames(server))["op"] == "error" end)
    assert %{"re" => 7, "code" => "unknown_op"} = List.last(LinkServer.frames(server))
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

  test "reconnects back off from about a second to a minute, with jitter" do
    for _ <- 1..50 do
      assert Dialer.backoff(0) in 500..1_000
      assert Dialer.backoff(3) in 4_000..8_000
      assert Dialer.backoff(20) in 30_000..60_000
    end
  end

  describe "the device key" do
    test "is made once and kept: the same account every time" do
      assert {:ok, {pub, _} = pair} = Identity.keypair()
      assert Identity.keypair() == {:ok, pair}
      assert Identity.fingerprint() == Pairing.fingerprint(pub)
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
