# Study data version 3 on the phone: five translations in a chooser, four new packs, machine translation marked
- Date: 2026-10-22
- Status: accepted (amends the "English" bullet of
  2026-10-17-study-preferences.md: the BSB is no longer the only alternative)

## Context
bezalel_core's data version 3 adds to its optional study packs: the
translations pack now holds the JPS 1917 and Literal and Simplified Texts
adapted from unfoldingWord's ULT and UST beside the NET (keys `jps1917`,
`ult`, `ust` in `Bezalel.Study.Translations.all/0`; the BSB stays in core),
and four new packs arrive: `witnesses` (the Samaritan Pentateuch, the
SBLGNT and its apparatus, the UBS HOTTP), `fathers` (the Apostolic Fathers,
with CAFE's English), `dictionaries` (the UBS Hebrew and Greek
dictionaries) and `syntax` (MACULA clause structure). They are reached
through the existing tools; the app gains no tool. Two core changes reach
the app's own code: a citation can be a `:machine` translation (CAFE's
English is GPT-4o's), and a passage card's verse row can carry its own
`"version"` (the BSB standing in for a book the chosen translation lacks:
the JPS has no New Testament; this ULT and UST release has no Numbers,
1–2 Chronicles, Ecclesiastes, Isaiah, Jeremiah or Ezekiel).

## Decision
- **Translation is a row that opens a chooser sheet**, not a segmented
  control. Five abbreviations in a segmented control don't fit a phone at
  the larger text sizes, and the abbreviations alone (JPS, ULT, UST) say
  nothing about what each is or covers. Settings already picks one of a
  longer list this way: Answers, Pushback from and Pictures by are
  `choice_row`s opening a sheet (`Bezalel.Views.Sheets`) that closes on a
  choice. The translation does the same (`:translations` sheet); each row
  is the translation's name and `Views.Settings.translation_note/2`: what it
  is, where it comes from, what it covers (books quoted from the BSB
  instead), and whether this phone has it (the translations pack missing,
  or installed but from before data version 3, which holds only the NET).
  A translation the phone doesn't have can still be chosen: the tools quote
  the BSB until it is, and say so. Voice uses a pushed screen instead; a
  sheet suits a pick-one choice with no editing.
- The NET's permission line ("quoted by permission: see Sources and
  licences") shows under the row only while the NET is the translation.
- **The study library** lists the new packs in this order: core,
  translations, notes, lxx, witnesses (beside the Septuagint it is compared
  with), ancient, scrolls, fathers (after the ancient sources), dictionaries,
  syntax, graph. The translations pack is "Bible translations" (no longer
  only the NET); its note names the chosen translation when it lives in that
  pack and the pack isn't on the phone.
- **A machine translation is marked as one**: under Sources,
  "Machine translation (AI-generated), not a human translator's", with the
  links to the original. Not "AI translation", which on this phone means
  the assistant's own English, nor the HLT's "unpublished draft" wording.
- **A card verse quoted from another translation than the card's** shows
  that translation after it ("(BSB)", muted), so a ULT card with an Ezekiel
  example doesn't present the BSB's words as the ULT's.
- `data/SOURCES.md` gains the new sources (table rows, attributions
  verbatim from core's `Credits`, the Samaritan Pentateuch with the
  non-commercial material, the CC BY-SA adaptations, and a machine
  translation obligation).

## Consequences
- The ULT/UST coverage in the note is this release's (v91), written in the
  app; a later release that adds books needs the note changed (the tools
  read the pack and stay right either way).
- A phone with the data version 2 translations pack quotes the NET from it
  but the BSB for the JPS, ULT and UST until the pack is updated; Settings
  says so once a check has seen the update.
- The pin bump to the pushed bezalel_core commit is a separate step; until
  then this branch's tests pass only with `BEZALEL_LOCAL_DEPS=bezalel_core`.
