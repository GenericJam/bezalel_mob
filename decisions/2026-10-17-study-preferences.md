# Study preferences: a minimal fixed prompt, an editable approach, sources the user can switch off
- Date: 2026-10-17
- Status: accepted; the "English" bullet amended by 2026-10-22-study-data-v3.md

## Context
Bezalel's system prompt came from studybible-mcp, framed for evangelical
sermon preparation: a fixed persona and audience, confessional verdicts in
the data ("Contrast" notes on ancient sources, caveats that the NT's
judgement governs), and seeded copy and Workshop starters about sermons.
Kevin wants Bezalel to deliver what the texts say and where they came from,
for pastors and curious lay readers alike, and to let users "swing the
needle" themselves rather than inheriting one tradition's frame. The
setting storage the study-code move left for later
(decisions/2026-10-17-study-code-in-bezalel-core.md: "settings storage gets
an adapter when core first needs a setting") is now needed. bezalel_core
added `Bezalel.Study.Preferences`, `Sources`, `Translations` and a
three-part `Prompt` (fixed part, approach, the host's surface section).

## Decision
- **The fixed part of the prompt is minimal** (core's `Prompt.fixed/1`):
  Bezalel is a Bible-study companion that uses the tools, quotes and cites
  what they return, says where each claim comes from, doesn't invent, and
  labels translations; a guide to the tools left on; a line naming the
  sources switched off. Everything else (persona, audience, hermeneutics,
  traditions, answer style) is **the approach**, which the user can rewrite
  (Settings → Study → Approach); its default (`Prompt.default_approach/0`)
  is neutral and descriptive and credits each reading to those who hold it.
  Saving the default unchanged, or Restore default, stores nil, so a later
  default applies.
- **Scripture labels** (the canon status of non-biblical sources, by
  tradition) can be hidden; shown by default.
- **Editorial verdicts are a source, off by default.** Every source the
  tools draw on beside the text and lexicons (each ancient corpus, each
  theologian, the notes and reference works, ANE background, Kline's Torah
  weave, Fee & Stuart's genre guidance) can be switched off; a tool whose
  every source is off is withheld from the model, and the prompt tells the
  model not to bring the source in from memory. The screen says plainly
  that the model may still know a source from its training.
- **Results per list**: 8 by default, a setting (4 / 8 / 12 / 20).
- **English: the NET Bible by default**, the BSB as the alternative. The
  NET is quoted by the publisher's permission for free non-commercial use:
  "(NET)" after each quotation, NET linked to netbible.org (the passage
  card links it too), the acknowledgement on the attributions screen, its
  translators' notes not included. It comes in its own pack; without it the
  tools quote the BSB and say so.
- **Storage and wiring**: the preferences live in `Mob.State` as a plain
  map, read and written through `Bezalel.Settings`; core reads them through
  `config :bezalel_core, :preferences, {Bezalel.Settings,
  :study_preferences, []}` (one user per phone, so the tool's ctx is
  ignored). The phone's formatting section (a 40-character column, tables
  of at most three short columns) is the app's surface, passed to
  `Prompt.system_prompt/2`; core has no platform formatting.
- **A change applies from the next question**: a loop's prompt and tools
  are fixed when it starts, so a change releases the idle loops, the open
  conversation's too; a loop whose reply is streaming goes when it ends.
- Copy that assumed sermon preparation (the seeded study, the Workshop's
  prompt and starter, Study's build button, the README) is neutral now.
  The design specimen (`Bezalel.DesignGalleryScreen`) and the storyboard's
  sample tool ("Sermon Outline", the design's) are left as the design has
  them.

## Consequences
- The prompt the model sees varies per user; tests compare against
  `Bezalel.Agent.Live.system_prompt/1` for the preferences they set, and a
  test that mounts the app clears `:bezalel_study_preferences` first
  (`Mob.State` is global).
- An edited approach can drop the default's guidance (credit readings, mark
  uncertainty); the fixed part keeps only what keeps answers honest about
  their sources. That is the point: the user owns the frame.
- Switching a source off narrows the tools, not the model's training; the
  copy says so rather than promising the model won't know it.
- The NET's permission is non-commercial, like the CC BY-NC material: if
  Bezalel ever charged or carried ads, the NET would have to go first
  (data/SOURCES.md, "Obligations that follow").
- Publishing the translations pack needs the pack pipeline to take a pack
  built outside `data/build.sh` (bezalel_core's `mix bezalel.data.net`):
  `data/packs.json`, `make_packs.py`, `check_packs.py` and `publish.py`
  know only the packs split from studybible-mcp's database. Until it is
  published the app offers no NET download and quotes the BSB with a note.
- Later: a short onboarding that asks the user's tradition and interest
  and proposes an approach to start from (they can still edit it), instead
  of one default for everyone.
