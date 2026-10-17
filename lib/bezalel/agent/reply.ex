defmodule Bezalel.Agent.Reply do
  @moduledoc """
  A live reply as it streams: rho's loop events (`Rho.Events`) folded into
  the design's blocks. Each model call's thinking is a THINKING block, each
  tool call a TOOL CALL block (its name and arguments, the result on
  expand), and the answer the SUMMARY. Text the model writes in a call
  that also calls tools is working narration: it joins that call's
  THINKING. A `lookup_verse` or `word_study` result that names a passage
  becomes the passage card (`Bezalel.Agent.Card`).

  Pictures in a turn or a tool result are listed in `images`.

  Pure: `Bezalel.Views.Study` keeps one per conversation with a reply in
  flight. The loop writes the reply to the conversation's session as it
  goes; once stored, `Bezalel.Library.Transcript` draws it with this same
  fold over its entries.
  """

  alias Bezalel.Agent.{Card, Patterns}
  alias Bezalel.Library.Transcript
  alias Rho.Session

  @type status :: :running | :done | :stopped | :error

  @type t :: %__MODULE__{
          conversation_id: integer(),
          session_id: String.t() | nil,
          model: String.t(),
          status: status(),
          turn: non_neg_integer(),
          items: [map()],
          text: String.t(),
          summary: String.t(),
          card: Card.t() | nil,
          images: [Bezalel.Library.Message.image()],
          seen: [String.t()],
          kept: [String.t()],
          pending: [String.t()],
          retry: String.t() | nil,
          error: String.t() | nil,
          reason: atom() | nil
        }

  defstruct [
    :conversation_id,
    :session_id,
    :model,
    status: :running,
    turn: 0,
    items: [],
    text: "",
    summary: "",
    card: nil,
    images: [],
    seen: [],
    kept: [],
    pending: [],
    retry: nil,
    error: nil,
    reason: nil
  ]

  # A header line longer than this (about one line on a phone) is cut; the
  # whole text is then the rest, so nothing hides behind the cut.
  @first_max 32
  # Lines and characters of a tool result shown under its call.
  @result_lines 6
  @result_chars 500

  @doc "A reply about to stream in `conversation_id` from `model`."
  @spec new(integer(), String.t(), String.t() | nil) :: t()
  def new(conversation_id, model, session_id \\ nil),
    do: %__MODULE__{conversation_id: conversation_id, model: model, session_id: session_id}

  @doc "A reply that failed before it started (no credential): shown as its error."
  @spec failed(integer(), String.t(), String.t()) :: t()
  def failed(conversation_id, model, error),
    do: %{new(conversation_id, model) | status: :error, error: error}

  @doc "Folds one loop event in."
  @spec apply(t(), map()) :: t()
  def apply(r, %{type: :turn_start, turn: turn}), do: %{r | turn: turn, text: ""}

  def apply(r, %{type: :message_update, kind: :thinking, delta: delta}),
    do: %{update_think(r, &(&1 <> delta)) | retry: nil}

  def apply(r, %{type: :message_update, kind: :text, delta: delta}),
    do: %{r | text: r.text <> delta, retry: nil}

  def apply(r, %{type: :message_end, entry: %{"message" => %{"role" => "assistant"} = m} = entry}) do
    r = r |> saw(entry) |> add_images(entry)

    cond do
      m["stopReason"] == "error" ->
        %{r | error: r.error || m["errorMessage"]}

      Session.tool_calls(m) != [] and String.trim(r.text) != "" ->
        r |> update_think(&join(&1, r.text)) |> Map.put(:text, "")

      true ->
        %{r | summary: join(r.summary, r.text), text: ""}
    end
  end

  def apply(r, %{type: :message_end, entry: %{"message" => %{"role" => "toolResult"}} = entry}),
    do: r |> saw(entry) |> add_images(entry)

  def apply(r, %{type: :message_end, entry: %{"type" => "custom_message"} = entry}) do
    r = saw(r, entry)

    if Session.notice_kind(entry) == :error,
      do: %{r | error: r.error || Session.text(entry["content"])},
      else: r
  end

  # The message being streamed is dropped (a retry, or an overflow
  # compaction): its thinking and text with it.
  def apply(r, %{type: :retry, attempt: attempt, error: error}),
    do: %{discard_attempt(r) | retry: "Retrying (#{attempt}): #{error}"}

  def apply(r, %{type: :compaction_start, reason: :overflow}), do: discard_attempt(r)

  def apply(r, %{type: :tool_execution_start, id: id, name: name, arguments: args}) do
    item = %{
      id: "tool-#{id}",
      kind: :tool,
      name: name,
      args: args,
      result: nil,
      error: false,
      card: nil
    }

    %{r | items: r.items ++ [item]}
  end

  def apply(r, %{type: :tool_execution_end, id: id, name: name} = event) do
    # Replayed from the session (`Bezalel.Library.Transcript`), the card
    # is the one kept with the result; live, it's built from the details.
    card =
      cond do
        event.is_error -> nil
        Map.has_key?(event, :card) -> event.card
        true -> Card.from_tool(name, event[:details])
      end

    items =
      Enum.map(r.items, fn
        %{id: "tool-" <> ^id} = item ->
          %{item | result: event.text, error: event.is_error, card: card}

        item ->
          item
      end)

    %{r | items: items, card: pick_card(r.card, card, name)}
  end

  def apply(r, %{type: :turn_end, error: error}) when is_binary(error),
    do: %{r | error: r.error || error}

  def apply(r, %{type: :agent_end, reason: reason}) do
    status =
      cond do
        r.error != nil or reason == :error -> :error
        reason == :stopped -> :stopped
        true -> :done
      end

    %{r | status: status, reason: reason, retry: nil, summary: join(r.summary, r.text), text: ""}
  end

  def apply(r, _event), do: r

  @doc "Whether the reply is still streaming."
  @spec running?(t() | nil) :: boolean()
  def running?(%__MODULE__{status: :running}), do: true
  def running?(_reply), do: false

  @doc "Whether there's anything to show: a block, a card or a picture."
  @spec any?(t()) :: boolean()
  def any?(r), do: blocks(r) != [] or r.card != nil or r.images != []

  @doc """
  Starts over after the steering message `text` was injected: the reply so
  far is done (the chat shows it from the session now: its entries move to
  `kept`), the run goes on as a new reply. `pending` loses `text`.
  """
  @spec continue(t(), String.t()) :: t()
  def continue(r, text) do
    %{
      new(r.conversation_id, r.model, r.session_id)
      | turn: r.turn,
        pending: r.pending -- [text],
        kept: r.kept ++ r.seen
    }
  end

  @doc """
  The blocks in the design's shape (`%{"id", "type", "first", "rest"}`, plus
  `"cut" => true` when `first` is a cut-short header and `rest` the whole
  text): each call's THINKING and TOOL CALLs in order, then the SUMMARY
  (with the text still streaming).

  `first` is a plain line (`header/1`); `rest` is Markdown, the model's or
  the tool's own, which the chat renders. THINKING and SUMMARY carry the
  model's whole text as `"text"` (what Copy copies).
  """
  @spec blocks(t()) :: [map()]
  def blocks(r) do
    items =
      for item <- r.items, block = item_block(item), do: block

    case String.trim(join(r.summary, r.text)) do
      "" -> items
      summary -> items ++ [block("sum", "SUMMARY", summary)]
    end
  end

  @doc """
  One line of Markdown as plain text, for a block's header: heading, list
  and quote marks dropped, a table row's cells joined by " · ", emphasis,
  code and strikethrough marks dropped, links and images as their text.
  """
  @spec header(String.t()) :: String.t()
  def header(line) do
    line
    |> String.trim()
    |> strip_block_marks()
    |> then(&Regex.replace(Patterns.get(:md_link), &1, "\\1"))
    |> String.replace(["**", "__", "~~", "`", "*"], "")
    |> then(&Regex.replace(Patterns.get(:md_underscore), &1, ""))
    |> String.split()
    |> Enum.join(" ")
  end

  defp strip_block_marks(line) do
    cond do
      String.starts_with?(line, "|") ->
        line |> String.trim("|") |> String.split("|") |> Enum.map_join(" · ", &String.trim/1)

      String.starts_with?(line, ["```", "~~~"]) ->
        ""

      true ->
        Regex.replace(Patterns.get(:md_block_mark), line, "")
    end
  end

  defp item_block(%{kind: :think, id: id, text: text}) do
    case String.trim(text) do
      "" -> nil
      text -> block(id, "THINKING", text)
    end
  end

  defp item_block(%{kind: :tool} = item) do
    %{"id" => item.id, "type" => "TOOL CALL", "first" => call_label(item), "rest" => result(item)}
  end

  # `"cut"` marks a header cut short: `rest` then holds the whole text.
  defp block(id, type, text) do
    {first, rest, cut?} = split(text)
    b = %{"id" => id, "type" => type, "first" => first, "rest" => rest, "text" => text}
    if cut?, do: Map.put(b, "cut", true), else: b
  end

  # The header: the first line when it's a block of its own (a heading, a
  # list item, a quote), else the first sentence; the rest is what follows
  # it. A table or a code block first stays whole under its first line, as
  # does a text whose header would be long, or empty, or would leave the
  # rest's Markdown unbalanced (a link or emphasis running on past it).
  defp split(text) do
    [line | _] = String.split(text, "\n", parts: 2)

    head =
      cond do
        Regex.match?(Patterns.get(:md_block_line), line) -> line
        match = Regex.run(Patterns.get(:first_sentence), text) -> hd(match)
        true -> text
      end

    first = header(head)
    whole? = String.starts_with?(String.trim_leading(line), ["|", "```", "~~~"])

    if whole? or first == "" or String.length(first) > @first_max or
         not balanced?(strip_block_marks(String.trim(head))),
       do: {cut(text), text, true},
       else: {first, text |> String.slice(String.length(head)..-1//1) |> String.trim(), false}
  end

  defp balanced?(markdown) do
    count = &(length(String.split(markdown, &1)) - 1)
    singles = markdown |> String.replace("**", "") |> String.split("*") |> length()

    underscores =
      length(Regex.scan(Patterns.get(:md_underscore), String.replace(markdown, "__", "")))

    count.("[") == count.("]") and count.("(") == count.(")") and
      Enum.all?(["`", "~~", "**", "__"], &(rem(count.(&1), 2) == 0)) and rem(singles - 1, 2) == 0 and
      rem(underscores, 2) == 0
  end

  # The first line with words in it, plain, cut to about a line.
  defp cut(text) do
    line = text |> String.split("\n") |> Enum.map(&header/1) |> Enum.find("", &(&1 != ""))

    if String.length(line) <= @first_max do
      line
    else
      head = String.slice(line, 0, @first_max)

      case String.split(head, " ") do
        [_one] -> head <> "…"
        words -> (words |> Enum.drop(-1) |> Enum.join(" ")) <> "…"
      end
    end
  end

  defp call_label(%{name: name, args: args}) when is_map(args) do
    shown =
      Enum.map_join(args, ", ", fn {key, value} ->
        "#{key}: " <> if(is_binary(value), do: inspect(value), else: Jason.encode!(value))
      end)

    "#{name}(#{shown})"
  end

  defp call_label(%{name: name}), do: "#{name}()"

  defp result(%{result: nil}), do: "Running…"

  # A passage reads better as its verses than as the Markdown the model got.
  defp result(%{card: %{} = card}), do: "→ " <> Card.text(card)

  # The tool's Markdown as it is, its first lines: whole lines, so a table
  # row or a heading isn't cut through (a cut fence runs to the end, as
  # Markdown has it). The "…" is a paragraph of its own, or it would join a
  # table as a row.
  defp result(%{result: text, error: error}) do
    lines = text |> String.trim() |> String.split("\n")
    {shown, more?} = first_lines(lines)
    shown = if more?, do: shown <> "\n\n…", else: shown
    if error, do: "Error: " <> shown, else: shown
  end

  defp first_lines(lines) do
    {kept, _count, _chars} =
      Enum.reduce_while(lines, {[], 0, 0}, fn line, {kept, count, chars} ->
        count = if String.trim(line) == "", do: count, else: count + 1
        chars = chars + String.length(line) + 1

        if count > @result_lines or (kept != [] and chars > @result_chars),
          do: {:halt, {kept, count, chars}},
          else: {:cont, {[line | kept], count, chars}}
      end)

    shown = kept |> Enum.reverse() |> Enum.join("\n") |> String.trim_trailing()

    # A first line longer than the limit on its own (JSON, minified HTML) is
    # cut at a word.
    if String.length(shown) > @result_chars,
      do: {clip(shown), true},
      else: {shown, length(kept) < length(lines)}
  end

  defp clip(text) do
    head = String.slice(text, 0, @result_chars)

    case String.split(head, " ") do
      [_one] -> head
      words -> words |> Enum.drop(-1) |> Enum.join(" ")
    end
  end

  # A passage from lookup_verse wins over word_study's examples; the
  # latest of a kind over an earlier one.
  defp pick_card(current, nil, _name), do: current
  defp pick_card(%{"from" => "lookup_verse"} = current, _card, "word_study"), do: current
  defp pick_card(_current, card, _name), do: card

  defp update_think(r, fun) do
    id = "think-#{r.turn}"

    {items, found?} =
      Enum.map_reduce(r.items, false, fn
        %{id: ^id} = item, _found -> {%{item | text: fun.(item.text)}, true}
        item, found -> {item, found}
      end)

    items = if found?, do: items, else: items ++ [%{id: id, kind: :think, text: fun.("")}]
    %{r | items: items}
  end

  # Pictures in a model's turn or a tool's result, keyed as the stored
  # reply's are (`Bezalel.Library.Message`).
  defp add_images(r, entry),
    do: %{r | images: r.images ++ Transcript.images([entry], r.session_id || "")}

  # The session entries the loop wrote for this reply so far (`seen`); the
  # chat leaves them to the stream while it runs.
  defp saw(r, %{"id" => id}), do: %{r | seen: r.seen ++ [id]}
  defp saw(r, _entry), do: r

  defp discard_attempt(r) do
    id = "think-#{r.turn}"
    %{r | text: "", items: Enum.reject(r.items, &(&1.id == id))}
  end

  defp join("", b), do: b
  defp join(a, ""), do: a
  defp join(a, b), do: a <> "\n\n" <> b
end
