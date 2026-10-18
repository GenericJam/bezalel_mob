defmodule Bezalel.VoiceScreenTest do
  # Settings → Voice (Bezalel.VoiceScreen) over the recorded native calls
  # (Bezalel.Test.Native): the phone's voices grouped by language, English
  # first; a pick is stored, reported to Settings and said; the speaker
  # uses it.
  use Mob.ScreenCase
  @moduletag :screen

  alias Bezalel.{AppScreen, Settings, VoiceScreen}
  alias Bezalel.Test.Native

  @arabic %{
    id: "ar-xa-x-arc-local",
    name: "Arabic arc",
    language: "ar",
    quality: :normal,
    network: false
  }
  @us %{
    id: "en-us-x-sfg-local",
    name: "English (United States) sfg",
    language: "en-US",
    quality: :very_high,
    network: false
  }
  @uk %{
    id: "en-gb-x-gbb-network",
    name: "English (United Kingdom) gbb",
    language: "en-GB",
    quality: :high,
    network: true
  }
  @french %{
    id: "fr-fr-x-frb-local",
    name: "French (France) frb",
    language: "fr-FR",
    quality: :normal,
    network: false
  }

  setup do
    Mob.State.delete(:bezalel_voice)
    Native.reset()
    on_exit(fn -> Mob.State.delete(:bezalel_voice) end)
    :ok
  end

  defp texts(view), do: for(%{props: %{text: t}} <- find_all(view, :text), do: t)

  defp loaded(voices) do
    Native.put_voices({:ok, voices})
    mounted()
  end

  defp mounted, do: VoiceScreen |> mount_screen(%{app: self()}) |> render_async()

  defp index(list, item), do: Enum.find_index(list, &(&1 == item))

  test "the voices come grouped by language, English first and open, the rest folded; Default is chosen" do
    Native.put_voices({:ok, [@arabic, @uk, @us, @french]})
    view = mount_screen(VoiceScreen, %{app: self()})
    assert "Finding your phone's voices…" in texts(view)

    view = render_async(view)
    shown = texts(view)
    assert index(shown, "English") < index(shown, "Arabic")
    assert index(shown, "Arabic") < index(shown, "French")
    assert "en-US · Very high quality · on the phone" in shown
    assert "en-GB · High quality · needs internet" in shown
    # Folded: the count, not the voices.
    assert "1 voice" in shown
    refute "Arabic arc" in shown

    # Default is chosen (the one row marked); it reads in the phone's default voice.
    assert [row] = Enum.filter(find_all(view, :row), &("Chosen" in texts(&1)))
    assert "Default" in texts(row)
    assert "Your phone's default voice" in shown

    view = render_info(view, {:tap, {:group, "ar"}})
    assert "Arabic arc" in texts(view)
    assert_renderable(view)
  end

  test "picking a voice stores it, tells Settings and says the sample in it; Try it says it again" do
    view = loaded([@us, @uk])
    view = render_info(view, {:tap, {:pick, @uk.id}})

    voice = %{id: @uk.id, name: @uk.name, language: @uk.language}
    assert Settings.voice() == voice
    assert_received {:voice_chosen, ^voice}

    assert [{:stop_speaking, nil}, {:speak, {sample, [voice: "en-gb-x-gbb-network"]}}] =
             Native.calls()

    assert sample =~ "Bezalel"
    assert VoiceScreen.label(voice) in texts(view)

    Native.reset()
    render_info(view, {:tap, :try})

    assert [{:stop_speaking, nil}, {:speak, {^sample, [voice: "en-gb-x-gbb-network"]}}] =
             Native.calls()

    # Back to the default: nothing stored, no voice option.
    Native.reset()
    view = render_info(view, {:tap, {:pick, :default}})
    assert Settings.voice() == nil
    assert_received {:voice_chosen, nil}
    assert [_stop, {:speak, {_sample, []}}] = Native.calls()
    assert "Your phone's default voice" in texts(view)
  end

  test "a stored voice this phone doesn't have says so; its language's group opens" do
    Settings.put_voice(%{id: "fr-fr-x-gone-local", name: "French gone", language: "fr-FR"})
    view = loaded([@us, @french])

    assert "Not on this phone: a voice for its language reads instead, or the default." in texts(
             view
           )

    assert "French (France) frb" in texts(view)
  end

  test "when the voices can't be listed, it says why and the default reads" do
    Native.put_voices({:error, :unavailable})
    assert mounted() |> texts() |> Enum.any?(&(&1 =~ "text-to-speech engine didn't start"))

    Native.put_voices({:error, :unsupported})
    assert mounted() |> texts() |> Enum.any?(&(&1 =~ "can't list your phone's voices"))
  end

  test "Settings shows the chosen voice and opens the screen" do
    view = AppScreen |> mount_screen() |> render_info({:tap, {:tab, :settings}})
    assert "Your phone's default voice" in texts(view)

    voice = %{id: @uk.id, name: @uk.name, language: @uk.language}
    view = render_info(view, {:voice_chosen, voice})
    assert VoiceScreen.label(voice) in texts(view)

    view = render_info(view, {:tap, {:settings, :voice}})
    assert navigated_to(view) == VoiceScreen
  end
end
