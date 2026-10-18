defmodule Bezalel.StudySourcesScreen do
  @moduledoc """
  Settings → Study → Sources: every source the study tools draw on that
  the user may switch off (bezalel_core's `Bezalel.Study.Sources`),
  grouped as it groups them, each with its label, description and an
  On/Off control (`Bezalel.Study.Preferences`, `excluded_sources`).

  Pushed from Settings with `%{app: pid}`: a stored change is reported to
  that screen (`{:study_preferences, :changed}`), which releases the idle
  loops, so it applies from the next question.
  """
  use Mob.Screen

  alias Bezalel.Settings
  alias Bezalel.Study.Sources
  alias MobBezalel.UI

  def mount(params, _session, socket) do
    {:ok,
     Mob.Socket.assign(socket,
       cover: Settings.cover(),
       app: params[:app],
       prefs: Settings.study_preferences()
     )}
  end

  def render(assigns) do
    back = UI.bar_button("Settings", {self(), :back}, assigns.cover)

    groups =
      Sources.all()
      |> Enum.chunk_by(& &1.group)
      |> Enum.map(fn [first | _] = sources ->
        group(first.group, Enum.map(sources, &source(&1, assigns.prefs)))
      end)

    ~MOB"""
    <Column background={:background} fill_width={true} fill_height={true}>
      {UI.top_bar("Sources", @cover, trailing: back)}
      <Scroll id="study-sources" weight={1} background={:background}>
        <Column
          padding_left={18}
          padding_right={18}
          padding_top={22}
          padding_bottom={28}
          gap={18}
          fill_width={true}
        >
          <Text text="Sources" font={:display} text_size={30} text_color={:on_background} />
          {intro()}
          {groups}
        </Column>
      </Scroll>
    </Column>
    """
  end

  defp intro do
    UI.card(
      [
        body(
          "The sources the study tools draw on beside the Bible text and the lexicons. Switching one off stops the tools from supplying it and tells Bezalel not to lean on it. The model may still know it from its training.",
          14
        ),
        body("Changes apply from your next question.", 13)
      ],
      padding: 16,
      gap: 8
    )
  end

  defp group(title, children) do
    ~MOB"""
    <Column gap={8} fill_width={true}>
      {UI.kicker(title)}
      {children}
    </Column>
    """
  end

  defp source(source, prefs) do
    on? = Sources.enabled?(prefs, source.key)

    options = [
      {"On", {self(), {:source, source.key, true}}},
      {"Off", {self(), {:source, source.key, false}}}
    ]

    UI.card(
      [
        ~MOB(<Text text={source.label} font={:ui_medium} text_size={15} text_color={:on_surface} />),
        ~MOB(<Text text={source.description} text_size={12.5} line_height={1.45} text_color={:muted} />),
        UI.segmented(options, if(on?, do: 0, else: 1))
      ],
      padding: 14,
      gap: 8
    )
  end

  defp body(text, size),
    do: ~MOB(<Text text={text} text_size={size} line_height={1.5} text_color={:on_surface} />)

  def handle_info({:tap, {:source, key, on?}}, socket) do
    before = socket.assigns.prefs

    prefs =
      Settings.update_study_preferences(fn prefs ->
        excluded =
          if on?,
            do: MapSet.delete(prefs.excluded_sources, key),
            else: MapSet.put(prefs.excluded_sources, key)

        %{prefs | excluded_sources: excluded}
      end)

    if prefs != before and socket.assigns.app,
      do: send(socket.assigns.app, {:study_preferences, :changed})

    {:noreply, Mob.Socket.assign(socket, :prefs, prefs)}
  end

  def handle_info({:tap, :back}, socket), do: {:noreply, Mob.Socket.pop_screen(socket)}
  def handle_info(_message, socket), do: {:noreply, socket}
end
