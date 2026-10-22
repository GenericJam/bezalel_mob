defmodule Bezalel.LinkedComputersScreenTest do
  # Settings → Linked computers (Bezalel.LinkedComputersScreen) against a
  # fake website (Bezalel.Test.LinkServer), the camera and scanner
  # recorded (Bezalel.Test.Native): scan, who asked, Link or Cancel, the
  # list and Log out.
  use Mob.ScreenCase
  @moduletag :screen

  alias Bezalel.{AppScreen, Link, LinkedComputersScreen}
  alias Bezalel.Link.{Identity, Pairing, Store}
  alias Bezalel.Test.{LinkServer, MemoryStore, Native}

  @origin "https://study.example"
  @browser %{
    "browser" => "Firefox on Linux",
    "ip" => "203.0.113.7",
    "place" => "Toronto, CA",
    "requested_at" => "2026-10-19T12:00:00Z"
  }

  setup do
    stop_dialers()
    Store.clear()
    MemoryStore.delete("bezalel.link.device_key")
    Native.reset()

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

  defp texts(view), do: for(%{props: %{text: t}} <- find_all(view, :text), do: t)

  defp shows?(view, fragment), do: Enum.any?(texts(view), &(&1 =~ fragment))

  defp mounted, do: mount_screen(LinkedComputersScreen, %{app: self()})

  # Scan → the camera asked for, the scanner opened, the code read and claimed.
  defp scanned(view, text) do
    view
    |> render_info({:tap, :scan})
    |> render_info({:permission, :camera, :granted})
    |> render_info({:scan, :result, %{type: :qr, value: text}})
    |> render_async(5_000)
  end

  defp code(server) do
    {pair_id, secret} = LinkServer.offer(server, @browser)
    LinkServer.qr(server, pair_id, secret)
  end

  test "Link a computer: camera, scanner, who asked (browser, place, IP) and the warning; Link links it" do
    server = LinkServer.start(@origin)
    view = mounted()
    assert shows?(view, "open study.genericjam.com there")

    view = render_info(view, {:tap, :scan})
    assert Native.calls() == [{:request_permission, :camera}]
    view = render_info(view, {:permission, :camera, :granted})
    assert Native.names() == [:request_permission, :scan_qr]

    view = render_info(view, {:scan, :result, %{type: :qr, value: code(server)}})
    assert "Checking the code…" in texts(view)
    view = render_async(view, 5_000)

    assert "LINK THIS COMPUTER?" in texts(view)
    assert "study.example" in texts(view)
    assert "Firefox on Linux" in texts(view)
    assert "Toronto, CA · 203.0.113.7" in texts(view)
    assert shows?(view, "Only continue if you opened study.example on your computer yourself")
    assert Identity.fingerprint() in texts(view)
    assert Link.count() == 0

    view = view |> render_info({:tap, :approve}) |> render_async(5_000)
    assert "Linked: Firefox on Linux." in texts(view)
    assert "Firefox on Linux" in texts(view)
    assert "Log out" in texts(view)
    assert "Connected" in texts(view)
    assert Link.count() == 1
    assert_received {:linked_computers, :changed}
  end

  test "Cancel links nothing and tells the website no" do
    server = LinkServer.start(@origin)
    view = mounted() |> scanned(code(server))
    assert "Firefox on Linux" in texts(view)

    view = view |> render_info({:tap, :reject}) |> render_async(5_000)
    assert "Not linked." in texts(view)
    assert Link.count() == 0
    assert "pair.reject" in LinkServer.ops(server)
  end

  test "a code that isn't Bezalel's, an expired one, a refused camera: each says what to do" do
    server = LinkServer.start(@origin)

    view = mounted() |> scanned("https://example.com/menu")
    assert shows?(view, "That isn't a Bezalel code")

    {pair_id, secret} = Pairing.offer()
    view = scanned(view, LinkServer.qr(server, pair_id, secret))
    assert shows?(view, "That code expired")
    assert Link.count() == 0

    view = view |> render_info({:tap, :scan}) |> render_info({:permission, :camera, :denied})
    assert shows?(view, "needs the camera to scan the code")
  end

  test "scanner results other than QR codes are never treated as link requests" do
    server = LinkServer.start(@origin)
    view = mounted()

    view =
      render_info(view, {:scan, :result, %{type: :aztec, value: code(server)}})

    assert shows?(view, "isn't a QR code")
    assert LinkServer.frames(server) == []
  end

  test "the list shows each computer; Log out drops it here and on the website" do
    server = LinkServer.start(@origin)

    view =
      mounted() |> scanned(code(server)) |> render_info({:tap, :approve}) |> render_async(5_000)

    [%{"id" => id}] = Store.sessions(@origin)
    assert_received {:linked_computers, :changed}

    view = render_info(view, {:tap, {:logout, @origin, id}})
    refute "Firefox on Linux" in texts(view)
    assert "Logged out: Firefox on Linux." in texts(view)
    # A website with no computer left isn't listed.
    refute "STUDY.EXAMPLE" in texts(view)
    assert_received {:linked_computers, :changed}
    # Sent at once: the website acknowledges it and drops it too.
    assert eventually(fn -> Store.revokes(@origin) == [] end)
    assert LinkServer.sessions(server) == []
  end

  defp eventually(fun, tries \\ 100) do
    cond do
      fun.() ->
        true

      tries == 0 ->
        flunk("never happened")

      true ->
        Process.sleep(20)
        eventually(fun, tries - 1)
    end
  end

  test "Settings counts the linked computers and opens the screen" do
    view = AppScreen |> mount_screen() |> render_info({:tap, {:tab, :settings}})
    assert "Linked computers" in texts(view)
    assert shows?(view, "None. Use Bezalel on a computer through this phone.")

    Store.put_sessions(@origin, [%{"id" => "a"}, %{"id" => "b"}])
    view = render_info(view, {:bezalel_link, @origin, {:sessions, Store.sessions(@origin)}})
    assert "2 computers" in texts(view)

    view = render_info(view, {:tap, {:settings, :linked_computers}})
    assert navigated_to(view) == LinkedComputersScreen
  end

  test "times show as how long ago, without a time zone" do
    now = ~U[2026-10-19 15:00:00Z]
    assert LinkedComputersScreen.ago("Linked", "2026-10-19T14:59:30Z", now) == "Linked just now"

    assert LinkedComputersScreen.ago("last active", "2026-10-19T14:20:00Z", now) ==
             "last active 40 min ago"

    assert LinkedComputersScreen.ago("Linked", "2026-10-19T12:00:00Z", now) == "Linked 3 h ago"
    assert LinkedComputersScreen.ago("Linked", "2026-10-15T12:00:00Z", now) == "Linked 4 days ago"
    assert LinkedComputersScreen.ago("Linked", nil, now) == nil
  end
end
