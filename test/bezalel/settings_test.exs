defmodule Bezalel.SettingsTest do
  use Mob.ScreenCase
  @moduletag :screen

  alias Bezalel.Agent.Live
  alias Bezalel.{ApproachScreen, AppScreen, AttributionsScreen, Settings, StudySourcesScreen}
  alias Bezalel.Study.{Preferences, Prompt, Sources}
  alias Bezalel.Test.{Browser, MemoryStore}

  @openai_key "sk-proj-abcdefghijklmnop1234WXYZ"

  setup do
    MemoryStore.clear()
    Mob.State.delete(:bezalel_model)
    Mob.State.delete(:bezalel_study_preferences)
    File.rm(Path.join(Rho.Config.data_dir(), "usage.json"))
    on_exit(fn -> Mob.State.delete(:bezalel_study_preferences) end)
    :ok
  end

  # Whether the segment (or pill) tapping `tag` is the selected one.
  defp selected?(view, tag) do
    view
    |> find_all(:box)
    |> Enum.any?(&match?(%{props: %{on_tap: {_, ^tag}, background: :secondary}}, &1))
  end

  defp settings, do: AppScreen |> mount_screen() |> render_info({:tap, {:tab, :settings}})

  defp model_ids(view) do
    view = render_info(view, {:tap, {:settings, :models}})

    view
    |> find_all(:box)
    |> Enum.flat_map(fn
      %{props: %{on_tap: {_, {:model, id}}}} -> [id]
      _ -> []
    end)
  end

  describe "subscriptions" do
    test "signed out, each subscription offers a browser sign-in" do
      view = settings()
      assert text(view) =~ "Pro or Max subscription"
      assert text(view) =~ "Plus or Pro subscription"
      refute text(view) =~ "Not built yet"
      assert_renderable(view)
    end

    test "Sign in opens the provider's authorize page; Claude's takes a pasted code" do
      view = settings()

      view = render_info(view, {:tap, {:settings, {:sign_in, :openai_codex}}})
      assert Browser.last() =~ ~r{^https://auth\.openai\.com/oauth/authorize\?}
      assert text(view) =~ "Finish in the browser; it returns here."

      view = render_info(view, {:tap, {:settings, {:sign_in, :anthropic}}})
      assert Browser.last() =~ ~r{^https://claude\.ai/oauth/authorize\?}
      assert assigns(view).login == :anthropic
      assert find(view, :text_field, placeholder: "Paste the code")

      # A code from another sign-in (its state doesn't match) is refused,
      # and the flow stays open for the right one.
      view = render_info(view, {:change, {:settings, :login_code}, "the-code#not-this-flow"})
      view = render_info(view, {:tap, {:settings, :paste_code}})
      assert assigns(view).toast.text =~ "from another sign-in"
      assert assigns(view).login == :anthropic
    end

    test "a finished sign-in shows the account; Sign out forgets it" do
      view = settings()

      :ok =
        Rho.Auth.put(:anthropic, %{
          "type" => "oauth",
          "access" => "access-token",
          "refresh" => "refresh-token",
          "expires" => System.os_time(:millisecond) + 3_600_000,
          "email" => "pastor@example.org"
        })

      view = render_info(view, {:rho_login, :anthropic, :ok})
      assert text(view) =~ "pastor@example.org"
      assert text(view) =~ "Claude · signed in through the browser"
      assert assigns(view).toast.text == "Signed in to Claude."

      view = render_info(view, {:tap, {:settings, {:sign_out, :anthropic}}})
      refute text(view) =~ "pastor@example.org"
      assert MemoryStore.get("auth:anthropic") == :error
    end

    test "a failed sign-in says why" do
      view = settings()
      view = render_info(view, {:tap, {:settings, {:sign_in, :anthropic}}})
      view = render_info(view, {:rho_login, :anthropic, {:error, "Claude said no (denied)"}})
      assert assigns(view).toast.text == "Sign-in failed: Claude said no (denied)"
      assert assigns(view).login == nil
      refute find(view, :text_field, placeholder: "Paste the code")
    end
  end

  describe "API keys" do
    test "a saved key is stored, shown masked, survives a restart and can be removed" do
      view = settings()
      view = render_info(view, {:change, {:settings, {:key, :openai}}, "  #{@openai_key}\n"})
      view = render_info(view, {:tap, {:settings, {:save_key, :openai}}})

      assert {:ok, json} = MemoryStore.get("auth:openai")
      assert Jason.decode!(json) == %{"type" => "api_key", "key" => @openai_key}
      assert assigns(view).toast.text == "OpenAI key saved."
      assert text(view) =~ "sk-pro…WXYZ"
      refute text(view) =~ @openai_key
      refute inspect(assigns(view).account) =~ @openai_key

      # A fresh mount (the app restarted) reads it back from the store.
      view = settings()
      assert text(view) =~ "sk-pro…WXYZ"

      view = render_info(view, {:tap, {:settings, {:remove_key, :openai}}})
      assert MemoryStore.get("auth:openai") == :error
      refute text(view) =~ "sk-pro…WXYZ"
      assert find(view, :text_field, placeholder: "Paste your key", secure: true)
    end

    test "with an Anthropic key, Claude's sign-in says it replaces the key" do
      :ok = Rho.Auth.put_api_key(:anthropic, "sk-ant-api03-abcdefghijklmnop")
      assert text(settings()) =~ "Signing in replaces your Anthropic key"
    end

    test "saving an empty key asks for one and stores nothing" do
      view = settings()
      view = render_info(view, {:change, {:settings, {:key, :google}}, "   "})
      view = render_info(view, {:tap, {:settings, {:save_key, :google}}})
      assert assigns(view).toast.text == "Paste your Google Gemini key first."
      assert MemoryStore.get("auth:google") == :error
    end
  end

  describe "models" do
    test "the model list follows the credentials" do
      view = settings()
      assert model_ids(view) == []
      view = render_info(view, {:tap, {:settings, :models}})
      assert text(view) =~ "No models yet."
      # The default is Claude; without access it says what it needs.
      view = render_info(view, {:tap, :sheet})
      assert text(view) =~ "Needs your Claude sign-in or Anthropic API key"

      view =
        render_info(
          view,
          {:change, {:settings, {:key, :google}}, "AIzaSyFakeButWellFormedKey0123"}
        )

      view = render_info(view, {:tap, {:settings, {:save_key, :google}}})
      ids = model_ids(view)
      assert ids != []
      assert Enum.all?(ids, &String.starts_with?(&1, "google:"))

      sheet = render_info(view, {:tap, {:settings, :models}})
      assert text(sheet) =~ "GEMINI (GOOGLE)"
      assert text(sheet) =~ "Gemini API key"
      assert text(sheet) =~ "IMAGES"
      assert_renderable(sheet)

      # The pick persists, and Settings names it.
      [id | _] = ids
      view = render_info(sheet, {:tap, {:model, id}})
      assert Bezalel.Settings.model() == id
      assert text(view) =~ Bezalel.Models.get(id).name
      assert text(view) =~ "Gemini (Google)"

      view = render_info(view, {:tap, {:settings, {:remove_key, :google}}})
      assert model_ids(view) == []
    end
  end

  describe "text size" do
    setup do
      Mob.State.delete(:bezalel_text_size)
      Mob.State.delete(:bezalel_mode)

      on_exit(fn ->
        Mob.State.delete(:bezalel_text_size)
        Mob.State.delete(:bezalel_mode)
        Mob.Theme.set(MobBezalel.Dark)
      end)
    end

    test "Default until chosen; a choice is the theme's text_scale, kept across a re-mount" do
      view = settings()
      assert assigns(view).text_size == :default
      assert selected?(view, {:settings, {:text_size, :default}})
      assert Mob.Theme.current().text_scale == 1.0
      assert find(view, :text, id: "text-size-preview")

      view = render_info(view, {:tap, {:settings, {:text_size, :largest}}})
      assert selected?(view, {:settings, {:text_size, :largest}})
      refute selected?(view, {:settings, {:text_size, :default}})
      assert Mob.Theme.current().text_scale == 1.5
      assert text(view) =~ "Largest"
      assert_renderable(view)

      Mob.Theme.set(MobBezalel.Dark)
      view = settings()
      assert assigns(view).text_size == :largest
      assert Mob.Theme.current().text_scale == 1.5
    end

    test "a theme change, and System mode following the phone, keep the text size" do
      view = render_info(settings(), {:tap, {:settings, {:text_size, :small}}})

      view = render_info(view, {:tap, {:settings, {:mode, :night}}})
      assert Mob.Theme.current().background == MobBezalel.Night.theme().background
      assert Mob.Theme.current().text_scale == 0.85

      view = render_info(view, {:tap, {:settings, {:mode, :system}}})
      _view = render_info(view, {:mob_device, :color_scheme_changed, :light})
      assert Mob.Theme.current().text_scale == 0.85
    end

    test "the size picker's letters stay their own sizes whatever the choice" do
      sizes = fn view ->
        for %{type: :box, props: %{on_tap: {_, {:settings, {:text_size, _}}}}} = box <-
              find_all(view, :box),
            %{type: :text, props: %{text: "A", text_size: s}} <- box.children,
            # What reaches the screen: the renderer multiplies by text_scale.
            do: Float.round(s * Mob.Theme.current().text_scale, 6)
      end

      view = settings()
      default = sizes.(view)
      assert default == Enum.sort(default)
      assert [_, _, _, _, _] = Enum.uniq(default)
      assert sizes.(render_info(view, {:tap, {:settings, {:text_size, :largest}}})) == default
    end
  end

  describe "study" do
    # The translation chooser's rows: the key each taps, in order, and the
    # one outlined as chosen.
    defp translation_rows(view) do
      for %{props: %{on_tap: {_, {:settings, {:translation, key}}}} = props} <-
            find_all(view, :box),
          do: {key, props.border_color == :secondary}
    end

    test "translation, results per list and scripture labels: the defaults, then each persists across a re-mount" do
      view = settings()
      assert assigns(view).study == %Preferences{}

      assert %{props: %{on_tap: {_, {:settings, :translations}}}} =
               find(view, :box, id: "settings-translation")

      assert text(view) =~ "NET Bible"
      assert selected?(view, {:settings, {:limit, 8}})
      assert selected?(view, {:settings, {:labels, true}})
      assert text(view) =~ "Needs the Bible translations pack"
      assert_renderable(view)

      # The chooser: the five translations, the NET chosen.
      chooser = render_info(view, {:tap, {:settings, :translations}})
      assert assigns(chooser).sheet == :translations

      assert translation_rows(chooser) == [
               {"net", true},
               {"bsb", false},
               {"jps1917", false},
               {"ult", false},
               {"ust", false}
             ]

      assert_renderable(chooser)

      # A choice closes it.
      view = render_info(chooser, {:tap, {:settings, {:translation, "jps1917"}}})
      assert assigns(view).sheet == nil
      assert assigns(view).study.translation == "jps1917"
      assert text(view) =~ "JPS 1917"

      view =
        view
        |> render_info({:tap, {:settings, {:limit, 12}}})
        |> render_info({:tap, {:settings, {:labels, false}}})

      assert %{translation: "jps1917", limit: 12, scripture_labels: false} = assigns(view).study

      again = settings()
      assert %{translation: "jps1917", limit: 12, scripture_labels: false} = assigns(again).study

      assert {"jps1917", true} in translation_rows(
               render_info(again, {:tap, {:settings, :translations}})
             )

      assert selected?(again, {:settings, {:limit, 12}})
      assert selected?(again, {:settings, {:labels, false}})

      # What the study tools read (config :bezalel_core, :preferences),
      # whatever the session.
      assert %{translation: "jps1917", limit: 12, scripture_labels: false} =
               Preferences.current(%{session_id: "any"})
    end

    test "each translation says what it is, what it covers and whether the phone has it" do
      # The translations pack's keys: not installed, data version 3, and one
      # from before the JPS, ULT and UST.
      none = nil
      installed = ~w(net jps1917 ult ust)
      outdated = ~w(net)

      note = &Bezalel.Views.Settings.translation_note/2

      assert note.("bsb", none) == "Public domain; the whole Bible, from the core pack."
      assert note.("net", installed) =~ "quoted by permission. The whole Bible."

      assert note.("jps1917", installed) =~
               "The Old Testament only: New Testament verses are quoted from the BSB."

      for key <- ["ult", "ust"] do
        assert note.(key, installed) =~
                 "It doesn't have Numbers, 1–2 Chronicles, Ecclesiastes, Isaiah, Jeremiah and Ezekiel yet: those are quoted from the BSB."

        refute note.(key, installed) =~ "unfoldingWord"
      end

      for key <- ["net", "jps1917", "ult", "ust"] do
        assert note.(key, installed) =~ "From the Bible translations pack on this phone."
        assert note.(key, none) =~ "Needs the Bible translations pack (Study library)"
      end

      assert note.("net", outdated) =~ "From the Bible translations pack on this phone."

      for key <- ["jps1917", "ult", "ust"],
          do: assert(note.(key, outdated) =~ "is older and doesn't have it: update the pack")

      # Still being read: what it is, nothing about the pack.
      assert note.("ult", :loading) ==
               "A literal English text adapted from the ULT (CC BY-SA 4.0). It doesn't have Numbers, 1–2 Chronicles, Ecclesiastes, Isaiah, Jeremiah and Ezekiel yet: those are quoted from the BSB."

      # A damaged pack: not "update", but remove and download again.
      for key <- ["net", "jps1917", "ult", "ust"] do
        assert note.(key, :unreadable) =~
                 "The Bible translations pack on this phone can't be read: remove it and download it again (Study library)."
      end
    end

    test "the NET's acknowledgement is a tap away while the NET is the translation" do
      view = settings()
      ack = "The NET Bible® is quoted by permission: see Sources and licences"

      assert %{props: %{on_tap: {_, {:packs, :attributions}}}} = find(view, :text, text: ack)

      assert navigated_to(render_info(view, {:tap, {:packs, :attributions}})) ==
               AttributionsScreen

      view = render_info(view, {:tap, {:settings, {:translation, "ust"}}})
      refute find(view, :text, text: ack)
    end

    test "the approach: your own saved and kept, a toast that it applies from the next question, the fixed part shown; Restore default clears it" do
      view = settings()
      assert text(view) =~ "The default: what the texts say, credited"
      assert navigated_to(render_info(view, {:tap, {:settings, :approach}})) == ApproachScreen

      screen = mount_screen(ApproachScreen, %{app: self()})
      assert assigns(screen).draft == Prompt.default_approach()
      assert %{props: %{lines: lines}} = find(screen, :text_field)
      assert lines > 1
      t = text(screen)
      assert t =~ "ALWAYS INCLUDED"
      assert t =~ "## Ground rules"
      assert t =~ "## Formatting for a phone"
      assert t =~ Live.phone_formatting() |> String.split("\n") |> Enum.at(2)
      assert_renderable(screen)

      mine = "Answer as a historian of religion would, briefly."

      screen =
        screen
        |> render_info({:change, :approach, mine})
        |> render_info({:tap, :save})

      assert Settings.study_preferences().approach == mine
      assert assigns(screen).toast.text == "Saved. It applies from your next question."
      assert text(screen) =~ "Saved. It applies from your next question."
      assert_receive {:study_preferences, :changed}

      again = mount_screen(ApproachScreen, %{app: self()})
      assert assigns(again).draft == mine
      assert text(again) =~ "YOUR OWN APPROACH."

      # The app's screen follows (and says so on its row).
      view = render_info(view, {:study_preferences, :changed})
      assert assigns(view).study.approach == mine
      assert text(view) =~ "Your own"

      again = render_info(again, {:tap, :restore})
      assert Settings.study_preferences().approach == nil
      assert assigns(again).draft == Prompt.default_approach()
      assert assigns(again).toast.text =~ "Restored the default."
      assert_receive {:study_preferences, :changed}

      # Saving the default as it is keeps the default (nil).
      again = render_info(again, {:tap, :save})
      assert Settings.study_preferences().approach == nil
      assert_receive {:study_preferences, :changed}

      # Saving a blank field restores the default, and says so.
      Settings.update_study_preferences(&%{&1 | approach: mine})

      again =
        again
        |> render_info({:change, :approach, "  \n "})
        |> render_info({:tap, :save})

      assert Settings.study_preferences().approach == nil
      assert assigns(again).draft == Prompt.default_approach()

      assert assigns(again).toast.text ==
               "Restored the default. It applies from your next question."
    end

    test "the sources: grouped, each with its description and On/Off; editorial verdicts and genre guidance off by default; a switch persists" do
      view = settings()
      total = length(Sources.all())
      off = Enum.count(Sources.default_excluded())
      assert off == 2
      assert text(view) =~ "#{total - off} of #{total} on"
      assert navigated_to(render_info(view, {:tap, {:settings, :sources}})) == StudySourcesScreen

      screen = mount_screen(StudySourcesScreen, %{app: self()})
      t = text(screen)
      assert t =~ "may still know it from its training"

      for source <- Sources.all() do
        assert String.contains?(t, source.label)
        assert String.contains?(t, source.description)
        assert String.contains?(t, String.upcase(source.group))
      end

      assert selected?(screen, {:source, "editorial:verdicts", false})
      assert selected?(screen, {:source, "notes:dictionary", true})
      assert_renderable(screen)

      screen = render_info(screen, {:tap, {:source, "notes:dictionary", false}})
      assert_receive {:study_preferences, :changed}
      assert selected?(screen, {:source, "notes:dictionary", false})
      assert MapSet.member?(Settings.study_preferences().excluded_sources, "notes:dictionary")

      screen = render_info(screen, {:tap, {:source, "editorial:verdicts", true}})
      assert_receive {:study_preferences, :changed}

      again = mount_screen(StudySourcesScreen, %{app: self()})
      assert selected?(again, {:source, "notes:dictionary", false})
      assert selected?(again, {:source, "editorial:verdicts", true})

      assert Settings.study_preferences().excluded_sources ==
               MapSet.new(["notes:dictionary", "method:genre_guidance"])

      # Tapping what's already selected changes nothing and tells no one.
      render_info(screen, {:tap, {:source, "editorial:verdicts", true}})
      refute_received {:study_preferences, :changed}

      view = render_info(view, {:study_preferences, :changed})
      assert text(view) =~ "#{total - 2} of #{total} on"
    end
  end
end
