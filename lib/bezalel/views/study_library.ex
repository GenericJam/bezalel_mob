defmodule Bezalel.Views.StudyLibrary do
  @moduledoc """
  The study packs in the app: Settings' "Study library" section (each pack
  with its size, version and progress; Download, Update, Remove, Cancel;
  Check for updates; storage used; the sources and licences) and the
  first-launch offer of the core pack. The downloads themselves run in
  `Bezalel.Packs`; this follows them through `{:bezalel_packs, …}`
  messages into the `:packs` assign. Events are `{:tap, {:packs, event}}`.
  """
  import Mob.Sigil

  alias Bezalel.{Packs, Settings}
  alias Bezalel.Views.Helpers
  alias Mob.Socket
  alias MobBezalel.UI

  @titles %{
    "core" => "Core",
    "notes" => "Notes",
    "lxx" => "Septuagint",
    "ancient" => "Ancient sources",
    "graph" => "People and places",
    "translations" => "NET Bible"
  }

  # ── State ─────────────────────────────────────────────────────────────────

  @doc """
  On mount: the library's state, and the first-launch offer of the core
  pack (once, while core isn't on the phone).
  """
  def mount(socket) do
    socket = refresh(socket)

    if Settings.packs_offered?() or installed?(socket.assigns.packs, "core") do
      socket
    else
      Settings.put_packs_offered()
      :ok = Packs.load_manifest()
      Socket.assign(socket, :sheet, :packs_offer)
    end
  end

  @doc "A `{:bezalel_packs, event}` from `Bezalel.Packs`."
  def event(:changed, socket), do: refresh(socket)
  def event({:notice, text}, socket), do: socket |> refresh() |> Helpers.toast(text)

  defp refresh(socket),
    do: Socket.assign(socket, packs: Packs.status(), metered: Packs.metered?())

  defp installed?(status, name),
    do: Enum.any?(status.packs, &(&1.name == name and &1.installed != nil))

  # ── Events ────────────────────────────────────────────────────────────────

  @doc "Handles a study-library event."
  def handle({:download, name}, socket) do
    :ok = Packs.download(name)
    sheet = if socket.assigns.sheet == :packs_offer, do: nil, else: socket.assigns.sheet
    {:noreply, socket |> Socket.assign(:sheet, sheet) |> refresh()}
  end

  def handle({:cancel, name}, socket) do
    :ok = Packs.cancel(name)
    {:noreply, refresh(socket)}
  end

  def handle({:remove, name}, socket) do
    case Packs.remove(name) do
      :ok -> {:noreply, socket |> refresh() |> Helpers.toast("Removed the #{title(name)} pack.")}
      {:error, message} -> {:noreply, Helpers.toast(socket, message)}
    end
  end

  def handle(:check, socket) do
    :ok = Packs.check()
    {:noreply, refresh(socket)}
  end

  def handle(:attributions, socket),
    do: {:noreply, Socket.push_screen(socket, Bezalel.AttributionsScreen)}

  # ── Settings section ──────────────────────────────────────────────────────

  @doc "The Study library section of Settings."
  def render(assigns) do
    status = assigns.packs
    check = if status.checking, do: nil, else: {self(), {:packs, :check}}
    check_label = if status.checking, do: "Checking…", else: "Check for updates"
    sources = {self(), {:packs, :attributions}}

    empty =
      cond do
        status.packs != [] ->
          nil

        status.checking ->
          "Looking up the study library…"

        true ->
          "The list of packs comes from the study library online. Check for updates to fetch it."
      end

    intro =
      UI.card(
        [
          ~MOB(<Text
  text="The study tools read these packs on this phone, so they work offline. Core holds the Bible text, Hebrew and Greek, lexicons and cross references; the others are optional."
  text_size={14}
  line_height={1.5}
  text_color={:on_surface}
/>),
          metered_note(assigns, Enum.any?(status.packs, &(&1.installed == nil))),
          net_note(assigns.study, status),
          note(empty)
        ],
        padding: 14,
        gap: 10
      )

    footer =
      UI.card(
        [
          ~MOB"""
          <Row gap={12} align={:center} fill_width={true}>
            <Column gap={2} weight={1}>
              <Text text="Storage used" font={:ui_medium} text_size={15} text_color={:on_surface} />
              <Text text={size(status.storage)} text_size={12} text_color={:muted} />
            </Column>
            {UI.pill_button(check_label, check, :outline, height: 36, fill: false, text_size: 13)}
          </Row>
          """,
          note(status.notice)
        ],
        padding: 14,
        gap: 10
      )

    sources_button =
      UI.pill_button("Sources and licences", sources, :outline,
        height: 40,
        fill: false,
        text_size: 13
      )

    # A card per pack, not one card of them all: on iOS a tall card of
    # nested columns cut the descriptions short.
    [intro | Enum.map(status.packs, &pack_card/1)] ++ [footer, sources_button]
  end

  defp pack_card(pack) do
    name = title(pack.name) <> if(pack.required, do: " · needed", else: "")
    status_line = line(pack)

    UI.card(
      [
        ~MOB"""
        <Row gap={12} align={:center} fill_width={true}>
          <Text text={name} font={:ui_medium} text_size={15} text_color={:on_surface} weight={1} />
          {button(pack)}
        </Row>
        """,
        ~MOB(<Text text={pack.description} text_size={12} line_height={1.4} text_color={:muted} />),
        ~MOB(<Text text={status_line} text_size={12} line_height={1.4} text_color={:on_surface} />),
        progress(pack.state),
        error(pack.error)
      ],
      padding: 14,
      gap: 6
    )
  end

  defp button(%{state: state, name: name}) when state != :idle,
    do: small("Cancel", {:cancel, name}, :outline)

  defp button(%{installed: %{}, update: true, name: name}),
    do: small("Update", {:download, name}, :primary)

  defp button(%{installed: %{}, required: false, name: name}),
    do: small("Remove", {:remove, name}, :outline)

  defp button(%{installed: %{}}), do: []

  defp button(%{name: name, required: required}),
    do: small("Download", {:download, name}, if(required, do: :primary, else: :outline))

  defp small(label, event, variant),
    do:
      UI.pill_button(label, {self(), {:packs, event}}, variant,
        height: 36,
        fill: false,
        text_size: 13
      )

  defp line(%{state: {:downloading, done, total}}),
    do: "Downloading · #{size(done)} of #{size(total)}"

  defp line(%{state: {:installing, done, total}}),
    do: "Checking and unpacking · #{percent(done, total)}%"

  defp line(%{state: :queued}), do: "Waiting to download"
  defp line(%{state: :retrying}), do: "Connection lost; trying again…"

  defp line(%{installed: %{} = installed} = pack) do
    version =
      case installed.data_version do
        nil -> "version not checked yet"
        v -> "library version #{v}"
      end

    update = if pack.update, do: " · update available (#{size(pack.size)})", else: ""
    "On the phone · #{size(installed.size)} · #{version}#{update}"
  end

  defp line(%{size: nil}), do: "Not downloaded"

  defp line(pack), do: "#{size(pack.size)} download · #{size(pack.raw_size)} on the phone"

  defp progress({phase, done, total}) when phase in [:downloading, :installing],
    do: UI.meter(done / max(total, 1), :primary)

  defp progress(_state), do: []

  defp error(nil), do: []

  defp error(text),
    do: ~MOB(<Text text={text} text_size={12} line_height={1.45} text_color={:error} />)

  defp metered_note(%{metered: true}, true),
    do: note("You're on mobile data. The packs are large: Wi-Fi may be better.")

  defp metered_note(_assigns, _missing), do: []

  # The NET (the default translation) is in a pack of its own; without it
  # the tools quote the BSB from core, and say so.
  defp net_note(%{translation: "net"}, status) do
    if installed?(status, "translations"),
      do: [],
      else:
        note(
          "Your translation, the NET Bible, needs the NET Bible pack. Until it's on this phone, the study tools quote the BSB from the core pack and say so."
        )
  end

  defp net_note(_prefs, _status), do: []

  defp note(nil), do: []

  defp note(text),
    do: ~MOB(<Text text={text} text_size={12} line_height={1.45} text_color={:muted} />)

  # ── First-launch offer (a sheet) ─────────────────────────────────────────

  @doc "The first-launch sheet offering the core pack."
  def offer(assigns) do
    status = assigns.packs
    core = Enum.find(status.packs, &(&1.name == "core"))
    download = {self(), {:packs, {:download, "core"}}}
    later = {self(), :sheet}

    sizes =
      cond do
        core && core.size ->
          "#{size(core.size)} to download, #{size(core.raw_size)} on the phone."

        status.checking ->
          "Looking up the study library…"

        true ->
          status.notice || "The study library couldn't be reached. Try again from Settings."
      end

    metered =
      if (assigns.metered and core) && core.size,
        do: note("You're on mobile data. Wi-Fi may be better for #{size(core.size)}."),
        else: []

    [
      ~MOB(<Text
  text="Download the study library"
  font={:display}
  text_size={24}
  text_color={:on_background}
/>),
      ~MOB(<Text
  text="Bezalel's study tools look things up on this phone: the Hebrew and Greek text, the Berean Standard Bible, lexicons, names and cross references. They come in the core pack."
  text_size={14.5}
  line_height={1.55}
  text_color={:on_background}
/>),
      ~MOB(<Text text={sizes} font={:ui_medium} text_size={14} text_color={:on_background} />),
      metered,
      note(
        "Study works without it, but the tools will say the pack is missing. The core pack and the optional ones (the NET Bible, notes, Septuagint, ancient sources, people and places) are in Settings → Study library."
      ),
      ~MOB"""
      <Row gap={10} fill_width={true}>
        {UI.pill_button("Download core", download, :primary, weight: 1, height: 48)}
        {UI.pill_button("Not now", later, :outline, weight: 1, height: 48)}
      </Row>
      """
    ]
  end

  # ── Formatting ────────────────────────────────────────────────────────────

  @doc "A pack's title."
  @spec title(String.t()) :: String.t()
  def title(name), do: Map.get(@titles, name, name)

  @doc "Bytes as the library states them (MB = 10^6 bytes): `182 MB`, `1.3 MB`, `640 kB`."
  @spec size(non_neg_integer()) :: String.t()
  def size(0), do: "0 MB"
  def size(bytes) when bytes >= 10_000_000, do: "#{round(bytes / 1_000_000)} MB"
  def size(bytes) when bytes >= 1_000_000, do: "#{Float.round(bytes / 1_000_000, 1)} MB"
  def size(bytes), do: "#{max(round(bytes / 1000), 1)} kB"

  defp percent(done, total), do: div(done * 100, max(total, 1))
end
