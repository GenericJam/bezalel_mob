defmodule Bezalel.Agent.CardTest do
  # The passage card's translation label, from a tool's data.
  use ExUnit.Case, async: true

  alias Bezalel.Agent.Card

  @net %{key: "net", abbreviation: "NET", url: "http://netbible.org"}
  @bsb %{key: "bsb", abbreviation: "BSB", url: "https://bereanbible.com"}

  defp verse(n, translated?) do
    %{chapter: 31, verse: n, english: "verse #{n}", words: [], translated: translated?}
  end

  defp lookup(verses, translation) do
    Card.from_tool("lookup_verse", %{
      label: "Exodus 31:2-3",
      reference: "Exo.31.2-3",
      verses: verses,
      translation: translation
    })
  end

  test "labelled with the translation when any verse shown is its text, as the tool labels it" do
    card = lookup([verse(2, false), verse(3, true)], @net)
    assert card["version"] == "NET"
    assert card["version_url"] == "http://netbible.org"
  end

  test "the BSB is labelled, with no link" do
    card = lookup([verse(2, true)], @bsb)
    assert card["version"] == "BSB"
    assert card["version_url"] == nil
    assert Card.text(card) == "2 verse 2 (Exodus 31:2-3, BSB)"
  end

  test "no label when every verse shown is only the gloss" do
    card = lookup([verse(2, false), verse(3, false)], @net)
    assert card["version"] == ""
    assert card["version_url"] == nil
  end
end
