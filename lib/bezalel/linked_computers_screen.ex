defmodule Bezalel.LinkedComputersScreen do
  @moduledoc """
  Settings → Linked computers (decisions/2026-10-19-phone-link.md): the
  computers using Bezalel through this phone, by website, each with its
  browser, place, when it was linked and last active, and Log out (one,
  or all on a website); offline it shows the list the website last sent,
  and a log-out waits for the next connection (`Bezalel.Link.revoke/2`).

  Link a computer asks for the camera, scans the website's QR code
  (`Bezalel.Native.scan_qr/1`, mob_scanner), claims it
  (`Bezalel.Link.claim/1`) and shows who asked: the website, the browser,
  its IP and place, when, and the warning to continue only if the user
  opened the page just now. Nothing is linked without Link.

  Pushed from Settings with `%{app: pid}`: a change in the list is
  reported to that screen (`{:linked_computers, :changed}`).
  """
  use Mob.Screen

  alias Bezalel.Link
  alias Bezalel.Link.{Identity, Store}
  alias Bezalel.Native
  alias Bezalel.Settings
  alias MobBezalel.UI

  def mount(params, _session, socket) do
    :ok = Link.subscribe()

    {:ok,
     Mob.Socket.assign(socket,
       cover: Settings.cover(),
       app: params[:app],
       linked: Link.linked(),
       fingerprint: Identity.fingerprint(),
       # :list, :claiming (a code is being checked), :confirm (who asked),
       # :approving
       phase: :list,
       offer: nil,
       info: nil,
       note: nil
     )}
  end

  def render(assigns) do
    back = UI.bar_button("Settings", {self(), :back}, assigns.cover)

    ~MOB"""
    <Column background={:background} fill_width={true} fill_height={true}>
      {UI.top_bar("Linked computers", @cover, trailing: back)}
      <Scroll id="linked" weight={1} background={:background}>
        <Column
          padding_left={18}
          padding_right={18}
          padding_top={22}
          padding_bottom={28}
          gap={18}
          fill_width={true}
        >
          <Text text="Linked computers" font={:display} text_size={30} text_color={:on_background} />
          {body(assigns)}
        </Column>
      </Scroll>
    </Column>
    """
  end

  defp body(%{phase: phase} = assigns) when phase in [:confirm, :approving],
    do: confirm(assigns)

  defp body(assigns) do
    [
      link_card(assigns),
      Enum.map(assigns.linked, &site/1),
      account(assigns.fingerprint)
    ]
  end

  # What linking is, the last outcome, and the button.
  defp link_card(assigns) do
    {label, tap} =
      case assigns.phase do
        :claiming -> {"Checking the code…", nil}
        _ -> {"Link a computer", {self(), :scan}}
      end

    UI.card(
      [
        text(
          "Use Bezalel on a computer: open study.genericjam.com there, choose Link your phone, and scan the code it shows. Your sign-ins and conversations live on this phone; sign-ins are shared over an encrypted link with the website's memory while you're connected.",
          14,
          :on_surface
        ),
        note(assigns.note),
        UI.pill_button(label, tap, :primary, height: 44)
      ],
      padding: 16,
      gap: 12
    )
  end

  defp site(%{origin: origin, host: host, sessions: sessions, status: status}) do
    rows =
      case sessions do
        [] -> [note("No computers linked here.")]
        _ -> Enum.map(sessions, &computer(origin, &1))
      end

    all =
      if match?([_, _ | _], sessions),
        do: [
          UI.pill_button("Log out of all computers", {self(), {:logout, origin, "all"}}, :outline,
            height: 40,
            text_size: 13
          )
        ],
        else: []

    ~MOB"""
    <Column gap={8} fill_width={true}>
      {UI.kicker(host)}
      {note(status_line(status))}
      {UI.card(rows, padding: 0, gap: 0)}
      {all}
    </Column>
    """
  end

  defp computer(origin, session) do
    where = Enum.reject([session["place"], session["ip"]], &(&1 in [nil, ""]))

    when_line =
      Enum.join(
        Enum.reject(
          [
            ago("Linked", session["linked_at"]),
            ago("last active", session["last_seen_at"])
          ],
          &is_nil/1
        ),
        " · "
      )

    title = session["browser"] || "A browser"
    place = Enum.join(where, " · ")
    logout = {self(), {:logout, origin, session["id"]}}

    ~MOB"""
    <Row
      gap={12}
      align={:center}
      padding_left={16}
      padding_right={16}
      padding_top={12}
      padding_bottom={12}
      fill_width={true}
    >
      <Column gap={2} weight={1}>
        <Text text={title} font={:ui_medium} text_size={15} text_color={:on_surface} />
        <Text text={place} text_size={12} text_color={:muted} />
        <Text text={when_line} text_size={12} text_color={:muted} />
      </Column>
      <Text text="Log out" font={:ui_medium} text_size={13} text_color={:error} on_tap={logout} />
    </Row>
    """
  end

  defp account(nil), do: []

  defp account(fingerprint),
    do:
      note(
        "This phone is your account on the websites it links (#{fingerprint}). Logging out a computer ends its session there; nothing on this phone changes."
      )

  # Who asked to be linked, and the choice.
  defp confirm(assigns) do
    %{offer: offer, info: info} = assigns
    host = URI.parse(offer.origin).host
    where = Enum.reject([info["place"], info["ip"]], &(&1 in [nil, ""]))

    buttons =
      if assigns.phase == :approving,
        do: [UI.pill_button("Linking…", nil, :primary, height: 44)],
        else: [
          UI.pill_button("Link", {self(), :approve}, :primary, height: 44),
          UI.pill_button("Cancel", {self(), :reject}, :outline, height: 44)
        ]

    UI.card(
      [
        UI.kicker("Link this computer?"),
        text(host, 20, :on_surface, :ui_semibold),
        detail("Browser", info["browser"] || "Unknown"),
        detail("Where", if(where == [], do: "Unknown", else: Enum.join(where, " · "))),
        detail("Asked", ago(nil, info["requested_at"]) || "Just now"),
        detail("This phone", assigns.fingerprint || "Unknown"),
        text(
          "The computer will ask \"Is this your phone?\" and show #{assigns.fingerprint || "this phone's code"}. Choose Link this browser there only if it matches.",
          13,
          :muted
        ),
        text(
          "Only continue if you opened #{host} on your computer yourself, just now. Linking lets that computer use Bezalel as you, with your sign-ins, until you log it out here.",
          13,
          :error
        ),
        buttons
      ],
      padding: 16,
      gap: 10
    )
  end

  defp detail(label, value) do
    ~MOB"""
    <Row gap={12} fill_width={true}>
      <Text text={label} text_size={13} text_color={:muted} width={72} />
      <Text text={value} font={:ui_medium} text_size={14} text_color={:on_surface} weight={1} />
    </Row>
    """
  end

  defp status_line(:connected), do: "Connected"
  defp status_line(:connecting), do: "Connecting…"

  defp status_line({:error, :key_changed}),
    do:
      "This website's identity changed: it isn't the one these computers were linked on, so Bezalel won't connect to it."

  defp status_line({:error, _}), do: "Can't connect."
  defp status_line(_offline), do: "Offline: the list as the website last sent it."

  # "Linked 3 h ago", "last active just now"; nil without a time.
  @doc false
  def ago(prefix, iso, now \\ DateTime.utc_now()) do
    case is_binary(iso) && DateTime.from_iso8601(iso) do
      {:ok, at, _} ->
        span = relative(DateTime.diff(now, at))
        if prefix, do: "#{prefix} #{span}", else: String.capitalize(span)

      _ ->
        nil
    end
  end

  defp relative(seconds) when seconds < 60, do: "just now"
  defp relative(seconds) when seconds < 3_600, do: "#{div(seconds, 60)} min ago"
  defp relative(seconds) when seconds < 86_400, do: "#{div(seconds, 3_600)} h ago"
  defp relative(seconds) when seconds < 2 * 86_400, do: "yesterday"
  defp relative(seconds), do: "#{div(seconds, 86_400)} days ago"

  defp text(text, size, color, font \\ :ui) do
    ~MOB(<Text text={text} font={font} text_size={size} line_height={1.45} text_color={color} />)
  end

  defp note(nil), do: []
  defp note(text), do: text(text, 12.5, :muted)

  # ── events ──

  def handle_info({:tap, :scan}, socket),
    do: {:noreply, socket |> note_is(nil) |> Native.request_permission(:camera)}

  def handle_info({:permission, :camera, :granted}, socket),
    do: {:noreply, Native.scan_qr(socket)}

  def handle_info({:permission, :camera, _denied}, socket),
    do: {:noreply, note_is(socket, camera_note())}

  def handle_info({:scan, :result, %{type: type, value: text}}, socket)
      when type in [:qr, "qr"] and is_binary(text) do
    case Link.parse(text) do
      {:ok, offer} ->
        {:noreply,
         socket
         |> Mob.Socket.assign(phase: :claiming, offer: offer, note: nil)
         |> Mob.Socket.start_async(:claim, fn -> Link.claim(offer) end)}

      {:error, :not_a_link} ->
        {:noreply,
         note_is(
           socket,
           "That isn't a Bezalel code. On the computer, open Link your phone and scan the code there."
         )}
    end
  end

  def handle_info({:scan, :result, _other}, socket),
    do: {:noreply, note_is(socket, "That isn't a QR code. Scan the square Bezalel code.")}

  def handle_info({:scan, :cancelled}, socket), do: {:noreply, socket}

  def handle_info({:scan, :permission_denied}, socket),
    do: {:noreply, note_is(socket, camera_note())}

  def handle_info({:scan, _other}, socket),
    do: {:noreply, note_is(socket, "The scanner couldn't open on this phone.")}

  def handle_info({:tap, :approve}, %{assigns: %{phase: :confirm, offer: offer}} = socket) do
    {:noreply,
     socket
     |> Mob.Socket.assign(:phase, :approving)
     |> Mob.Socket.start_async(:approve, fn -> Link.approve(offer) end)}
  end

  def handle_info({:tap, :reject}, %{assigns: %{phase: :confirm, offer: offer}} = socket) do
    {:noreply,
     socket
     |> listing("Not linked.")
     |> Mob.Socket.start_async(:reject, fn -> Link.reject(offer) end)}
  end

  def handle_info({:tap, {:logout, origin, id}}, socket) do
    name =
      if id == "all",
        do: "every computer on #{URI.parse(origin).host}",
        else:
          Enum.find_value(
            Store.sessions(origin),
            "the computer",
            &(&1["id"] == id && &1["browser"])
          )

    :ok = Link.revoke(origin, id)
    notify(socket)
    {:noreply, socket |> note_is("Logged out: #{name}.") |> refresh()}
  end

  def handle_info({:tap, :back}, socket) do
    if offer = socket.assigns.offer, do: Link.cancel(offer.origin)
    {:noreply, Mob.Socket.pop_screen(socket)}
  end

  def handle_info({:bezalel_link, _origin, event}, socket) do
    if match?({:sessions, _}, event), do: notify(socket)
    {:noreply, refresh(socket)}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  def handle_async(:claim, {:ok, {:ok, info}}, socket),
    do:
      {:noreply,
       Mob.Socket.assign(socket,
         phase: :confirm,
         info: info,
         fingerprint: Identity.fingerprint()
       )}

  def handle_async(:claim, {:ok, {:error, reason}}, socket),
    do: {:noreply, failed(socket, reason)}

  def handle_async(:claim, {:exit, _reason}, socket), do: {:noreply, failed(socket, :crashed)}

  def handle_async(:approve, {:ok, {:ok, session}}, socket) do
    notify(socket)
    {:noreply, listing(socket, "Linked: #{session["browser"] || "the computer"}.")}
  end

  def handle_async(:approve, {:ok, {:error, reason}}, socket),
    do: {:noreply, failed(socket, reason)}

  def handle_async(:approve, {:exit, _reason}, socket), do: {:noreply, failed(socket, :crashed)}

  def handle_async(:reject, _result, socket), do: {:noreply, socket}

  defp failed(socket, reason) do
    if offer = socket.assigns.offer, do: Link.cancel(offer.origin)
    listing(socket, message(reason, socket.assigns.offer))
  end

  @doc false
  def message("expired", _offer),
    do:
      "That code expired. Show a new one on the computer (it changes every 30 seconds) and scan again."

  def message("claimed", _offer),
    do: "That code was already used. Show a new one on the computer and scan again."

  def message("rate_limited", _offer),
    do: "Too many tries for now. Wait a few minutes, then scan a new code."

  def message(:key_changed, offer),
    do:
      "This code doesn't match #{host(offer)}'s identity, so Bezalel didn't link it. If you linked computers there before, the website isn't the same one."

  def message(:secure_store, _offer),
    do: "Bezalel couldn't read this phone's secure store. Unlock the phone and try again."

  def message(reason, offer) when reason in [:timeout, :disconnected, :stopped],
    do: "Couldn't reach #{host(offer)}. Check the phone's connection and try again."

  def message(_other, _offer),
    do: "That didn't work. Show a new code on the computer and try again."

  defp host(%{origin: origin}), do: URI.parse(origin).host
  defp host(_none), do: "the website"

  defp camera_note,
    do:
      "Bezalel needs the camera to scan the code. Allow it in the phone's Settings, then try again."

  defp listing(socket, note),
    do: socket |> Mob.Socket.assign(phase: :list, offer: nil, info: nil, note: note) |> refresh()

  defp refresh(socket),
    do: Mob.Socket.assign(socket, linked: Link.linked(), fingerprint: Identity.fingerprint())

  defp note_is(socket, note), do: Mob.Socket.assign(socket, :note, note)

  defp notify(%{assigns: %{app: app}}) when is_pid(app),
    do: send(app, {:linked_computers, :changed})

  defp notify(_socket), do: :ok
end
