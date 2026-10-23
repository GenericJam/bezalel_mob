defmodule Bezalel.Views.Sources do
  @moduledoc """
  The sources under an agent reply: what its study tools consulted
  (`Bezalel.Study.Citation`s, marked `cited` when the reply links them:
  `Bezalel.Agent.Reply.sources/1`, or a stored message's `citations`).

  A collapsed SOURCES row (its count, and how many the reply cites) opens
  to the list grouped by work (`Bezalel.Study.Citations.by_work/1`): the
  ones the reply cites first, then "Also consulted". An entry with a page
  opens it in the browser (Study's `{:open_url, url}`); a print-only book
  is its reference as text. English the model makes itself from an
  original is marked "AI translation", a published machine translation
  (CAFE's English of the Apostolic Fathers) "Machine translation", and the
  unpublished draft rendering the textual-variant tool quotes is marked as
  such, not Heiser's: each with links to the original texts.

  Open or not is the reply's `"<id>:sources"` key in Study's `expanded`,
  toggled by `{:block, key}` like a block's, so a streamed reply's open
  list stays open once it's stored.
  """
  import Mob.Sigil

  alias Bezalel.Study.{Citation, Citations}
  alias MobBezalel.UI

  @doc "The `expanded` key of message `id`'s sources."
  @spec key(String.t()) :: String.t()
  def key(id), do: id <> ":sources"

  @doc """
  Message `id`'s sources row (open when its key is in `expanded`), or
  nothing when its tools consulted none.
  """
  @spec render(String.t(), [Citation.t()], MapSet.t()) :: [map()]
  def render(_id, [], _expanded), do: []

  def render(id, citations, expanded) do
    key = key(id)
    open? = MapSet.member?(expanded, key)
    body = if open?, do: list(citations), else: ""
    [UI.block("SOURCES", summary(citations), body, open?, {self(), {:study, {:block, key}}})]
  end

  @doc ~s|The row's line: "Sources (5) · 2 cited", or "Sources (5)" when the reply cites none.|
  @spec summary([Citation.t()]) :: String.t()
  def summary(citations) do
    case Enum.count(citations, & &1.cited) do
      0 -> "Sources (#{length(citations)})"
      cited -> "Sources (#{length(citations)}) · #{cited} cited"
    end
  end

  defp list(citations) do
    {cited, rest} = Enum.split_with(citations, & &1.cited)

    sections =
      case {cited, rest} do
        {[], rest} -> [groups(rest)]
        {cited, []} -> [section("Cited in the reply", cited)]
        {cited, rest} -> [section("Cited in the reply", cited), section("Also consulted", rest)]
      end

    ~MOB"""
    <Column gap={14} fill_width={true}>
      {sections}
    </Column>
    """
  end

  defp section(title, citations) do
    ~MOB"""
    <Column gap={8} fill_width={true}>
      {UI.kicker(title)}
      {groups(citations)}
    </Column>
    """
  end

  defp groups(citations) do
    for {_work, title, group} <- Citations.by_work(citations) do
      entries = Enum.map(group, &entry/1)

      ~MOB"""
      <Column gap={4} fill_width={true}>
        <Text text={title} font={:ui_semibold} text_size={13} text_color={:on_surface} />
        {entries}
      </Column>
      """
    end
  end

  defp entry(%Citation{} = c) do
    ~MOB"""
    <Column gap={2} fill_width={true}>
      {label(c)}
      {mark(c)}
      {originals(c)}
      {licence(c)}
    </Column>
    """
  end

  # A page opens in the browser; a book (or a record with no page) is text.
  defp label(%Citation{url: url} = c) when is_binary(url) do
    ~MOB"""
    <Box padding_top={4} padding_bottom={4} fill_width={true} on_tap={open(url)}>
      <Text text={display(c)} text_size={14} line_height={1.4} text_color={:secondary} />
    </Box>
    """
  end

  defp label(%Citation{} = c) do
    text = display(c)
    ~MOB(<Text text={text} text_size={14} line_height={1.4} text_color={:on_surface} />)
  end

  # A book's label is its reference, the title in Markdown italics.
  defp display(%Citation{book: %{}, label: label}), do: String.replace(label, "*", "")
  defp display(%Citation{label: label}), do: label

  defp mark(%Citation{translation: :unpublished_draft}),
    do: [note("Unpublished draft rendering (AI-assisted), not Heiser's")]

  defp mark(%Citation{translation: :assistant}),
    do: [note("AI translation: any English for it is the assistant's own")]

  defp mark(%Citation{translation: :machine}),
    do: [note("Machine translation (AI-generated), not a human translator's")]

  defp mark(_published), do: []

  defp originals(%Citation{translation: t, original: [_ | _] = original})
       when t in [:assistant, :unpublished_draft, :machine] do
    links =
      for %{label: label, url: url} <- original do
        ~MOB"""
        <Box padding_top={6} padding_bottom={6} fill_width={false} on_tap={open(url)}>
          <Text text={label} font={:ui_semibold} text_size={12} text_color={:secondary} />
        </Box>
        """
      end

    ~MOB"""
    <Wrap spacing={12} run_spacing={0} fill_width={true}>
      <Box padding_top={6} padding_bottom={6} fill_width={false}>
        <Text text="Original:" text_size={12} text_color={:muted} />
      </Box>
      {links}
    </Wrap>
    """
  end

  defp originals(_citation), do: []

  defp licence(%Citation{licence: licence}) when is_binary(licence), do: [note(licence)]
  defp licence(_citation), do: []

  defp note(text),
    do: ~MOB(<Text text={text} font={:ui_medium} text_size={11} text_color={:muted} />)

  defp open(url), do: {self(), {:study, {:open_url, url}}}
end
