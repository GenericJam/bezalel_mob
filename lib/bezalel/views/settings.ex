defmodule Bezalel.Views.Settings do
  @moduledoc """
  The Settings tab: account, appearance, models (who answers, who pushes
  back, who draws pictures), study (translation,
  results per list, scripture labels, and the approach and sources
  screens, `Bezalel.ApproachScreen` and `Bezalel.StudySourcesScreen`), the
  study library (`Bezalel.Views.StudyLibrary`), usage
  (`Bezalel.Views.Usage`), what's on the phone.
  """
  import Mob.Sigil

  alias Bezalel.{Account, Agent, Models, Settings}
  alias Bezalel.Agent.Pushback
  alias Bezalel.Study.{Sources, Translations}
  alias Bezalel.Study.Tools.DrawImage
  alias Bezalel.Views.{Helpers, StudyLibrary}
  alias Bezalel.Views.Usage, as: UsageView
  alias Mob.Socket
  alias MobBezalel.{Palette, UI}
  alias Rho.Auth
  alias Rho.Auth.Login

  # Results per list: a few choices around the default (8).
  @limits [4, 8, 12, 20]

  @doc "The Settings body."
  def render(assigns) do
    mode_index = Enum.find_index(Settings.modes(), &(&1 == assigns.mode))
    cover_index = Enum.find_index(Settings.covers(), &(&1 == assigns.cover))
    mode_opts = for m <- Settings.modes(), do: {label(m), {self(), {:settings, {:mode, m}}}}
    cover_opts = for c <- Settings.covers(), do: {label(c), {self(), {:settings, {:cover, c}}}}
    gallery_tap = {self(), {:settings, :gallery}}

    system_note =
      if assigns.mode == :system,
        do: "Follows your phone: #{MobBezalel.mode() || :dark} right now.",
        else: nil

    model_note =
      if Agent.live?(assigns.account),
        do: nil,
        else: "Replies come from the design’s script until you sign in or add an API key."

    appearance =
      UI.card(
        [
          ~MOB(<Text text="Theme" font={:ui_medium} text_size={14} text_color={:on_surface} />),
          UI.segmented(mode_opts, mode_index),
          note(system_note),
          ~MOB(<Text text="Cover" font={:ui_medium} text_size={14} text_color={:on_surface} />),
          UI.segmented(cover_opts, cover_index)
        ],
        padding: 16,
        gap: 10
      )

    on_phone =
      UI.card(
        [
          device_row("Conversations", "#{assigns.counts.conversations} stored", true),
          device_row("Materials", "#{assigns.counts[:materials] || 0} kept", true),
          device_row("Tools", "#{assigns.counts.tools} built", true),
          device_row("Bible text (BSB)", "Exodus 31 sample", false)
        ],
        padding: 0,
        gap: 0
      )

    sections = [
      section("Account", account(assigns)),
      section("Appearance", [appearance]),
      section("Models", models(assigns) ++ [note(model_note)]),
      section("Study", study(assigns)),
      section("Voice", voice(assigns)),
      section("Study library", StudyLibrary.render(assigns)),
      section("Usage", UsageView.settings(assigns)),
      section("On this phone", [on_phone]),
      section("Design", [
        UI.pill_button("Design specimen", gallery_tap, :outline,
          height: 40,
          fill: false,
          text_size: 13
        )
      ])
    ]

    ~MOB"""
    <Scroll weight={1} background={:background}>
      <Column
        padding_left={18}
        padding_right={18}
        padding_top={22}
        padding_bottom={28}
        gap={18}
        fill_width={true}
      >
        <Text text="Settings" font={:display} text_size={30} text_color={:on_background} />
        {sections}
      </Column>
    </Scroll>
    """
  end

  defp note(nil), do: []

  defp note(text),
    do: ~MOB(<Text text={text} text_size={12} line_height={1.45} text_color={:muted} />)

  defp section(title, children) do
    ~MOB"""
    <Column gap={8} fill_width={true}>
      {UI.kicker(title)}
      {children}
    </Column>
    """
  end

  # Read aloud (and the voice it reads in, on a screen of its own) and dictation.
  defp voice(assigns) do
    read_opts = [
      {"On", {self(), {:settings, {:read_aloud, true}}}},
      {"Off", {self(), {:settings, {:read_aloud, false}}}}
    ]

    voice_note =
      case assigns.voice do
        nil -> "Your phone's default voice"
        v -> Bezalel.VoiceScreen.label(v)
      end

    [
      UI.card(
        [
          field("Read replies aloud"),
          UI.segmented(read_opts, if(assigns.read_aloud, do: 0, else: 1)),
          note(
            "Each finished reply's summary is read aloud. The speaker beside any reply reads it whenever you like."
          ),
          field("Dictation"),
          note(
            "Tap the mic beside the question box to talk. Bezalel uses your phone's recogniser, or its own on the phone (a 60 MB download the first time), which also writes out recordings."
          )
        ],
        padding: 16,
        gap: 10
      ),
      nav_row("Voice", voice_note, {self(), {:settings, :voice}})
    ]
  end

  # The study preferences (`Bezalel.Study.Preferences`): the choices in a
  # card, then the approach and the sources, each on a screen of its own.
  defp study(assigns) do
    prefs = assigns.study
    translations = Translations.all()

    translation_opts =
      for t <- translations, do: {t.abbreviation, {self(), {:settings, {:translation, t.key}}}}

    limit_opts = for n <- @limits, do: {"#{n}", {self(), {:settings, {:limit, n}}}}

    label_opts = [
      {"Show", {self(), {:settings, {:labels, true}}}},
      {"Hide", {self(), {:settings, {:labels, false}}}}
    ]

    licence = {self(), {:packs, :attributions}}

    choices =
      UI.card(
        [
          field("Translation"),
          UI.segmented(translation_opts, index(translations, &(&1.key == prefs.translation))),
          note(translation_note(prefs.translation, assigns.packs)),
          ~MOB(<Text
  text="The NET Bible® is quoted by permission: see Sources and licences"
  font={:ui_medium}
  text_size={12}
  text_color={:secondary}
  on_tap={licence}
/>),
          field("Results per list"),
          UI.segmented(limit_opts, index(@limits, &(&1 == prefs.limit))),
          note(
            "How many results a list (cross references, names, verses) gives when Bezalel doesn't ask for a number."
          ),
          field("Scripture labels"),
          UI.segmented(label_opts, if(prefs.scripture_labels, do: 0, else: 1)),
          note(
            "Whether ancient sources are labelled with their place in the canon, by tradition where traditions differ."
          )
        ],
        padding: 16,
        gap: 10
      )

    approach_note =
      if prefs.approach, do: "Your own", else: "The default: what the texts say, credited"

    on = Enum.count(Sources.all(), &Sources.enabled?(prefs, &1.key))
    sources_note = "#{on} of #{length(Sources.all())} on"

    [
      choices,
      nav_row("Approach", approach_note, {self(), {:settings, :approach}}),
      nav_row("Sources", sources_note, {self(), {:settings, :sources}}),
      note("Changes apply from your next question.")
    ]
  end

  defp field(text),
    do: ~MOB(<Text text={text} font={:ui_medium} text_size={14} text_color={:on_surface} />)

  defp index(list, fun), do: Enum.find_index(list, fun)

  defp translation_note("net", packs) do
    if Enum.any?(packs.packs, &(&1.name == "translations" and &1.installed != nil)),
      do: "NET Bible, from its pack on this phone.",
      else:
        "The NET Bible comes in its own pack (Study library). Until it's on this phone, the tools quote the BSB and say so."
  end

  defp translation_note(_bsb, _packs), do: "Berean Standard Bible, from the core pack."

  # A row opening a screen: its title, what it's set to, and an Edit cue.
  defp nav_row(title, value, tap) do
    ~MOB"""
    <Box
      background={:surface}
      border_color={:border}
      border_width={1}
      corner_radius={18}
      padding_left={16}
      padding_right={16}
      padding_top={10}
      padding_bottom={10}
      fill_width={true}
      on_tap={tap}
    >
      <Row gap={12} align={:center} fill_width={true}>
        <Column gap={2} weight={1}>
          <Text text={title} font={:ui_medium} text_size={15} text_color={:on_surface} />
          <Text text={value} text_size={12} text_color={:muted} />
        </Column>
        <Text text="Edit" font={:ui_medium} text_size={13} text_color={:secondary} />
      </Row>
    </Box>
    """
  end

  # Subscriptions (browser sign-in) in one card, API keys in another.
  defp account(assigns) do
    subscriptions =
      UI.card(
        [
          ~MOB(<Text
  text="Sign in with your model subscription. It opens in your browser and returns here."
  text_size={14}
  line_height={1.5}
  text_color={:on_surface}
/>)
          | Enum.map(Account.subscriptions(), &subscription(&1, assigns))
        ],
        padding: 14,
        gap: 12
      )

    keys =
      UI.card(
        [
          ~MOB(<Text
  text="Or use an API key. It stays in this phone's secure store. A provider keeps one: a key and a sign-in replace each other."
  text_size={14}
  line_height={1.5}
  text_color={:on_surface}
/>)
          | Enum.map(Account.api_keys(), &api_key(&1, assigns))
        ],
        padding: 14,
        gap: 12
      )

    [subscriptions, keys]
  end

  defp subscription(provider, assigns) do
    name = Account.subscription_name(provider)

    case assigns.account[provider] do
      %{type: :oauth, email: email} ->
        out = {self(), {:settings, {:sign_out, provider}}}
        who = email || "#{name} subscription"
        initial = who |> String.first() |> String.upcase()

        ~MOB"""
        <Row gap={12} align={:center} fill_width={true}>
          <Box
            width={40}
            height={40}
            corner_radius={20}
            background={Palette.brand().umber}
            align="center"
            fill_width={false}
          >
            <Text
              text={initial}
              font={:display}
              text_size={18}
              text_color={Palette.overlay().mark_gold}
            />
          </Box>
          <Column gap={2} weight={1}>
            <Text text={who} font={:ui_medium} text_size={15} text_color={:on_surface} />
            <Text text={name <> " · signed in through the browser"} text_size={12} text_color={:muted} />
          </Column>
          {UI.pill_button("Sign out", out, :outline, height: 36, fill: false, text_size: 13)}
        </Row>
        """

      _ ->
        tap = {self(), {:settings, {:sign_in, provider}}}

        what =
          cond do
            match?(%{type: :api_key}, assigns.account[provider]) ->
              "Signing in replaces your #{Account.key_name(provider)} key"

            provider == :anthropic ->
              "Pro or Max subscription"

            true ->
              "Plus or Pro subscription"
          end

        row = ~MOB"""
        <Row gap={12} align={:center} fill_width={true}>
          <Column gap={2} weight={1}>
            <Text text={name} font={:ui_medium} text_size={15} text_color={:on_surface} />
            <Text text={what} text_size={12} text_color={:muted} />
          </Column>
          {UI.pill_button("Sign in", tap, :outline, height: 36, fill: false, text_size: 13)}
        </Row>
        """

        [row | pending(provider, assigns)]
    end
  end

  # While a sign-in waits for the browser. Claude's page may show a code
  # instead of coming back: it goes in the field.
  defp pending(provider, %{login: provider} = assigns) when provider == :anthropic do
    change = {self(), {:settings, :login_code}}
    use_tap = {self(), {:settings, :paste_code}}

    [
      note("Finish in the browser. If the page shows a code instead, paste it here."),
      ~MOB"""
      <Row gap={8} align={:center} fill_width={true}>
        <TextField
          value={@login_code}
          placeholder="Paste the code"
          on_change={change}
          background={:background}
          border_color={:border}
          border_width={1}
          text_size={14}
          weight={1}
        />
        {UI.pill_button("Use code", use_tap, :primary, height: 40, fill: false, text_size: 13)}
      </Row>
      """
    ]
  end

  defp pending(provider, %{login: provider}),
    do: [note("Finish in the browser; it returns here.")]

  defp pending(_provider, _assigns), do: []

  defp api_key(provider, assigns) do
    name = Account.key_name(provider)

    case assigns.account[provider] do
      %{type: :api_key, masked: masked} ->
        remove = {self(), {:settings, {:remove_key, provider}}}

        ~MOB"""
        <Row gap={12} align={:center} fill_width={true}>
          <Column gap={2} weight={1}>
            <Text text={name <> " key"} font={:ui_medium} text_size={15} text_color={:on_surface} />
            <Text text={masked} text_size={12} text_color={:muted} />
          </Column>
          {UI.pill_button("Remove", remove, :outline, height: 36, fill: false, text_size: 13)}
        </Row>
        """

      _ ->
        change = {self(), {:settings, {:key, provider}}}
        save = {self(), {:settings, {:save_key, provider}}}
        value = Map.get(assigns.key_drafts, provider, "")

        ~MOB"""
        <Column gap={6} fill_width={true}>
          <Text text={name <> " key"} font={:ui_medium} text_size={15} text_color={:on_surface} />
          <Row gap={8} align={:center} fill_width={true}>
            <TextField
              value={value}
              placeholder="Paste your key"
              on_change={change}
              secure={true}
              background={:background}
              border_color={:border}
              border_width={1}
              text_size={14}
              weight={1}
            />
            {UI.pill_button("Save", save, :outline, height: 40, fill: false, text_size: 13)}
          </Row>
        </Column>
        """
    end
  end

  # Who answers, who pushes back, who draws: each a row that opens its
  # chooser.
  defp models(assigns) do
    account = assigns.account
    model = Models.get(assigns.model_id)
    critic = assigns.study.pushback_model
    image = Enum.find(DrawImage.models(), &(&1.id == assigns.study.image_model))

    pushback =
      case critic && Auth.provider_for_model(critic) do
        {:ok, provider} ->
          {Pushback.label(critic), access(provider, account), Models.dot(provider)}

        _none ->
          {"None", "Choose a model to review replies, on the button or a conversation's switch",
           nil}
      end

    [
      choice_row("Answers", {model.name, access(model.provider, account), model.dot},
        tap: {self(), {:settings, :models}},
        id: "settings-model"
      ),
      choice_row("Pushback from", pushback,
        tap: {self(), {:settings, :pushback_models}},
        id: "settings-pushback"
      ),
      choice_row(
        "Pictures by",
        {image.label, access(image.provider, account), Models.dot(image.provider)},
        tap: {self(), {:settings, :image_models}},
        id: "settings-images"
      )
    ]
  end

  defp access(provider, account) do
    if match?(%{signed_in: true}, account[provider]),
      do: Auth.label(provider),
      else: "Needs your " <> Models.needs(provider)
  end

  # The provider's dot sits by the model's name, so every row's label
  # starts at the same edge (None has no dot).
  defp choice_row(label, {name, note, dot}, opts) do
    dot =
      if dot,
        do: [
          ~MOB(<Box width={8} height={8} corner_radius={4} background={dot} fill_width={false} />)
        ],
        else: []

    ~MOB"""
    <Box
      id={opts[:id]}
      background={:surface}
      border_color={:border}
      border_width={1}
      corner_radius={18}
      padding_left={16}
      padding_right={16}
      padding_top={10}
      padding_bottom={10}
      fill_width={true}
      on_tap={opts[:tap]}
    >
      <Row gap={12} align={:center} fill_width={true}>
        <Column gap={2} weight={1}>
          {UI.kicker(label)}
          <Row gap={8} align={:center} fill_width={true}>
            {dot}
            <Text text={name} font={:ui_medium} text_size={15} text_color={:on_surface} weight={1} />
          </Row>
          <Text text={note} text_size={12} text_color={:muted} />
        </Column>
        <Text text="Change" font={:ui_medium} text_size={13} text_color={:secondary} />
      </Row>
    </Box>
    """
  end

  defp device_row(k, v, rule?) do
    row = ~MOB"""
    <Row align={:center} height={48} padding_left={16} padding_right={16} fill_width={true}>
      <Text text={k} text_size={14} text_color={:on_surface} weight={1} />
      <Text text={v} text_size={14} text_color={:muted} />
    </Row>
    """

    if rule?, do: [row, ~MOB(<Divider color={:border} />)], else: [row]
  end

  defp label(atom), do: atom |> Atom.to_string() |> String.capitalize()

  # ── Events ────────────────────────────────────────────────────────────────

  @doc "Handles a Settings event."
  def handle({:mode, mode}, socket) do
    Settings.put_mode(mode)
    Mob.Theme.set(Settings.theme_module(mode))
    {:noreply, Socket.assign(socket, :mode, mode)}
  end

  def handle({:cover, cover}, socket) do
    Settings.put_cover(cover)
    {:noreply, Socket.assign(socket, :cover, cover)}
  end

  def handle(:models, socket), do: {:noreply, Socket.assign(socket, :sheet, :models)}

  def handle(:pushback_models, socket),
    do: {:noreply, Socket.assign(socket, :sheet, :pushback_models)}

  def handle(:image_models, socket), do: {:noreply, Socket.assign(socket, :sheet, :image_models)}

  # Study preferences both (bezalel_core's Bezalel.Study.Preferences): the
  # chooser closes on a choice.
  def handle({:pushback_model, spec}, socket),
    do: {:noreply, socket |> put_study(pushback_model: spec) |> Socket.assign(:sheet, nil)}

  def handle({:image_model, id}, socket),
    do: {:noreply, socket |> put_study(image_model: id) |> Socket.assign(:sheet, nil)}

  def handle({:sign_in, provider}, socket) do
    case Login.begin(provider) do
      {:ok, _url} ->
        {:noreply, Socket.assign(socket, login: provider, login_code: "")}

      {:error, reason} ->
        {:noreply, Helpers.toast(socket, begin_error(reason))}
    end
  end

  def handle(:paste_code, socket) do
    case Login.paste(:anthropic, socket.assigns.login_code) do
      :ok ->
        {:noreply,
         socket
         |> Socket.assign(login: nil, login_code: "")
         |> Helpers.toast("Checking the code with Claude…")}

      {:error, reason} ->
        {:noreply, Helpers.toast(socket, paste_error(reason))}
    end
  end

  def handle({:sign_out, provider}, socket), do: {:noreply, forget(socket, provider)}
  def handle({:remove_key, provider}, socket), do: {:noreply, forget(socket, provider)}

  def handle({:save_key, provider}, socket) do
    key = socket.assigns.key_drafts |> Map.get(provider, "") |> String.trim()
    name = Account.key_name(provider)

    with false <- key == "",
         :ok <- Auth.put_api_key(provider, key) do
      {:noreply,
       socket
       |> Socket.assign(:key_drafts, Map.delete(socket.assigns.key_drafts, provider))
       |> refresh()
       |> Helpers.toast("#{name} key saved.")}
    else
      true ->
        {:noreply, Helpers.toast(socket, "Paste your #{name} key first.")}

      {:error, reason} ->
        {:noreply, Helpers.toast(socket, "Couldn't save the key: #{Auth.describe_error(reason)}")}
    end
  end

  def handle(:refresh_usage, socket), do: {:noreply, UsageView.refresh_usage(socket)}

  # A provider's billing page (Usage, a failed reply's card).
  def handle({:open_url, url}, socket) do
    Rho.Config.open_url(url)
    {:noreply, socket}
  end

  def handle(:gallery, socket),
    do: {:noreply, Socket.push_screen(socket, Bezalel.DesignGalleryScreen)}

  def handle({:translation, key}, socket), do: {:noreply, put_study(socket, translation: key)}
  def handle({:limit, n}, socket), do: {:noreply, put_study(socket, limit: n)}
  def handle({:labels, show?}, socket), do: {:noreply, put_study(socket, scripture_labels: show?)}

  def handle({:read_aloud, on?}, socket) do
    Settings.put_read_aloud(on?)
    {:noreply, Socket.assign(socket, :read_aloud, on?)}
  end

  # The screens tell this one (`study_changed/1`) when they store a change.
  def handle(:approach, socket),
    do: {:noreply, Socket.push_screen(socket, Bezalel.ApproachScreen, %{app: self()})}

  def handle(:sources, socket),
    do: {:noreply, Socket.push_screen(socket, Bezalel.StudySourcesScreen, %{app: self()})}

  # The voice screen tells this one (`{:voice_chosen, voice}`) when it stores a choice.
  def handle(:voice, socket),
    do: {:noreply, Socket.push_screen(socket, Bezalel.VoiceScreen, %{app: self()})}

  @doc """
  The study preferences changed (here, or on the approach or sources
  screen): Settings shows them, and the agent's idle loops go so the next
  question follows them (`Bezalel.Views.Helpers.release_idle/1`).
  """
  def study_changed(socket) do
    socket
    |> Socket.assign(:study, Settings.study_preferences())
    |> Helpers.release_idle()
  end

  defp put_study(socket, changes) do
    before = socket.assigns.study

    if Settings.update_study_preferences(&struct(&1, changes)) == before,
      do: socket,
      else: study_changed(socket)
  end

  @doc "Handles typing in a Settings field: an API key, or Claude's sign-in code."
  def change({:key, provider}, value, socket),
    do: Socket.assign(socket, :key_drafts, Map.put(socket.assigns.key_drafts, provider, value))

  def change(:login_code, value, socket), do: Socket.assign(socket, :login_code, value)

  @doc """
  A sign-in finished (`{:rho_login, provider, result}` from
  `Rho.Auth.Login`): Settings shows the new account, or why it failed.
  """
  def login_result(provider, :ok, socket) do
    socket
    |> Socket.assign(login: nil, login_code: "")
    |> refresh()
    |> Helpers.toast("Signed in to #{Account.subscription_name(provider)}.")
  end

  def login_result(_provider, {:error, message}, socket) do
    socket
    |> Socket.assign(login: nil, login_code: "")
    |> Helpers.toast("Sign-in failed: #{message}")
  end

  @doc "Re-reads the sign-ins and API keys (after a change here or anywhere)."
  def refresh(socket), do: Socket.assign(socket, :account, Account.status())

  # Sign-out and key removal: the provider's one credential goes.
  defp forget(socket, provider) do
    case Auth.delete(provider) do
      :ok ->
        refresh(socket)

      {:error, reason} ->
        Helpers.toast(socket, "Couldn't remove it: #{Auth.describe_error(reason)}")
    end
  end

  # The sign-in listens on the provider's fixed localhost port; another
  # app's sign-in in progress can hold it.
  defp begin_error({:listen, _port, :eaddrinuse}),
    do: "Another app is signing in right now. Finish or close that sign-in, then try again."

  defp begin_error(_reason), do: "Couldn't start the sign-in. Try again."

  defp paste_error(:no_code), do: "Paste the code the Claude page shows."
  defp paste_error(:state_mismatch), do: "That code is from another sign-in. Tap Sign in again."
  defp paste_error(:no_login_started), do: "Tap Sign in first."
  defp paste_error({:started_for, _}), do: "Another sign-in is in progress. Tap Sign in again."
end
