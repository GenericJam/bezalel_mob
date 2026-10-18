defmodule Bezalel.Views.Sheets do
  @moduledoc """
  The bottom sheets: choose a model, confirm a delete, a Hebrew word (the
  storyboard's, or a word from a live reply's passage card), the
  first-launch offer of the core study pack, approving a Workshop proposal.
  """
  import Mob.Sigil

  alias Bezalel.{Models, Scripture}
  alias Bezalel.Views.{Attach, Stills, StudyLibrary, Workshop}
  alias MobBezalel.UI

  @doc "The sheet for `assigns.sheet`, or nothing."
  def render(%{sheet: nil}), do: []

  def render(assigns) do
    style = UI.sheet_style()
    dismiss = {self(), :sheet}
    content = content(assigns.sheet, assigns)
    detents = detents(assigns.sheet)

    ~MOB"""
    <Sheet
      detents={detents}
      on_dismiss={dismiss}
      background={style.background}
      corner_radius={style.corner_radius}
      scrim={style.scrim}
      drag_indicator_color={style.drag_indicator_color}
      drag_indicator_width={style.drag_indicator_width}
      drag_indicator_height={style.drag_indicator_height}
      drag_indicator_rail_height={style.drag_indicator_rail_height}
    >
      <Scroll>
        <Column
          padding_left={18}
          padding_right={18}
          padding_top={24}
          padding_bottom={34}
          gap={14}
          fill_width={true}
        >
          {content}
        </Column>
      </Scroll>
    </Sheet>
    """
  end

  # The stills picker opens tall: its frame, scrubber and Keep in view.
  defp detents({:stills, _video_id}), do: [:large]
  defp detents(_sheet), do: [:medium, :large]

  defp content(:approve_build, assigns), do: Workshop.approve_sheet(assigns)
  defp content(:packs_offer, assigns), do: StudyLibrary.offer(assigns)
  defp content(:attach, _assigns), do: Attach.menu_sheet()
  defp content({:video_notice, source}, _assigns), do: Attach.video_sheet(source)
  defp content({:stills, _video_id}, assigns), do: Stills.sheet(assigns)

  defp content({:delete_material, id}, _assigns) do
    confirm = {self(), {:materials, {:confirm_delete, id}}}
    keep = {self(), :sheet}

    [
      ~MOB(<Text text="Delete this material?" font={:display} text_size={24} text_color={:on_background} />),
      ~MOB(<Text
  text="It goes from this phone, with its transcript and stills. A conversation that sent it keeps its words but can't show it, and the agent is told it couldn't be loaded. A drawing made from it stays."
  text_size={14.5}
  line_height={1.55}
  text_color={:on_background}
/>),
      ~MOB"""
      <Row gap={10} fill_width={true}>
        {UI.pill_button("Delete", confirm, :danger, weight: 1, height: 48)}
        {UI.pill_button("Keep it", keep, :outline, weight: 1, height: 48)}
      </Row>
      """
    ]
  end

  defp content(:models, assigns) do
    groups =
      for {group, models} <- Models.groups(assigns.account) do
        rows = Enum.map(models, &model_row(&1, assigns.model_id))

        ~MOB"""
        <Column gap={6} fill_width={true}>
          {UI.kicker(group)}
          {rows}
        </Column>
        """
      end

    [
      ~MOB"""
      <Row align={:end} fill_width={true}>
        <Text
          text="Choose a model"
          font={:display}
          text_size={24}
          text_color={:on_background}
          weight={1}
        />
        <Text text="Switch anytime; the chat stays" text_size={12} text_color={:muted} />
      </Row>
      """
      | if(groups == [], do: [no_models()], else: groups)
    ]
  end

  defp content({:confirm_delete, id}, _assigns) do
    confirm = {self(), {:study, {:confirm_delete, id}}}
    keep = {self(), :sheet}

    [
      ~MOB(<Text text="Delete this message?" font={:display} text_size={24} text_color={:on_background} />),
      ~MOB(<Text
  text="Replies further down were built on it. Removing it can leave the agent working from a conversation that no longer quite adds up. The messages below it stay."
  text_size={14.5}
  line_height={1.55}
  text_color={:on_background}
/>),
      ~MOB"""
      <Row gap={10} fill_width={true}>
        {UI.pill_button("Delete anyway", confirm, :danger, weight: 1, height: 48)}
        {UI.pill_button("Keep it", keep, :outline, weight: 1, height: 48)}
      </Row>
      """
    ]
  end

  defp content({:word, key}, assigns) do
    w = Scripture.word(key)
    {before, after_} = w.phrase
    model = Models.get(assigns.model_id)
    ask = {self(), {:study, {:ask_word, key}}}
    meta = "#{w.strong} · #{w.count}× in the OT"
    refs = for r <- w.refs, do: UI.chip(r)

    [
      ~MOB(<Text
  text={before <> w.heb <> after_}
  font={:hebrew}
  text_size={21}
  line_height={1.8}
  text_color={:muted}
  text_align="right"
  fill_width={true}
/>),
      ~MOB"""
      <Row gap={12} align={:center} fill_width={true}>
        <Text text={w.heb} font={:hebrew_medium} text_size={40} text_color={:on_background} />
        <Column gap={2}>
          <Text text={w.translit} font={:scripture_italic} text_size={19} text_color={:on_background} />
          <Text text={meta} text_size={12} text_color={:muted} />
        </Column>
      </Row>
      """,
      ~MOB(<Text
  text={w.gloss}
  font={:scripture}
  text_size={19}
  line_height={1.45}
  text_color={:on_background}
/>),
      ~MOB(<Text text={w.note} text_size={14.5} line_height={1.55} text_color={:on_background} />),
      UI.kicker("Cross-references"),
      ~MOB(<Wrap spacing={8} run_spacing={8} fill_width={true}>
  {refs}
</Wrap>),
      UI.pill_button(ask_label(model, w.translit, assigns.account), ask)
    ]
  end

  # A word of a live reply's passage card (`Bezalel.Agent.Card`): what the
  # verse's word data says, and the lexicon entry once it's read (`lex`:
  # nil while loading, `:none` when the pack has none).
  defp content({:lexeme, w, lex}, assigns) do
    model = Models.get(assigns.model_id)
    ask = {self(), {:study, {:ask_lexeme, w}}}
    font = if hebrew?(w), do: :hebrew_medium, else: :scripture
    meta = lexeme_meta(w, lex)
    definition = lexeme_definition(w, lex)

    [
      ~MOB"""
      <Row gap={12} align={:center} fill_width={true}>
        <Text text={w["word"]} font={font} text_size={40} text_color={:on_background} />
        <Column gap={2} weight={1}>
          <Text
            text={w["translit"]}
            font={:scripture_italic}
            text_size={19}
            text_color={:on_background}
          />
          <Text text={meta} text_size={12} text_color={:muted} />
        </Column>
      </Row>
      """,
      UI.kicker("In this verse"),
      ~MOB(<Text
  text={w["gloss"]}
  font={:scripture}
  text_size={19}
  line_height={1.45}
  text_color={:on_background}
/>),
      UI.kicker("Lexicon"),
      ~MOB(<Text text={definition} text_size={14.5} line_height={1.55} text_color={:on_background} />),
      UI.pill_button(ask_label(model, w["translit"], assigns.account), ask)
    ]
  end

  defp hebrew?(w), do: String.starts_with?(w["strongs"], "H")

  # "H7307G · HNcfsc · 378× in the OT"
  defp lexeme_meta(w, lex) do
    count = if is_map(lex), do: lex["usage_count"]
    testament = if hebrew?(w), do: "OT", else: "NT"
    times = if is_integer(count) and count > 0, do: ["#{count}× in the #{testament}"], else: []
    Enum.join([w["strongs"], w["morph"]] ++ times, " · ")
  end

  defp lexeme_definition(_w, nil), do: "Reading the lexicon…"
  defp lexeme_definition(w, :none), do: "No lexicon entry on this phone for #{w["strongs"]}."
  defp lexeme_definition(_w, lex), do: lex["short_definition"] || ""

  defp model_row(model, current) do
    border = if model.id == current, do: :secondary, else: :border
    tap = {self(), {:model, model.id}}
    tags = for t <- model.tags, do: tag(t)

    ~MOB"""
    <Box
      background={:surface}
      border_color={border}
      border_width={1.5}
      corner_radius={16}
      padding_left={14}
      padding_right={14}
      padding_top={8}
      padding_bottom={8}
      fill_width={true}
      on_tap={tap}
    >
      <Row gap={12} align={:center} fill_width={true}>
        <Box width={10} height={10} corner_radius={5} background={model.dot} fill_width={false} />
        <Column gap={2} weight={1}>
          <Text text={model.name} font={:ui_medium} text_size={15} text_color={:on_surface} />
          <Text text={model.note} text_size={12} text_color={:muted} />
        </Column>
        {tags}
      </Row>
    </Box>
    """
  end

  defp tag(label) do
    ~MOB"""
    <Box
      border_color={:border}
      border_width={1}
      corner_radius={10}
      padding_left={8}
      padding_right={8}
      padding_top={3}
      padding_bottom={3}
      fill_width={false}
    >
      <Text
        text={label}
        font={:ui_semibold}
        text_size={10}
        letter_spacing={0.6}
        text_color={:muted}
      />
    </Box>
    """
  end

  defp ask_label(model, translit, account) do
    if Bezalel.Agent.live?(account),
      do: "Ask #{model.name} about #{translit}",
      else: "Ask about #{translit}"
  end

  defp no_models do
    ~MOB(<Text
  text="No models yet. Sign in with Claude or ChatGPT, or add an API key, in Settings → Account."
  text_size={14}
  line_height={1.5}
  text_color={:muted}
/>)
  end
end
