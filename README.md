# Bezalel (bezalel_mob)

A free Bible-study companion for Android and iOS, built with
[Mob](https://github.com/GenericJam/mob) (Elixir on the phone), for pastors
and curious readers alike: it shows what the texts say and where they came
from. Ask about a passage and it answers from the Hebrew and Greek: lexicons,
Strong's numbers, morphology, cross-references, people and places, study
notes, in the English of your choice (the NET Bible or the Berean Standard
Bible). Tap a word for its entry. Settings → Study sets how it reads and
answers (its approach, which you can rewrite) and which sources it draws on.
The Workshop builds small study tools, such as a passage outline.

Bezalel is free, with no ads. You bring your own model: sign in with a Claude
or ChatGPT subscription, or enter an Anthropic, OpenAI or Google Gemini API key.

"See, I have called by name Bezalel… and I have filled him with the Spirit of
God, with skill, ability, and knowledge in all kinds of craftsmanship."
Exodus 31:2–3 (BSB)

## How it fits together

- The agent is [rho](https://github.com/GenericJam/rho), an Elixir port of
  pi's agent core running on the phone.
- The study tools are an Elixir port of
  [studybible-mcp](https://github.com/djayatillake/studybible-mcp) (MIT),
  called directly rather than over MCP. They live in
  [bezalel_core](https://github.com/GenericJam/bezalel_core), shared with
  the website; see its `docs/study_tools.md`.
- The study database is built from studybible-mcp's pipeline at a pinned
  commit and downloaded by the app in packs. Sources, licences and the
  attributions the app shows: [data/SOURCES.md](data/SOURCES.md); how to
  rebuild: [data/README.md](data/README.md).
- The look comes from the mob_bezalel style package; the design is in
  [design/](design/).

## The Bezalel repositories

| Repository | What |
|---|---|
| **bezalel_mob** (this; was GenericJam/bezalel) | The phone app, and the build of the study packs (`data/`) |
| [bezalel_core](https://github.com/GenericJam/bezalel_core) | The study tools, pack access, corpus registry and system prompt, shared by every Bezalel app |
| [rho](https://github.com/GenericJam/rho) | The agent core |
| [mob_bezalel](https://github.com/GenericJam/mob_bezalel) | Bezalel's look for Mob: themes, palette, fonts, UI composites |
| [mob_markdown](https://github.com/GenericJam/mob_markdown), [mob_secure_store](https://github.com/GenericJam/mob_secure_store) | Native Markdown views; Keychain / Keystore secrets |

bezalel_ca, the website, is in progress and uses bezalel_core and rho too.

## Credit

The study tools and the study database come from
[studybible-mcp](https://github.com/djayatillake/studybible-mcp) (MIT): its
tools are ported to Elixir in bezalel_core, and its pipeline builds the
database, pinned to commit `38cef28`. The data's own sources (STEPBible,
BibleAquifer, ACAI, Theographic, Perseus and others) and their licences are
in [data/SOURCES.md](data/SOURCES.md); the NET Bible® is quoted by permission
(Biblical Studies Press, http://netbible.org). The app shows them under
Settings → Study library → Sources and licences. See [NOTICE](NOTICE).

## Building and running

```bash
mix setup                  # deps and the git hooks
mix test                   # host tests (no device needed)
mix mob.deploy --android   # or --ios; add --native after native changes
```

Elixir 1.20 on OTP 29, Java 17 and a pinned Zig (`.tool-versions`). To work on
bezalel_core (or another sibling) alongside the app, check it out next to this
one and run with `BEZALEL_LOCAL_DEPS=bezalel_core`.

## Status

In development. [PLAN.md](PLAN.md) is the plan; work is tracked in beads
(`bd ready`). Contributors and coding agents: start with
[AGENTS.md](AGENTS.md).
