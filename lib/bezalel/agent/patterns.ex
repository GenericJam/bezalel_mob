defmodule Bezalel.Agent.Patterns do
  @moduledoc """
  The regular expressions the live agent's replies and passage cards use
  (`Bezalel.Agent.Reply`, `Bezalel.Agent.Card`), compiled on first use and
  kept in `:persistent_term`, as bezalel_core's `Bezalel.Study.Patterns`
  keeps the study tools'. They are not `~r` literals: a regex compiled into
  a module is tied to the OTP it was compiled under, and mob_dev builds the
  app on one OTP for phones running another.
  """

  @sources %{
    # Bezalel.Agent.Card: punctuation and quotes around an English word.
    word_edges: {~S"^[\p{P}\p{S}]+|[\p{P}\p{S}]+$", "u"},
    # Bezalel.Agent.Reply: a block's header, its first sentence or line.
    first_sentence: {~S"\A.+?(?:[.?!:](?=\s)|\n|\z)", "su"},
    # Bezalel.Agent.Reply: a Markdown line that is a block of its own (a
    # heading, a list item, a quote, a table row, a fence) ...
    md_block_line: {~S"^ {0,3}(?:#{1,6}(?:\s|$)|[-*+]\s|[0-9]{1,9}[.)]\s|>|\||```|~~~)", "u"},
    # ... the marks that open it (nested: "> - [ ] item") ...
    md_block_mark:
      {~S"^(?:\s*(?:#{1,6}(?:\s+|$)|[-*+]\s+(?:\[[ xX]\]\s+)?|[0-9]{1,9}[.)]\s+|>\s?))+", "u"},
    # ... and a link or image, its text kept.
    md_link: {~S"!?\[([^\]]*)\]\([^)]*\)", "u"},
    # ... and an underscore that can open or close emphasis (not one inside
    # a word, as in lookup_verse).
    md_underscore: {~S"(?<![\p{L}\p{N}])_|_(?![\p{L}\p{N}])", "u"}
  }

  # The cache key carries a hash of the sources, so a hot-loaded version of
  # this module with a changed pattern compiles it afresh instead of reading
  # the old one out of :persistent_term.
  @version :erlang.phash2(@sources)

  @doc "The compiled pattern `name`."
  @spec get(atom()) :: Regex.t()
  def get(name) do
    key = {__MODULE__, @version, name}

    case :persistent_term.get(key, nil) do
      nil ->
        {source, options} = Map.fetch!(@sources, name)
        regex = Regex.compile!(source, options)
        :persistent_term.put(key, regex)
        regex

      regex ->
        regex
    end
  end
end
