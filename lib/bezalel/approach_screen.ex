defmodule Bezalel.ApproachScreen do
  @moduledoc """
  Settings → Study → Approach: the part of the study prompt the user may
  rewrite (persona, audience, how to read, how to answer;
  `Bezalel.Study.Preferences`, `approach`), in a multi-line field, with
  Save and Restore default; beneath it, read-only, what is always
  included (bezalel_core's `Bezalel.Study.Prompt.fixed/1` for the current
  preferences, and the phone's formatting section,
  `Bezalel.Agent.Live.phone_formatting/0`).

  Pushed from Settings with `%{app: pid}`: a stored change is reported to
  that screen (`{:study_preferences, :changed}`), which releases the idle
  loops, so it applies from the next question.
  """
  use Mob.Screen

  alias Bezalel.Agent.Live
  alias Bezalel.Settings
  alias Bezalel.Study.Prompt
  alias Bezalel.Views.Helpers
  alias MobBezalel.UI

  @applies "It applies from your next question."
  @saved "Saved. " <> @applies

  def mount(params, _session, socket) do
    prefs = Settings.study_preferences()

    {:ok,
     Mob.Socket.assign(socket,
       cover: Settings.cover(),
       app: params[:app],
       prefs: prefs,
       draft: prefs.approach || Prompt.default_approach(),
       toast: nil
     )}
  end

  def render(assigns) do
    sa = assigns[:safe_area] || %{top: 0, bottom: 0}
    back = UI.bar_button("Settings", {self(), :back}, assigns.cover)
    change = {self(), :approach}
    # Android's Material field pads its text itself.
    field_android = %{padding: 0, underline: false}
    always = Prompt.fixed(assigns.prefs) <> "\n" <> Live.phone_formatting()

    who =
      if assigns.prefs.approach,
        do: "Your own approach.",
        else: "Bezalel's default approach."

    buttons = ~MOB"""
    <Row gap={10} fill_width={true}>
      {UI.pill_button("Save", {self(), :save}, :primary, weight: 1, height: 44)}
      {UI.pill_button("Restore default", {self(), :restore}, :outline, weight: 1, height: 44)}
    </Row>
    """

    ~MOB"""
    <Box align="bottom" fill_width={true} fill_height={true} background={:background}>
      <Column background={:background} fill_width={true} fill_height={true}>
        {UI.top_bar("Approach", @cover, trailing: back)}
        <Scroll id="approach" weight={1} background={:background}>
          <Column
            padding_left={18}
            padding_right={18}
            padding_top={22}
            padding_bottom={28}
            gap={18}
            fill_width={true}
          >
            <Text text="Approach" font={:display} text_size={30} text_color={:on_background} />
            {body("How Bezalel reads and answers: who it is for, how it treats traditions and disputed questions, how it writes. Rewrite it to suit you; Bezalel follows it from your next question.", 14)}
            <Column gap={8} fill_width={true}>
              {UI.kicker(who)}
              {UI.card([~MOB(<TextField value={@draft} placeholder="How Bezalel should read and answer" on_change={change} lines={14} background={:surface} border_color={:surface} text_size={14} android={field_android} padding={4} />)], padding: 14)}
              {buttons}
            </Column>
            <Column gap={8} fill_width={true}>
              {UI.kicker("Always included")}
              {body("Bezalel's ground rules, its guide to the study tools you have on, and the phone's formatting. They go before your approach and can't be edited.", 13)}
              {UI.card([body(always, 12)], padding: 14)}
            </Column>
          </Column>
        </Scroll>
      </Column>
      {toast(@toast, sa.bottom)}
    </Box>
    """
  end

  defp toast(nil, _inset), do: []
  defp toast(toast, inset), do: Helpers.toast_box(toast.text, [], 24, inset)

  defp body(text, size),
    do: ~MOB(<Text text={text} text_size={size} line_height={1.5} text_color={:on_surface} />)

  def handle_info({:change, :approach, value}, socket),
    do: {:noreply, Mob.Socket.assign(socket, :draft, value)}

  # The default saved as it is stays the default (nil), so a later
  # version of it applies; a blank field restores the default.
  def handle_info({:tap, :save}, socket) do
    draft = String.trim(socket.assigns.draft)

    cond do
      draft == "" -> {:noreply, restore(socket)}
      draft == String.trim(Prompt.default_approach()) -> {:noreply, store(socket, nil, @saved)}
      true -> {:noreply, store(socket, socket.assigns.draft, @saved)}
    end
  end

  def handle_info({:tap, :restore}, socket), do: {:noreply, restore(socket)}
  def handle_info({:tap, :back}, socket), do: {:noreply, Mob.Socket.pop_screen(socket)}

  def handle_info({:toast_expire, ref}, socket) do
    case socket.assigns.toast do
      %{ref: ^ref} -> {:noreply, Mob.Socket.assign(socket, :toast, nil)}
      _ -> {:noreply, socket}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp restore(socket) do
    socket
    |> Mob.Socket.assign(:draft, Prompt.default_approach())
    |> store(nil, "Restored the default. " <> @applies)
  end

  defp store(socket, approach, text) do
    prefs = Settings.update_study_preferences(&%{&1 | approach: approach})
    if socket.assigns.app, do: send(socket.assigns.app, {:study_preferences, :changed})

    socket
    |> Mob.Socket.assign(:prefs, prefs)
    |> Helpers.toast(text)
  end
end
