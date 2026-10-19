defmodule Bezalel.DesignGalleryScreen do
  @moduledoc """
  A specimen of the design plugin (mob_bezalel): every theme, the two covers,
  the type faces and the recurring pieces from the Core Screens v2 design,
  on one screen. Used to check the plugin on simulators and emulators before
  the app's own screens are built.
  """
  use Mob.Screen

  alias Mob.Theme.AdaptiveWatcher
  alias MobBezalel.{Palette, UI}

  @modes [
    light: MobBezalel.Light,
    dark: MobBezalel.Dark,
    night: MobBezalel.Night,
    system: MobBezalel.System
  ]

  @blocks [
    {:think, "THINKING",
     "The user wants the heart of a Bezalel sermon. Start where the text is surprising.",
     "Exodus 31:3 is the first explicit “filled with the Spirit of God” in the canon, and it’s given to an artisan.",
     :aside},
    {:tool, "TOOL CALL", "lookup_passage(ref: \"Exodus 31:2–3\", version: \"BSB\")",
     "→ returned 2 verses · 48 words\nlexicon(H7307, H2451) → 2 entries", :aside},
    {:sum, "SUMMARY",
     "This is the first time Scripture says someone was filled with the Spirit of God.",
     "And the result is craftsmanship: called by name, filled with the Spirit, put to the work.",
     :summary}
  ]

  def mount(_params, _session, socket) do
    AdaptiveWatcher.register_adaptive(MobBezalel.System)
    # In System mode the screen re-resolves the theme itself on an OS flip:
    # the watcher updates the theme but doesn't repaint a screen that's
    # already showing, and a repaint racing it could keep the old palette.
    Mob.Device.subscribe(:appearance)
    mode = Mob.State.get(:bezalel_mode, :dark)
    Mob.Theme.set(Keyword.fetch!(@modes, mode))

    {:ok,
     Mob.Socket.assign(socket,
       mode: mode,
       cover: Mob.State.get(:bezalel_cover, :leather),
       open: MapSet.new([:sum]),
       sheet: false,
       draft: ""
     )}
  end

  def render(assigns) do
    sa = assigns[:safe_area] || %{top: 0, bottom: 0}

    mode_opts =
      for {key, _mod} <- @modes,
          do: {key |> Atom.to_string() |> String.capitalize(), {self(), {:mode, key}}}

    cover_opts =
      for c <- Palette.covers(),
          do: {c |> Atom.to_string() |> String.capitalize(), {self(), {:cover, c}}}

    mode_index = Enum.find_index(@modes, fn {k, _} -> k == assigns.mode end)
    cover_index = Enum.find_index(Palette.covers(), &(&1 == assigns.cover))
    sheet_tap = {self(), :open_sheet}
    trailing = UI.bar_button("Word", sheet_tap, assigns.cover)
    draft_change = {self(), :draft}
    send_tap = {self(), :noop}

    tabs =
      for {l, icon} <- [
            study: :study,
            conversations: :conversations,
            workshop: :workshop,
            settings: :settings
          ],
          do: {l |> Atom.to_string() |> String.capitalize(), icon, {self(), :noop}}

    sheet_dismiss = {self(), :sheet_dismissed}

    sheet = UI.sheet_style()

    ~MOB"""
    <Column background={:background} fill_width={true} fill_height={true}>
      {UI.top_bar("Design", @cover, trailing: trailing)}
      <Scroll id="gallery" weight={1} background={:background}>
        <Column
          padding_left={18}
          padding_right={18}
          padding_top={22}
          padding_bottom={28}
          gap={18}
          fill_width={true}
        >
          <Text text="Specimen" font={:display} text_size={30} text_color={:on_background} />
          {section("Appearance", [
            UI.card([
              ~MOB(<Text text="Theme" font={:ui_medium} text_size={14} text_color={:on_surface} />),
              UI.segmented(mode_opts, mode_index),
              ~MOB(<Text text="Cover" font={:ui_medium} text_size={14} text_color={:on_surface} />),
              UI.segmented(cover_opts, cover_index)
            ], padding: 16, gap: 10)
          ])}
          {section("Type", [type_specimen()])}
          {section("Study", study_specimen(@open))}
          {section("Controls", controls_specimen())}
          {section("Rows", rows_specimen())}
          {section("Colors", [swatches(@mode)])}
        </Column>
      </Scroll>
      {UI.composer(@draft, "Ask about this passage…", draft_change, send_tap)}
      {UI.tab_bar(tabs, 0, @cover, sa.bottom)}
      <Sheet
        :if={@sheet}
        detents={[:medium, :large]}
        on_dismiss={sheet_dismiss}
        background={sheet.background}
        corner_radius={sheet.corner_radius}
        scrim={sheet.scrim}
        drag_indicator_color={sheet.drag_indicator_color}
        drag_indicator_width={sheet.drag_indicator_width}
        drag_indicator_height={sheet.drag_indicator_height}
        drag_indicator_rail_height={sheet.drag_indicator_rail_height}
      >
        {word_sheet()}
      </Sheet>
    </Column>
    """
  end

  # The repaint after handle_info picks up the new theme: the frame
  # fingerprint covers Mob.Theme.current(), so an unchanged tree still paints.
  def handle_info({:mob_device, :color_scheme_changed, _scheme}, socket) do
    if socket.assigns.mode == :system, do: Mob.Theme.set(MobBezalel.System)
    {:noreply, socket}
  end

  def handle_info({:tap, {:mode, mode}}, socket) do
    Mob.Theme.set(Keyword.fetch!(@modes, mode))
    Mob.State.put(:bezalel_mode, mode)
    {:noreply, Mob.Socket.assign(socket, :mode, mode)}
  end

  def handle_info({:tap, {:cover, cover}}, socket) do
    Mob.State.put(:bezalel_cover, cover)
    {:noreply, Mob.Socket.assign(socket, :cover, cover)}
  end

  def handle_info({:tap, {:block, id}}, socket) do
    open = socket.assigns.open
    open = if MapSet.member?(open, id), do: MapSet.delete(open, id), else: MapSet.put(open, id)
    {:noreply, Mob.Socket.assign(socket, :open, open)}
  end

  def handle_info({:tap, :open_sheet}, socket),
    do: {:noreply, Mob.Socket.assign(socket, :sheet, true)}

  def handle_info({:tap, :close_sheet}, socket),
    do: {:noreply, Mob.Socket.assign(socket, :sheet, false)}

  def handle_info({:dismiss, :sheet_dismissed}, socket),
    do: {:noreply, Mob.Socket.assign(socket, :sheet, false)}

  def handle_info({:change, :draft, value}, socket),
    do: {:noreply, Mob.Socket.assign(socket, :draft, value)}

  def handle_info(_message, socket), do: {:noreply, socket}

  defp section(title, children) do
    ~MOB"""
    <Column gap={8} fill_width={true}>
      {UI.kicker(title)}
      {children}
    </Column>
    """
  end

  defp type_specimen do
    UI.card(
      [
        ~MOB(<Text text="Your tools" font={:display} text_size={30} text_color={:on_surface} />),
        ~MOB"""
        <Row fill_width={true}>
          {UI.kicker("Exodus 31:2–3")}
          <Spacer weight={1} />
          {UI.kicker("BSB")}
        </Row>
        """,
        ~MOB(<Text
  text="See, I have called by name Bezalel son of Uri, the son of Hur, of the tribe of Judah. And I have filled him with the Spirit of God, with skill, ability, and knowledge in all kinds of craftsmanship."
  font={:scripture}
  text_size={19}
  line_height={1.55}
  text_color={:on_surface}
/>),
        ~MOB(<Text
  text="“…to devise artistic designs, to work in gold, silver, and bronze.” Ex 31:4"
  font={:scripture_italic}
  text_size={15}
  text_color={:muted}
/>),
        ~MOB"""
        <Row gap={12} align={:center} fill_width={true}>
          <Text text="רוּחַ" font={:hebrew_medium} text_size={40} text_color={:on_surface} />
          <Column gap={2}>
            <Text text="rûaḥ" font={:scripture_italic} text_size={19} text_color={:on_surface} />
            <Text text="H7307 · 378× in the OT" font={:ui_medium} text_size={12} text_color={:muted} />
          </Column>
        </Row>
        """,
        ~MOB(<Text
  text="וָאֲמַלֵּא אֹתוֹ רוּחַ אֱלֹהִים"
  font={:hebrew}
  text_size={21}
  text_color={:muted}
  text_align="right"
  fill_width={true}
/>),
        ~MOB(<Text text="τομώτερος ὑπὲρ πᾶσαν μάχαιραν" font={:scripture} text_size={19} text_color={:muted} />),
        ~MOB(<Text
  text="Instrument Sans carries the interface: labels, controls, the model picker. Never scripture."
  text_size={15}
  line_height={1.5}
  text_color={:on_surface}
/>)
      ],
      padding: 16,
      gap: 12
    )
  end

  defp study_specimen(open) do
    blocks =
      for {id, type, first, rest, kind} <- @blocks do
        UI.block(type, first, rest, MapSet.member?(open, id), {self(), {:block, id}}, kind)
      end

    # Another model's message: a pushback's critique, between the reply it
    # reviews and the answer to it.
    critique =
      UI.consult_block(
        "Pushback · GPT-5",
        "1. major: “the first person filled with the Spirit”: Genesis 41:38 says it of Joseph.",
        "2. minor: the answer reads ḥokhmah as “wisdom” only; in Exodus 31 it is the craftsman’s skill.",
        MapSet.member?(open, "consult"),
        {self(), {:block, "consult"}}
      )

    [UI.user_bubble("Help me prepare a sermon on Bezalel. What’s the heart of it?")] ++
      blocks ++
      [
        ~MOB(<Text text="Claude Sonnet" font={:ui_medium} text_size={11} text_color={:muted} />),
        critique
      ]
  end

  defp controls_specimen do
    noop = {self(), :noop}

    [
      ~MOB"""
      <Wrap spacing={8} run_spacing={8} fill_width={true}>
        {UI.chip("Sermon outline helper", noop)}
        {UI.chip("Word study view", noop)}
        {UI.chip("Reading plan", noop)}
      </Wrap>
      """,
      UI.pill_button("Build with Claude Sonnet", noop, :primary, height: 52, text_size: 16),
      ~MOB"""
      <Row gap={10} fill_width={true}>
        {UI.pill_button("Discuss in Study", noop, :primary, weight: 1)}
        {UI.pill_button("Change the tool", noop, :outline, weight: 1)}
      </Row>
      """,
      ~MOB"""
      <Row gap={10} fill_width={true}>
        {UI.pill_button("Delete anyway", noop, :danger, weight: 1, height: 48)}
        {UI.pill_button("Keep it", noop, :outline, weight: 1, height: 48)}
      </Row>
      """
    ]
  end

  defp rows_specimen do
    [
      conv_row("THIS WEEK · OCT 18", "Exodus 31 · Bezalel", "Sermon prep · 3 tools used", true),
      conv_row("OCT 11", "Psalm 119 · A lamp to my feet", "Sermon prep · 42 messages", false),
      UI.card(
        [
          ~MOB"""
          <Row gap={8} align={:end}>
            <Text text="182k" font={:display} text_size={30} text_color={:on_surface} />
            <Text text="tokens across 3 models" text_size={12} text_color={:muted} />
          </Row>
          """,
          usage_bar("Claude Sonnet", "124k", 0.68, 0xFFC67139),
          usage_bar("Gemini Pro", "41k", 0.23, 0xFF4A6FA5),
          usage_bar("Llama (open) · free", "17k", 0.09, 0xFF7A8A5E)
        ],
        padding: 16,
        gap: 12
      )
    ]
  end

  defp conv_row(kicker, name, meta, open?) do
    {border, state, state_color} =
      if open?, do: {:secondary, "OPEN", :secondary}, else: {:border, "SHELVED", :muted}

    UI.card(
      ~MOB"""
      <Row gap={14} align={:center} fill_width={true}>
        <Column gap={3} weight={1}>
          {UI.kicker(kicker)}
          <Text text={name} font={:display} text_size={18} text_color={:on_surface} />
          <Text text={meta} text_size={12} text_color={:muted} />
        </Column>
        {UI.kicker(state, state_color)}
      </Row>
      """,
      border: border,
      border_width: 1.5,
      padding: 14
    )
  end

  defp usage_bar(name, value, pct, color) do
    ~MOB"""
    <Column gap={5} fill_width={true}>
      <Row fill_width={true}>
        <Text text={name} font={:ui_medium} text_size={13} text_color={:on_surface} />
        <Spacer weight={1} />
        <Text text={value} font={:ui_medium} text_size={13} text_color={:muted} />
      </Row>
      {UI.meter(pct, color)}
    </Column>
    """
  end

  defp swatches(mode) do
    roles = Palette.roles(if mode == :system, do: MobBezalel.mode() || :dark, else: mode)

    entries =
      Enum.map(roles, fn {k, v} -> {Atom.to_string(k), v} end) ++
        Enum.map(Palette.brand(), fn {k, v} -> {Atom.to_string(k), v} end)

    ~MOB"""
    <Wrap spacing={8} run_spacing={10} fill_width={true}>
      {Enum.map(entries, fn {name, argb} -> swatch(name, argb) end)}
    </Wrap>
    """
  end

  defp swatch(name, argb) do
    ~MOB"""
    <Column gap={4} width={76}>
      <Box
        width={76}
        height={44}
        corner_radius={12}
        background={argb}
        border_color={:border}
        border_width={1}
        fill_width={false}
      />
      <Text
        text={name}
        font={:ui_semibold}
        text_size={10}
        text_color={:on_background}
        max_lines={1}
      />
    </Column>
    """
  end

  defp word_sheet do
    ~MOB"""
    <Scroll>
      <Column
        padding_left={18}
        padding_right={18}
        padding_top={28}
        padding_bottom={34}
        gap={14}
        fill_width={true}
      >
        <Text
          text="וָאֲמַלֵּא אֹתוֹ רוּחַ אֱלֹהִים"
          font={:hebrew}
          text_size={21}
          line_height={1.8}
          text_color={:muted}
          text_align="right"
          fill_width={true}
        />
        <Row gap={12} align={:center}>
          <Text text="רוּחַ" font={:hebrew_medium} text_size={40} text_color={:on_background} />
          <Column gap={2}>
            <Text text="rûaḥ" font={:scripture_italic} text_size={19} text_color={:on_background} />
            <Text text="H7307 · 378× in the OT" text_size={12} text_color={:muted} />
          </Column>
        </Row>
        <Text
          text="wind, breath, spirit"
          font={:scripture}
          text_size={19}
          line_height={1.45}
          text_color={:on_background}
        />
        <Text
          text="The same breath that hovers over the waters in Genesis 1:2 now rests on a craftsman."
          text_size={14.5}
          line_height={1.55}
          text_color={:on_background}
        />
        {UI.kicker("Cross-references")}
        <Wrap spacing={8} run_spacing={8} fill_width={true}>
          {UI.chip("Gen 1:2")}
          {UI.chip("Num 11:25")}
          {UI.chip("Isa 11:2")}
          {UI.chip("Acts 2:3")}
        </Wrap>
        {UI.pill_button("Ask Claude Sonnet about rûaḥ", {self(), :close_sheet})}
      </Column>
    </Scroll>
    """
  end
end
