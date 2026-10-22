defmodule Bezalel.LinkShapesTest do
  # The byte checks a linked computer's names go through
  # (Bezalel.Link.Shapes) accept exactly what the regular expressions they
  # replaced accepted.
  use ExUnit.Case, async: true

  alias Bezalel.Link.Shapes

  @uid "123e4567-e89b-42d3-a456-426614174000"
  @uuid "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"

  defp regex(source), do: Regex.compile!("\\A" <> source <> "\\z")

  test "a uid is a lowercase UUID" do
    pattern = regex(@uuid)

    for value <- [
          @uid,
          String.upcase(@uid),
          String.replace(@uid, "-", ""),
          @uid <> "\n",
          " " <> @uid,
          String.replace(@uid, "e", "g"),
          "123e4567-e89b-42d3-a456-42661417400",
          "",
          "../" <> @uid
        ] do
      assert Shapes.uid?(value) == Regex.match?(pattern, value), inspect(value)
    end

    refute Shapes.uid?(nil)
  end

  test "a SHA is 64 lowercase hex digits" do
    pattern = regex("[0-9a-f]{64}")
    sha = String.duplicate("ab01", 16)

    for value <- [sha, String.upcase(sha), sha <> "0", binary_part(sha, 1, 63), sha <> "\n"] do
      assert Shapes.sha?(value) == Regex.match?(pattern, value), inspect(value)
    end
  end

  test "a session file is <stamp>_<uid>.jsonl, the stamp of letters, digits, _ and -" do
    pattern = regex("[A-Za-z0-9_-]+_" <> @uuid <> "\\.jsonl")

    for value <- [
          "2026-10-20T12-00-00-000Z_#{@uid}.jsonl",
          "_#{@uid}.jsonl",
          "a__#{@uid}.jsonl",
          "../x_#{@uid}.jsonl",
          "x y_#{@uid}.jsonl",
          "x_#{@uid}.json",
          "x_#{@uid}.jsonl\n",
          "x.#{@uid}.jsonl"
        ] do
      expected = Regex.match?(pattern, value) and String.ends_with?(value, "_#{@uid}.jsonl")
      assert Shapes.session_file?(value, @uid) == expected, inspect(value)
    end

    refute Shapes.session_file?("x_#{@uid}.jsonl", String.upcase(@uid))
  end

  test "an artifact is <word char>, at most 127 of word chars, . and -, then .txt" do
    pattern = regex("[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}\\.txt")

    for value <- [
          "call1.txt",
          "a.txt",
          ".txt",
          "-a.txt",
          "a.b-c_d.txt",
          "a/b.txt",
          "a.TXT",
          "a.txt\n",
          "a" <> String.duplicate("b", 127) <> ".txt",
          "a" <> String.duplicate("b", 128) <> ".txt",
          "é.txt"
        ] do
      assert Shapes.artifact?(value) == Regex.match?(pattern, value), inspect(value)
    end
  end
end
