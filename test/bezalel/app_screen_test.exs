defmodule Bezalel.AppScreenTest do
  use Mob.ScreenCase
  # Shares the test database and Mob.State with the other modules' setup.
  @moduletag :screen

  import Ecto.Query, only: [from: 2]

  alias Bezalel.{AppScreen, Library, Repo, Settings}
  alias Bezalel.Library.{Conversation, Tool, Undo}
  alias Bezalel.Test.MemoryStore
  alias Bezalel.Views.Helpers

  setup do
    for schema <- [Tool, Conversation], do: Repo.delete_all(schema)
    Mob.State.delete(:bezalel_conversation)
    Mob.State.delete(:bezalel_mode)
    Mob.State.delete(:bezalel_model)
    Mob.State.delete(:bezalel_study_preferences)
    # No sign-in or API key: replies are the storyboard's (live replies are
    # Bezalel.LiveAgentTest's).
    MemoryStore.clear()
    :ok
  end

  test "first launch opens the worked Exodus 31 study, and every tab renders what the natives can draw" do
    view = mount_screen(AppScreen)
    assert assigns(view).conversation.name == "Exodus 31 · Bezalel"
    assert text(view) =~ "STUDY · EXODUS 31"
    refute text(view) =~ ~r/sermon/i

    for tab <- [:convs, :workshop, :settings, :study] do
      view = render_info(view, {:tap, {:tab, tab}})
      assert_renderable(view)
    end
  end

  test "asking adds the question and the agent's reply, with its summary open" do
    view = mount_screen(AppScreen)
    view = render_info(view, {:change, :draft, "What does “skill” mean?"})
    view = render_info(view, {:tap, {:study, :send}})

    assert Helpers.replying?(assigns(view))
    assert assigns(view).draft == ""

    view = render_async(view)
    refute Helpers.replying?(assigns(view))
    [question, reply] = Enum.take(assigns(view).messages, -2)
    assert question.text == "What does “skill” mean?"
    # Scripted replies are attributed to the script, not the chosen model.
    assert %{role: :agent, model: "storyboard"} = reply
    assert MapSet.member?(assigns(view).expanded, "#{reply.id}:sum")
    assert text(view) =~ "ḥokmâ"
  end

  test "a computer answering the open study blocks each phone start with a visible reason" do
    view = mount_screen(AppScreen)
    uid = assigns(view).conversation.session_id
    before = length(assigns(view).messages)

    view =
      render_info(view, {:bezalel_link, "https://study.example", {:conversation_hold, uid, true}})

    view = render_info(view, {:change, :draft, "What does skill mean?"})

    for action <- [:send, :retry, :ask_again, :pushback] do
      view = render_info(view, {:tap, {:study, action}})
      assert assigns(view).toast.text == "Your computer is answering in this conversation."
      assert assigns(view).draft == "What does skill mean?"
      assert length(assigns(view).messages) == before
      refute Helpers.replying?(assigns(view))
    end

    view =
      render_info(
        view,
        {:bezalel_link, "https://study.example", {:conversation_hold, uid, false}}
      )

    view = render_info(view, {:tap, {:study, :send}})
    assert Helpers.replying?(assigns(view))
    view = render_async(view)
    assert length(assigns(view).messages) == before + 2
  end

  test "a reply lands in the conversation it was asked in, even after switching away" do
    view = mount_screen(AppScreen)
    study = assigns(view).conversation
    before = length(assigns(view).messages)
    view = render_info(view, {:change, :draft, "What does “skill” mean?"})
    view = render_info(view, {:tap, {:study, :send}})
    view = render_info(view, {:tap, {:convs, :new}})
    new = assigns(view).conversation

    view = render_async(view)

    assert assigns(view).conversation.id == new.id
    assert assigns(view).messages == []
    asked = study.id |> Library.messages() |> Enum.drop(before)
    assert [%{role: :user, text: "What does “skill” mean?"}, %{role: :agent} = reply] = asked
    assert Enum.find(reply.blocks, &(&1["id"] == "sum"))["first"] =~ "ḥokmâ"
  end

  test "while a reply is on its way, sending waits and keeps the draft" do
    view = mount_screen(AppScreen)
    before = length(assigns(view).messages)

    view = render_info(view, {:change, :draft, "skill?"})
    view = render_info(view, {:tap, {:study, :send}})
    view = render_info(view, {:change, :draft, "Oholiab?"})
    view = render_info(view, {:tap, {:study, :send}})
    assert assigns(view).draft == "Oholiab?"

    view = render_async(view)
    view = render_info(view, {:tap, {:study, :send}})
    view = render_async(view)

    asked = assigns(view).messages |> Enum.drop(before)
    assert [:user, :agent, :user, :agent] = Enum.map(asked, & &1.role)
    assert [%{text: "skill?"}, _, %{text: "Oholiab?"}, _] = asked
  end

  test "a delete for a message that's already gone does nothing" do
    view = mount_screen(AppScreen)
    last = List.last(assigns(view).messages)
    view = render_info(view, {:tap, {:study, {:delete, last.id}}})
    count = length(assigns(view).messages)

    view = render_info(view, {:tap, {:study, {:delete, last.id}}})
    assert length(assigns(view).messages) == count

    # And in an empty conversation.
    view = render_info(view, {:tap, {:convs, :new}})
    view = render_info(view, {:tap, {:study, {:delete, last.id}}})
    assert assigns(view).messages == []
  end

  test "Ask again waits for a reply that's already on its way" do
    view = mount_screen(AppScreen)
    before = length(assigns(view).messages)
    last = List.last(assigns(view).messages)
    view = render_info(view, {:tap, {:study, {:delete, last.id}}})
    view = render_info(view, {:change, :draft, "skill?"})
    view = render_info(view, {:tap, {:study, :send}})
    view = render_info(view, {:tap, {:study, :ask_again}})
    view = render_async(view)

    # The deleted reply's slot is gone; one question, one answer.
    assert [:user, :agent] =
             assigns(view).messages |> Enum.drop(before - 1) |> Enum.map(& &1.role)
  end

  test "a reply that finishes while the shelf is open shows on the shelf" do
    view = mount_screen(AppScreen)
    count = length(assigns(view).messages)
    view = render_info(view, {:change, :draft, "skill?"})
    view = render_info(view, {:tap, {:study, :send}})
    view = render_info(view, {:tap, {:tab, :convs}})
    view = render_async(view)

    assert text(view) =~ "#{count + 2} messages"
  end

  test "a delete's toast goes away with its conversation" do
    view = mount_screen(AppScreen)
    last = List.last(assigns(view).messages)
    view = render_info(view, {:tap, {:study, {:delete, last.id}}})
    assert assigns(view).toast

    view = render_info(view, {:tap, {:convs, :new}})
    assert assigns(view).toast == nil
  end

  test "asking from the word sheet gets that word's lexicon entry" do
    view = mount_screen(AppScreen)
    view = render_info(view, {:tap, {:study, {:word, "spirit"}}})
    view = render_info(view, {:tap, {:study, {:ask_word, "spirit"}}})
    view = render_info(view, {:tap, {:study, :send}})
    view = render_async(view)

    reply = List.last(assigns(view).messages)
    assert Enum.find(reply.blocks, &(&1["id"] == "sum"))["first"] =~ "רוּחַ (rûaḥ, H7307)"
  end

  test "deleting the last reply offers Undo and Ask again; Undo puts it back" do
    view = mount_screen(AppScreen)
    last = List.last(assigns(view).messages)

    view = render_info(view, {:tap, {:study, {:delete, last.id}}})
    assert %{undo: %Undo{messages: [%{id: id}]}, ask_again: true} = assigns(view).toast
    assert id == last.id
    refute Enum.any?(assigns(view).messages, &(&1.id == last.id))

    view = render_info(view, {:tap, {:study, :undo}})
    assert List.last(assigns(view).messages).id == last.id
    assert assigns(view).toast == nil
  end

  test "deleting further up asks first, and keeping it changes nothing" do
    view = mount_screen(AppScreen)
    first = hd(assigns(view).messages)
    count = length(assigns(view).messages)

    view = render_info(view, {:tap, {:study, {:delete, first.id}}})
    assert assigns(view).sheet == {:confirm_delete, first.id}

    view = render_info(view, {:tap, :sheet})
    assert length(assigns(view).messages) == count

    view = render_info(view, {:tap, {:study, {:delete, first.id}}})
    view = render_info(view, {:tap, {:study, {:confirm_delete, first.id}}})
    assert length(assigns(view).messages) == count - 1
  end

  test "a Workshop build without a model makes the design's sample and opens it" do
    view = mount_screen(AppScreen)
    view = render_info(view, {:tap, {:tab, :workshop}})
    view = render_info(view, {:change, :desc, "A passage outline helper for Exodus 31:2–3"})
    # Without a model, the Workshop says what the build will make before it starts.
    assert text(view) =~ "Build the sample"
    assert text(view) =~ "No model is connected, so this builds the design’s sample"

    view = render_info(view, {:tap, {:workshop, :build}})
    view = render_async(view)

    assert assigns(view).tab == :tool
    assert %Tool{name: "Sermon Outline"} = assigns(view).tool
    assert text(view) =~ "God fills ordinary hands for holy work."
  end

  test "a build that finishes after the user left the Workshop doesn't pull them back" do
    view = mount_screen(AppScreen)
    view = render_info(view, {:tap, {:tab, :workshop}})
    view = render_info(view, {:change, :desc, "Sermon outline for Exodus 31"})
    view = render_info(view, {:tap, {:workshop, :build}})
    view = render_info(view, {:tap, {:tab, :settings}})
    view = render_async(view)

    assert assigns(view).tab == :settings
    assert assigns(view).toast.text =~ "Sermon Outline is built"
    # The open Settings tab counts it.
    assert text(view) =~ "1 built"
  end

  test "a tool that's gone opens the Workshop instead" do
    view = mount_screen(AppScreen)
    view = render_info(view, {:tap, {:workshop, {:open_tool, -1}}})
    assert assigns(view).tab == :workshop
    assert_renderable(view)
  end

  test "a new conversation opens empty and becomes the open one on the shelf" do
    view = mount_screen(AppScreen)
    view = render_info(view, {:change, :draft, "half-typed"})
    view = render_info(view, {:tap, {:convs, :new}})

    assert assigns(view).messages == []
    assert assigns(view).draft == ""

    view = render_info(view, {:tap, {:tab, :convs}})
    assert text(view) =~ "New study"
    assert text(view) =~ "OPEN"
  end

  describe "deleting a conversation" do
    defp study!(name) do
      {:ok, c} = Library.create_conversation(%{name: name, kicker: "STUDY", kind: "Study"})
      {:ok, _} = Library.add_message(c, %{role: :user, text: "#{name}?"})
      Library.get_conversation(c.id)
    end

    defp shelf(view), do: Enum.map(assigns(view).shelf, & &1.conversation.id)

    # Taps what the screen draws: the row's ⋯, then its Delete chip.
    defp delete(view, id) do
      view = view |> tap_node(find(view, :box, id: "conversation-more-#{id}"))
      tap_node(view, find(view, :box, on_tap: {self(), {:convs, {:delete, id}}}))
    end

    defp undo(view), do: tap_node(view, find(view, :text, text: "Undo"))

    defp tap_node(view, %{props: %{on_tap: {pid, tag}}}) when pid == self(),
      do: render_info(view, {:tap, tag})

    # Three studies, John 1 the latest (open at mount), then Psalm 119, Ruth.
    defp shelf! do
      ruth = study!("Ruth")
      psalms = study!("Psalm 119")
      john = study!("John 1")

      for {c, day} <- [{ruth, 1}, {psalms, 2}, {john, 3}] do
        at = DateTime.new!(Date.new!(2026, 10, day), ~T[09:00:00.000000])
        Repo.update_all(from(x in Conversation, where: x.id == ^c.id), set: [updated_at: at])
      end

      {ruth, psalms, john}
    end

    test "from its ⋯ menu takes the row off at once, and Undo puts it back in its place" do
      {ruth, psalms, john} = shelf!()
      view = AppScreen |> mount_screen() |> render_info({:tap, {:tab, :convs}})
      assert shelf(view) == [john.id, psalms.id, ruth.id]

      view = delete(view, psalms.id)
      assert shelf(view) == [john.id, ruth.id]
      assert assigns(view).toast.text == "Deleted “Psalm 119”"
      assert assigns(view).conversation.id == john.id
      assert_renderable(view)

      view = undo(view)
      assert shelf(view) == [john.id, psalms.id, ruth.id]
      assert assigns(view).toast == nil
      assert assigns(view).tab == :convs

      view = render_info(view, {:tap, {:convs, {:open, psalms.id}}})
      assert [%{text: "Psalm 119?"}] = assigns(view).messages
    end

    test "the open one opens the latest left; Undo opens it again" do
      {_ruth, psalms, john} = shelf!()
      view = AppScreen |> mount_screen() |> render_info({:tap, {:tab, :convs}})

      view = delete(view, john.id)
      assert assigns(view).conversation.id == psalms.id
      assert [%{text: "Psalm 119?"}] = assigns(view).messages
      assert Settings.conversation_id() == psalms.id
      assert assigns(view).tab == :convs

      view = undo(view)
      assert assigns(view).conversation.id == john.id
      assert [%{text: "John 1?"}] = assigns(view).messages
      assert assigns(view).tab == :convs
    end

    test "the last one opens a new study; Undo brings it back and the new study goes" do
      view = AppScreen |> mount_screen() |> render_info({:tap, {:tab, :convs}})
      seeded = assigns(view).conversation

      view = delete(view, seeded.id)
      assert %{name: "New study"} = assigns(view).conversation
      assert assigns(view).messages == []
      assert [%{conversation: %{name: "New study"}}] = assigns(view).shelf

      view = undo(view)
      assert assigns(view).conversation.id == seeded.id
      assert shelf(view) == [seeded.id]
      assert Library.conversation_count() == 1
    end

    test "once the Undo window ends it's purged, its session with it, and Undo does nothing" do
      {ruth, psalms, john} = shelf!()
      view = AppScreen |> mount_screen() |> render_info({:tap, {:tab, :convs}})
      view = delete(view, psalms.id)

      assert_receive {:purge, deleted} = purge, Helpers.toast_ms() + 1_000
      assert deleted.conversation_id == psalms.id
      assert File.exists?(Library.session_path(psalms))
      view = render_info(view, purge)

      assert assigns(view).toast == nil
      refute Repo.get(Conversation, psalms.id)
      refute File.exists?(Library.session_path(psalms))

      view = render_info(view, {:tap, {:convs, :undo}})
      assert shelf(view) == [john.id, ruth.id]
    end

    test "a delete whose Undo was still up when the app closed is purged at the next start" do
      {_ruth, psalms, _john} = shelf!()

      _view =
        AppScreen |> mount_screen() |> render_info({:tap, {:tab, :convs}}) |> delete(psalms.id)

      _view = mount_screen(AppScreen)
      refute Repo.get(Conversation, psalms.id)
      refute File.exists?(Library.session_path(psalms))
    end
  end
end
