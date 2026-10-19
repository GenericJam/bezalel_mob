defmodule Bezalel.PushbackTest do
  # Pushback on the phone: another model reviews a finished reply and the
  # answering model responds (bezalel_core's Bezalel.Agent.Pushback), from
  # the reply's button, the conversation's switch, and Settings → Models.
  # rho's loop and its consults run on a scripted model
  # (Bezalel.Test.FakeLLM), no network; the screen runs in the test process,
  # so the loop's events arrive here and are fed to it.
  use Mob.ScreenCase
  @moduletag :screen

  alias Bezalel.Agent.{Live, Pushback, Reply}
  alias Bezalel.{AppScreen, Library, Repo}
  alias Bezalel.Library.{Conversation, Tool}
  alias Bezalel.Test.{FakeLLM, MemoryStore}

  setup do
    for schema <- [Tool, Conversation], do: Repo.delete_all(schema)

    for key <- [:bezalel_conversation, :bezalel_mode, :bezalel_model, :bezalel_study_preferences],
        do: Mob.State.delete(key)

    MemoryStore.clear()
    :ok = Rho.Auth.put_api_key(:anthropic, "sk-ant-api03-test-key-0123456789")
    :ok = Rho.Auth.put_api_key(:openai, "sk-proj-test-key-0123456789abcdef")

    on_exit(fn ->
      Application.delete_env(:bezalel, Live)
      Bezalel.Agent.release_all()
      Mob.State.delete(:bezalel_study_preferences)
    end)

    %{critic: hd(Rho.Models.catalog(:openai)).spec}
  end

  @answer "Bezalel is **filled** with the Spirit of God, Exodus 31:3."
  @critique "1. **major** “filled with the Spirit”: the verse says God filled him; say who acts."
  @revised "Point 1 is right: God is the one who fills him. Corrected: God filled Bezalel."

  defp script(replies) do
    {:ok, llm} = FakeLLM.start(replies)
    Application.put_env(:bezalel, Live, llm: {FakeLLM, llm}, retry_base_ms: 1)
  end

  defp ask(view, text) do
    view
    |> render_info({:change, :draft, text})
    |> render_info({:tap, {:study, :send}})
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

  defp stream(view), do: assigns(view).streams[assigns(view).conversation.id]
  defp roles(view), do: Enum.map(assigns(view).messages, & &1.role)
  defp texts(view), do: for(%{props: %{text: t}} <- find_all(view, :text), do: t)

  defp choose_critic(view, critic),
    do: render_info(view, {:tap, {:settings, {:pushback_model, critic}}})

  defp user_text(request),
    do: request.messages |> Enum.flat_map(& &1.content) |> Enum.map_join("\n", & &1.text)

  test "the Pushback button: the critique streams in its own block, then the answer to it; the reviewed reply stays",
       %{critic: critic} do
    script([[{:text, @answer}], [{:text, @critique}], [{:text, @revised}]])

    view = AppScreen |> mount_screen() |> ask("Who is Bezalel?") |> until()
    assert_receive {:llm_request, _question}
    reviewed = List.last(assigns(view).messages)
    assert reviewed.role == :agent
    assert find(view, :box, id: "pushback-" <> reviewed.id)

    # No critic chosen yet: said, and nothing runs.
    view = render_info(view, {:tap, {:study, :pushback}})
    assert assigns(view).toast.text == "Choose a model to push back in Settings (Pushback from)."
    refute stream(view)

    view = view |> choose_critic(critic) |> render_info({:tap, {:study, :pushback}})
    assert %Reply{consult: %{model: ^critic, purpose: "critique"}} = stream(view)
    # The status line names the critic while its critique comes.
    assert (Pushback.label(critic) <> " is pushing back…") in texts(view)
    # Nothing to tap while it runs; Stop stops it.
    refute find(view, :box, id: "pushback-" <> reviewed.id)
    assert find(view, :box, id: "composer-stop")

    # The critic gets the study critic's brief, the question and the answer.
    assert_receive {:llm_request, crit}
    assert crit.model == critic
    assert crit.system_prompt == Pushback.critic_prompt()
    assert user_text(crit) =~ "Who is Bezalel?"
    assert user_text(crit) =~ "filled"

    # Stored, the critique leaves the stream for the chat only at the end:
    # meanwhile the reviewed reply stays shown and the critique streams.
    view = until(view, &match?(%{type: :message_end, entry: %{"type" => "custom_message"}}, &1))
    assert List.last(assigns(view).messages).id == reviewed.id
    refute :consult in roles(view)
    assert [%{"type" => "CONSULT", "text" => @critique} | _] = Reply.blocks(stream(view))
    assert Pushback.title(critic, "critique") in texts(view)

    # The answering model gets the critique, attributed, and answers it.
    assert_receive {:llm_request, lead}
    assert lead.model == assigns(view).model_id
    assert user_text(lead) =~ "major"

    view = until(view)
    refute stream(view)
    assert [_ | _] = msgs = assigns(view).messages

    assert [%{id: id, role: :agent}, %{role: :consult} = critique, %{role: :agent} = answer] =
             Enum.take(msgs, -3)

    assert id == reviewed.id
    assert critique.model == critic
    assert critique.text == @critique
    assert answer.blocks |> List.last() |> Map.get("text") == @revised
    # The critique in its own block, titled with its model, and one round per
    # reply: no button on the answer to it.
    assert Pushback.title(critic, "critique") in texts(view)
    refute find(view, :box, id: "pushback-" <> answer.id)
    refute find(view, :box, id: "pushback-" <> reviewed.id)
  end

  test "the conversation's switch: each finished reply is pushed back on, once, and the switch is kept",
       %{critic: critic} do
    script([[{:text, @answer}], [{:text, @critique}], [{:text, @revised}]])

    view = AppScreen |> mount_screen() |> choose_critic(critic)
    cid = assigns(view).conversation.id

    view = render_info(view, {:tap, {:study, :conversation_menu}})
    assert assigns(view).sheet == :conversation
    assert %{props: %{value: false}} = find(view, :toggle, id: "auto-pushback")

    view = render_info(view, {:change, {:study, :auto_pushback}, true})
    assert Library.get_conversation(cid).pushback
    assert %{props: %{value: true}} = find(view, :toggle, id: "auto-pushback")
    view = render_info(view, {:tap, :sheet})

    view = view |> ask("Who is Bezalel?") |> until()
    # The reply ended and its pushback began at once.
    assert %Reply{consult: %{model: ^critic}} = stream(view)
    view = until(view)

    assert [:agent, :consult, :agent] = view |> roles() |> Enum.take(-3)
    assert_receive {:llm_request, _question}
    assert_receive {:llm_request, %{model: ^critic}}
    assert_receive {:llm_request, _answer}
    # The answer to the critique isn't pushed back on in turn.
    refute_receive {:llm_request, _}, 300
    refute stream(view)

    # Kept with the conversation: off again from the menu.
    view = render_info(view, {:change, {:study, :auto_pushback}, false})
    refute Library.get_conversation(cid).pushback
    refute assigns(view).conversation.pushback
  end

  test "a critique that fails is said where it would have been; nothing is dropped and it can be asked for again",
       %{critic: critic} do
    script([
      [{:text, @answer}],
      [{:error, {:other, "the critic broke"}}],
      [{:text, @critique}],
      [{:text, @revised}]
    ])

    view =
      AppScreen |> mount_screen() |> choose_critic(critic) |> ask("Who is Bezalel?") |> until()

    reviewed = List.last(assigns(view).messages)

    view =
      view
      |> render_info({:tap, {:study, :pushback}})
      |> until(&match?(%{type: :consult_end}, &1))

    assert %Reply{status: :done, reason: :consult_failed, error: error} = stream(view)
    assert error =~ "the critic broke"
    assert "PUSHBACK DIDN'T COME" in texts(view)
    assert "Model call failed: the critic broke" in texts(view)
    # Its error in place of the critique, not a block left running.
    refute "Running…" in texts(view)

    # No run failed: the reply it reviewed is still the last, the loop
    # stays, and no Try again of the question.
    assert List.last(assigns(view).messages).id == reviewed.id
    assert Live.running?(assigns(view).conversation.id)
    refute "Try again" in texts(view)

    view = view |> render_info({:tap, {:study, :pushback}}) |> until()
    assert [:agent, :consult, :agent] = view |> roles() |> Enum.take(-3)
  end

  test "a critic whose provider isn't signed in is named, with what to do; the loop started for it goes" do
    script([[{:text, @answer}]])
    gemini = hd(Rho.Models.catalog(:google)).spec

    view = AppScreen |> mount_screen() |> ask("Who is Bezalel?") |> until()
    cid = assigns(view).conversation.id
    # Choosing a critic releases the idle loop; the tap starts it again.
    view = choose_critic(view, gemini)
    refute Live.running?(cid)

    view = render_info(view, {:tap, {:study, :pushback}})
    assert assigns(view).toast.text =~ "#{Pushback.label(gemini)} can't push back:"
    refute stream(view)
    # Refused, it isn't left running untracked (with the old preferences).
    refute Live.running?(cid)
    assert assigns(view).sessions == %{}
  end

  test "the answer to a critique fails: the critique goes too, and the pushback can be asked for again",
       %{critic: critic} do
    script([
      [{:text, @answer}],
      [{:text, @critique}],
      [{:tool_call, "c1", "lookup_verse", %{"reference" => "Exodus 31:2-3"}}],
      [{:error, {:other, "the lead broke"}}],
      [{:text, @critique}],
      [{:text, @revised}]
    ])

    view =
      AppScreen |> mount_screen() |> choose_critic(critic) |> ask("Who is Bezalel?") |> until()

    reviewed = List.last(assigns(view).messages)
    view = view |> render_info({:tap, {:study, :pushback}}) |> until()

    assert %Reply{status: :error, error: error} = stream(view)
    assert error =~ "the lead broke"
    # The reply it reviewed is the last again, in the chat and the session:
    # no critique left unanswered.
    assert List.last(assigns(view).messages).id == reviewed.id
    refute :consult in roles(view)
    refute Enum.any?(Library.messages(assigns(view).conversation.id), &(&1.role == :consult))
    refute Pushback.title(critic, "critique") in texts(view)
    # Nor what the failed answer's tool found: that answer is gone too.
    refute Enum.any?(texts(view), &String.starts_with?(&1, "Sources ("))
    # Its card asks for the pushback again, not the question.
    assert "Ask for pushback again" in texts(view)
    refute "Try again" in texts(view)

    view = view |> render_info({:tap, {:study, :pushback}}) |> until()
    refute stream(view)
    assert [%{id: id}, %{role: :consult}, %{role: :agent}] = Enum.take(assigns(view).messages, -3)
    assert id == reviewed.id
  end

  test "deleting the answer to a critique offers no Ask again; deleting the critique too brings the button back",
       %{critic: critic} do
    script([[{:text, @answer}], [{:text, @critique}], [{:text, @revised}]])

    view =
      AppScreen |> mount_screen() |> choose_critic(critic) |> ask("Who is Bezalel?") |> until()

    reviewed = List.last(assigns(view).messages)
    view = view |> render_info({:tap, {:study, :pushback}}) |> until()

    assert [_, %{role: :consult}, %{role: :agent} = answer] =
             Enum.take(assigns(view).messages, -3)

    view = render_info(view, {:tap, {:study, {:delete, answer.id}}})
    refute assigns(view).toast.ask_again
    critique = List.last(assigns(view).messages)
    assert critique.role == :consult

    view = render_info(view, {:tap, {:study, {:delete, critique.id}}})
    assert List.last(assigns(view).messages).id == reviewed.id
    assert find(view, :box, id: "pushback-" <> reviewed.id)
  end

  test "a pushback's failure card goes when the reply it was about is deleted", %{critic: critic} do
    script([[{:text, @answer}], [{:error, {:other, "the critic broke"}}]])

    view =
      AppScreen |> mount_screen() |> choose_critic(critic) |> ask("Who is Bezalel?") |> until()

    reviewed = List.last(assigns(view).messages)

    view =
      view
      |> render_info({:tap, {:study, :pushback}})
      |> until(&match?(%{type: :consult_end}, &1))

    assert "Ask for pushback again" in texts(view)
    view = render_info(view, {:tap, {:study, {:delete, reviewed.id}}})
    refute stream(view)
    refute "Ask for pushback again" in texts(view)
  end

  test "a pushback that fails after the reply it was about was deleted meanwhile leaves no card",
       %{critic: critic} do
    script([
      [{:text, @answer}],
      [{:error, {:other, "the critic broke"}}],
      [{:text, @answer}],
      [{:text, @critique}],
      [{:error, {:other, "the lead broke"}}]
    ])

    view =
      AppScreen |> mount_screen() |> choose_critic(critic) |> ask("Who is Bezalel?") |> until()

    # Deleted while the critique comes; it fails after.
    reviewed = List.last(assigns(view).messages)
    view = view |> render_info({:tap, {:study, :pushback}})
    view = render_info(view, {:tap, {:study, {:delete, reviewed.id}}})
    view = until(view, &match?(%{type: :consult_end}, &1))
    refute Enum.any?(Library.messages(assigns(view).conversation.id), &(&1.id == reviewed.id))
    refute stream(view)
    refute "Ask for pushback again" in texts(view)

    # Deleted while the answer to the critique comes; it fails after.
    view = view |> ask("Who is Bezalel?") |> until()
    reviewed = List.last(assigns(view).messages)
    view = render_info(view, {:tap, {:study, :pushback}})
    view = until(view, &match?(%{type: :message_end, entry: %{"type" => "custom_message"}}, &1))
    view = render_info(view, {:tap, {:study, {:delete, reviewed.id}}})
    view = until(view)
    refute Enum.any?(Library.messages(assigns(view).conversation.id), &(&1.id == reviewed.id))
    refute stream(view)
    refute "Ask for pushback again" in texts(view)
  end

  test "a message sent as the critique fails is answered once, not put back in the draft",
       %{critic: critic} do
    script([
      [{:text, @answer}],
      [{:error, {:other, "the critic broke"}}],
      [{:text, "Oholiab of the tribe of Dan."}]
    ])

    view =
      AppScreen |> mount_screen() |> choose_critic(critic) |> ask("Who is Bezalel?") |> until()

    view =
      view
      |> render_info({:tap, {:study, :pushback}})
      |> until(&match?(%{type: :consult_start}, &1))

    # The critique's failure is on its way when the message goes in: the
    # loop is idle while the critic works, so it starts a run at once.
    failed =
      receive do
        {:rho, _, %{type: :consult_end}} = message -> message
      after
        2_000 -> flunk("no consult_end")
      end

    view = ask(view, "And Oholiab?")
    view = view |> render_info(failed) |> until()

    assert assigns(view).draft == ""
    refute stream(view)

    assert [%{role: :user, text: "And Oholiab?"}, %{role: :agent} = answer] =
             Enum.take(assigns(view).messages, -2)

    assert answer.blocks |> List.last() |> Map.get("text") == "Oholiab of the tribe of Dan."

    assert Enum.count(assigns(view).messages, &(&1.role == :user and &1.text == "And Oholiab?")) ==
             1
  end

  test "an answering model that can't answer now is said before any critique is asked for",
       %{critic: critic} do
    script([[{:text, @answer}]])
    gemini = hd(Rho.Models.catalog(:google)).spec

    view =
      AppScreen |> mount_screen() |> choose_critic(critic) |> ask("Who is Bezalel?") |> until()

    assert_receive {:llm_request, _question}

    view =
      view |> render_info({:tap, {:model, gemini}}) |> render_info({:tap, {:study, :pushback}})

    assert assigns(view).toast.text =~ "No pushback: "
    assert assigns(view).toast.text =~ "Gemini API key"
    refute stream(view)
    refute_receive {:llm_request, _}, 200
  end

  test "the switch after a reply that had edits waiting: they're made first, so the pushback doesn't see them",
       %{critic: critic} do
    script([[{:text, @answer}], [{:text, @critique}], [{:text, @revised}]])

    view = AppScreen |> mount_screen() |> choose_critic(critic)
    cid = assigns(view).conversation.id
    opening = hd(assigns(view).messages)
    opening_text = opening.text || opening.blocks |> List.last() |> Map.get("text")
    view = render_info(view, {:change, {:study, :auto_pushback}, true})

    # Deleted while the reply streams: it waits for the reply's end.
    view = ask(view, "Who is Bezalel?")
    view = render_info(view, {:tap, {:study, {:confirm_delete, opening.id}}})
    assert MapSet.member?(assigns(view).stale, cid)

    view = until(view)
    # Made before the pushback began.
    refute Enum.any?(Library.messages(cid), &(&1.id == opening.id))
    assert %Reply{consult: %{model: ^critic}} = stream(view)

    view = until(view)
    assert [:agent, :consult, :agent] = view |> roles() |> Enum.take(-3)
    assert_receive {:llm_request, question}
    assert user_text(question) =~ opening_text
    assert_receive {:llm_request, %{model: ^critic}}
    # The answer to the critique is asked without the deleted message.
    assert_receive {:llm_request, lead}
    assert user_text(lead) =~ "major"
    refute user_text(lead) =~ opening_text
  end

  test "the switch's refusal doesn't take the Undo of a delete made during the reply" do
    script([[{:text, @answer}]])
    gemini = hd(Rho.Models.catalog(:google)).spec

    view = AppScreen |> mount_screen() |> choose_critic(gemini)
    opening = hd(assigns(view).messages)
    view = render_info(view, {:change, {:study, :auto_pushback}, true})

    view = ask(view, "Who is Bezalel?")
    view = render_info(view, {:tap, {:study, {:confirm_delete, opening.id}}})
    view = until(view)

    # Refused (Gemini isn't signed in), quietly: the delete's Undo stays.
    refute stream(view)
    assert %Library.Undo{} = assigns(view).toast.undo
  end

  test "a critique that fails while edits wait: the loop goes and the edits are made",
       %{critic: critic} do
    script([[{:text, @answer}], [{:error, {:other, "the critic broke"}}]])

    view =
      AppScreen |> mount_screen() |> choose_critic(critic) |> ask("Who is Bezalel?") |> until()

    cid = assigns(view).conversation.id
    opening = hd(assigns(view).messages)

    view = render_info(view, {:tap, {:study, :pushback}})
    view = render_info(view, {:tap, {:study, {:confirm_delete, opening.id}}})
    assert MapSet.member?(assigns(view).stale, cid)

    view = until(view, &match?(%{type: :consult_end}, &1))
    assert %Reply{reason: :consult_failed} = stream(view)
    refute Live.running?(cid)
    refute Enum.any?(Library.messages(cid), &(&1.id == opening.id))
    assert "Ask for pushback again" in texts(view)
  end

  describe "Settings → Models" do
    test "Pushback from: none by default; every provider's models, the ones not signed in shown with what they need",
         %{critic: critic} do
      view = AppScreen |> mount_screen() |> render_info({:tap, {:tab, :settings}})
      assert find(view, :box, id: "settings-pushback")
      assert "None" in texts(view)

      view = render_info(view, {:tap, {:settings, :pushback_models}})
      assert assigns(view).sheet == :pushback_models
      assert %{props: %{on_tap: _}} = find(view, :box, id: "pushback-none")
      assert %{props: %{on_tap: _}} = find(view, :box, id: "pushback-" <> critic)

      gemini = find(view, :box, id: "pushback-" <> hd(Rho.Models.catalog(:google)).spec)
      refute Map.has_key?(gemini.props, :on_tap)

      assert "Needs your Gemini API key" in for(
               %{props: %{text: t}} <- find_all(gemini, :text),
               do: t
             )

      view = choose_critic(view, critic)
      assert assigns(view).sheet == nil
      assert assigns(view).study.pushback_model == critic
      assert Pushback.label(critic) in texts(view)

      view = choose_critic(view, nil)
      assert assigns(view).study.pushback_model == nil
    end

    test "Pictures by: the image models, a Gemini one once there's a Gemini key" do
      view =
        AppScreen
        |> mount_screen()
        |> render_info({:tap, {:tab, :settings}})
        |> render_info({:tap, {:settings, :image_models}})

      # None chosen, an OpenAI key and no ChatGPT sign-in: Automatic is selected, and is gpt-image.
      assert assigns(view).study.image_model == nil

      assert %{props: %{border_color: :secondary}} = find(view, :box, id: "image-automatic")
      assert "Automatic: OpenAI gpt-image-2" in texts(view)

      refute Map.has_key?(find(view, :box, id: "image-google:gemini-3-pro-image").props, :on_tap)

      :ok = Rho.Auth.put_api_key(:google, "AIza-test-key-0123456789abcdef")
      view = render_info(view, {:rho_auth, :changed})
      assert %{props: %{on_tap: tap}} = find(view, :box, id: "image-google:gemini-3-pro-image")

      view = render_info(view, {:tap, elem(tap, 1)})
      assert assigns(view).study.image_model == "google:gemini-3-pro-image"
      assert "Gemini 3 Pro Image" in texts(view)
    end

    test "Pictures by: ChatGPT on the ChatGPT sign-in; Automatic draws with it once signed in" do
      view =
        AppScreen
        |> mount_screen()
        |> render_info({:tap, {:tab, :settings}})
        |> render_info({:tap, {:settings, :image_models}})

      row = fn view -> find(view, :box, id: "image-openai_codex:gpt-image") end
      refute Map.has_key?(row.(view).props, :on_tap)
      assert "Needs your ChatGPT sign-in" in texts(view)

      :ok =
        Rho.Auth.put(:openai_codex, %{
          "type" => "oauth",
          "access" => "a",
          "refresh" => "r",
          "expires" => System.os_time(:millisecond) + 3_600_000,
          "accountId" => "acc"
        })

      view = render_info(view, {:rho_auth, :changed})
      assert %{props: %{on_tap: tap}} = row.(view)
      assert "Automatic: ChatGPT (your sign-in)" in texts(view)
      assert assigns(view).study.image_model == nil

      # Chosen, then back to Automatic; the Settings row says which.
      view = render_info(view, {:tap, elem(tap, 1)})
      assert assigns(view).study.image_model == "openai_codex:gpt-image"
      assert "ChatGPT (your sign-in)" in texts(view)
      refute "Automatic: ChatGPT (your sign-in)" in texts(view)

      view = render_info(view, {:tap, {:settings, :image_models}})
      %{props: %{on_tap: back}} = find(view, :box, id: "image-automatic")
      view = render_info(view, {:tap, elem(back, 1)})
      assert assigns(view).study.image_model == nil
      assert "Automatic: ChatGPT (your sign-in)" in texts(view)
    end
  end
end
