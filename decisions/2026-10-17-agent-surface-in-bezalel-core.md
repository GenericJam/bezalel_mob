# The agent's surface moves to bezalel_core too
- Date: 2026-10-17
- Status: accepted (amends 2026-10-17-study-code-in-bezalel-core.md, which
  kept `Bezalel.Agent.Patterns` here)

## Context
The website (bezalel_ca) shows conversations the same way the phone app
does: rho's loop events folded into THINKING / TOOL CALL / SUMMARY blocks
and a passage card while a reply streams, and the same blocks read back
off the conversation's rho session, with Delete and Undo as branch moves.
That code was pure and lived here: `Bezalel.Agent.Reply`,
`Bezalel.Agent.Card`, `Bezalel.Agent.Patterns`, `Bezalel.Library.Transcript`
and `Bezalel.Library.Message`. Its only dependencies were rho and
`Bezalel.Study.*`; the app's modules appeared only in its docs.

## Decision
- The five modules move to bezalel_core with their tests
  (`test/bezalel/agent/card_test.exs`, `reply_test.exs`), module names and
  functions unchanged; only their docs changed, to name "the host app"
  instead of this app's modules. This app no longer defines them.
- What stays here: the state and the drawing (`Bezalel.Views.Study`), the
  live loop (`Bezalel.Agent.Live`, which keeps the card in the tool
  result's `details`), and reading and writing the session file and the
  shelf (`Bezalel.Library`, whose tests stay here).
- bezalel_core has no `decisions/` of its own; this record covers both
  repositories.

## Consequences
- A change to the reply blocks, the card or the branch moves is a commit in
  bezalel_core and a pin bump here, as for the study tools; run this app's
  suite against the checkout (`BEZALEL_LOCAL_DEPS=bezalel_core mix test`)
  first.
- The regex rule now points at two caches in bezalel_core
  (`Bezalel.Study.Patterns`, `Bezalel.Agent.Patterns`); this app's `lib/`
  still must not use compile-time `~r`.
