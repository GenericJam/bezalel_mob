defmodule Bezalel.AttributionsScreen do
  @moduledoc """
  Sources and licences of the study library (bead `bezalel-e47.6`), from
  Settings → Study library: the modification notice, every source with the
  attribution string `data/SOURCES.md` gives verbatim and its licence and
  links, the credits for the summarised scholarship, studybible-mcp's MIT
  licence in full, and the ShareAlike note. Edit `data/SOURCES.md` and this
  together.
  """
  use Mob.Screen

  alias MobBezalel.UI

  @sources_md "https://github.com/GenericJam/bezalel_mob/blob/master/data/SOURCES.md"
  @readme_md "https://github.com/GenericJam/bezalel_mob/blob/master/data/README.md"
  @manifest "https://bezalel.genericjam.com/packs/manifest.json"

  @by "https://creativecommons.org/licenses/by/4.0/"
  @by_sa "https://creativecommons.org/licenses/by-sa/4.0/"
  @by_nc "https://creativecommons.org/licenses/by-nc/4.0/"
  @by_3 "https://creativecommons.org/licenses/by/3.0/"

  # The NET's acknowledgement, as bezalel_core quotes it (its terms ask for
  # it verbatim).
  @net Bezalel.Study.Translations.get("net")

  @notice "Modified for Bezalel: the sources below were converted into SQLite databases, " <>
            "selected and excerpted, reformatted (for example HTML to plain text), re-keyed to " <>
            "Bible references, indexed for search, and split into downloadable packs. Their " <>
            "wording is otherwise unchanged."

  # {title, attribution (verbatim from SOURCES.md), [{licence, url}], [links]}
  @sources [
    {"STEP Bible",
     "Hebrew and Greek texts, morphology, lexicons and proper names from STEP Bible (www.STEPBible.org), created by Tyndale House, Cambridge. CC BY 4.0. Modified.",
     [{"CC BY 4.0", @by}], ["https://www.STEPBible.org"]},
    {"Berean Standard Bible",
     "The Holy Bible, Berean Standard Bible, BSB is produced in cooperation with Bible Hub, Discovery Bible, unfoldingWord, Bible Aquifer, OpenBible.com, and the Berean Bible Translation Committee. This text of God's Word has been dedicated to the public domain.",
     [{"Public domain", nil}], ["https://bereanbible.com"]},
    {@net.name, @net.copyright,
     [
       {"Free non-commercial use by permission (netbible.com/copyright). The NET's translators' notes are not included.",
        nil}
     ], [@net.url]},
    {"Brown-Driver-Briggs",
     "Brown-Driver-Briggs Hebrew and English Lexicon (1906), public domain; digital edition by Eliran Wong.",
     [{"Public domain", nil}], ["https://github.com/eliranwong/unabridged-BDB-Hebrew-lexicon"]},
    {"Abbott-Smith",
     "G. Abbott-Smith, A Manual Greek Lexicon of the New Testament (1922), public domain; TEI edition by the Abbott-Smith project.",
     [{"Public domain", nil}], ["https://github.com/translatable-exegetical-tools/Abbott-Smith"]},
    {"OpenBible.info",
     "Cross references from OpenBible.info, CC BY 4.0, drawing primarily on the Treasury of Scripture Knowledge. Place coordinates from OpenBible.info Bible Geocoding, CC BY 4.0. Modified.",
     [{"CC BY 4.0", @by}],
     ["https://www.openbible.info/labs/cross-references/", "https://www.openbible.info/geo/"]},
    {"ACAI",
     "ACAI Biblical Entity Data © 2024 by BiblioNexus is licensed under CC BY-SA 4.0. Modified.",
     [{"CC BY-SA 4.0", @by_sa}], ["https://github.com/BibleAquifer/ACAI"]},
    {"Aquifer Open Study Notes",
     "Aquifer Open Study Notes © 2026 Mission Mutual, licensed under CC BY-SA 4.0. This work is an adaptation of Tyndale Open Study Notes © 2023 Tyndale House Publishers, licensed under CC BY-SA 4.0. Modified.",
     [{"CC BY-SA 4.0", @by_sa}], ["https://github.com/BibleAquifer/AquiferOpenStudyNotes"]},
    {"Aquifer Open Bible Dictionary",
     "Aquifer Open Bible Dictionary © 2026 Mission Mutual, licensed under CC BY-SA 4.0. This work is an adaptation of Tyndale Open Bible Dictionary © 2023 Tyndale House Publishers, licensed under CC BY-SA 4.0. Modified.",
     [{"CC BY-SA 4.0", @by_sa}], ["https://github.com/BibleAquifer/AquiferOpenBibleDictionary"]},
    {"unfoldingWord",
     "unfoldingWord® Translation Notes © 2022 unfoldingWord. Released under CC BY-SA 4.0. Modified.",
     [{"CC BY-SA 4.0", @by_sa}], ["https://github.com/BibleAquifer/UWTranslationNotes"]},
    {"SIL",
     "Open Translator's Notes © 2024 SIL International, licensed under CC BY-SA 4.0. Modified.",
     [{"CC BY-SA 4.0", @by_sa}], ["https://opentn.bible"]},
    {"FIA Key Terms",
     "Familiarization, Internalization, Articulation (FIA) Key Terms © 2025 Word Collective. Released under CC BY-SA 4.0. Modified.",
     [{"CC BY-SA 4.0", @by_sa}], ["https://github.com/BibleAquifer/FIAKeyTerms"]},
    {"Theographic", "Theographic Bible Metadata by Robert Rouse, CC BY-SA 4.0. Modified.",
     [{"CC BY-SA 4.0", @by_sa}],
     [
       "https://github.com/robertrouse/theographic-bible-metadata",
       "https://github.com/robertrouse/theographic-bible-metadata/blob/master/docs/data-source-bibliography.md"
     ]},
    {"Torah Weave",
     "Torah literary units dataset by Moshe Kline (chaver.com), CC BY 4.0. Modified.",
     [{"CC BY 4.0", @by}], ["https://chaver.com/torah-weave/"]},
    {"Septuagint",
     "LXX morphology data by Seth Kushniryk, CC BY 4.0, derived from Rahlfs Septuagint (Eliran Wong digital edition); versification mapping derived in part from TVTMS by STEPBible.org / Tyndale House Cambridge, CC BY 4.0. Rahlfs (1935) Greek text: public domain. Modified.",
     [{"CC BY 4.0", @by}, {"Public domain (Rahlfs text)", nil}],
     ["https://github.com/OpenScriptorium/lxx-morph"]},
    {"Brenton",
     "Sir Lancelot C. L. Brenton, The Septuagint with Apocrypha (1851), English and Greek, public domain, from eBible.org.",
     [{"Public domain", nil}], ["https://ebible.org/details.php?id=eng-Brenton"]},
    {"Josephus",
     "Josephus, Greek (Niese) and English (Whiston) from the Perseus Digital Library canonical-greekLit, CC BY-SA 4.0. Modified.",
     [{"CC BY-SA 4.0", @by_sa}], ["https://github.com/PerseusDL/canonical-greekLit"]},
    {"Philo",
     "Philo, Greek (Cohn–Wendland) and English (Yonge) from the First1KGreek project, CC BY-SA 4.0. Modified.",
     [{"CC BY-SA 4.0", @by_sa}], ["https://github.com/OpenGreekAndLatin/First1KGreek"]},
    {"Targum Onkelos",
     "Targum Onkelos, Aramaic text: public domain (Torat Emet); English: Metsudah Chumash, Metsudah Publications, 2009, CC BY-NC 4.0; both via Sefaria. Modified.",
     [{"CC BY-NC 4.0 (English)", @by_nc}, {"Public domain (Aramaic)", nil}],
     ["https://www.sefaria.org"]},
    {"Dead Sea Scrolls",
     "Dead Sea Scrolls (CD, 1QS, 1QSa and 1QpHab in the ancient pack; the scrolls pack's 30 major non-biblical works from 132 Qumran manuscripts and the biblical manuscripts' readings): transcription by Martin G. Abegg Jr., James E. Bowley and Edward M. Cook, ETCBC/dss, CC BY-NC 4.0. Modified. Manuscript names and script periods: the Leon Levy Dead Sea Scrolls Digital Library (Israel Antiquities Authority).",
     [{"CC BY-NC 4.0", @by_nc}], ["https://github.com/ETCBC/dss"]},
    {"Mishnah",
     "Mishnah, ed. Romm, Vilna 1913 (public domain); English: Joshua Kulp, Mishnah Yomit, CC BY 3.0; via Sefaria. Modified.",
     [{"CC BY 3.0 (English)", @by_3}, {"Public domain (Hebrew)", nil}],
     ["https://www.sefaria.org"]},
    {"1 Enoch",
     "1 Enoch, translated by R. H. Charles (1912), public domain, from English Wikisource.",
     [{"Public domain", nil}], ["https://en.wikisource.org"]},
    {"4 Ezra",
     "4 Ezra (2 Esdras 3–14): King James Version, from eBible.org; Latin: Clementine Vulgate from Latin Wikisource, CC BY-SA 4.0. Modified.",
     [{"CC BY-SA 4.0 (Latin)", @by_sa}, {"Public domain (English)", nil}],
     ["https://la.wikisource.org"]},
    {"studybible-mcp",
     "Study tools, ANE context, theology summaries, textual variants and editorial notes adapted from studybible-mcp, Copyright (c) 2024 Study Bible MCP Contributors, MIT License.",
     [{"MIT (full text below)", nil}], ["https://github.com/djayatillake/studybible-mcp"]}
  ]

  @scholarship [
    {"Michael S. Heiser",
     "Summaries of, and textual-variant analysis from, the published work of Michael S. Heiser, including 'Deuteronomy 32:8 and the Sons of God' (Bibliotheca Sacra, 2001), 'Monotheism, Polytheism, Monolatry, or Henotheism?' (Bulletin for Biblical Research, 2008), his articles in the Faithlife Study Bible and the Lexham Bible Dictionary, and the Naked Bible Podcast.",
     [], ["https://drmsh.com"]},
    {"John Stott",
     "Summaries of John Stott's The Cross of Christ, Basic Christianity, and The Message of Romans, Galatians, Ephesians, Acts and the Sermon on the Mount (The Bible Speaks Today), and Baptism and Fullness.",
     [], []},
    {"John Lennox",
     "Summaries of John Lennox's Seven Days That Divide the World, Against the Flow, Joseph, and Determined to Believe?",
     [], []},
    {"Bradley",
     "Summary of Bradley, 'Two Fathers Only: Rival Pater Familias and the Organizing Binary of Scripture'.",
     [], []},
    {"Andrew Remington Rillera",
     "Ancient Near East context entries summarising Andrew Remington Rillera, Lamb of the Free (Cascade Books, 2024), and the work of Jacob Milgrom on which it builds.",
     [], []},
    {"John Owen",
     "Summaries of John Owen's works (public domain), linking the texts at the Christian Classics Ethereal Library.",
     [], ["https://ccel.org/ccel/owen"]}
  ]

  # studybible-mcp's LICENSE at the pinned commit (38cef28d), the MIT part.
  @mit """
  MIT License

  Copyright (c) 2024 Study Bible MCP Contributors

  Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

  The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.\
  """

  def mount(_params, _session, socket) do
    {:ok, Mob.Socket.assign(socket, cover: Bezalel.Settings.cover())}
  end

  def render(assigns) do
    back = UI.bar_button("Settings", {self(), :back}, assigns.cover)

    sections = [
      section("Sources", Enum.map(@sources, &source/1)),
      section("Summaries of scholarship", [
        scholarship_intro() | Enum.map(@scholarship, &source/1)
      ]),
      section("studybible-mcp licence", [UI.card([body(@mit, 12)], padding: 16)])
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
        link("The study library's packs", @manifest),
        ~MOB(<Divider color={:border} />),
        body(@notice, 14),
        link("How the database is built", @readme_md),
        link("Every source, pinned, with its licence", @sources_md)
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
