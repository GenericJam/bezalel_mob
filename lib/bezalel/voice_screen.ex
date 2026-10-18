defmodule Bezalel.VoiceScreen do
  @moduledoc """
  Settings → Voice: the voice replies are read aloud in. The phone's
  text-to-speech voices (`Bezalel.Native.voices/0`, `Mob.Speech.voices/0`,
  loaded with `start_async`: on Android the engine can take seconds to
  start) grouped by language, English first, each group folding, with the
  phone's own default at the top. Picking one stores it
  (`Bezalel.Settings.put_voice/1`) and says a line in it; Try it says the
  line again in the chosen voice. The speaker beside a reply and reading
  finished replies aloud use the choice (`Bezalel.Views.Study.speak/3`).

  Pushed from Settings with `%{app: pid}`: a stored choice is reported to
  that screen (`{:voice_chosen, voice}`), which shows it.
  """
  use Mob.Screen

  alias Bezalel.{Native, Settings}
  alias MobBezalel.{Icons, UI}

  @sample "See, I have called by name Bezalel the son of Uri, the son of Hur, of the tribe of Judah."

  # Base language codes' names, for the group headings (others show their code).
  @languages %{
    "af" => "Afrikaans",
    "am" => "Amharic",
    "ar" => "Arabic",
    "bg" => "Bulgarian",
    "bn" => "Bengali",
    "ca" => "Catalan",
    "cmn" => "Chinese (Mandarin)",
    "cs" => "Czech",
    "cy" => "Welsh",
    "da" => "Danish",
    "de" => "German",
    "el" => "Greek",
    "en" => "English",
    "es" => "Spanish",
    "et" => "Estonian",
    "eu" => "Basque",
    "fa" => "Persian",
    "fi" => "Finnish",
    "fil" => "Filipino",
    "fr" => "French",
    "ga" => "Irish",
    "gl" => "Galician",
    "gu" => "Gujarati",
    "he" => "Hebrew",
    "hi" => "Hindi",
    "hr" => "Croatian",
    "hu" => "Hungarian",
    "id" => "Indonesian",
    "is" => "Icelandic",
    "it" => "Italian",
    "iw" => "Hebrew",
    "ja" => "Japanese",
    "jv" => "Javanese",
    "km" => "Khmer",
    "kn" => "Kannada",
    "ko" => "Korean",
    "lt" => "Lithuanian",
    "lv" => "Latvian",
    "ml" => "Malayalam",
    "mr" => "Marathi",
    "ms" => "Malay",
    "my" => "Burmese",
    "nb" => "Norwegian",
    "ne" => "Nepali",
    "nl" => "Dutch",
    "pa" => "Punjabi",
    "pl" => "Polish",
    "pt" => "Portuguese",
    "ro" => "Romanian",
    "ru" => "Russian",
    "si" => "Sinhala",
    "sk" => "Slovak",
    "sl" => "Slovenian",
    "sq" => "Albanian",
    "sr" => "Serbian",
    "su" => "Sundanese",
    "sv" => "Swedish",
    "sw" => "Swahili",
    "ta" => "Tamil",
    "te" => "Telugu",
    "th" => "Thai",
    "tr" => "Turkish",
    "uk" => "Ukrainian",
    "ur" => "Urdu",
    "vi" => "Vietnamese",
    "yue" => "Chinese (Cantonese)",
    "zh" => "Chinese",
    "zu" => "Zulu"
  }

  @quality %{
    very_high: "Very high quality",
    high: "High quality",
    normal: "Normal quality",
    low: "Low quality",
    very_low: "Very low quality"
  }

  def mount(params, _session, socket) do
    voice = Settings.voice()

    socket =
      socket
      |> Mob.Socket.assign(
        cover: Settings.cover(),
        app: params[:app],
        voice: voice,
        voices: :loading,
        sample_pending: 0,
        open: MapSet.new(["en" | if(voice, do: [base(voice.language)], else: [])])
      )
      |> Mob.Socket.start_async(:voices, fn -> Native.voices() end)

    {:ok, socket}
  end

  @doc "A stored voice as Settings shows it: its name and language tag."
  @spec label(%{name: String.t(), language: String.t()}) :: String.t()
  def label(%{name: name, language: language}), do: "#{name} · #{language}"

  @doc """
  `voices` grouped by base language for the list: `[{code, title,
  voices}]`, English first, then by title; each group keeps the
  platform's order (best quality first).
  """
  @spec groups([map()]) :: [{String.t(), String.t(), [map()]}]
  def groups(voices) do
    voices
    |> Enum.group_by(&base(&1.language))
    |> Enum.map(fn {code, group} -> {code, Map.get(@languages, code, code), group} end)
    |> Enum.sort_by(fn {code, title, _} -> {code != "en", title} end)
  end

  defp base(language), do: language |> String.split(["-", "_"]) |> hd() |> String.downcase()

  def render(assigns) do
    back = UI.bar_button("Settings", {self(), :back}, assigns.cover)

    ~MOB"""
    <Column background={:background} fill_width={true} fill_height={true}>
      {UI.top_bar("Voice", @cover, trailing: back)}
      <Scroll id="voices" weight={1} background={:background}>
        <Column
          padding_left={18}
          padding_right={18}
          padding_top={22}
          padding_bottom={28}
          gap={18}
          fill_width={true}
        >
          <Text text="Voice" font={:display} text_size={30} text_color={:on_background} />
          {chosen(assigns)}
          {list(assigns)}
        </Column>
      </Scroll>
    </Column>
    """
  end

  # The choice, whether this phone has it, and Try it.
  defp chosen(assigns) do
    {title, note} =
      case assigns.voice do
        nil ->
          {"Your phone's default voice", "As set in the phone's text-to-speech settings."}

        v ->
          {label(v), missing_note(v, assigns.voices)}
      end

    try_it =
      UI.pill_button("Try it", {self(), :try}, :outline, height: 40, fill: false, text_size: 13)

    UI.card(
      [
        UI.kicker("Replies are read in"),
        ~MOB(<Text text={title} font={:ui_medium} text_size={15} text_color={:on_surface} />),
        note(note),
        try_it
      ],
      padding: 16,
      gap: 8
    )
  end

  defp missing_note(v, {:ok, voices}) do
    if Enum.any?(voices, &(&1.id == v.id)),
      do: nil,
      else: "Not on this phone: a voice for its language reads instead, or the default."
  end

  defp missing_note(_v, _loading_or_error), do: nil

  defp list(%{voices: :loading}), do: [note("Finding your phone's voices…")]

  defp list(%{voices: {:error, :unavailable}}),
    do: [
      note(
        "Your phone's text-to-speech engine didn't start, so its voices can't be listed. Replies are read in its default voice; check the phone's text-to-speech settings."
      )
    ]

  defp list(%{voices: {:error, _unsupported}}),
    do: [
      note(
        "This build of Bezalel can't list your phone's voices. Replies are read in its default voice."
      )
    ]

  defp list(%{voices: {:ok, voices}} = assigns) do
    default =
      row(
        "Default",
        "Your phone's default voice",
        assigns.voice == nil,
        {self(), {:pick, :default}}
      )

    groups =
      for {code, title, group} <- groups(voices) do
        group(code, title, group, assigns)
      end

    [UI.card([default], padding: 0, gap: 0) | groups]
  end

  defp group(code, title, voices, assigns) do
    open? = MapSet.member?(assigns.open, code)

    chevron =
      Icons.icon(if(open?, do: :chevron_up, else: :chevron_down), 14, :muted, stroke: 2.75)

    count = if match?([_], voices), do: "1 voice", else: "#{length(voices)} voices"
    toggle = {self(), {:group, code}}

    rows =
      if open?,
        do:
          Enum.map(voices, fn v ->
            row(v.name, details(v), selected?(v, assigns.voice), {self(), {:pick, v.id}})
          end),
        else: []

    header =
      ~MOB"""
      <Row
        gap={10}
        align={:center}
        padding_top={8}
        padding_bottom={8}
        fill_width={true}
        on_tap={toggle}
      >
        <Column gap={2} weight={1}>
          <Text text={title} font={:ui_semibold} text_size={15} text_color={:on_background} />
          <Text text={count} text_size={12} text_color={:muted} />
        </Column>
        {chevron}
      </Row>
      """

    ~MOB"""
    <Column gap={6} fill_width={true}>
      {header}
      {if rows == [], do: [], else: UI.card(rows, padding: 0, gap: 0)}
    </Column>
    """
  end

  # Language tag, quality, and whether it needs a connection.
  defp details(v) do
    where = if v.network, do: "needs internet", else: "on the phone"
    "#{v.language} · #{Map.get(@quality, v.quality, "Quality unknown")} · #{where}"
  end

  defp selected?(v, %{id: id}), do: v.id == id
  defp selected?(_v, nil), do: false

  defp row(title, subtitle, selected?, tap) do
    mark =
      if selected?,
        do: [
          ~MOB(<Text text="Chosen" font={:ui_medium} text_size={13} text_color={:secondary} />)
        ],
        else: []

    ~MOB"""
    <Row
      gap={12}
      align={:center}
      padding_left={16}
      padding_right={16}
      padding_top={10}
      padding_bottom={10}
      fill_width={true}
      on_tap={tap}
    >
      <Column gap={2} weight={1}>
        <Text text={title} font={:ui_medium} text_size={15} text_color={:on_surface} />
        <Text text={subtitle} text_size={12} text_color={:muted} />
      </Column>
      {mark}
    </Row>
    """
  end

  defp note(nil), do: []

  defp note(text),
    do: ~MOB(<Text text={text} text_size={12.5} line_height={1.45} text_color={:muted} />)

  def handle_async(:voices, {:ok, result}, socket),
    do: {:noreply, Mob.Socket.assign(socket, :voices, result)}

  def handle_async(:voices, {:exit, _reason}, socket),
    do: {:noreply, Mob.Socket.assign(socket, :voices, {:error, :unavailable})}

  def handle_info({:tap, {:pick, :default}}, socket), do: {:noreply, choose(socket, nil)}

  def handle_info({:tap, {:pick, id}}, socket) do
    case socket.assigns.voices do
      {:ok, voices} ->
        case Enum.find(voices, &(&1.id == id)) do
          nil -> {:noreply, socket}
          v -> {:noreply, choose(socket, Map.take(v, [:id, :name, :language]))}
        end

      _ ->
        {:noreply, socket}
    end
  end

  def handle_info({:tap, :try}, socket), do: {:noreply, say(socket)}

  def handle_info({:tap, {:group, code}}, socket) do
    open = socket.assigns.open

    open =
      if MapSet.member?(open, code), do: MapSet.delete(open, code), else: MapSet.put(open, code)

    {:noreply, Mob.Socket.assign(socket, :open, open)}
  end

  # Stops only this screen's own sample: the stop is global, and a reply
  # being read when Voice was opened should keep going.
  def handle_info({:tap, :back}, socket) do
    socket = if socket.assigns.sample_pending > 0, do: Native.stop_speaking(socket), else: socket
    {:noreply, Mob.Socket.pop_screen(socket)}
  end

  def handle_info({:speech, ended}, socket) when ended in [:done, :cancelled, :failed],
    do:
      {:noreply,
       Mob.Socket.assign(socket, :sample_pending, max(socket.assigns.sample_pending - 1, 0))}

  def handle_info(_message, socket), do: {:noreply, socket}

  # Stores the choice, tells Settings, and says the sample in it.
  defp choose(socket, voice) do
    Settings.put_voice(voice)
    if socket.assigns.app, do: send(socket.assigns.app, {:voice_chosen, voice})
    socket |> Mob.Socket.assign(:voice, voice) |> say()
  end

  defp say(socket) do
    socket
    |> Native.stop_speaking()
    |> Native.speak(@sample, Settings.voice_opts())
    |> Mob.Socket.assign(:sample_pending, socket.assigns.sample_pending + 1)
  end
end
