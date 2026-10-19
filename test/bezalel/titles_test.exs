defmodule Bezalel.TitlesTest do
  # Conversation titles and summaries (Bezalel.Titles over bezalel_core's
  # Bezalel.Agent.Title): the live agent and the naming model are both
  # scripted (Bezalel.Test.FakeLLM, a script each), no network. The screen
  # runs in the test process, so the loop's events and `{:titled, _}`
  # arrive here and are fed to it.
  use Mob.ScreenCase
  @moduletag :screen

  alias Bezalel.Agent.{Live, Title}
  alias Bezalel.{AppScreen, Library, Repo, Titles}
  alias Bezalel.Library.{Conversation, Tool}
  alias Bezalel.Test.{FakeLLM, MemoryStore}

  setup do
    for schema <- [Tool, Conversation], do: Repo.delete_all(schema)

    for key <- [:bezalel_conversation, :bezalel_mode, :bezalel_model, :bezalel_study_preferences],
        do: Mob.State.delete(key)

    MemoryStore.clear()
    :ok = Rho.Auth.put_api_key(:anthropic, "sk-ant-api03-test-key-0123456789")

    on_exit(fn ->
      Application.delete_env(:bezalel, Live)
      Application.put_env(:bezalel, Titles, enabled: false)
      Bezalel.Agent.release_all()
    end)

    :ok
  end

  # The lead's replies, and the naming model's answers (its own script).
  defp script(replies, titles) do
    {:ok, lead} = FakeLLM.start(replies)
    {:ok, namer} = FakeLLM.start(titles)
    Application.put_env(:bezalel, Live, llm: {FakeLLM, lead}, retry_base_ms: 1)
    Application.put_env(:bezalel, Titles, enabled: true, consult: [llm: {FakeLLM, namer}])
  end

  defp named(title, summary), do: [{:text, "Title: #{title}\nSummary: #{summary}"}]

  defp ask(view, text) do
    view
    |> render_info({:change, :draft, text})
    |> render_info({:tap, {:study, :send}})
  end

  # Feeds the loop's events to the screen until its run ends.
  defp until_done(view) do
    receive do
      {:rho, _session, event} = message ->
        view = render_info(view, message)
        if match?(%{type: :agent_end}, event), do: view, else: until_done(view)
    after
      2_000 -> flunk("the loop went quiet")
    end
  end

  # The naming model's request, then the screen told of the new title.
  defp titled(view) do
    system = Title.system()
    assert_receive {:llm_request, %{system_prompt: ^system} = request}, 2_000
    assert_receive {:titled, %Conversation{}} = message, 2_000
    {render_info(view, message), request}
  end

  defp prompt(%{messages: [message | _]}), do: Enum.map_join(message.content, & &1.text)
  defp texts(view), do: for(%{props: %{text: t}} <- find_all(view, :text), do: t)

  test "each finished reply titles the conversation and sums it up, refined on the next" do
    script(
      [
        [{:text, "Bezalel, son of Uri, was filled with the Spirit to build the tabernacle."}],
        [{:text, "Oholiab of Dan was his partner in the work."}]
      ],
      [
        named("Bezalel the craftsman", "Who Bezalel was and what he was filled with."),
        named("Bezalel and Oholiab", "The two craftsmen of the tabernacle and their gifts.")
      ]
    )

    view =
      AppScreen
      |> mount_screen()
      |> render_info({:tap, {:convs, :new}})
      |> render_info({:tap, {:tab, :study}})

    assert assigns(view).conversation.name == "New study"
    view = ask(view, "Who was Bezalel, and why does Exodus make so much of him?")

    # Until its title comes, a new study has its first question's name.
    assert assigns(view).conversation.name ==
             "Who was Bezalel, and why does Exodus make so much of him?"

    {view, first} = view |> until_done() |> titled()
    assert first.model =~ "anthropic:claude-haiku"
    assert prompt(first) =~ "User: Who was Bezalel, and why does Exodus make so much of him?"
    assert prompt(first) =~ "Assistant: Bezalel, son of Uri"
    refute prompt(first) =~ "Current title"

    # Study's header.
    assert assigns(view).conversation.name == "Bezalel the craftsman"
    assert find(view, :text, id: "study-title").props.text == "Bezalel the craftsman"

    {view, second} = view |> ask("And Oholiab?") |> until_done() |> titled()

    assert prompt(second) =~
             "Current title: Bezalel the craftsman\nCurrent summary: Who Bezalel was and what he was filled with."

    # The Conversations tab: the title, the summary under it.
    view = render_info(view, {:tap, {:tab, :convs}})
    assert "Bezalel and Oholiab" in texts(view)
    assert "The two craftsmen of the tabernacle and their gifts." in texts(view)

    c = Library.get_conversation(assigns(view).conversation.id)

    assert {c.name, c.summary} ==
             {"Bezalel and Oholiab", "The two craftsmen of the tabernacle and their gifts."}
  end

  test "a naming that fails, or comes after the conversation moved on, keeps the name it had" do
    {:ok, c} = Library.create_conversation(%{name: "New study", kicker: "STUDY", kind: "Study"})
    {:ok, _} = Library.add_message(c, %{role: :user, text: "Word study on ruach"})

    {:ok, _} =
      Library.add_message(c, %{role: :agent, blocks: [%{"id" => "sum", "text" => "Wind."}]})

    :ok = Library.touch(c.id)
    c = Library.get_conversation(c.id)

    script([], [[{:error, {:other, "overloaded"}}]])
    assert Titles.name(c.id, "anthropic:claude-opus-4-1") == {:error, {:other, "overloaded"}}
    assert %{name: "New study", summary: nil} = Library.get_conversation(c.id)

    assert Library.put_title(c.id, %{title: "Ruach", summary: "Wind."}, c.message_count + 1) ==
             nil

    assert %{name: "New study"} = Library.get_conversation(c.id)

    assert %{name: "Ruach", summary: "Wind."} =
             Library.put_title(c.id, %{title: "Ruach", summary: "Wind."}, c.message_count)
  end
end
