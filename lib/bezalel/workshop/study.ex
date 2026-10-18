defmodule Bezalel.Workshop.Study do
  @moduledoc """
  What a tool built in the Workshop may read of the study library: the only
  Bezalel module Dyn code may call (`config :rho, :dyn, allowed:`). It runs
  the study tools (`Bezalel.Study.Tools`) by name, read-only, and returns
  their data (`result/2`) or the Markdown the model reads (`text/2`), with
  shortcuts for a passage and a word.

  Everything comes back as `{:ok, value}` or `{:error, message}`, also
  when the study code itself fails: a failure of the Core's own code must
  not count as a crash of the built tool (its generation's probation, see
  `Rho.Dyn.Keeper`), so it is logged and returned as an error.
  """

  alias Bezalel.Study.Tools

  require Logger

  @doc "The study tools a built tool can run: `[%{name: ..., description: ...}]`."
  @spec tools() :: [%{name: String.t(), description: String.t()}]
  def tools, do: for(t <- Tools.all(), do: %{name: t.name(), description: t.description()})

  @doc """
  The data of study tool `name` for `args` (the tool's parameters, string
  keys, as the model would pass them), as its `result/1` returns it:
  maps with atom keys (for `lookup_verse`, `%{reference: ..., verses:
  [%{reference:, english:, original:, words: [%{word:, strongs:, gloss:,
  morph:, transliteration:}]}]}`).
  """
  @spec result(String.t(), map()) :: {:ok, term()} | {:error, String.t()}
  def result(name, args \\ %{}) do
    with {:ok, tool} <- tool(name), do: contained(name, fn -> tool.result(args) end)
  end

  @doc "The Markdown study tool `name` answers the model with for `args`."
  @spec text(String.t(), map()) :: {:ok, String.t()} | {:error, String.t()}
  def text(name, args \\ %{}) do
    with {:ok, tool} <- tool(name),
         do: contained(name, fn -> markdown(tool.run(args, %{})) end)
  end

  defp markdown({:ok, {:details, markdown, _details}}), do: {:ok, markdown}
  defp markdown(other), do: other

  @doc """
  A passage ("John 3:16", "Ps 23", "Exodus 31:1-11"): `lookup_verse`'s
  data, each verse with its English (the user's translation, which
  `translation` names), its Hebrew or Greek and its words, and a `label`
  as people write it ("Exodus 31:2"; `reference` is the packs'
  "Exo.31.2"). At most 50 verses.
  """
  @spec passage(String.t()) :: {:ok, map()} | {:error, String.t()}
  def passage(reference) when is_binary(reference) do
    with {:ok, p} <- result("lookup_verse", %{"reference" => reference}) do
      {:ok, %{p | verses: Enum.map(p.verses, &Map.put(&1, :label, label(p.book_name, &1)))}}
    end
  end

  defp label(book, %{verse: 0, heading: heading}), do: "#{book}: #{heading}"
  defp label(book, %{chapter: chapter, verse: verse}), do: "#{book} #{chapter}:#{verse}"

  @doc ~S|A lexicon word by Strong's number ("H7307", "G26"): `word_study`'s data.|
  @spec word(String.t()) :: {:ok, map()} | {:error, String.t()}
  def word(strongs) when is_binary(strongs), do: result("word_study", %{"strongs" => strongs})

  defp tool(name) do
    case Enum.find(Tools.all(), &(&1.name() == name)) do
      nil -> {:error, "no study tool is named #{inspect(name)}"}
      tool -> {:ok, tool}
    end
  end

  # The study code's own failure is reported, not raised into the caller.
  defp contained(name, fun) do
    fun.()
  rescue
    exception ->
      Logger.error("[workshop] study tool #{name} failed: " <> Exception.message(exception))
      {:error, "the study library couldn't answer (#{name} failed)"}
  end
end
