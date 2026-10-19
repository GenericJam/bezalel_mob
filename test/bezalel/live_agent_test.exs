defmodule Bezalel.LiveAgentTest do
  # Study on the live agent: rho's loop with the study tools (fixture packs)
  # and a scripted model (Bezalel.Test.FakeLLM), no network. The screen runs
  # in the test process, so the loop's events arrive here and are fed to it.
  use Mob.ScreenCase
  @moduletag :screen

  alias Bezalel.Agent.{Live, Reply}
  alias Bezalel.{AppScreen, Library, Repo, Settings}
  alias Bezalel.Library.{Conversation, Tool}
  alias Bezalel.Study.{Preferences, Prompt}
  alias Bezalel.Test.{Browser, FakeLLM, MemoryStore}
  alias Bezalel.Views.{Helpers, Study}
  alias MobBezalel.UI

  @lookup {:tool_call, "c1", "lookup_verse", %{"reference" => "Exodus 31:2-3"}}

  setup do
    for schema <- [Tool, Conversation], do: Repo.delete_all(schema)

    for key <- [:bezalel_conversation, :bezalel_mode, :bezalel_model, :bezalel_study_preferences],
        do: Mob.State.delete(key)

    MemoryStore.clear()
    :ok = Rho.Auth.put_api_key(:anthropic, "sk-ant-api03-test-key-0123456789")

    on_exit(fn ->
      Application.delete_env(:bezalel, Live)
      Bezalel.Agent.release_all()
      Mob.State.delete(:bezalel_study_preferences)
    end)

    :ok
  end

  defp script(replies) do
    {:ok, llm} = FakeLLM.start(replies)
    Application.put_env(:bezalel, Live, llm: {FakeLLM, llm}, retry_base_ms: 1)
  end

  defp ask(view, text) do
    view
    |> render_info({:change, :draft, text})
    |> render_info({:tap, {:study, :send}})
  end

  # Feeds the loop's events to the screen until `done?` holds for one (it
  # is fed too), by default the end of the run.
  defp until(view, done? \\ &match?(%{type: :agent_end}, &1)) do
    receive do
      {:rho, _session, event} = message ->
        view = render_info(view, message)
        if done?.(event), do: view, else: until(view, done?)
    after
      2_000 -> flunk("the loop went quiet")
    end
  end

  # Feeds the screen what the loop has sent and still sends for a moment.
  defp drain(view) do
    receive do
      {:rho, _session, _event} = message -> view |> render_info(message) |> drain()
    after
      200 -> view
    end
  end

  defp stream(view), do: assigns(view).streams[assigns(view).conversation.id]
  defp types(blocks), do: Enum.map(blocks, & &1["type"])
  defp block(blocks, type), do: Enum.find(blocks, &(&1["type"] == type))
  defp loop?(view), do: Live.running?(assigns(view).conversation.id)
  # The Markdown view of the block under `key` (`Helpers.block_key/2`).
  defp markdown(view, key), do: find(view, :native_view, id: String.to_atom("md:" <> key))
  defp texts(view), do: for(%{props: %{text: t}} <- find_all(view, :text), do: t)
  defp tool_names(request), do: Enum.map(request.tools, & &1.name)

  test "a reply streams into THINKING, a TOOL CALL with its result, the SUMMARY and the passage card, then is stored" do
    script([
      [{:thinking, "Find the verse."}, {:text, "Let me look it up."}, @lookup],
      [{:text, "Bezalel is "}, {:text, "**filled** with the Spirit. He is the first."}]
    ])

    view = AppScreen |> mount_screen() |> ask("Who is Bezalel?")
    assert assigns(view).draft == ""
    assert_receive {:llm_request, first}
    # The study prompt for the default preferences, with the phone's
    # formatting section and the rule for asking another model.
    assert first.system_prompt == Live.system_prompt(%Preferences{})

    assert first.system_prompt ==
             Prompt.system_prompt(%Preferences{},
               surface: Live.phone_formatting(),
               ask_model: true
             )

    assert first.system_prompt =~ "## Formatting for a phone"
    assert first.system_prompt =~ "column about 40 characters wide"

    # The study tools, read_artifact and ask_model (another model, asked
    # for in words).
    assert Enum.sort(Enum.map(first.tools, & &1.name)) ==
             Enum.sort(Enum.map(Live.tools(), & &1.name()))

    assert "ask_model" in tool_names(first)

    # The loop starts from the conversation as stored: the seeded study.
    assert [%{role: :user} = opening | _] = first.messages
    assert hd(opening.content).text =~ "Help me study Bezalel"

    view = until(view, &match?(%{type: :tool_execution_end}, &1))
    blocks = Reply.blocks(stream(view))
    assert types(blocks) == ["THINKING", "TOOL CALL"]
    assert block(blocks, "THINKING")["rest"] =~ "Let me look it up."
    tool = block(blocks, "TOOL CALL")
    assert tool["first"] == ~s|lookup_verse(reference: "Exodus 31:2-3")|
    assert tool["rest"] =~ "→ "
    # The passage card, from the tool's data: tappable words with Strong's numbers.
    card = stream(view).card
    assert card["title"] == "Exodus 31:2-3"
    # (The NET's "I have chosen Bezalel": the gloss is "called", so "chosen" stays plain.)
    assert ["Bezalel", "H1212G"] in hd(card["verses"])["tokens"]
    assert ["chosen", nil] in hd(card["verses"])["tokens"]
    assert card["words"]["H7307G"]["translit"] == "Ru.ach"
    assert text(view) =~ "Tap a highlighted word for the original"
    # The translation it quotes (the NET, the default, from the fixture
    # translations pack), labelled; "(NET)" follows the last verse, linked
    # to the first verse's page at netbible.org, as the NET's terms ask.
    assert card["version"] == "NET"
    net_url = "https://netbible.org/bible/Exodus+31:2"
    assert card["version_url"] == net_url
    assert "NET" in texts(view)
    net = {:study, {:open_url, net_url}}
    assert %{props: %{on_tap: {_, ^net}}} = find(view, :text, text: "(NET)")

    [last_verse] =
      view |> find_all(:wrap) |> Enum.filter(&(find(&1, :text, text: "(NET)") != nil))

    assert List.last(last_verse.children).props.text == "(NET)"
    render_info(view, {:tap, net})
    assert Browser.last() == net_url

    view = until(view, &match?(%{type: :message_update, delta: "Bezalel is "}, &1))
    assert block(Reply.blocks(stream(view)), "SUMMARY")["first"] == "Bezalel is"
    assert Helpers.replying?(assigns(view))
    assert find(view, :box, id: "composer-stop")

    view = until(view)
    refute stream(view)
    refute find(view, :box, id: "composer-stop")
    reply = List.last(assigns(view).messages)
    assert %{role: :agent, card: %{"title" => "Exodus 31:2-3"}} = reply
    assert reply.model == assigns(view).model_id
    assert types(reply.blocks) == ["THINKING", "TOOL CALL", "SUMMARY"]
    # A first sentence longer than a line is cut in the header (plain); the
    # rest holds all of it, as the model wrote it, in the Markdown view.
    assert block(reply.blocks, "SUMMARY")["first"] == "Bezalel is filled with the…"
    source = "Bezalel is **filled** with the Spirit. He is the first."
    assert block(reply.blocks, "SUMMARY")["rest"] == source

    assert MapSet.member?(assigns(view).expanded, "#{reply.id}:sum")
    assert markdown(view, "#{reply.id}:sum").props.text == source
    refute text(view) =~ "He is the first."

    # A highlighted word opens its sheet; the lexicon entry comes from the pack.
    word = reply.card["words"]["H7307G"]
    view = render_info(view, {:tap, {:study, {:lexeme, word}}})
    assert {:lexeme, ^word, nil} = assigns(view).sheet
    view = render_async(view)
    assert {:lexeme, ^word, %{"strongs" => "H7307"}} = assigns(view).sheet
    assert_renderable(view)
  end

  describe "study preferences" do
    @approach "Answer briefly, as a rabbi reading with students would."

    test "a change releases the idle loop; the next question's loop has the new prompt and withholds the tools of the sources switched off" do
      script([[{:text, "First."}], [{:text, "Second."}]])

      view = AppScreen |> mount_screen() |> ask("Who is Bezalel?") |> until()
      assert_receive {:llm_request, first}
      assert first.system_prompt =~ "Evidence and range, not verdicts"
      assert first.system_prompt =~ "Moshe Kline's Woven Torah hypothesis"
      refute first.system_prompt =~ @approach
      assert "get_torah_weave" in tool_names(first)
      # The loop stays while the conversation is open.
      assert loop?(view)

      # The approach and sources screens store the change and tell the app.
      Settings.update_study_preferences(fn prefs ->
        %{
          prefs
          | approach: @approach,
            excluded_sources: MapSet.put(prefs.excluded_sources, "method:torah_weave")
        }
      end)

      view = render_info(view, {:study_preferences, :changed})
      assert assigns(view).study.approach == @approach
      refute loop?(view)

      view |> ask("And Oholiab?") |> until()
      assert_receive {:llm_request, second}
      # The user's approach in place of the default one.
      assert second.system_prompt =~ @approach
      refute second.system_prompt =~ "Evidence and range, not verdicts"
      # Kline's Torah weave switched off: its tool and its guide line go,
      # and the prompt names it as switched off.
      refute second.system_prompt =~ "Moshe Kline's Woven Torah hypothesis"
      assert second.system_prompt =~ "## Sources switched off"
      assert second.system_prompt =~ "Torah Weave (Moshe Kline)"
      refute "get_torah_weave" in tool_names(second)
      assert "lookup_verse" in tool_names(second)
      # The second loop resumed the conversation: the first answer is there.
      assert Enum.any?(second.messages, &(&1.role == :assistant))
    end

    test "a change made while a reply streams keeps its loop until the reply ends" do
      script([[{:text, "Partial"}, {:sleep, 300}, {:text, " answer."}], [{:text, "Next."}]])

      view = AppScreen |> mount_screen() |> ask("Who is Bezalel?")
      view = until(view, &match?(%{type: :message_update}, &1))
      %{id: cid} = assigns(view).conversation

      view = render_info(view, {:tap, {:settings, {:translation, "bsb"}}})
      assert Settings.study_preferences().translation == "bsb"
      assert loop?(view)
      assert MapSet.member?(assigns(view).stale, cid)

      view = until(view)
      refute loop?(view)
      refute MapSet.member?(assigns(view).stale, cid)
    end
  end

  test "Markdown renders natively: the summary as it streams, thinking and tool results opened; headers stay plain text" do
    script([
      [{:thinking, "Look up **Ex 31:3**.\n\n- the verse"}, @lookup],
      [{:text, "## Bezalel\n\nHe is "}, {:text, "**filled**.\n\n| a | b |\n|--|--|\n| 1 | 2 |"}]
    ])

    view = AppScreen |> mount_screen() |> ask("Who is Bezalel?")
    live = Helpers.live_id(assigns(view).conversation.id)
    view = until(view, &match?(%{type: :message_update, delta: "## Bezalel\n\nHe is "}, &1))

    # The streaming summary: a plain header, the Markdown so far in the view.
    summary = markdown(view, live <> ":sum")
    assert summary.props.text == "He is"
    assert summary.props.module == MobMarkdown.View

    assert Map.take(summary.props, [:text_color, :ios, :android]) ==
             Map.take(UI.markdown_style(:summary), [:text_color, :ios, :android])

    assert "Bezalel" in texts(view)
    refute text(view) =~ "#"

    # Thinking and the tool call stay folded (no view) until opened, then
    # show their Markdown in the muted style.
    [think, call, _sum] = Reply.blocks(stream(view))
    assert think["first"] == "Look up Ex 31:3."

    for b <- [think, call] do
      key = "#{live}:#{b["id"]}"
      refute markdown(view, key)
      opened = render_info(view, {:tap, {:study, {:block, key}}})
      body = markdown(opened, key)
      assert body.props.text == b["rest"]
      assert body.props.text_color == UI.markdown_style(:aside).text_color
    end

    view = until(view)
    reply = List.last(assigns(view).messages)
    source = "## Bezalel\n\nHe is **filled**.\n\n| a | b |\n|--|--|\n| 1 | 2 |"

    assert markdown(view, "#{reply.id}:sum").props.text ==
             "He is **filled**.\n\n| a | b |\n|--|--|\n| 1 | 2 |"

    # Copy takes the Markdown as the model wrote it.
    assert Study.copy_text(reply) =~ source
    assert_renderable(view)
  end

  test "past the native views the screen can hold, the oldest open blocks show their Markdown as text" do
    messages =
      for n <- 1..125,
          do: %{id: "m#{n}", role: :agent, blocks: [%{"id" => "sum", "rest" => "**#{n}**"}]}

    expanded = MapSet.new(messages, &"#{&1.id}:sum")
    live = {%{id: "live-1"}, [%{"id" => "sum", "rest" => "**live**"}]}
    keys = Study.markdown_keys(messages, live, MapSet.put(expanded, "live-1:sum"))

    assert MapSet.size(keys) == 120
    assert "live-1:sum" in keys and "m125:sum" in keys and "m7:sum" in keys
    refute "m6:sum" in keys

    # Folded blocks and empty bodies take none.
    assert Study.markdown_keys(messages, {nil, []}, MapSet.new()) == MapSet.new()
  end

  test "a message sent mid-reply steers it: the reply so far, the message, then the rest" do
    script([
      [{:text, "Looking."}, {:sleep, 300}, @lookup],
      [{:text, "Both answered."}]
    ])

    view = AppScreen |> mount_screen() |> ask("Who is Bezalel?")
    before = length(assigns(view).messages)
    view = ask(view, "And Oholiab?")
    assert assigns(view).draft == ""
    assert stream(view).pending == ["And Oholiab?"]
    assert text(view) =~ "Queued"

    view = until(view)
    asked = Enum.drop(assigns(view).messages, before)

    assert [
             %{role: :agent} = partial,
             %{role: :user, text: "And Oholiab?"},
             %{role: :agent} = rest
           ] = asked

    assert "TOOL CALL" in types(partial.blocks)
    assert types(rest.blocks) == ["SUMMARY"]

    assert_receive {:llm_request, _}
    assert_receive {:llm_request, second}
    assert hd(List.last(second.messages).content).text == "And Oholiab?"
  end

  test "Stop keeps what streamed and lets the conversation go on" do
    script([[{:text, "Partial answer"}, :block]])

    view = AppScreen |> mount_screen() |> ask("Who is Bezalel?")
    view = until(view, &match?(%{type: :message_update}, &1))
    view = render_info(view, {:tap, {:study, :stop}})
    view = until(view)

    assert %{role: :agent, blocks: [%{"type" => "SUMMARY", "first" => "Partial answer"}]} =
             List.last(assigns(view).messages)

    refute Helpers.replying?(assigns(view))
    refute loop?(view)
  end

  test "a message queued as the run hits its iteration limit goes back to the draft" do
    script([[{:sleep, 300}, @lookup], [{:text, "Status: looked it up."}]])

    Application.put_env(
      :bezalel,
      Live,
      Application.get_env(:bezalel, Live) ++ [max_iterations: 1]
    )

    view = AppScreen |> mount_screen() |> ask("Who is Bezalel?")
    view = view |> ask("And Oholiab?") |> until()

    refute stream(view)
    refute Helpers.replying?(assigns(view))
    refute loop?(view)
    assert assigns(view).draft == "And Oholiab?"
    refute Enum.any?(assigns(view).messages, &(&1.role == :user and &1.text == "And Oholiab?"))
    assert block(List.last(assigns(view).messages).blocks, "SUMMARY")["first"] =~ "Status"
  end

  test "a stop clears a delete's pending release and the loop's session" do
    script([[{:text, "Partial answer"}, :block]])

    view = AppScreen |> mount_screen() |> ask("Who is Bezalel?")
    view = until(view, &match?(%{type: :message_update}, &1))
    question = List.last(assigns(view).messages)
    view = render_info(view, {:tap, {:study, {:delete, question.id}}})
    assert MapSet.member?(assigns(view).stale, assigns(view).conversation.id)

    view = view |> render_info({:tap, {:study, :stop}}) |> until()
    assert assigns(view).stale == MapSet.new()
    assert assigns(view).sessions == %{}
  end

  test "deleting a conversation while its reply streams stops it first; Undo brings it back as the chat showed it" do
    script([[{:text, "Partial answer"}, :block]])

    view = AppScreen |> mount_screen() |> ask("Who is Bezalel?")
    view = until(view, &match?(%{type: :message_update}, &1))
    %{id: cid} = assigns(view).conversation
    question = List.last(assigns(view).messages)
    # A delete waiting for the reply to end, and a message it hasn't taken in.
    view = render_info(view, {:tap, {:study, {:delete, question.id}}})
    shown = Enum.map(assigns(view).messages, & &1.id)
    view = ask(view, "And Oholiab?")
    assert stream(view).pending == ["And Oholiab?"]

    view = render_info(view, {:tap, {:convs, {:delete, cid}}})
    refute Live.running?(cid)
    refute Map.has_key?(assigns(view).streams, cid)
    assert assigns(view).sessions == %{}
    assert assigns(view).stale == MapSet.new()
    assert assigns(view).edits == %{}
    assert %{name: "New study"} = assigns(view).conversation
    # What the loop sent as it stopped reaches nobody.
    view = drain(view)
    assert Library.get_conversation(cid) == nil

    view = render_info(view, {:tap, {:convs, :undo}})
    assert assigns(view).conversation.id == cid
    messages = assigns(view).messages
    # The waiting delete was made; what streamed was kept, then the message.
    refute Enum.any?(messages, &(&1.id == question.id))
    assert Enum.drop(Enum.map(messages, & &1.id), -2) == shown

    assert [
             %{role: :agent, blocks: [%{"type" => "SUMMARY", "first" => "Partial answer"}]},
             %{role: :user, text: "And Oholiab?"}
           ] = Enum.take(messages, -2)

    assert %{message_count: count} = Enum.find(assigns(view).shelf, &(&1.conversation.id == cid))
    assert count == length(messages)
  end

  defmodule SlowTool do
    @moduledoc false
    @behaviour Rho.Tool

    @impl true
    def name, do: "slow_tool"
    @impl true
    def description, do: "Takes a moment."
    @impl true
    def parameter_schema, do: %{"type" => "object", "properties" => %{}}

    @impl true
    def run(_args, _ctx) do
      Process.sleep(300)
      {:ok, "slow result"}
    end
  end

  test "deleting a conversation while a tool runs waits for its result before the loop goes" do
    :ok = Rho.ToolRegistry.register(SlowTool)
    on_exit(fn -> Rho.ToolRegistry.unregister("slow_tool") end)
    script([[{:tool_call, "c1", "slow_tool", %{}}], [{:text, "Never asked."}]])

    view = AppScreen |> mount_screen() |> ask("Who is Bezalel?")
    view = until(view, &match?(%{type: :tool_execution_start}, &1))
    %{id: cid} = assigns(view).conversation

    view = render_info(view, {:tap, {:convs, {:delete, cid}}})
    refute Live.running?(cid)
    _view = drain(view)

    # Deleted, kept until its purge.
    path = Conversation |> Repo.get(cid) |> Library.session_path()
    {:ok, _session, branch} = Rho.Session.open(path, "anthropic:x")

    assert Enum.any?(
             branch,
             &match?(%{"message" => %{"role" => "toolResult", "toolCallId" => "c1"}}, &1)
           )
  end

  test "a message the loop took in just before a delete isn't added again by it" do
    script([[{:sleep, 300}, {:text, "First part."}], [{:text, "More"}, :block]])

    view = AppScreen |> mount_screen() |> ask("Who is Bezalel?")
    view = ask(view, "And Oholiab?")
    assert stream(view).pending == ["And Oholiab?"]
    # The loop takes it in and asks again; this screen hasn't seen that yet.
    assert_receive {:llm_request, _}
    assert_receive {:llm_request, _}, 2_000
    %{id: cid} = assigns(view).conversation

    view = render_info(view, {:tap, {:convs, {:delete, cid}}})
    view = render_info(view, {:tap, {:convs, :undo}})

    assert ["Who is Bezalel?", "And Oholiab?"] ==
             assigns(view).messages
             |> Enum.take(-4)
             |> Enum.flat_map(&if(&1.role == :user, do: [&1.text], else: []))
  end

  test "a message that started a run after one ended isn't added again by a delete" do
    script([[{:text, "First answer."}], [{:text, "More"}, :block]])

    view = AppScreen |> mount_screen() |> ask("Who is Bezalel?")
    # The run ends; this screen hasn't seen that yet, so the next message
    # steers the idle loop, which starts a run with it.
    await_queued(&match?({:rho, _, %{type: :agent_end}}, &1))
    view = ask(view, "And Oholiab?")
    assert stream(view).pending == ["And Oholiab?"]
    assert_receive {:llm_request, _}
    assert_receive {:llm_request, _}, 2_000
    %{id: cid} = assigns(view).conversation

    view = render_info(view, {:tap, {:convs, {:delete, cid}}})
    view = render_info(view, {:tap, {:convs, :undo}})

    assert ["Who is Bezalel?", "And Oholiab?"] ==
             assigns(view).messages
             |> Enum.take(-4)
             |> Enum.flat_map(&if(&1.role == :user, do: [&1.text], else: []))
  end

  # Waits until a message matching `queued?` is in this process's mailbox,
  # leaving it there.
  defp await_queued(queued?, tries \\ 200) do
    {:messages, messages} = Process.info(self(), :messages)

    cond do
      Enum.any?(messages, queued?) ->
        :ok

      tries == 0 ->
        flunk("never queued")

      true ->
        Process.sleep(10)
        await_queued(queued?, tries - 1)
    end
  end

  test "after a restart the next question resumes the session: the model sees the reply as written" do
    script([[{:text, "Wait for it…\nThe end."}], [{:text, "Again."}]])

    view = AppScreen |> mount_screen() |> ask("First?") |> until()
    assert_receive {:llm_request, _}
    assert block(List.last(assigns(view).messages).blocks, "SUMMARY")["first"] == "Wait for it…"
    shown = assigns(view).messages

    # A fresh screen (the app restarted): every loop goes, the conversation
    # reads back from its session as it was.
    view = mount_screen(AppScreen)

    for {pid, _} <- Registry.lookup(Live, assigns(view).conversation.id),
        do: refute(Process.alive?(pid))

    assert Enum.map(assigns(view).messages, & &1.id) == Enum.map(shown, & &1.id)
    assert List.last(assigns(view).messages).blocks == List.last(shown).blocks

    _view = view |> ask("Second?") |> until()
    assert_receive {:llm_request, second}
    texts = for m <- second.messages, part <- m.content, do: part.text
    assert ["First?", "Wait for it…\nThe end.", "Second?"] == Enum.take(texts, -3)
  end

  test "a long first sentence is cut in its header and kept whole beneath" do
    long = String.duplicate("word ", 40) <> "end."
    script([[{:text, long}], [{:text, "Again."}]])

    view = AppScreen |> mount_screen() |> ask("First?") |> until()

    assert %{"cut" => true, "rest" => ^long} =
             block(List.last(assigns(view).messages).blocks, "SUMMARY")

    :ok = Bezalel.Agent.release(assigns(view).conversation.id)
    _view = view |> ask("Second?") |> until()
    assert_receive {:llm_request, _}
    assert_receive {:llm_request, second}
    assert long in for(m <- second.messages, part <- m.content, do: part.text)
  end

  test "without a credential for the chosen model, a card points to Settings" do
    MemoryStore.clear()
    :ok = Rho.Auth.put_api_key(:openai, "sk-proj-abcdefghijklmnop1234WXYZ")
    script([])

    view = AppScreen |> mount_screen() |> ask("Who is Bezalel?")
    assert %Reply{status: :error, error: error} = stream(view)
    assert error =~ "needs a Claude sign-in or Anthropic API key"
    assert text(view) =~ "Open Settings"
    refute_receive {:llm_request, _}
    refute loop?(view)

    # Live, not scripted: Settings drops the script note.
    view = render_info(view, {:tap, {:tab, :settings}})
    refute text(view) =~ "design’s script"
  end

  test "a provider error is the reply's error, and Try again asks afresh" do
    script([[{:error, {:http, 401, "invalid x-api-key"}}], [{:text, "Now it works."}]])

    view = AppScreen |> mount_screen() |> ask("Who is Bezalel?")
    count = length(assigns(view).messages)
    view = until(view)

    assert %Reply{status: :error, error: error} = stream(view)
    assert error =~ "401 (sign-in rejected): invalid x-api-key"
    assert text(view) =~ "Try again"
    assert text(view) =~ "Open Settings"
    assert length(assigns(view).messages) == count

    view = view |> render_info({:tap, {:study, :retry}}) |> until()
    refute stream(view)

    assert [%{role: :user, text: "Who is Bezalel?"}, %{role: :agent} = reply] =
             Enum.take(assigns(view).messages, -2)

    assert block(reply.blocks, "SUMMARY")["first"] == "Now it works."
  end

  test "a missing study pack is a tool error the model sees; the reply still lands" do
    dir = Path.join(System.tmp_dir!(), "bezalel_no_packs_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    packs = Application.fetch_env!(:bezalel, :study_packs_dir)
    Application.put_env(:bezalel, :study_packs_dir, dir)
    on_exit(fn -> Application.put_env(:bezalel, :study_packs_dir, packs) end)

    script([[@lookup], [{:text, "The text isn't on this phone yet."}]])

    view = AppScreen |> mount_screen() |> ask("Show me Exodus 31:2-3")
    view = until(view)

    reply = List.last(assigns(view).messages)
    assert block(reply.blocks, "TOOL CALL")["rest"] =~ "Error: The core study pack"
    assert reply.card == nil
    assert_receive {:llm_request, _}
    assert_receive {:llm_request, second}
    assert %{role: :tool} = List.last(second.messages)
    assert hd(List.last(second.messages).content).text =~ "core study pack"
  end

  test "a reply lands in the conversation it was asked in, after switching away" do
    script([[{:sleep, 100}, {:text, "About Bezalel."}]])

    view = AppScreen |> mount_screen() |> ask("Who is Bezalel?")
    study = assigns(view).conversation
    view = render_info(view, {:tap, {:convs, :new}})
    new = assigns(view).conversation

    view = until(view)
    assert assigns(view).conversation.id == new.id
    assert assigns(view).messages == []
    refute assigns(view).streams[study.id]

    assert [%{role: :user}, %{role: :agent} = reply] =
             study.id |> Library.messages() |> Enum.take(-2)

    assert block(reply.blocks, "SUMMARY")["first"] == "About Bezalel."
    # Its loop went with the conversation.
    assert Registry.lookup(Live, study.id) == []
  end

  test "a deleted reply is out of the agent's context from the next question" do
    script([[{:text, "First answer."}], [{:text, "Second answer."}]])

    view = AppScreen |> mount_screen() |> ask("First?") |> until()
    first = List.last(assigns(view).messages)
    assert_receive {:llm_request, _}

    view = render_info(view, {:tap, {:study, {:delete, first.id}}})
    refute loop?(view)
    view = view |> ask("Second?") |> until()

    assert_receive {:llm_request, second}
    texts = for m <- second.messages, part <- m.content, do: part.text
    refute "First answer." in texts
    assert ["First?", "Second?"] == Enum.take(texts, -2)
    assert block(List.last(assigns(view).messages).blocks, "SUMMARY")["first"] == "Second answer."
  end

  test "Undo after a delete puts the reply back, for the agent too" do
    script([[{:text, "First answer."}], [{:text, "Second answer."}]])

    view = AppScreen |> mount_screen() |> ask("First?") |> until()
    first = List.last(assigns(view).messages)
    assert_receive {:llm_request, _}

    view = render_info(view, {:tap, {:study, {:delete, first.id}}})
    refute Enum.any?(assigns(view).messages, &(&1.id == first.id))
    view = render_info(view, {:tap, {:study, :undo}})
    assert List.last(assigns(view).messages).id == first.id

    _view = view |> ask("Second?") |> until()
    assert_receive {:llm_request, second}
    texts = for m <- second.messages, part <- m.content, do: part.text
    assert ["First?", "First answer.", "Second?"] == Enum.take(texts, -3)
  end

  test "a delete made while a reply streams waits for it: hidden now, out of the session after" do
    script([[{:text, "Partial"}, {:sleep, 200}, {:text, " answer."}], [{:text, "Next."}]])

    view = AppScreen |> mount_screen()
    opening = hd(assigns(view).messages)
    view = view |> ask("Who is Bezalel?") |> until(&match?(%{type: :message_update}, &1))
    view = render_info(view, {:tap, {:study, {:delete, opening.id}}})
    view = render_info(view, {:tap, {:study, {:confirm_delete, opening.id}}})
    assert {:pending, _, _} = assigns(view).toast.undo
    refute Enum.any?(assigns(view).messages, &(&1.id == opening.id))

    view = until(view)
    refute Enum.any?(assigns(view).messages, &(&1.id == opening.id))
    refute Enum.any?(Library.messages(assigns(view).conversation.id), &(&1.id == opening.id))
    # The toast's Undo is the done delete's now.
    assert %Library.Undo{} = assigns(view).toast.undo

    assert block(List.last(assigns(view).messages).blocks, "SUMMARY")["first"] ==
             "Partial answer."
  end

  describe "pictures" do
    alias Bezalel.Images.Codec
    alias Bezalel.Test.{PictureTool, Png}

    defp with_picture_tool do
      Application.put_env(
        :bezalel,
        Live,
        Application.get_env(:bezalel, Live) ++ [tools: Live.tools() ++ [PictureTool]]
      )
    end

    defp image_node(view, key), do: find(view, :box, id: "image-" <> key)

    test "a tool's picture shows in the reply, downscaled to the chat's width, and opens full-screen" do
      script([[{:tool_call, "p1", "draw_lampstand", %{}}], [{:text, "There it is."}]])
      with_picture_tool()

      view = AppScreen |> mount_screen() |> ask("Draw the lampstand")

      view =
        until(
          view,
          &match?(%{type: :message_end, entry: %{"message" => %{"role" => "toolResult"}}}, &1)
        )

      assert [%{key: key}] = stream(view).images
      # Made off the screen process, a placeholder until then.
      assert assigns(view).images[{key, :chat}] == :loading
      assert text(view) =~ "Preparing the picture…"

      view = view |> render_async() |> until()
      reply = List.last(assigns(view).messages)
      assert [%{key: ^key, mime: "image/png"}] = reply.images

      assert {:ok, %{path: path, width: w, height: h}} = assigns(view).images[{key, :chat}]
      # 393 dp wide at 3× on the host: (393 - 32) × 3 = 1083 px, from 1200 × 800.
      assert {w, h} == {1083, 722}

      assert {:ok, %{width: 1083, height: 722}} = path |> File.read!() |> Codec.info()

      assert image_node(view, key)
      assert_renderable(view)

      view = render_info(view, {:tap, {:image, {:open, key}}})
      assert %{key: ^key, zoom: 1.0} = assigns(view).viewer
      assert find(view, :box, id: "viewer-close")
      view = render_async(view)
      # The viewer's is made for the screen (twice it, for zooming): the original fits.
      assert {:ok, %{width: 1200, height: 800}} = assigns(view).images[{key, :viewer}]
      view = render_info(view, {:double_tap, {:image, :zoom}})
      assert assigns(view).viewer.zoom == 2.5
      view = render_info(view, {:pinch, {:image, :zoom}, %{scale: 4.0, phase: :ended}})
      assert assigns(view).viewer.zoom == 4.0
      assert_renderable(view)
      view = render_info(view, {:tap, {:image, :close}})
      assert assigns(view).viewer == nil
    end

    test "a picture the model returns shows in its reply, whatever the provider" do
      png = Png.solid(3000, 1500, {28, 42, 68})
      script([[{:text, "Here is a drawing."}, {:image, "image/png", png}]])

      view = AppScreen |> mount_screen() |> ask("Draw it") |> until() |> render_async()
      reply = List.last(assigns(view).messages)
      assert [%{key: key}] = reply.images
      assert {:ok, %{width: 1083, height: 542}} = assigns(view).images[{key, :chat}]
      assert image_node(view, key)
    end

    test "a picture that can't be read says so instead" do
      script([[{:text, "Broken."}, {:image, "image/png", "not a png"}]])

      view = AppScreen |> mount_screen() |> ask("Draw it") |> until() |> render_async()
      [%{key: key}] = List.last(assigns(view).messages).images
      assert assigns(view).images[{key, :chat}] == :error
      assert text(view) =~ "This picture can’t be shown."
    end
  end
end
