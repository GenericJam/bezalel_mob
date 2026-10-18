defmodule Bezalel.AttributionsScreen do
  @moduledoc """
  Sources and licences of the study library (bead `bezalel-e47.6`), from
  Settings → Study library: the modification notice, every source with the
  attribution string `data/SOURCES.md` gives verbatim and its licence and
  links, the credits for the summarised scholarship, studybible-mcp's MIT
  licence in full, and the ShareAlike note. The data is bezalel_core's
  `Bezalel.Study.Credits` (shared with the website); edit `data/SOURCES.md`
  and it together.
  """
  use Mob.Screen

  alias Bezalel.Study.Credits
  alias MobBezalel.UI

  def mount(_params, _session, socket) do
    {:ok, Mob.Socket.assign(socket, cover: Bezalel.Settings.cover())}
  end

  def render(assigns) do
    back = UI.bar_button("Settings", {self(), :back}, assigns.cover)

    sections = [
      section("Sources", Enum.map(Credits.sources(), &source/1)),
      section("Summaries of scholarship", [
        scholarship_intro() | Enum.map(Credits.scholarship(), &source/1)
      ]),
      section("studybible-mcp licence", [UI.card([body(Credits.mit_licence(), 12)], padding: 16)])
    ]

    ~MOB"""
    <Column background={:background} fill_width={true} fill_height={true}>
      {UI.top_bar("Sources", @cover, trailing: back)}
      <Scroll id="attributions" weight={1} background={:background}>
        <Column
          padding_left={18}
          padding_right={18}
          padding_top={22}
          padding_bottom={28}
          gap={18}
          fill_width={true}
        >
          <Text
            text="Sources and licences"
            font={:display}
            text_size={30}
            text_color={:on_background}
          />
          {intro()}
          {sections}
        </Column>
      </Scroll>
    </Column>
    """
  end

  defp intro do
    UI.card(
      [
        body(
          "Bezalel's study library is built from the sources below. Bezalel is free, with no ads or purchases. The database packs are available under the licences of their sources, as plain files from the study library.",
          14
        ),
        link("The study library's packs", Credits.links().manifest),
        ~MOB(<Divider color={:border} />),
        body(Credits.notice(), 14),
        link("How the database is built", Credits.links().readme_md),
        link("Every source, pinned, with its licence", Credits.links().sources_md)
      ],
      padding: 16,
      gap: 10
    )
  end

  defp scholarship_intro do
    body(
      "studybible-mcp's own summaries (MIT, as above) of these authors' published work. No licence applies to them; these are credits.",
      13
    )
  end

  defp section(title, children) do
    ~MOB"""
    <Column gap={8} fill_width={true}>
      {UI.kicker(title)}
      {children}
    </Column>
    """
  end

  defp source({title, text, licences, links}) do
    licence_rows =
      for {label, url} <- licences do
        if url,
          do: link(label, url),
          else: ~MOB(<Text text={label} font={:ui_medium} text_size={13} text_color={:muted} />)
      end

    UI.card(
      [
        ~MOB(<Text text={title} font={:ui_medium} text_size={15} text_color={:on_surface} />),
        body(text, 13.5),
        licence_rows,
        Enum.map(links, &link(&1, &1))
      ],
      padding: 14,
      gap: 6
    )
  end

  defp body(text, size),
    do: ~MOB(<Text text={text} text_size={size} line_height={1.5} text_color={:on_surface} />)

  defp link(label, url) do
    tap = {self(), {:open, url}}

    ~MOB(<Text text={label} font={:ui_medium} text_size={13} text_color={:secondary} on_tap={tap} />)
  end

  def handle_info({:tap, :back}, socket), do: {:noreply, Mob.Socket.pop_screen(socket)}

  def handle_info({:tap, {:open, url}}, socket) do
    Rho.Config.open_url(url)
    {:noreply, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}
end
