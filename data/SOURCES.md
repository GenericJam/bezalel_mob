# Study database: sources and licences

The licence audit for Bezalel's study database (bead `bezalel-e47.1`). Bezalel is
free and non-commercial: no price, no ads, no in-app purchases, ever. On that
basis public domain, CC BY, CC BY-SA and CC BY-NC material is **in**. Material
still in copyright without a grant is **out**, with one exception decided by the
maintainer (Kevin, 2026-10-15): studybible-mcp's summaries of in-copyright
theological scholarship are **in**, while full texts of in-copyright works stay
out (section "Included by the maintainer's decision"). Audited at studybible-mcp
`38cef28dc2d7c1e834cbd5248edc0f65843e7819` (2026-10-14); every source below is
pinned in `pins.json` or by that commit's own download scripts.

The packs are built by `data/build.sh` (see `README.md`); `exclusions.json` lists
the files deleted before the build, and `scripts/check_packs.py` checks that none
of them shipped.

## In

| Source | Supplies (table → pack) | Where from (pin) | Licence |
|---|---|---|---|
| STEPBible TAHOT, TAGNT (Tyndale House Cambridge) | Hebrew OT and Greek NT word by word with morphology, Strong's numbers and English glosses (`verses`, `passages` → core) | github.com/STEPBible/STEPBible-Data @ `043ffd0a` (sha256 per file in studybible-mcp `download_stepbible.py`) | CC BY 4.0 |
| STEPBible TFLSJ (formatted full LSJ), TBESG, TBESH | Greek lexicon; brief Greek/Hebrew lexicons (`lexicon` → core) | same | CC BY 4.0 |
| STEPBible TIPNR | Proper names (`names` → core) | same | CC BY 4.0 |
| STEPBible TEGMC, TEHMC | Morphology codes (`morphology` → core) | same | CC BY 4.0 |
| Brown-Driver-Briggs, unabridged (1906), formatted by Eliran Wong | Hebrew lexicon (`lexicon` → core) | github.com/eliranwong/unabridged-BDB-Hebrew-lexicon @ `6e8326c6` | Public domain |
| G. Abbott-Smith, *A Manual Greek Lexicon of the NT* (1922), TEI by translatable-exegetical-tools | Greek lexicon enrichment (`lexicon` → core) | github.com/translatable-exegetical-tools/Abbott-Smith @ `4048093c` | Public domain |
| Berean Standard Bible | **The English the tools quote** when the user chooses the BSB, when the translations pack isn't on the phone, and for a book the chosen translation doesn't have (labelled BSB on that verse) (`bsb_verses` → core); also the text the similar-passage vectors are computed from | bereanbible.com/bsb.txt (sha256 pinned in studybible-mcp `parsers/bsb.py`) | Public domain (dedicated by the publisher) |
| NET Bible® (Biblical Studies Press, 2019 text) | **The English the tools quote by default** (`translations`, `translation_verses` → translations; built by bezalel_core's `data/`, `mix bezalel.data.net`). The verse text only: none of the NET's translators' notes | labs.bible.org/api (formatting=full, one request per book, each response sha256-pinned in bezalel_core `data/pins.json`) | **Free non-commercial use by permission** (netbible.com/copyright): "(NET)" after each quotation, NET linked to http://netbible.org, text unaltered, acknowledgement shown |
| JPS 1917, *The Holy Scriptures according to the Masoretic Text* (Jewish Publication Society of America), eBible.org's USFM | The English the tools quote when the user chooses the JPS; Old Testament only (`translation_verses` → translations). eBible's inline Hebrew verse numbers removed, the Psalm titles numbered verse 0 | eBible.org/Scriptures/engjps_usfm.zip (sha256 in bezalel_core `data/pins.json` → `jps`) | Public domain |
| Literal Text (ULT, adapted), from unfoldingWord® Literal Text, Door43 release v91 | The English the tools quote when the user chooses the ULT; the books released so far (not Numbers, 1–2 Chronicles, Ecclesiastes, Isaiah, Jeremiah or Ezekiel) (`translation_verses` → translations). Word alignment, footnotes and headings removed; shown without the unfoldingWord® trademark, as its licence asks | git.door43.org/unfoldingWord/en_ult @ `35d21595` (tag v91; sha256 per file in `data/pins.json` → `ult`) | CC BY-SA 4.0 |
| Simplified Text (UST, adapted), from unfoldingWord® Simplified Text, Door43 release v91 | The English the tools quote when the user chooses the UST; the same released books as the ULT (`translation_verses` → translations). Changed as the ULT | git.door43.org/unfoldingWord/en_ust @ `85f274a7` (tag v91; sha256 per file in `data/pins.json` → `ust`) | CC BY-SA 4.0 |
| OpenBible.info cross references (Treasury of Scripture Knowledge plus votes) | `cross_references` → core (`type = 'tsk'`) | a.openbible.info/data/cross-references.zip, file dated 2026-10-12, vendored as `vendor/openbible-cross-references-2026-10-12.txt.zst` (the published file is regenerated in place) | CC BY 4.0 |
| ACAI Biblical Entity Data (BiblioNexus, via BibleAquifer) | People, places, groups, key terms (`acai_entities` → core) | github.com/BibleAquifer/ACAI @ `7e6a2d66` | CC BY-SA 4.0 |
| Torah Weave, Moshe Kline | Literary units of the Torah (`torah_weave_units`, `torah_weave_cells` → core) | `data/torah_weave/torah-units.json` in studybible-mcp (from chaver.com) | CC BY 4.0 |
| studybible-mcp (David Jayatillake and contributors) | The thematic cross-references (`thematic_references` → core), the schema, and the project's own prose below | github.com/djayatillake/studybible-mcp @ `38cef28d` | MIT |
| Similar verses and passages (computed here) | `similar_verses`, `similar_passages` → core | Vectors from BAAI/bge-small-en-v1.5 @ `5c38ec7c` (MIT model; the model is not shipped) over the BSB text | Derived from public-domain text; no attribution required |
| Aquifer Open Study Notes (Mission Mutual, adapted from Tyndale Open Study Notes) | `aquifer_content` (`study_notes`) → notes | github.com/BibleAquifer/AquiferOpenStudyNotes @ `bbb3f860` | CC BY-SA 4.0 |
| Aquifer Open Bible Dictionary (Mission Mutual, adapted from Tyndale Open Bible Dictionary) | `aquifer_content` (`dictionary`) → notes | github.com/BibleAquifer/AquiferOpenBibleDictionary @ `4d92a9ac` | CC BY-SA 4.0 |
| unfoldingWord Translation Notes | `aquifer_content` (`translation_notes_uw`) → notes | github.com/BibleAquifer/UWTranslationNotes @ `dbfb46e0` | CC BY-SA 4.0 |
| SIL Open Translator's Notes | `aquifer_content` (`translation_notes_sil`) → notes | github.com/BibleAquifer/SILOpenTranslatorsNotes @ `0ba58c29` | CC BY-SA 4.0 |
| FIA Key Terms (Word Collective) | `aquifer_content` (`key_terms`) → notes | github.com/BibleAquifer/FIAKeyTerms @ `91e4a774` | CC BY-SA 4.0 |
| ANE context entries (studybible-mcp, original summary prose naming standard reference works) | `ane_entries`, `ane_book_mappings` → notes (all 120 entries; the 18 drawn from *Lamb of the Free* are listed under the maintainer's decision) | `data/ane_context/` in studybible-mcp | MIT |
| John Owen (d. 1683), summaries written for studybible-mcp, linking CCEL texts | `theology_*` → notes (45 entries) | `data/owen/` | Owen's works: public domain; summaries: MIT |
| Theme taxonomies (studybible-mcp) | `theology_themes` → notes | `data/heiser/themes.json`, `data/bradley/themes.json`, `data/synthesis/themes.json`, `data/reformed_evangelical/themes.json` | MIT |
| Rahlfs Septuagint (1935) morphology, OpenScriptorium lxx-morph (Seth Kushniryk, from Eliran Wong's digital edition), with its `verse_pairs.jsonl` mapping derived in part from STEPBible TVTMS | LXX text and morphology (`biblical_version_verses` → lxx) | github.com/OpenScriptorium/lxx-morph @ `c91f6b1e` (blob hashes pinned in studybible-mcp) | Morphology and mapping: CC BY 4.0; Rahlfs text: public domain |
| Brenton, *The Septuagint with Apocrypha* (1851), English and Greek, from eBible.org | `biblical_version_verses` → lxx | ebible.org eng-Brenton, grcbrent (sha256 per book pinned in studybible-mcp) | Public domain |
| Josephus, Perseus canonical-greekLit (Niese Greek, Whiston English, TEI) | `ancient_source_*` → ancient | github.com/PerseusDL/canonical-greekLit @ `01b725d8` | CC BY-SA 4.0 |
| Philo, First1KGreek (Cohn–Wendland Greek, Yonge English, TEI) | `ancient_source_*` → ancient | github.com/OpenGreekAndLatin/First1KGreek @ `03776b39` | CC BY-SA 4.0 |
| Targum Onkelos (Sefaria): Aramaic (Torat Emet) | `ancient_source_*` → ancient | github.com/Sefaria/Sefaria-Export-Archive @ `3f101363` | Public domain |
| Targum Onkelos English: Metsudah Chumash (Metsudah Publications, 2009), via Sefaria | `ancient_source_*` → ancient | same | **CC BY-NC 4.0** |
| Dead Sea Scrolls CD, 1QS, 1QSa, 1QpHab: ETCBC/dss (Abegg, Bowley, Cook) | `ancient_source_*` → ancient | github.com/ETCBC/dss @ `47ecc173` | **CC BY-NC 4.0** |
| Dead Sea Scrolls, the scrolls pack: 30 major non-biblical works (132 Qumran manuscripts) and the biblical manuscripts' readings, ETCBC/dss (Abegg, Bowley, Cook); built by bezalel_core's `data/` (`mix bezalel.data.scrolls`). No English translation | `ancient_source_*` (corpus `qumran`), `dss_biblical_manuscripts`, `dss_biblical_verses` → scrolls | github.com/ETCBC/dss @ `47ecc173` (v2.0.1; files sha256-pinned in bezalel_core `data/pins.json`) | **CC BY-NC 4.0**. Manuscript names and script periods: the Leon Levy Dead Sea Scrolls Digital Library (IAA) (facts, no licence) |
| Mishnah: Vilna (Romm, 1913) Hebrew; Joshua Kulp's *Mishnah Yomit* English, via Sefaria | `ancient_source_*` → ancient | Sefaria-Export-Archive @ `3f101363` | Hebrew: public domain; English: CC BY (3.0) |
| 1 Enoch: R. H. Charles (1912/1917), English Wikisource | `ancient_source_*` → ancient | Wikisource revisions pinned in studybible-mcp | Public domain |
| 4 Ezra: KJV Apocrypha (eBible.org eng-kjv) and Clementine Vulgate Latin (Latin Wikisource rev. 148869) | `ancient_source_*` → ancient | sha256/revision pinned in studybible-mcp | English: public domain (see note on the KJV); Latin transcription: CC BY-SA 4.0 |
| Ancient-source editorial notes and biblical links (studybible-mcp) | `ancient_source_notes`, `ancient_source_biblical_links` → ancient | `src/study_bible_mcp/corpora/` | MIT |
| Theographic Bible Metadata (Robert Rouse) | People, places, events, family edges, verse mentions (`graph_*` → graph) | github.com/robertrouse/theographic-bible-metadata @ `52e049ef` (People, Places, Events, PeopleGroups CSVs). Its rows carry Easton's Bible Dictionary text (1897, public domain) and OpenBible.info Bible Geocoding coordinates (CC BY 4.0) | CC BY-SA 4.0 |
| DT-UCPH/sp, Text-Fabric Dataset of the Samaritan Pentateuch (Højgaard, Naaijer & Schorch) | Samaritan Pentateuch consonantal text, Genesis–Deuteronomy (`sp_verses` → witnesses) | github.com/DT-UCPH/sp @ `6da31aa` (tag v7.2.4; sha256 per file in bezalel_core `data/pins.json` → `sp`) | **CC BY-NC 4.0** |
| SBL Greek New Testament and its apparatus (Faithlife/SBLGNT) | Greek NT text and the apparatus's variation units (`sblgnt_verses`, `sblgnt_apparatus` → witnesses) | github.com/Faithlife/SBLGNT @ `c4d241a` (sha256 per file in `data/pins.json` → `sblgnt`) | CC BY 4.0 |
| UBS Hebrew Old Testament Text Project (HOTTP), Preliminary and Interim Report | Text-critical entries: readings, ratings, factors, English (`hottp_*` → witnesses) | github.com/ubsicap/ubs-open-license @ `a15a96c` `HOTTP/` (sha256 in `data/pins.json` → `hottp`) | CC BY-SA 4.0 |
| Open Apostolic Fathers 1.0 (James Tauber and Seumas Macdonald, 2019), a corrected text of Kirsopp Lake's edition (1912–1913) | The Apostolic Fathers' Greek (and Latin), 18 works (`ancient_source_*`, corpus `apostolic_fathers` → fathers) | github.com/jtauber/apostolic-fathers @ `a07f9207` `texts/` (sha256 per file in `data/pins.json` → `fathers.greek`) | CC BY-SA 4.0 |
| CAFE, the Contemporary Apostolic Fathers Edition (James Cuénod, 2024): **a machine translation** drafted with GPT-4o | The English beside each Greek line, labelled a machine translation wherever it is shown (`ancient_source_*` → fathers) | github.com/jcuenod/CAFE @ `06b19aec` (sha256 per file in `data/pins.json` → `fathers.english`) | CC BY-SA 4.0 |
| UBS Dictionary of Biblical Hebrew (v0.9.4) and UBS Dictionary of the Greek New Testament (v1.1), English, with their semantic domains | Senses, glosses and domains by Strong's number (`dictionary_*` → dictionaries) | github.com/ubsicap/ubs-open-license @ `a15a96cf` `dictionaries/` (sha256 per file in `data/pins.json` → `ubs_dictionaries`) | CC BY-SA 4.0 |
| Clear-Bible MACULA Hebrew (WLC) and Greek (SBLGNT) Linguistic Datasets, the lowfat syntax trees | Clause structure per verse: each clause's subject, verb, object… with their words (`syntax_*` → syntax). The UBS semantic attributes MACULA uses by permission, and the SIL Hebrew glosses (SILHA), are not imported | github.com/Clear-Bible/macula-hebrew @ `47db250b`, github.com/Clear-Bible/macula-greek @ `8423afe4` (sha256 per file in bezalel_core `data/macula_files.json`, from `data/pins.json` → `macula`) | CC BY 4.0 (WLC text and Berean glosses: public domain) |

The `ancient_source_passages` rows carry their own `edition`, `license`,
`original_license`, `translation_license` and source URL, so the app can show the
right credit beside each passage.

## Included by the maintainer's decision

No licence grant. These are studybible-mcp's own summaries (MIT as code and prose),
written from the authors' published books, papers and podcasts; they describe the
authors' arguments, sometimes quoting a sentence. Kevin decided on 2026-10-15 to
include them. The full texts they were written from are not included (see Out,
and the full-text check in `check_packs.py`).

| Author and works | Supplies (table → pack) | Where from |
|---|---|---|
| Michael S. Heiser: summaries of 17 papers, dictionary articles and Naked Bible Podcast episodes (e.g. "Deuteronomy 32:8 and the Sons of God", *Bibliotheca Sacra* 158, 2001; "Monotheism, Polytheism, Monolatry, or Henotheism?", *BBR* 18.1, 2008; *Faithlife Study Bible* and *Lexham Bible Dictionary* articles; ETS 2010 and SBL 2012 papers on Psalm 82), with links to the copies he posted; his theme taxonomy | `theology_content`, `theology_verse_index`, `theology_themes`, `theology_theme_index` → notes (46 entries) | `data/heiser/content/*.json`, `data/heiser/themes.json` |
| Michael S. Heiser: the textual-variant dataset: 30 MT/LXX/DSS cases with readings, witnesses and dates, an unsourced consensus summary, his analysis, and his "Heiser Literal Translation" decisions; 22 NT→OT LXX-form quotation hints | `textual_variant_*`, `textual_*`, `nt_ot_lxx_quote_hints` → notes (used by `get_textual_variant` and `lookup_verse`'s cues) | `data/heiser/variants/*.json`, `data/heiser/lxx_quote_hints.json` |
| John Stott: summaries of *The Cross of Christ*, *Basic Christianity*, and *The Message of* Romans, Galatians, Ephesians, Acts (with *Baptism and Fullness*) and the Sermon on the Mount (Bible Speaks Today) | `theology_*` → notes (62 entries) | `data/stott/content/*.json`, `data/reformed_evangelical/themes.json` |
| John Lennox: summaries of *Seven Days That Divide the World*, *Against the Flow* (Daniel), *Joseph* and *Determined to Believe?* | `theology_*` → notes (23 entries) | `data/lennox/content/*.json` |
| Bradley: summary of the paper "Two Fathers Only: Rival Pater Familias and the Organizing Binary of Scripture" | `theology_*` → notes (12 entries) | `data/bradley/` |
| Andrew Remington Rillera, *Lamb of the Free* (Cascade, 2024), building on Jacob Milgrom: 18 ANE entries (`relig_012`–`relig_021`, `legal_009`, `death_008`, `gender_008`, `cosmo_015`, `method_005`–`method_008`) and additions to `relig_008` and `cosmo_013` | `ane_entries`, `ane_book_mappings` → notes | `data/ane_context/` (from `ingest_lamb_of_free.py`, `ingest_atonement_synthesis.py`) |
| Atonement synthesis (studybible-mcp), drawing on Bradley and Rillera | `theology_*` → notes (2 entries) | `data/synthesis/` |

## Out

| Source | What it is | Why out |
|---|---|---|
| Full texts in `data/heiser/content/*.txt` | 26 files: Heiser's papers and Naked Bible Podcast transcripts in full (`monotheism_divine_plurality.txt` carries "Copyright 2008 The Institute for Biblical Research. All rights reserved.") | In copyright, no grant. studybible-mcp's importer reads only the `*.json` summaries; `scripts/prune.py` deletes the `.txt` files before the build anyway, and `check_packs.py` checks that no more than 20% of any of them appears in the notes pack (the summaries quote at most 8%) |
| Burnett, "So Shall Your Seed Be" (JSPL 5.2, 2015), and the Bradley/Gage John–Revelation spreadsheet | `ingest_burnett_gage.py` reads `data/Burnett-JSPL5.2.pdf` and `data/bradley_gage_john_rev.xlsx` | Absent from the repository at the pin, so they can't be built; the hosted database's 3 Burnett entries and 2,088 `gage`/`burnett` cross references are not in our packs |
| Harrison–Römhild cross references (`CH-CrossReference.xlsx`) | 57,614 `cross_references` rows (`type = 'ch'`) in the hosted database | No licence stated; the file is "requested from Robert Rouse / Viz.Bible", not published. Not obtainable from the pin |
| OpenAI embeddings (`verse_vectors`, `passage_vectors`) | `text-embedding-3-small` vectors of the STEPBible gloss text in the hosted database | Not licence-blocked, but not reproducible (an OpenAI key, a paid API, non-deterministic output, and the vectors in the hosted file can't be pinned). Replaced by `similar_verses`/`similar_passages`, computed here |

Tables in the hosted `study_bible.db` that no script at the pin builds, and which
are therefore not in our packs: `hlt_verses`, `hlt_annotations`,
`hlt_study_notes` (a draft "Heiser Literal Translation" with Heiser-derived notes)
and `verse_comparison_scores` (LLM-assigned scores).

## Attribution the app must show

The attributions screen (bead `bezalel-e47.6`; its data is bezalel_core's
`Bezalel.Study.Credits`, edit it with this file) shows these, each with its link and
licence link (https://creativecommons.org/licenses/by/4.0/,
https://creativecommons.org/licenses/by-sa/4.0/,
https://creativecommons.org/licenses/by-nc/4.0/; the Mishnah English is CC BY 3.0,
https://creativecommons.org/licenses/by/3.0/). CC BY, BY-SA and BY-NC require
credit, a licence link, and an indication of our changes while keeping any earlier
ones (Aquifer's adaptation notices stay as written). Public-domain credits are
courtesy.

Above the list, the screen shows this modification notice, which covers every
CC-licensed item:

> Modified for Bezalel: the sources below were converted into SQLite databases,
> selected and excerpted, reformatted (for example HTML to plain text), re-keyed to
> Bible references, indexed for search, and split into downloadable packs. Their
> wording is otherwise unchanged.

The notice links to how the database is built:
https://github.com/GenericJam/bezalel_mob/blob/master/data/README.md

Each string below also ends with "Modified." where the source is CC-licensed
(the ULT's and UST's say instead what changed, as their licence asks).
Strings to use verbatim:

1. **STEP Bible** — "Hebrew and Greek texts, morphology, lexicons and proper names
   from STEP Bible (www.STEPBible.org), created by Tyndale House, Cambridge.
   CC BY 4.0. Modified." Link: https://www.STEPBible.org
   (STEPBible asks for credit "to 'STEP Bible' linked to www.STEPBible.org".)
2. **Berean Standard Bible** — "The Holy Bible, Berean Standard Bible, BSB is
   produced in cooperation with Bible Hub, Discovery Bible, unfoldingWord, Bible
   Aquifer, OpenBible.com, and the Berean Bible Translation Committee. This text of
   God's Word has been dedicated to the public domain." Link: https://bereanbible.com
3. **Brown-Driver-Briggs** — "Brown-Driver-Briggs Hebrew and English Lexicon
   (1906), public domain; digital edition by Eliran Wong."
   Link: https://github.com/eliranwong/unabridged-BDB-Hebrew-lexicon
4. **Abbott-Smith** — "G. Abbott-Smith, A Manual Greek Lexicon of the New
   Testament (1922), public domain; TEI edition by the Abbott-Smith project."
   Link: https://github.com/translatable-exegetical-tools/Abbott-Smith
5. **OpenBible.info** — "Cross references from OpenBible.info, CC BY 4.0, drawing
   primarily on the Treasury of Scripture Knowledge. Place coordinates from
   OpenBible.info Bible Geocoding, CC BY 4.0. Modified." Links:
   https://www.openbible.info/labs/cross-references/ and https://www.openbible.info/geo/
6. **ACAI** — "ACAI Biblical Entity Data © 2024 by BiblioNexus is licensed under
   CC BY-SA 4.0. Modified." Link:
   https://github.com/BibleAquifer/ACAI
7. **Aquifer Open Study Notes** — "Aquifer Open Study Notes © 2026 Mission Mutual,
   licensed under CC BY-SA 4.0. This work is an adaptation of Tyndale Open Study
   Notes © 2023 Tyndale House Publishers, licensed under CC BY-SA 4.0. Modified."
   Link: https://github.com/BibleAquifer/AquiferOpenStudyNotes
8. **Aquifer Open Bible Dictionary** — "Aquifer Open Bible Dictionary © 2026
   Mission Mutual, licensed under CC BY-SA 4.0. This work is an adaptation of
   Tyndale Open Bible Dictionary © 2023 Tyndale House Publishers, licensed under
   CC BY-SA 4.0. Modified." Link: https://github.com/BibleAquifer/AquiferOpenBibleDictionary
9. **unfoldingWord** — "unfoldingWord® Translation Notes © 2022 unfoldingWord.
   Released under CC BY-SA 4.0. Modified." Link: https://github.com/BibleAquifer/UWTranslationNotes
10. **SIL** — "Open Translator's Notes © 2024 SIL International, licensed under
    CC BY-SA 4.0. Modified." Link: https://opentn.bible
11. **FIA Key Terms** — "Familiarization, Internalization, Articulation (FIA) Key
    Terms © 2025 Word Collective. Released under CC BY-SA 4.0. Modified."
    Link: https://github.com/BibleAquifer/FIAKeyTerms
12. **Theographic** — "Theographic Bible Metadata by Robert Rouse, CC BY-SA 4.0.
    Modified." Link:
    https://github.com/robertrouse/theographic-bible-metadata (its README asks
    users also to credit the original sources listed in its
    `docs/data-source-bibliography.md`; linking that file satisfies it).
13. **Torah Weave** — "Torah literary units dataset by Moshe Kline (chaver.com),
    CC BY 4.0. Modified." Link: https://chaver.com/torah-weave/
14. **Septuagint** — "LXX morphology data by Seth Kushniryk, CC BY 4.0, derived
    from Rahlfs Septuagint (Eliran Wong digital edition); versification mapping
    derived in part from TVTMS by STEPBible.org / Tyndale House Cambridge,
    CC BY 4.0. Rahlfs (1935) Greek text: public domain. Modified." Link:
    https://github.com/OpenScriptorium/lxx-morph
15. **Brenton** — "Sir Lancelot C. L. Brenton, The Septuagint with Apocrypha
    (1851), English and Greek, public domain, from eBible.org."
    Link: https://ebible.org/details.php?id=eng-Brenton
16. **Josephus** — "Josephus, Greek (Niese) and English (Whiston) from the Perseus
    Digital Library canonical-greekLit, CC BY-SA 4.0. Modified." Link:
    https://github.com/PerseusDL/canonical-greekLit
17. **Philo** — "Philo, Greek (Cohn–Wendland) and English (Yonge) from the
    First1KGreek project, CC BY-SA 4.0. Modified." Link:
    https://github.com/OpenGreekAndLatin/First1KGreek
18. **Targum Onkelos** — "Targum Onkelos, Aramaic text: public domain (Torat
    Emet); English: Metsudah Chumash, Metsudah Publications, 2009, CC BY-NC 4.0;
    both via Sefaria. Modified." Link: https://www.sefaria.org
19. **Dead Sea Scrolls** — "Dead Sea Scrolls (CD, 1QS, 1QSa and 1QpHab in the
    ancient pack; the scrolls pack's 30 major non-biblical works from 132 Qumran
    manuscripts and the biblical manuscripts' readings): transcription by Martin
    G. Abegg Jr., James E. Bowley and Edward M. Cook, ETCBC/dss, CC BY-NC 4.0.
    Modified. Manuscript names and script periods: the Leon Levy Dead Sea Scrolls
    Digital Library (Israel Antiquities Authority)."
    Link: https://github.com/ETCBC/dss
20. **Mishnah** — "Mishnah, ed. Romm, Vilna 1913 (public domain); English: Joshua
    Kulp, Mishnah Yomit, CC BY 3.0; via Sefaria. Modified." Links:
    https://www.sefaria.org and https://creativecommons.org/licenses/by/3.0/
21. **1 Enoch** — "1 Enoch, translated by R. H. Charles (1912), public domain,
    from English Wikisource."
22. **4 Ezra** — "4 Ezra (2 Esdras 3–14): King James Version, from eBible.org;
    Latin: Clementine Vulgate from Latin Wikisource, CC BY-SA 4.0. Modified."
    Link: https://la.wikisource.org
23. **studybible-mcp** — "Study tools, ANE context, theology summaries, textual
    variants and editorial notes adapted from studybible-mcp, Copyright (c) 2024
    Study Bible MCP Contributors, MIT License." The MIT notice must accompany
    copies of substantial portions: include the full MIT licence text from the
    studybible-mcp `LICENSE` file on the attributions screen.
24. **NET Bible** — "Scripture quoted by permission. Quotations designated (NET)
    are from the NET Bible® copyright ©1996, 2019 by Biblical Studies Press,
    L.L.C. http://netbible.com All rights reserved." (verbatim, as bezalel_core's
    `Translations.get("net").copyright`). Licence line: "Free non-commercial use
    by permission (netbible.com/copyright). The NET's translators' notes are not
    included." Link: http://netbible.org
25. **Samaritan Pentateuch** — "The Samaritan Pentateuch: Christian Canu
    Højgaard, Martijn Naaijer and Stefan Schorch, Text-Fabric Dataset of the
    Samaritan Pentateuch (Zenodo, 2023, doi:10.5281/zenodo.7734632), DT-UCPH/sp,
    CC BY-NC 4.0; the text of MS Dublin Chester Beatty Library 751 and MS
    Garizim 1 as transcribed by the Samaritanus project (Stefan Schorch, Halle).
    Modified." Links: https://github.com/DT-UCPH/sp and
    https://doi.org/10.5281/zenodo.7734632
26. **SBL Greek New Testament** — "The SBL Greek New Testament and its
    apparatus, copyright 2010 by the Society of Biblical Literature and Logos
    Bible Software, CC BY 4.0, from Faithlife/SBLGNT. Modified." Links:
    https://sblgnt.com and https://github.com/Faithlife/SBLGNT
27. **Hebrew Old Testament Text Project** — "Preliminary and Interim Report on
    the Hebrew Old Testament Text Project (HOTTP), © United Bible Societies
    1973-1980, 2003-2023, CC BY-SA 4.0, from ubsicap/ubs-open-license (the
    English text). Modified." Link:
    https://github.com/ubsicap/ubs-open-license/tree/main/HOTTP
28. **JPS 1917** — "The Holy Scriptures according to the Masoretic Text: A New
    Translation (Jewish Publication Society of America, 1917), public domain,
    from eBible.org. Modified: eBible's inline Hebrew verse numbers removed and
    the Psalm titles numbered verse 0." Link:
    https://ebible.org/find/details.php?id=engjps
29. **Literal Text (ULT, adapted)** — "Literal Text (ULT, adapted): adapted from
    a work copyright © 2022 by unfoldingWord, licensed CC BY-SA 4.0
    (https://creativecommons.org/licenses/by-sa/4.0/). The original work by
    unfoldingWord is available from unfoldingword.org/ult. Changes: the word
    alignment, footnotes and headings are removed, the Psalm titles numbered
    verse 0 and 2 Corinthians 13:13 numbered 13:14; the verse text is otherwise
    unaltered. This adaptation is available under the same licence." (verbatim,
    as bezalel_core's `Translations.get("ult").copyright`). Links:
    https://www.unfoldingword.org/ult and https://git.door43.org/unfoldingWord/en_ult
30. **Simplified Text (UST, adapted)** — "Simplified Text (UST, adapted):
    adapted from a work copyright © 2022 by unfoldingWord, licensed CC BY-SA 4.0
    (https://creativecommons.org/licenses/by-sa/4.0/). The original work by
    unfoldingWord is available from unfoldingword.org/ust. Changes: the word
    alignment, footnotes and headings are removed, the Psalm titles numbered
    verse 0 and 2 Corinthians 13:13 numbered 13:14; the verse text is otherwise
    unaltered. This adaptation is available under the same licence." (verbatim,
    as `Translations.get("ust").copyright`). Links:
    https://www.unfoldingword.org/ust and https://git.door43.org/unfoldingWord/en_ust
31. **Apostolic Fathers** — "The Apostolic Fathers: Greek (and Latin) text from
    Open Apostolic Fathers 1.0, edited by James Tauber and Seumas Macdonald
    (2019), a corrected text of Kirsopp Lake's edition (1912–1913),
    doi:10.5281/zenodo.2555673, CC BY-SA 4.0; English from CAFE, the
    Contemporary Apostolic Fathers Edition by James Cuénod (2024), a machine
    translation drafted with GPT-4o, CC BY-SA 4.0. Modified." Links:
    https://github.com/jtauber/apostolic-fathers and https://github.com/jcuenod/CAFE
32. **UBS Dictionary of Biblical Hebrew** — "UBS Dictionary of Biblical Hebrew
    © United Bible Societies, 2023. Adapted from Semantic Dictionary of Biblical
    Hebrew © 2000-2023 United Bible Societies. Licensed under CC BY-SA 4.0.
    Modified." Links:
    https://translation.bible/tools-resources/ubs-dictionary-of-biblical-hebrew/
    and https://github.com/ubsicap/ubs-open-license/tree/main/dictionaries/hebrew
33. **UBS Dictionary of the Greek New Testament** — "UBS Dictionary of New
    Testament Greek, © United Bible Societies, 2023. Adapted from Semantic
    Dictionary of Biblical Greek: © United Bible Societies 2018-2023, which is
    adapted from Greek-English Lexicon of the New Testament: Based on Semantic
    Domains, Eds. J P Louw, Eugene Albert Nida © United Bible Societies 1988,
    1989. Licensed under CC BY-SA 4.0. Modified." Links:
    https://translation.bible/tools-resources/ubs-dictionary-of-the-greek-new-testament/
    and https://github.com/ubsicap/ubs-open-license/tree/main/dictionaries/greek
34. **MACULA syntax trees** — "Clause structure from the MACULA Hebrew
    Linguistic Datasets, available at https://github.com/Clear-Bible/macula-hebrew/,
    and the MACULA Greek Linguistic Datasets, available at
    https://github.com/Clear-Bible/macula-greek/, © 2022-2024 Biblica, Inc, CC BY
    4.0: syntax trees of the Westminster Leningrad Codex (public domain) with the
    Westminster Hebrew Syntax (J. Alan Groves Center for Advanced Biblical
    Research, CC BY 4.0), OpenScriptures Hebrew Bible morphology (CC BY 4.0) and
    Cherith glosses (Andi Wu, Cherith Analytics, CC BY 4.0); and of the SBL Greek
    New Testament (Society of Biblical Literature and Logos Bible Software, CC BY
    4.0) with Berean Interlinear Bible glosses (public domain) and Cherith glosses
    (CC BY 4.0). The United Bible Societies' semantic data MACULA uses by
    permission, and the SIL Hebrew glosses (SILHA) it carries, are not included.
    Modified." Links: https://github.com/Clear-Bible/macula-hebrew and
    https://github.com/Clear-Bible/macula-greek

Under a heading such as "Summaries of scholarship", the screen also credits the
authors whose work studybible-mcp summarises (no licence applies; these are
credits, and the summaries are studybible-mcp's own words):

35. **Michael S. Heiser** — "Summaries of, and textual-variant analysis from, the
    published work of Michael S. Heiser, including 'Deuteronomy 32:8 and the Sons
    of God' (Bibliotheca Sacra, 2001), 'Monotheism, Polytheism, Monolatry, or
    Henotheism?' (Bulletin for Biblical Research, 2008), his articles in the
    Faithlife Study Bible and the Lexham Bible Dictionary, and the Naked Bible
    Podcast." Link: https://drmsh.com
36. **John Stott** — "Summaries of John Stott's The Cross of Christ, Basic
    Christianity, and The Message of Romans, Galatians, Ephesians, Acts and the
    Sermon on the Mount (The Bible Speaks Today), and Baptism and Fullness."
37. **John Lennox** — "Summaries of John Lennox's Seven Days That Divide the World,
    Against the Flow, Joseph, and Determined to Believe?"
38. **Bradley** — "Summary of Bradley, 'Two Fathers Only: Rival Pater Familias and
    the Organizing Binary of Scripture'."
39. **Andrew Remington Rillera** — "Ancient Near East context entries summarising
    Andrew Remington Rillera, Lamb of the Free (Cascade Books, 2024), and the work
    of Jacob Milgrom on which it builds."
40. **John Owen** — "Summaries of John Owen's works (public domain), linking the
    texts at the Christian Classics Ethereal Library." Link: https://ccel.org/ccel/owen

## Obligations that follow

- **Non-commercial (CC BY-NC):** the Dead Sea Scrolls and the Metsudah English are
  in the ancient pack, the whole scrolls pack is the Dead Sea Scrolls, and the
  Samaritan Pentateuch (DT-UCPH/sp) is in the witnesses pack, its credit shown
  with every reading. Bezalel is free with no ads (Decisions, 3); if that ever
  changed, those two would have to come out of the ancient pack, the Samaritan
  Pentateuch out of the witnesses pack, and the scrolls pack be withdrawn, first.
- **NET Bible (permission, non-commercial):** quoted under the publisher's
  permission for free non-commercial use (netbible.com/copyright). Every quotation
  is followed by "(NET)", in software on the internet with "NET" linked to
  http://netbible.org (the tools label it so, the passage card links it); the text
  is not altered; the acknowledgement above is shown on the attributions screen.
  The translators' notes are not licensed and are not in the pack. As with BY-NC,
  if Bezalel ever charged or carried ads, the NET would have to come out first.
- **ShareAlike (CC BY-SA):** our adapted versions (the pack tables holding ACAI,
  Aquifer, Theographic, Josephus, Philo, the Latin 4 Ezra, the ULT and UST, the
  HOTTP, the Apostolic Fathers' Greek and CAFE's English, and the UBS
  dictionaries) must be offered under CC BY-SA 4.0. Each pack file is a
  collection of separately licensed tables and rows, so the BY-SA and BY-NC
  material are not merged into one adaptation. Say on the attributions screen
  that the database packs are available under the licences of their sources,
  and keep the packs downloadable as plain files (they are, from the hosting in
  `bezalel-e47.5`), which also keeps them outside app-store DRM. The ULT and UST
  are shown without the unfoldingWord® trademark and with what changed, as their
  licence asks (strings 29 and 30).
- **Machine translation:** CAFE's English of the Apostolic Fathers is GPT-4o's,
  published without systematic human revision. Every place it is shown says it
  is a machine translation (the tools' passage labels, and the apps' Sources
  lists mark the citation "Machine translation (AI-generated)"), so it is never
  passed off as a human translator's.
- **KJV in the United Kingdom:** the Authorized Version is public domain everywhere
  except the UK, where the Crown's letters patent apply. It reaches the packs only
  as the English of 4 Ezra (2 Esdras 3–14). Low risk; noted for completeness.

## Decisions

Taken by Kevin on 2026-10-15, on the questions this audit raised:

1. **Summaries of in-copyright scholarship are in**: Heiser, Stott, Lennox,
   Bradley, Rillera (*Lamb of the Free*) and the atonement synthesis, run through
   studybible-mcp's own importers. Full texts stay out (Heiser's `.txt` papers and
   transcripts), as do Burnett and the Bradley/Gage spreadsheet, which the
   repository doesn't contain.
2. **`get_textual_variant`** uses Heiser's variant dataset as studybible-mcp builds
   it.
3. **CC BY-NC material stays**: Bezalel is free, with no ads, ever.
4. **Links**: the repository is public as GenericJam/bezalel_mob (renamed from
   GenericJam/bezalel on 2026-10-17; GitHub redirects the old URLs); the
   attributions screen links the modification notice to
   https://github.com/GenericJam/bezalel_mob/blob/master/data/README.md and
   this file to
   https://github.com/GenericJam/bezalel_mob/blob/master/data/SOURCES.md.
