defmodule Bezalel.AppScreen do
  @moduledoc """
  The app: Study, Conversations, Materials, Workshop (and a built tool) and
  Settings under one top bar and tab bar, with the sheets and the toast
  over them. Each tab's view and events live in `Bezalel.Views.*`; this
  screen holds the state and routes events to them, the native answers
  for the composer's materials and dictation (`Bezalel.Views.Attach`)
  included.
  """
  use Mob.Screen

  alias Bezalel.{Account, Library, Settings}

  alias Bezalel.Views.{
    Attach,
    Conversations,
    Helpers,
    Images,
    Sheets,
    Stills,
    Study,
    StudyLibrary,
    Workshop
  }

  alias Bezalel.Views.Materials, as: MaterialsView
  alias Bezalel.Views.Settings, as: SettingsView
  alias Mob.Theme.AdaptiveWatcher
  alias MobBezalel.{Palette, UI}
  alias Rho.Auth.Login

  @tabs [
    {:study, "Study", :study},
    {:convs, "Conversations", :conversations},
    {:materials, "Materials", :materials},
    {:workshop, "Workshop", :workshop},
    {:settings, "Settings", :settings}
  ]

  def mount(_params, _session, socket) do
    mode = Settings.mode()
    Mob.Theme.set(Settings.theme_module(mode))
    AdaptiveWatcher.register_adaptive(MobBezalel.System)
    # System mode: re-set the theme on an OS light/dark flip so this screen
    # repaints in the new palette (the watcher updates the theme only).
    Mob.Device.subscribe(:appearance)
    # Sign-ins, API keys and usage change from here and from model calls:
    # Settings follows both. A sign-in started before this screen
    # (re)started reports here from now on.
    :ok = Rho.Auth.subscribe()
    :ok = Rho.Usage.subscribe()
    login = Login.pending()
    # Loops left by an earlier run of this screen answer to nobody now; the
    # next question starts one from the conversation as stored.
    :ok = Bezalel.Agent.release_all()
    # Stills previews left by an earlier run.
    :ok = Stills.sweep()
    # The study library (Settings, the first-launch offer) follows the
    # downloads, which run outside this screen.
    :ok = Bezalel.Packs.subscribe()
    # Built tools' activations, crashes and reverts (the Workshop shows
    # them; a revert also says so wherever the user is).
    :ok = Rho.Dyn.subscribe()
    # The Workshop's shelf follows the generation that runs, which a revert
    # may have changed with nobody listening: at boot (a launch that died)
    # or while this screen was down. Subscribed first, so none is missed.
    :ok = Bezalel.Workshop.reconcile()
    # Conversations deleted while their Undo was offered when the app (or
    # this screen) went down stay deleted.
    :ok = Library.purge_deleted()

    conversation = Library.get_conversation(Settings.conversation_id()) || Library.seed!()

    socket =
      socket
      |> Mob.Socket.assign(
        mode: mode,
        cover: Settings.cover(),
        model_id: Settings.model(),
        study: Settings.study_preferences(),
        account: Account.status(),
        usage: Account.usage(),
        login: login,
        login_code: "",
        key_drafts: %{},
        sheet: nil,
        toast: nil,
        draft: "",
        desc: "",
        build: nil,
        tool: nil,
        tools: [],
        shelf: [],
        shelf_done: true,
        counts: %{conversations: 0, tools: 0},
        replying: %{},
        streams: %{},
        sessions: %{},
        stale: MapSet.new(),
        edits: %{},
        images: %{},
        viewer: nil,
        switched: false,
        move_open: 0,
        tool_host: nil,
        tool_view: nil,
        tool_screen: nil,
        tool_state: nil,
        tool_status: %{},
        change_of: nil,
        code_open: false,
        speaking: nil,
        speaking_ref: nil,
        read_aloud: Settings.read_aloud?()
      )
      |> Mob.Socket.assign(Attach.assigns() ++ MaterialsView.assigns() ++ Stills.assigns())
      |> Helpers.open_conversation(conversation)
      |> StudyLibrary.mount()

    {:ok, socket}
  end

  def render(assigns) do
    sa = assigns[:safe_area] || %{top: 0, bottom: 0}
    tabs = for {key, label, icon} <- @tabs, do: {label, icon, {self(), {:tab, key}}}

    ~MOB"""
    <Box align="bottom" fill_width={true} fill_height={true} background={:background}>
      <Column fill_width={true} fill_height={true} background={:background}>
        {top_bar(assigns)}
        {body(assigns)}
        {UI.tab_bar(tabs, active_index(@tab), @cover, sa.bottom)}
      </Column>
      {toast(@toast, @tab, sa.bottom)}
      {Sheets.render(assigns)}
      {Images.viewer(assigns)}
    </Box>
    """
  end

  defp top_bar(%{tab: :study} = assigns) do
    toggle =
      UI.bar_button(
        Study.toggle_all_label(assigns),
        {self(), {:study, :toggle_all}},
        assigns.cover
      )

    UI.top_bar("Study", assigns.cover, trailing: if(assigns.messages != [], do: toggle))
  end

  defp top_bar(%{tab: :tool} = assigns) do
    back = UI.bar_button("Workshop", {self(), {:tab, :workshop}}, assigns.cover)
    UI.top_bar(assigns.tool.name, assigns.cover, trailing: back)
  end

  defp top_bar(%{tab: :materials, mat_open: %{}} = assigns) do
    back = UI.bar_button("All materials", {self(), {:materials, :close}}, assigns.cover)
    UI.top_bar("Materials", assigns.cover, trailing: back)
  end

  defp top_bar(assigns) do
    title =
      %{
        convs: "Conversations",
        materials: "Materials",
        workshop: "Workshop",
        settings: "Settings"
      }[assigns.tab]

    UI.top_bar(title, assigns.cover)
  end

  defp body(%{tab: :study} = assigns), do: Study.render(assigns)
  defp body(%{tab: :convs} = assigns), do: Conversations.render(assigns)
  defp body(%{tab: :materials} = assigns), do: MaterialsView.render(assigns)
  defp body(%{tab: :workshop} = assigns), do: Workshop.render(assigns)
  defp body(%{tab: :tool} = assigns), do: Workshop.render_tool(assigns)
  defp body(%{tab: :settings} = assigns), do: SettingsView.render(assigns)

  defp active_index(:tool), do: active_index(:workshop)
  defp active_index(tab), do: Enum.find_index(@tabs, fn {key, _, _} -> key == tab end)

  # Sits above the composer in Study, above the tab bar elsewhere.
  defp toast(nil, _tab, _inset), do: []

  defp toast(toast, tab, inset) do
    bottom = if tab == :study, do: 150, else: 78
    o = Palette.overlay()

    # A deleted conversation's Undo is the shelf's; the rest are Study's.
    undo_owner = if match?({:conversation, _, _}, toast.undo), do: :convs, else: :study

    actions =
      for {show?, label, tap} <- [
            {toast.ask_again, "Ask again", {self(), {:study, :ask_again}}},
            {toast.undo != nil, "Undo", {self(), {undo_owner, :undo}}}
          ],
          show? do
        ~MOB(<Text
  text={label}
  font={:ui_semibold}
  text_size={13}
  text_color={o.popover_action}
  padding={4}
  on_tap={tap}
/>)
      end

    Helpers.toast_box(toast.text, actions, bottom, inset)
  end

  # ── Events ────────────────────────────────────────────────────────────────

  def handle_info({:tap, {:tab, tab}}, socket) do
    {:noreply,
     socket |> Stills.close() |> Mob.Socket.assign(sheet: nil, menu: nil) |> Helpers.go(tab)}
  end

  def handle_info({:tap, {:study, event}}, socket), do: Study.handle(event, socket)
  def handle_info({:tap, {:convs, event}}, socket), do: Conversations.handle(event, socket)
  def handle_info({:tap, {:workshop, event}}, socket), do: Workshop.handle(event, socket)
  def handle_info({:tap, {:tool, event}}, socket), do: Workshop.handle_tool(event, socket)
  def handle_info({:tap, {:settings, event}}, socket), do: SettingsView.handle(event, socket)
  def handle_info({:tap, {:packs, event}}, socket), do: StudyLibrary.handle(event, socket)
  def handle_info({:tap, {:attach, event}}, socket), do: Attach.handle(event, socket)
  def handle_info({:tap, {:materials, event}}, socket), do: MaterialsView.handle(event, socket)
  def handle_info({:tap, {:stills, event}}, socket), do: Stills.handle(event, socket)

  def handle_info({:change, {:stills, :at}, value}, socket),
    do: {:noreply, Stills.move(value, socket)}

  def handle_info({:stills, :settle, seq}, socket), do: {:noreply, Stills.settle(seq, socket)}

  # The native answers for the composer: permissions, pickers, the camera,
  # the recorder, the recogniser, Whisper's model; and playback ending.
  def handle_info({:permission, cap, result}, socket),
    do: {:noreply, Attach.permission(cap, result, socket)}

  def handle_info({:audio, event, _info}, socket)
      when event in [:playback_finished, :playback_error],
      do: {:noreply, MaterialsView.played(socket)}

  def handle_info({tag, _event, _value} = message, socket)
      when tag in [:photos, :camera, :files, :audio],
      do: {:noreply, Attach.picked(message, socket)}

  def handle_info({tag, :cancelled}, socket) when tag in [:photos, :camera, :files],
    do: {:noreply, socket}

  def handle_info({:speech, kind, value}, socket),
    do: {:noreply, Attach.speech(kind, value, socket)}

  def handle_info({:mob_whisper, :model, result}, socket),
    do: {:noreply, Attach.model(result, socket)}

  def handle_info({:attach, :tick}, socket), do: {:noreply, Attach.tick_recorder(socket)}

  def handle_info({:speaking_done, ref}, %{assigns: %{speaking_ref: ref}} = socket),
    do: {:noreply, Mob.Socket.assign(socket, speaking: nil, speaking_ref: nil)}

  # The notice in Study ("Now answering with …") shows after any change of
  # model, whichever tab it was made from, until the conversation changes.
  def handle_info({:tap, {:model, id}}, socket) do
    Settings.put_model(id)
    switched = id != socket.assigns.model_id

    {:noreply,
     Mob.Socket.assign(socket,
       model_id: id,
       sheet: nil,
       switched: switched or socket.assigns.switched
     )}
  end

  # However a sheet closes, a stills picker's tasks and previews go with it.
  def handle_info({:tap, :sheet}, socket),
    do: {:noreply, socket |> Stills.close() |> Mob.Socket.assign(:sheet, nil)}

  def handle_info({:dismiss, :sheet}, socket),
    do: {:noreply, socket |> Stills.close() |> Mob.Socket.assign(:sheet, nil)}

  def handle_info({:change, :draft, value}, socket),
    do: {:noreply, Mob.Socket.assign(socket, :draft, value)}

  def handle_info({:change, :desc, value}, socket),
    do: {:noreply, Mob.Socket.assign(socket, :desc, value)}

  def handle_info({:change, {:settings, field}, value}, socket),
    do: {:noreply, SettingsView.change(field, value, socket)}

  # The approach or sources screen (pushed from Settings) stored a change.
  def handle_info({:study_preferences, :changed}, socket),
    do: {:noreply, SettingsView.study_changed(socket)}

  def handle_info({:rho_auth, :changed}, socket), do: {:noreply, SettingsView.refresh(socket)}

  def handle_info({:rho_usage, :changed}, socket),
    do: {:noreply, SettingsView.refresh_usage(socket)}

  def handle_info({:bezalel_packs, event}, socket),
    do: {:noreply, StudyLibrary.event(event, socket)}

  def handle_info({:rho_login, provider, result}, socket),
    do: {:noreply, SettingsView.login_result(provider, result, socket)}

  def handle_info({:build_step, i}, socket), do: {:noreply, Workshop.step(i, socket)}

  def handle_info({Bezalel.Workshop.Host, pid, {:view, tree}}, socket),
    do: {:noreply, Workshop.host_view(pid, tree, socket)}

  def handle_info({:DOWN, ref, :process, _pid, reason}, socket),
    do: {:noreply, Workshop.host_down(ref, reason, socket)}

  def handle_info({:rho_dyn, event}, socket), do: {:noreply, Workshop.dyn_event(event, socket)}

  def handle_info({:toast_expire, ref}, socket) do
    case socket.assigns.toast do
      %{ref: ^ref} -> {:noreply, Mob.Socket.assign(socket, :toast, nil)}
      _ -> {:noreply, socket}
    end
  end

  def handle_info({:purge, deleted}, socket),
    do: {:noreply, Conversations.purge(deleted, socket)}

  def handle_info({:mob_device, :color_scheme_changed, _scheme}, socket) do
    if socket.assigns.mode == :system, do: Mob.Theme.set(MobBezalel.System)
    {:noreply, socket}
  end

  def handle_info({:rho, session_id, event}, socket),
    do: {:noreply, Study.agent_event(session_id, event, socket)}

  def handle_info({:tap, {:image, event}}, socket), do: Images.handle(event, socket)
  def handle_info({:double_tap, {:image, :zoom}}, socket), do: Images.handle(:zoom, socket)

  def handle_info({:pinch, {:image, :zoom}, payload}, socket),
    do: {:noreply, Images.pinch(payload, socket)}

  def handle_info(_message, socket), do: {:noreply, socket}

  def handle_async({:image, key, size}, result, socket),
    do: {:noreply, Images.loaded(key, size, result, socket)}

  def handle_async({:reply, conversation_id, _ref}, result, socket),
    do: {:noreply, Study.replied(conversation_id, result, socket)}

  def handle_async({:lexicon, strongs}, result, socket),
    do: {:noreply, Study.lexicon(strongs, result, socket)}

  def handle_async(:build, result, socket), do: {:noreply, Workshop.built(result, socket)}

  def handle_async({:keep, cid, _ref}, result, socket),
    do: {:noreply, Attach.kept(cid, result, socket)}

  def handle_async({:transcribe, id}, result, socket) do
    socket = Attach.transcribed(id, result, socket)
    {:noreply, MaterialsView.transcribed(id, socket)}
  end

  def handle_async({:prepare, _cid}, result, socket),
    do: {:noreply, Attach.prepared(result, socket)}

  def handle_async({:stills, :info, ref}, result, socket),
    do: {:noreply, Stills.info(ref, result, socket)}

  def handle_async({:stills, :frame, ref}, result, socket),
    do: {:noreply, Stills.framed(ref, result, socket)}
end
