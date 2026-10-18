defmodule Bezalel.Agent.Storyboard do
  @moduledoc """
  The scripted replies of the Core Screens v2 design, used while the user
  has no model (no sign-in, no API key: `Bezalel.Agent.live?/1`) and in
  tests. A question that mentions a word from `Bezalel.Scripture`'s
  lexicon (in English, transliterated, or Hebrew) gets that word's entry
  (Hebrew, Strong's number, cross-references); anything else gets a short
  reply placing it in Exodus 31:1–11. Replies are attributed to
  `"storyboard"`, not to the chosen model, which the script ignores.
  """

  alias Bezalel.Scripture

  @typedoc "A scripted reply: its blocks, an optional cited passage, and `by`: `\"storyboard\"`."
  @type reply :: %{blocks: [map()], passage: String.t() | nil, by: String.t()}

  @doc "The scripted reply to the last question in `messages`."
  @spec reply([Bezalel.Library.Message.t()], map()) :: {:ok, reply()}
  def reply(messages, _model) do
    question =
      messages
      |> Enum.reverse()
      |> Enum.find_value("", fn m -> if m.role == :user, do: m.text end)

    {:ok, %{blocks: blocks_for(question), passage: nil, by: "storyboard"}}
  end

  @doc "The opening reply of the Exodus 31 study (the design's first answer)."
  @spec opening_blocks() :: [map()]
  def opening_blocks do
    [
      block(
        "think",
        "THINKING",
        "The user wants the heart of the Bezalel passage. Start where the text is surprising.",
        "Exodus 31:3 is the first explicit “filled with the Spirit of God” in the canon, and it’s given to an artisan. That’s the hook. Structure follows the verbs: called (v.2), filled (v.3), given (v.6). Pull the Hebrew for rûaḥ and ḥokmâ so the reader can check the claim."
      ),
      block(
        "tool",
        "TOOL CALL",
        ~s|lookup_passage(ref: "Exodus 31:2–3", version: "BSB")|,
        "→ returned 2 verses · 48 words\nlexicon(H7307, H2451, H4390, H7121) → 4 entries\ncross_refs(\"Ex 31:3\") → Ex 35:31, Deut 34:9, Acts 2:4"
      ),
      block(
        "sum",
        "SUMMARY",
        "This is the first time Scripture says someone was filled with the Spirit of God.",
        "And the result is craftsmanship. That gives you three movements: called by name, filled with the Spirit, put to the work."
      )
    ]
  end

  defp blocks_for(question) do
    phrase = quoted(question) || question
    low = String.downcase(question)

    case Enum.find(Scripture.word_keys(), &mentions?(low, question, &1)) do
      nil -> general(phrase)
      key -> about_word(phrase, Scripture.word(key))
    end
  end

  defp mentions?(low, question, key) do
    w = Scripture.word(key)

    String.contains?(low, key) or String.contains?(low, String.downcase(w.translit)) or
      String.contains?(question, w.heb)
  end

  defp about_word(phrase, w) do
    refs = Enum.join(w.refs, ", ")

    [
      block(
        "think",
        "THINKING",
        "They want to dig into “#{phrase}”. Check the Hebrew behind the English.",
        "Pull the lexicon entry, then show what the word does in the passage."
      ),
      block(
        "tool",
        "TOOL CALL",
        "lexicon(#{w.strong})",
        "→ #{w.count} occurrences\ncross_refs → #{refs}"
      ),
      block(
        "sum",
        "SUMMARY",
        "“#{phrase}” translates #{w.heb} (#{w.translit}, #{w.strong}): #{w.gloss}.",
        "#{w.note} See #{refs}."
      )
    ]
  end

  defp general(phrase) do
    [
      block(
        "think",
        "THINKING",
        "Place “#{phrase}” inside the commission of Bezalel, vv. 1–11.",
        "Keep it short; offer the Hebrew or cross-references as a next step."
      ),
      block(
        "sum",
        "SUMMARY",
        "“#{phrase}” sits inside God’s commission of Bezalel: called, filled, given to the work.",
        "Want the Hebrew behind it, or the places Scripture echoes it?"
      )
    ]
  end

  defp quoted(text) do
    case Regex.run(Regex.compile!("[“\"](.+)[”\"]", "u"), text) do
      [_, inner] -> inner
      nil -> nil
    end
  end

  defp block(id, type, first, rest),
    do: %{"id" => id, "type" => type, "first" => first, "rest" => rest}
end
