defmodule Bezalel.Views.Workshop do
  @moduledoc """
  The Workshop tab (your tools first, then building a new one, and a
  proposal waiting for approval) and a built tool's own panel: the
  sample's sermon outline, or a Workshop tool's screen drawn from its
  host process (`Bezalel.Workshop.Host`) with how the tool is doing
  (probation, reverted). See `Bezalel.Workshop`.
  """
  import Mob.Sigil

  alias Bezalel.{Library, Models, Workshop}
  alias Bezalel.Views.Helpers
  alias Bezalel.Workshop.Host
  alias Mob.Socket
  alias MobBezalel.{Icons, Palette, UI}
  alias Rho.Dyn.Compiler

  @starters ["Passage outline helper", "Word study view", "Reading plan"]
  @diff_shown 6_000

  # ── Workshop ──────────────────────────────────────────────────────────────

  @doc "The Workshop body."
  def render(assigns) do
    model = Models.get(assigns.model_id)
    mode = Workshop.mode(assigns.account)
    tools = assigns.tools
    desc_change = {self(), :desc}
    build_tap = {self(), {:workshop, :build}}
    starters = for s <- @starters, do: UI.chip(s, {self(), {:workshop, {:starter, s}}})
    # Android's Material field pads its text itself.
    field_android = %{padding: 0, underline: false}
    rows = Enum.map(tools, &tool_row(&1, Map.get(assigns.tool_status, &1.id, :sample)))

    ~MOB"""
    <Scroll weight={1} background={:background}>
      <Column
        padding_left={18}
        padding_right={18}
        padding_top={22}
        padding_bottom={24}
        gap={18}
        fill_width={true}
      >
        <Column gap={10} fill_width={true}>
          <Text text="Your tools" font={:display} text_size={30} text_color={:on_background} />
          <Text
            :if={tools == []}
            text="Nothing built yet. Describe a tool below, or build one from a conversation in Study."
            text_size={13}
            line_height={1.5}
            text_color={:muted}
          />
          {rows}
        </Column>
        <Column gap={6} padding_top={6} fill_width={true}>
          <Text text="Build a new one" font={:display} text_size={22} text_color={:on_background} />
          <Text
            text="“…to devise artistic designs, to work in gold, silver, and bronze.” Ex 31:4"
            font={:scripture_italic}
            text_size={15}
            line_height={1.4}
            text_color={:muted}
          />
        </Column>
        {changing(assigns)}
        {UI.card(
          [
            ~MOB(<TextField value={@desc} placeholder="Describe a tool in a sentence or two" on_change={desc_change} lines={4} background={:surface} border_color={:surface} text_size={16} android={field_android} padding={4} />),
            ~MOB(<Wrap spacing={8} run_spacing={8} fill_width={true}>{starters}</Wrap>)
          ],
          padding: 14,
          gap: 12
        )}
        {build_state(@build, model, mode, build_tap, assigns)}
      </Column>
    </Scroll>
    """
  end

  defp tool_row(tool, status) do
    tile =
      if tool.kind == "sermon_outline", do: Palette.brand().umber, else: Palette.brand().tekhelet

    hammer = Icons.icon(:hammer, 20, Palette.overlay().mark_gold)
    detail = tool.data["text"] || tool.description

    meta =
      Enum.join(
        ["Built #{built_when(tool.inserted_at)}" | List.wrap(status_label(status))] ++ [detail],
        " · "
      )

    tap = {self(), {:workshop, {:open_tool, tool.id}}}

    ~MOB"""
    <Box
      background={:surface}
      border_color={:border}
      border_width={1}
      corner_radius={18}
      padding_left={14}
      padding_right={14}
      padding_top={12}
      padding_bottom={12}
      fill_width={true}
      on_tap={tap}
    >
      <Row gap={14} align={:center} fill_width={true}>
        <Box
          width={40}
          height={40}
          corner_radius={12}
          background={tile}
          align="center"
          fill_width={false}
        >
          {hammer}
        </Box>
        <Column gap={2} weight={1}>
          <Text text={tool.name} font={:display} text_size={18} text_color={:on_surface} />
          <Text text={meta} text_size={12} text_color={:muted} max_lines={1} />
        </Column>
      </Row>
    </Box>
    """
  end

  @doc "A short label for a built tool's `Bezalel.Workshop.status/1`, or nil."
  def status_label(:sample), do: nil
  def status_label(:probation), do: "On probation"
  def status_label(:running), do: "Ready"
  def status_label(:starting), do: "Starting"
  def status_label(:safe_mode), do: "Off for now"
  def status_label(:missing), do: "Not running"
  def status_label({:reverted, _}), do: "Taken out: it crashed"
  def status_label({:change_reverted, _}), do: "Change undone: it crashed"
  def status_label({:removal_reverted, _}), do: "Back: removing it was undone"

  # "Change the tool" names the tool the next build changes.
  defp changing(%{change_of: %{name: name}}) do
    cancel = {self(), {:workshop, :cancel_change}}

    ~MOB"""
    <Row gap={10} align={:center} fill_width={true}>
      <Text
        text={"Changing " <> name}
        font={:ui_medium}
        text_size={14}
        text_color={:on_background}
        weight={1}
      />
      {UI.chip("Build a new one instead", cancel)}
    </Row>
    """
  end

  defp changing(_assigns), do: []

  defp build_label(model, :live), do: "Build with " <> model.name
  defp build_label(_model, _mode), do: "Build the sample"

  defp build_state(nil, model, mode, tap, _assigns) do
    [
      UI.pill_button(build_label(model, mode), tap, :primary, height: 52, text_size: 16),
      mode_note(mode)
    ]
  end

  defp build_state({:failed, reason}, model, mode, tap, _assigns) do
    [
      UI.card(
        [~MOB(<Text text={reason} text_size={14} line_height={1.5} text_color={:on_surface} />)],
        padding: 14
      ),
      UI.pill_button(build_label(model, mode), tap, :primary, height: 52, text_size: 16),
      mode_note(mode)
    ]
  end

  defp build_state({:review, review}, _model, _mode, _tap, assigns),
    do: review_card(review, assigns.code_open)

  defp build_state({:step, current, live?}, model, _mode, _tap, _assigns) do
    heading =
      if live?,
        do: String.upcase(model.name) <> " IS BUILDING YOUR TOOL",
        else: "BUILDING THE SAMPLE (SCRIPTED)"

    steps =
      for {label, i} <- Enum.with_index(step_labels(live?)) do
        fill = if current > i, do: :secondary, else: :surface
        color = if current >= i, do: :on_surface, else: :muted

        ~MOB"""
        <Row gap={12} align={:center} fill_width={true}>
          <Box
            width={22}
            height={22}
            corner_radius={11}
            border_color={:secondary}
            border_width={1.5}
            background={fill}
            fill_width={false}
          />
          <Text text={label} text_size={15} text_color={color} />
        </Row>
        """
      end

    note =
      if live?,
        do: "Nothing runs until you approve it. Then it lives on your phone and works offline.",
        else: "Once it’s built, the tool lives on your phone and works offline."

    UI.card(
      [UI.kicker(heading)] ++
        steps ++
        [~MOB(<Text text={note} text_size={12} line_height={1.45} text_color={:muted} />)],
      padding: 16,
      gap: 12
    )
  end

  # The storyboard doesn't read the request, so its first step says what it does.
  defp step_labels(true), do: Workshop.steps(true)

  defp step_labels(false),
    do: List.replace_at(Workshop.steps(false), 0, "Opening the sample")

  # Without a model the builder ignores the description; say so up front.
  defp mode_note(:live), do: []

  defp mode_note(:sample),
    do: ~MOB(<Text
  text="No model is connected, so this builds the design’s sample whatever you describe: a sermon outline for Exodus 31:1–11."
  text_size={12}
  line_height={1.45}
  text_color={:muted}
/>)

  defp mode_note({:unavailable, why}),
    do: ~MOB(<Text
  text={why <> " Until then this builds the design’s sample: a sermon outline for Exodus 31:1–11."}
  text_size={12}
  line_height={1.45}
  text_color={:muted}
/>)

  # What the proposal adds, changes or removes, before the user approves it.
  defp review_card(review, code_open?) do
    approve = {self(), {:workshop, :review_approve}}
    discard = {self(), {:workshop, :discard}}
    code = {self(), {:workshop, :toggle_code}}
    passed = Enum.count(review.selftests, & &1.ok)

    tests =
      "Checked, compiled and tested on your phone: #{passed} of #{length(review.selftests)} " <>
        "parts passed their self-tests."

    summary =
      if review.summary != "",
        do: [
          ~MOB(<Text text={review.summary} text_size={14} line_height={1.5} text_color={:on_surface} />)
        ],
        else: []

    code_text = shown_diff(review.diff)

    diff =
      if code_open?,
        do: [
          ~MOB(<Text text={code_text} text_size={11} line_height={1.35} text_color={:on_surface} />)
        ],
        else: []

    code_label = if code_open?, do: "Hide the code", else: "Show the code"

    UI.card(
      [
        UI.kicker("Ready for your approval"),
        ~MOB(<Text
  text={review.rationale}
  font={:display}
  text_size={19}
  line_height={1.3}
  text_color={:on_surface}
/>)
      ] ++
        summary ++
        Enum.map(review.changes, &change_row/1) ++
        [
          ~MOB(<Text text={tests} text_size={12} line_height={1.45} text_color={:muted} />),
          ~MOB(<Text
  text={code_label}
  font={:ui_medium}
  text_size={13}
  text_color={:secondary}
  padding_top={4}
  padding_bottom={4}
  on_tap={code}
/>)
        ] ++
        diff ++
        [
          ~MOB"""
          <Row gap={10} fill_width={true}>
            {UI.pill_button("Approve…", approve, :primary, weight: 1)}
            {UI.pill_button("Discard", discard, :outline, weight: 1)}
          </Row>
          """
        ],
      padding: 16,
      gap: 10
    )
  end

  defp change_row(change) do
    what =
      case change.change do
        :new -> "New tool"
        :changed -> "Changed"
        :removed -> "Removed"
      end

    screen = if change.screen, do: " · with a screen", else: ""
    detail = "#{what} · #{change.tool}#{screen}"

    ~MOB"""
    <Column gap={2} fill_width={true}>
      <Text text={change.title} font={:display} text_size={17} text_color={:on_surface} />
      <Text text={detail} text_size={12} text_color={:muted} />
    </Column>
    """
  end

  defp shown_diff(diff) when byte_size(diff) <= @diff_shown, do: diff

  defp shown_diff(diff),
    do: String.slice(diff, 0, @diff_shown) <> "\n… (#{byte_size(diff) - @diff_shown} more bytes)"

  @doc "The approval sheet's content for the reviewed proposal."
  def approve_sheet(%{build: {:review, review}}) do
    approve = {self(), {:workshop, :approve}}
    keep = {self(), :sheet}
    removing? = Enum.all?(review.changes, &(&1.change == :removed)) and review.changes != []
    names = review.changes |> Enum.map(& &1.title) |> Enum.uniq() |> Enum.join(", ")

    {title, text} =
      if removing?,
        do:
          {"Remove #{names}?",
           "It stops running, and the study agent stops offering it. The shelf entry goes too. " <>
             "If Bezalel keeps crashing without it while that change is on probation, it’s put back."},
        else:
          {"Add #{if names == "", do: "this change", else: names} to Bezalel?",
           "It runs on your phone. It’s written to read only your study library and draw " <>
             "on the screen, and Bezalel checks its code before it runs. Until it has run a " <>
             "minute and the app has restarted, it’s on probation: if it crashes three " <>
             "times in a minute, Bezalel takes it back out and puts back what was there before."}

    [
      ~MOB(<Text text={title} font={:display} text_size={24} text_color={:on_background} />),
      ~MOB(<Text text={text} text_size={14.5} line_height={1.55} text_color={:on_background} />),
      ~MOB"""
      <Row gap={10} fill_width={true}>
        {UI.pill_button(if(removing?, do: "Remove", else: "Approve"), approve, if(removing?, do: :danger, else: :primary), weight: 1, height: 48)}
        {UI.pill_button("Not now", keep, :outline, weight: 1, height: 48)}
      </Row>
      """
    ]
  end

  def approve_sheet(_assigns), do: []

  defp built_when(at) do
    days = DateTime.diff(DateTime.utc_now(), at, :day)

    cond do
      days < 1 -> "today"
      days < 7 -> "this week"
      true -> at |> Calendar.strftime("%b %-d")
    end
  end

  # ── A built tool ──────────────────────────────────────────────────────────

  @doc "A built tool's panel."
  def render_tool(%{tool: %{kind: "dyn"}} = assigns) do
    tool = assigns.tool
    status = assigns.tool_state
    label = "Built by you · " <> (status_label(status) || "offline")

    ~MOB"""
    <Scroll weight={1} background={:background}>
      <Column
        padding_left={18}
        padding_right={18}
        padding_top={22}
        padding_bottom={24}
        gap={16}
        fill_width={true}
      >
        {header(tool.name, label)}
        {status_note(status)}
        {tool_body(assigns.tool_view, tool, status)}
        {UI.card([UI.kicker("What you asked for"), ~MOB(<Text text={tool.description} text_size={14} line_height={1.5} text_color={:on_surface} />)], gap: 4, padding: 14)}
        {tool_buttons()}
        {UI.pill_button("Remove this tool", {self(), {:tool, :remove}}, :outline)}
      </Column>
    </Scroll>
    """
  end

  def render_tool(assigns) do
    tool = assigns.tool
    data = tool.data

    moves =
      data["moves"]
      |> Enum.with_index()
      |> Enum.map(fn {m, i} -> move(m, i, assigns.move_open == i) end)

    ~MOB"""
    <Scroll weight={1} background={:background}>
      <Column
        padding_left={18}
        padding_right={18}
        padding_top={22}
        padding_bottom={24}
        gap={16}
        fill_width={true}
      >
        {header(tool.name, "Built by you · offline")}
        {UI.card([UI.kicker("Text"), ~MOB(<Text text={data["text"]} font={:display} text_size={18} text_color={:on_surface} />)], gap: 4, padding: 14)}
        {UI.card([UI.kicker("Big idea"), ~MOB(<Text text={data["big_idea"]} font={:scripture} text_size={20} line_height={1.35} text_color={:on_surface} />)], gap: 4, padding: 14)}
        {moves}
        {tool_buttons()}
      </Column>
    </Scroll>
    """
  end

  defp header(name, label) do
    ~MOB"""
    <Column gap={6} fill_width={true}>
      <Box
        background={:surface}
        border_color={:border}
        border_width={1}
        corner_radius={12}
        padding_left={9}
        padding_right={9}
        padding_top={4}
        padding_bottom={4}
        fill_width={false}
      >
        {UI.kicker(label)}
      </Box>
      <Text text={name} font={:display} text_size={30} text_color={:on_background} />
    </Column>
    """
  end

  defp tool_buttons do
    discuss = {self(), {:tool, :discuss}}
    change = {self(), {:tool, :change}}

    ~MOB"""
    <Row gap={10} fill_width={true}>
      {UI.pill_button("Discuss in Study", discuss, :primary, weight: 1)}
      {UI.pill_button("Change the tool", change, :outline, weight: 1)}
    </Row>
    """
  end

  @doc "What the panel says about a tool's `Bezalel.Workshop.status/1`, or nil."
  def status_text(:probation),
    do:
      "New, on probation: if it crashes three times within a minute, Bezalel takes it back " <>
        "out and puts back what was there before."

  def status_text({:reverted, why}),
    do:
      "This tool crashed while it was on probation (#{why}), so Bezalel took it back out. " <>
        "Change it to have it fixed, or remove it."

  def status_text({:change_reverted, why}),
    do:
      "Your last change to this tool crashed while it was on probation (#{why}), so Bezalel " <>
        "put back the version before it. That’s the one below."

  def status_text({:removal_reverted, why}),
    do:
      "Removing this tool was undone: Bezalel without it failed on probation (#{why}), so " <>
        "it put back the version with it. Remove it again if you still want it gone."

  def status_text(:safe_mode),
    do:
      "Bezalel started without your tools because two launches in a row failed. They come " <>
        "back once it starts normally."

  def status_text(:starting),
    do: "Bezalel is rebuilding your tools for this version of the app; this takes a moment."

  def status_text(:missing), do: "This tool’s code isn’t running."
  def status_text(_status), do: nil

  defp status_note(status) do
    case status_text(status) do
      nil ->
        []

      text ->
        UI.card(
          [
            ~MOB(<Text text={text} text_size={13.5} line_height={1.5} text_color={:on_surface} />)
          ],
          padding: 14
        )
    end
  end

  defp tool_body({:view, tree}, _tool, _status), do: tree

  defp tool_body(:opening, _tool, _status),
    do: ~MOB(<Text text="Opening…" text_size={14} text_color={:muted} />)

  defp tool_body({:crashed, why}, _tool, _status) do
    reopen = {self(), {:tool, :reopen}}

    UI.card(
      [
        UI.kicker("It stopped with an error"),
        ~MOB(<Text text={why} text_size={12.5} line_height={1.45} text_color={:on_surface} max_lines={6} />),
        ~MOB(<Text
  text="While it’s on probation, three crashes within a minute take it back out."
  text_size={12}
  line_height={1.45}
  text_color={:muted}
/>),
        UI.pill_button("Open it again", reopen, :outline)
      ],
      padding: 14,
      gap: 8
    )
  end

  defp tool_body(nil, %{data: %{"screen" => screen}}, status)
       when is_binary(screen) and status in [:running, :probation],
       do: []

  defp tool_body(nil, %{data: %{"screen" => nil}}, status) when status in [:running, :probation],
    do:
      UI.card(
        [
          ~MOB(<Text
  text="This tool has no screen of its own. The study agent uses it when it helps: ask in Study."
  text_size={13.5}
  line_height={1.5}
  text_color={:on_surface}
/>)
        ],
        padding: 14
      )

  defp tool_body(nil, _tool, _status), do: []

  defp move(m, i, open?) do
    tap = {self(), {:tool, {:move, i}}}
    sign = Icons.icon(if(open?, do: :chevron_up, else: :chevron_down), 16, :muted)

    points =
      if open?,
        do:
          for(
            p <- m["points"],
            do:
              ~MOB(<Text text={"• " <> p} text_size={14} line_height={1.5} text_color={:on_surface} />)
          ),
        else: []

    ~MOB"""
    <Box
      background={:surface}
      border_color={:border}
      border_width={1}
      corner_radius={18}
      fill_width={true}
    >
      <Column fill_width={true}>
        <Row
          gap={12}
          align={:center}
          padding_left={16}
          padding_right={16}
          padding_top={14}
          padding_bottom={14}
          fill_width={true}
          on_tap={tap}
        >
          <Text text={m["num"]} font={:display} text_size={20} text_color={:secondary} width={26} />
          <Column gap={2} weight={1}>
            <Text text={m["title"]} font={:display} text_size={18} text_color={:on_surface} />
            <Text text={m["ref"]} text_size={12} text_color={:muted} />
          </Column>
          {sign}
        </Row>
        <Column
          :if={open?}
          gap={6}
          padding_left={54}
          padding_right={16}
          padding_bottom={14}
          fill_width={true}
        >
          {points}
        </Column>
      </Column>
    </Box>
    """
  end

  # ── The panel's screen host ───────────────────────────────────────────────

  @doc """
  Opens `tool`'s panel: a Workshop tool's screen gets a host process
  (`Bezalel.Workshop.Host`) when its code runs. Any previous host stops.
  `tool_screen` keeps which version of the screen it runs and its module.
  """
  def open_panel(socket, tool) do
    socket = close_panel(socket)

    socket =
      Socket.assign(socket,
        tab: :tool,
        tool: tool,
        tool_state: Workshop.status(tool),
        move_open: 0
      )

    case screen_module(tool) do
      nil ->
        socket

      module ->
        {pid, ref} = Host.start(self(), module, socket.__mob__.platform, socket.assigns)

        Socket.assign(socket,
          tool_host: %{pid: pid, ref: ref},
          tool_view: :opening,
          tool_screen: {tool.data["generation"], module}
        )
    end
  end

  # The module of `tool`'s screen in the running generation.
  defp screen_module(tool) do
    with %{kind: "dyn", data: %{"screen" => screen}} when is_binary(screen) <- tool,
         {:ok, module} <- Rho.Dyn.lookup({:screen, screen}) do
      module
    else
      _ -> nil
    end
  end

  # Whether the open panel runs `tool`'s screen as it is now: the same
  # version (the shelf row's generation, Bezalel.Workshop.reconcile/0), not
  # a module of a generation just reverted (`reverted`). Not by module alone:
  # every generation renames all of its modules (`Dyn.G<n>.*`), unchanged
  # ones included, so another tool's activation would restart the panel.
  defp current?(tool, nil, _reverted), do: screen_module(tool) == nil

  defp current?(tool, {version, module}, reverted) do
    screen_module(tool) != nil and tool.data["generation"] == version and
      Compiler.generation_of(module) != reverted
  end

  @doc "Stops the open panel's screen host, if any."
  def close_panel(%{assigns: %{tool_host: %{pid: pid, ref: ref}}} = socket) do
    Process.demonitor(ref, [:flush])
    :ok = Host.stop(pid)
    Socket.assign(socket, tool_host: nil, tool_view: nil, tool_screen: nil)
  end

  def close_panel(socket),
    do: Socket.assign(socket, tool_host: nil, tool_view: nil, tool_screen: nil)

  @doc "The panel's host painted (stale hosts' views are dropped)."
  def host_view(pid, tree, %{assigns: %{tool_host: %{pid: pid}}} = socket),
    do: Socket.assign(socket, :tool_view, {:view, tree})

  def host_view(_pid, _tree, socket), do: socket

  @doc """
  A monitored process went down: the panel's host, if it is its monitor.
  The host describes its own crash (`Bezalel.Workshop.Host.outcome/1`), so
  no code of the screen's runs here.
  """
  def host_down(ref, reason, %{assigns: %{tool_host: %{ref: ref}}} = socket),
    do: Socket.assign(socket, tool_host: nil, tool_view: Host.outcome(reason))

  def host_down(_ref, _reason, socket), do: socket

  @doc """
  A Dyn event (`{:rho_dyn, event}`): a revert says what crashed, puts
  the shelf in line with the generation that runs now
  (`Bezalel.Workshop.reconcile/0`) and shows it; the others refresh the
  statuses shown.
  """
  def dyn_event(%{type: :reverted, from: from} = event, socket) do
    {removed, changed} =
      Library.list_tools(:all)
      |> Enum.filter(&(&1.kind == "dyn"))
      |> Enum.flat_map(fn t ->
        Enum.filter(t.data["versions"] || [], &(&1["generation"] == from))
        |> Enum.map(&{&1["removed"] == true, t.name})
      end)
      |> Enum.split_with(&elem(&1, 0))

    who =
      case {Enum.map(changed, &elem(&1, 1)), Enum.map(removed, &elem(&1, 1))} do
        {[], []} -> "Your latest tool change"
        {[], gone} -> "Bezalel without " <> Enum.join(gone, ", ")
        {names, _} -> Enum.join(names, ", ")
      end

    :ok = Bezalel.Workshop.reconcile()

    socket
    |> refresh_tools(from)
    |> Helpers.toast(
      "#{who} crashed (#{event[:reason] || "repeatedly"}), so Bezalel put back " <>
        "the version before it."
    )
  end

  def dyn_event(%{type: type, gen: n}, %{assigns: %{build: {:review, %{n: n}}}} = socket)
      when type in [:superseded, :discarded] do
    Socket.assign(socket, :build, nil)
  end

  def dyn_event(%{type: type}, socket)
      when type in [:activated, :proven, :loaded, :load_failed, :safe_mode],
      do: refresh_tools(socket)

  def dyn_event(_event, socket), do: socket

  # The Workshop's statuses, and the open panel: reopened only if the
  # version of the screen it runs changed or went (a change, a revert), or
  # it runs code of a reverted generation, so another tool's activation or
  # this one's proving doesn't restart it.
  defp refresh_tools(socket, reverted \\ nil)

  defp refresh_tools(%{assigns: %{tab: :tool, tool: tool}} = socket, reverted) do
    case Library.get_tool(tool.id) do
      nil ->
        Helpers.go(socket, :workshop)

      tool ->
        if current?(tool, socket.assigns.tool_screen, reverted),
          do: Socket.assign(socket, tool: tool, tool_state: Workshop.status(tool)),
          else: open_panel(socket, tool)
    end
  end

  defp refresh_tools(socket, _reverted), do: Helpers.refresh(socket)

  # ── Events ────────────────────────────────────────────────────────────────

  @doc "Handles a Workshop event."
  def handle({:starter, label}, socket),
    do: {:noreply, Socket.assign(socket, desc: label <> ": ", build: nil, change_of: nil)}

  def handle({:open_tool, id}, socket), do: {:noreply, Helpers.open_tool(socket, id)}

  def handle(:cancel_change, socket),
    do: {:noreply, Socket.assign(socket, change_of: nil, desc: "")}

  def handle(:build, socket) do
    desc =
      case String.trim(socket.assigns.desc) do
        "" ->
          "A passage outline helper: give it a passage, it drafts its main idea and movements I can edit."

        text ->
          text
      end

    screen = self()
    mode = Workshop.mode(socket.assigns.account)
    live? = mode == :live

    opts = [
      mode: mode,
      conversation_id: socket.assigns.conversation.id,
      model_id: socket.assigns.model_id,
      tool: if(live?, do: socket.assigns.change_of),
      on_step: &send(screen, {:build_step, &1})
    ]

    {:noreply,
     socket
     |> Socket.assign(desc: desc, build: {:step, 0, live?}, code_open: false)
     |> Socket.start_async(:build, fn -> Workshop.build(desc, opts) end)}
  end

  def handle(:review_approve, socket),
    do: {:noreply, Socket.assign(socket, :sheet, :approve_build)}

  # Only from the approval sheet: the tap on it is the user's approval.
  def handle(:approve, %{assigns: %{build: {:review, review}, sheet: :approve_build}} = socket) do
    socket = Socket.assign(socket, sheet: nil)

    case Workshop.approve(review) do
      {:ok, [tool | _]} ->
        {:noreply,
         socket
         |> Socket.assign(build: nil, desc: "", change_of: nil)
         |> open_panel(tool)}

      {:ok, []} ->
        {:noreply,
         socket
         |> Socket.assign(build: nil, desc: "", change_of: nil)
         |> Helpers.go(:workshop)
         |> Helpers.toast("Done: #{review.rationale}")}

      {:error, reason} ->
        {:noreply, Socket.assign(socket, :build, {:failed, reason})}
    end
  end

  def handle(:approve, socket), do: {:noreply, Socket.assign(socket, :sheet, nil)}

  def handle(:discard, %{assigns: %{build: {:review, review}}} = socket) do
    :ok = Workshop.discard(review)

    {:noreply,
     socket |> Socket.assign(build: nil) |> Helpers.toast("Discarded. Nothing changed.")}
  end

  def handle(:discard, socket), do: {:noreply, socket}

  def handle(:toggle_code, socket),
    do: {:noreply, Socket.assign(socket, :code_open, not socket.assigns.code_open)}

  @doc "A build step started (sent by the build task)."
  def step(i, socket) do
    case socket.assigns.build do
      {:step, _, live?} -> Socket.assign(socket, :build, {:step, i, live?})
      _ -> socket
    end
  end

  @doc """
  The build finished (`handle_async(:build, ...)`). The sample opens; a
  live build's proposal waits in the Workshop for approval. Away from the
  Workshop the user stays put and a toast says it's ready.
  """
  def built({:ok, {:ok, {:review, review}}}, socket) do
    socket = Socket.assign(socket, :build, {:review, review})

    if socket.assigns.tab == :workshop,
      do: socket,
      else: Helpers.toast(socket, "Your tool is ready to approve in the Workshop.")
  end

  def built({:ok, {:ok, tool}}, socket) do
    socket = Socket.assign(socket, build: nil, desc: "")

    if socket.assigns.tab == :workshop,
      do: Helpers.open_tool(socket, tool.id),
      else:
        socket
        |> Helpers.refresh()
        |> Helpers.toast("#{tool.name} is built. It’s in the Workshop.")
  end

  def built({:ok, {:error, reason}}, socket), do: Socket.assign(socket, :build, {:failed, reason})

  def built({:exit, _}, socket),
    do: Socket.assign(socket, :build, {:failed, "The build stopped before it finished."})

  @doc "Handles an event on a built tool."
  def handle_tool({:move, i}, socket),
    do:
      {:noreply,
       Socket.assign(socket, :move_open, if(socket.assigns.move_open == i, do: -1, else: i))}

  def handle_tool(:discuss, socket) do
    conversation =
      Library.get_conversation(socket.assigns.tool.conversation_id) ||
        socket.assigns.conversation

    {:noreply, Helpers.open_conversation(socket, conversation)}
  end

  # While a live build writes staging, a change or a removal would clobber it.
  def handle_tool(action, %{assigns: %{build: {:step, _, true}}} = socket)
      when action in [:change, :remove],
      do: {:noreply, Helpers.toast(socket, "A build is running; wait for it to finish.")}

  # A Workshop tool's change is built on it; the sample's builds a new sample.
  def handle_tool(:change, socket) do
    tool = socket.assigns.tool

    {:noreply,
     socket
     |> Socket.assign(
       desc: tool.description,
       build: nil,
       change_of: if(tool.kind == "dyn", do: tool)
     )
     |> Helpers.go(:workshop)}
  end

  def handle_tool(:reopen, socket), do: {:noreply, open_panel(socket, socket.assigns.tool)}

  def handle_tool(:remove, socket) do
    tool = socket.assigns.tool

    case Workshop.remove(tool) do
      {:ok, :removed} ->
        {:noreply, socket |> Helpers.go(:workshop) |> Helpers.toast("#{tool.name} is removed.")}

      {:ok, {:review, review}} ->
        {:noreply,
         socket
         |> Socket.assign(build: {:review, review}, code_open: false, change_of: nil)
         |> Helpers.go(:workshop)}

      {:error, reason} ->
        {:noreply, Helpers.toast(socket, reason)}
    end
  end
end
