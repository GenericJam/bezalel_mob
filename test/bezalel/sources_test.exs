defmodule Bezalel.SourcesTest do
  # The sources under a reply (Bezalel.Views.Sources): live, from rho's loop
  # with the study tools on the fixture packs and a scripted model, then
  # stored and read back from the session; and the marks an AI translation,
  # the unpublished draft and a book get.
  use Mob.ScreenCase
  @moduletag :screen

  alias Bezalel.Agent.Live
  alias Bezalel.{AppScreen, Repo}
  alias Bezalel.Library.{Conversation, Tool}
  alias Bezalel.Study.{Citation, Citations}
  alias Bezalel.Test.{Browser, FakeLLM, MemoryStore}
  alias Bezalel.Views.{Helpers, Sources, Study}

  @net_2 "https://netbible.org/bible/Exodus+31:2"
  @net_3 "https://netbible.org/bible/Exodus+31:3"

  setup do
    for schema <- [Tool, Conversation], do: Repo.delete_all(schema)

    for key <- [:bezalel_conversation, :bezalel_mode, :bezalel_model, :bezalel_study_preferences],
        do: Mob.State.delete(key)

    MemoryStore.clear()
    :ok = Rho.Auth.put_api_key(:anthropic, "sk-ant-api03-test-key-0123456789")

    on_exit(fn ->
      Application.delete_env(:bezalel, Live)
      Bezalel.Agent.release_all()
    end)

    :ok
  end

  defp script(replies) do
    {:ok, llm} = FakeLLM.start(replies)
    Application.put_env(:bezalel, Live, llm: {FakeLLM, llm}, retry_base_ms: 1)
  end

  defp until(view, done? \\ &match?(%{type: :agent_end}, &1)) do
    receive do
      {:rho, _session, event} = message ->
        view = render_info(view, message)
        if done?.(event), do: view, else: until(view, done?)
    after
      2_000 -> flunk("the loop went quiet")
    end
  end

  defp texts(tree), do: for(%{props: %{text: t}} <- find_all(tree, :text), do: t)

  defp before?(list, a, b) do
    {i, j} = {Enum.find_index(list, &(&1 == a)), Enum.find_index(list, &(&1 == b))}
    i != nil and j != nil and i < j
  end

  defp opens(tree, url), do: find(tree, :box, on_tap: {self(), {:study, {:open_url, url}}})

  # Every page the tree opens.
  defp links(tree) do
    for %{props: %{on_tap: {_, {:study, {:open_url, url}}}}} <- flatten(tree), do: url
  end

  test "a live reply's sources: a collapsed row, opened to the cited one first and the rest under Also consulted; an entry opens its page; once stored they stay, still open" do
    script([
      [{:tool_call, "c1", "lookup_verse", %{"reference" => "Exodus 31:2-3"}}],
      [{:text, "God called Bezalel by name ([Exodus 31:2](#{@net_2}))."}]
    ])

    view =
      AppScreen
      |> mount_screen()
      |> render_info({:change, :draft, "Who is Bezalel?"})
      |> render_info({:tap, {:study, :send}})
      |> until(&match?(%{type: :tool_execution_end}, &1))

    # The tool's sources, before the answer links any: collapsed.
    live_key = Sources.key(Helpers.live_id(assigns(view).conversation.id))
    assert "Sources (4)" in texts(view)
    refute "Exodus 31:3" in texts(view)

    view = render_info(view, {:tap, {:study, {:block, live_key}}})
    assert "Exodus 31:3" in texts(view)
    assert "Exodus 31:2 (Hebrew)" in texts(view)

    # Answered and stored: the reply links Exodus 31:2's page, so it's cited.
    view = until(view)
    reply = List.last(assigns(view).messages)
    assert [%Citation{label: "Exodus 31:2", cited: true} | [_, _, _] = rest] = reply.citations
    refute Enum.any?(rest, & &1.cited)
    assert MapSet.member?(assigns(view).expanded, Sources.key(reply.id))

    shown = texts(view)
    assert "Sources (4) · 1 cited" in shown
    net = Citations.work_title("net")
    assert before?(shown, "CITED IN THE REPLY", net)
    assert before?(shown, net, "Exodus 31:2")
    assert before?(shown, "Exodus 31:2", "ALSO CONSULTED")
    assert before?(shown, "ALSO CONSULTED", "Exodus 31:3")
    assert before?(shown, "ALSO CONSULTED", "Exodus 31:2 (Hebrew)")

    # An entry opens its page through Study's open_url.
    assert %{props: %{on_tap: {_, tap}}} = opens(view, @net_3)
    render_info(view, {:tap, tap})
    assert Browser.last() == @net_3

    # Expand all opens the blocks and leaves the list open; Collapse all
    # folds it with them; its row opens it again.
    assert Study.toggle_all_label(assigns(view)) == "Expand all"
    view = render_info(view, {:tap, {:study, :toggle_all}})
    assert "ALSO CONSULTED" in texts(view)
    assert Study.toggle_all_label(assigns(view)) == "Collapse all"
    view = render_info(view, {:tap, {:study, :toggle_all}})
    refute "ALSO CONSULTED" in texts(view)
    view = render_info(view, {:tap, {:study, {:block, Sources.key(reply.id)}}})
    assert "ALSO CONSULTED" in texts(view)
    assert_renderable(view)
  end

  test "no sources, no row" do
    script([[{:text, "Bezalel was a craftsman."}]])

    view =
      AppScreen
      |> mount_screen()
      |> render_info({:change, :draft, "Who is Bezalel?"})
      |> render_info({:tap, {:study, :send}})
      |> until()

    assert List.last(assigns(view).messages).citations == []
    refute Enum.any?(texts(view), &String.starts_with?(&1, "Sources ("))
  end

  describe "an entry's marks" do
    @hebrew "https://www.stepbible.org/?q=version=THOT@reference=Exo.31.2"
    @greek "https://www.stepbible.org/?q=version=LXX@reference=Exo.31.2"

    defp open_list(citations) do
      %{
        type: :column,
        props: %{},
        children: Sources.render("m1", citations, MapSet.new(["m1:sources"]))
      }
    end

    test "the unpublished draft: not Heiser's, with links to the originals; no page of its own" do
      draft = %Citation{
        work: "hlt",
        label: "Unpublished draft rendering of Exodus 31:2",
        translation: :unpublished_draft,
        original: [%{label: "Hebrew (MT)", url: @hebrew}, %{label: "Greek (LXX)", url: @greek}]
      }

      tree = open_list([draft])
      shown = texts(tree)
      assert "Unpublished draft rendering (AI-assisted), not Heiser's" in shown
      assert "Original:" in shown

      refute find(tree, :text, text: draft.label).props[:on_tap]
      assert links(tree) == [@hebrew, @greek]
    end

    test "an AI translation: marked, linked to its original" do
      original = %Citation{
        work: "targum",
        label: "Targum Onkelos Exodus 31:2",
        url: "https://www.sefaria.org/Onkelos_Exodus.31.2",
        translation: :assistant,
        original: [
          %{
            label: "Targum Onkelos Exodus 31:2",
            url: "https://www.sefaria.org/Onkelos_Exodus.31.2"
          }
        ]
      }

      tree = open_list([original])
      assert "AI translation: any English for it is the assistant's own" in texts(tree)
      assert "Original:" in texts(tree)
      # Its own page and its Original: link, the same text.
      assert links(tree) == [original.url, original.url]
    end

    test "a machine translation: marked as such, not the assistant's nor a human translator's, linked to its original" do
      lake =
        "https://raw.githubusercontent.com/jtauber/apostolic-fathers/a07f920/texts/021-didache.txt"

      cafe = %Citation{
        work: "apostolic_fathers",
        label: "Didache 1.1 (CAFE, machine translation)",
        url: "https://github.com/jcuenod/CAFE/blob/06b19ae/021-didache.txt",
        translation: :machine,
        original: [%{label: "Didache 1.1 (Lake)", url: lake}]
      }

      tree = open_list([cafe])
      shown = texts(tree)
      assert "Machine translation (AI-generated), not a human translator's" in shown
      refute Enum.any?(shown, &String.starts_with?(&1, "AI translation"))
      assert "Original:" in shown
      assert links(tree) == [cafe.url, lake]
    end

    test "a published record has no mark; a book is its reference as text, and a licence shows" do
      book = %Citation{
        work: "fee_stuart",
        label: "Fee and Stuart, *How to Read the Bible for All Its Worth* (2014), on narrative",
        book: %{author: "Fee and Stuart", title: "How to Read the Bible for All Its Worth"}
      }

      note = %Citation{
        work: "tyndale",
        label: "Tyndale note on Exodus 31:1-11",
        url: "https://example.org/tyndale/ex31",
        licence: "CC BY-SA 4.0"
      }

      tree = open_list([book, note])
      shown = texts(tree)

      assert "Fee and Stuart, How to Read the Bible for All Its Worth (2014), on narrative" in shown
      assert "CC BY-SA 4.0" in shown
      refute "Original:" in shown
      refute Enum.any?(shown, &String.starts_with?(&1, "AI translation"))
      refute Enum.any?(shown, &String.starts_with?(&1, "Unpublished draft rendering (AI"))
      # Only the note opens a page; the book has none.
      assert links(tree) == ["https://example.org/tyndale/ex31"]
    end
  end
end
