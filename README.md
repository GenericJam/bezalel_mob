# Bezalel

A free Bible-study companion for Android and iOS, built with
[Mob](https://github.com/GenericJam/mob) (Elixir on the phone). Ask about a
passage and it answers from the Hebrew and Greek: lexicons, Strong's numbers,
morphology, cross-references, people and places, study notes. Tap a word for
its entry. The Workshop builds small study tools, such as a sermon outline.

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

## Status

In development. [PLAN.md](PLAN.md) is the plan; work is tracked in beads
(`bd ready`). Agents working in this repo: start with [AGENTS.md](AGENTS.md).
