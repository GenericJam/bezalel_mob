# Pushback on the phone

2026-10-18. Status: accepted. Contracts: bezalel_core's
`Bezalel.Agent.Pushback` (bd700a4, PR #9) and rho 0.3's `Rho.Consult` /
`Rho.Tools.Consult`. Plan: "Models working together" (Kevin, 2026-10-18).

## Context

Kevin: "Claude generates the answer and Gemini provides pushback", both
automatically (a per-conversation switch) and on demand (a button on a
reply, or asking in words); the first answer stays, the critique shows as
its own block ("Pushback · Gemini 3 Pro"), then the answering model's
reply to it. Pictures can come from another model too ("Pictures by").
bezalel_core does the work (critic brief, target, one round per reply,
the CONSULT block, the live fold); the app chooses, shows and keeps state.

## Decision

- **Settings → Models** has three rows: Answers (the chat model, as
  before), Pushback from (none by default; every provider's catalog
  models, the ones not signed in shown in muted ink with what they need
  and not choosable) and Pictures by (`DrawImage.models/0`, the same
  rule: a Gemini model needs a Gemini key). Both are study preferences
  (`pushback_model`, `image_model`), so a change releases idle loops like
  any other preference. The Gemini key stays where the keys are
  (Settings → Account).
- **The switch is the conversation's**, a `pushback` column on the shelf
  row (migration `ConversationPushback`), not a Mob.State map: it lives and
  dies with the conversation (delete, undo, purge) with no bookkeeping. It
  sits in the conversation's menu, a sheet from a ⋯ in Study's top bar
  (the phone has no conversation header of its own), with who pushes back
  and who answers.
- **The button** sits beside the last reply's speaker when
  `Pushback.offered?/2` says so, live replies only, nothing streaming. A
  refusal (no critic, critic not signed in, one round each) is
  `Pushback.start/3`'s sentence as a toast. Before the critique is asked
  for, the answering model gets the same check as a question
  (`UsageView.preflight/2`: a credential, a limit not used up), so a
  critique isn't spent on an answer that can't come ("No pushback: …").
- **`Bezalel.Agent` gains `pushback/4` and `auto/4`.** The loop is
  private to `Bezalel.Agent.Live`; the button starts a loop when the
  conversation's was released (the reviewed reply is in the session), and
  the lead answers on the model chosen now. A loop started for a pushback
  that is then refused is shut again: the screen never tracked it, so
  nothing else would release it and the next question would reuse it with
  the old preferences. `auto/4` uses the loop that just answered, or
  starts one when the screen released it first (below).
- **A pushback is a reply of its own** in `streams`
  (`Reply.pushback/4`). The screen finishes a reply on any event that
  leaves it not running, not just `:agent_end`: a critique's
  `consult_end` can end it before any run. A failed critique
  (`:consult_failed`) keeps its stream, shown as a card ("Pushback didn't
  come", its error, Ask for pushback again, Open Settings) in place of the
  CONSULT block; it never runs `Library.drop_failed/1` or Try again,
  because no run failed, and the loop stays for the retry unless edits
  wait for it or the conversation isn't open (then it goes, as after any
  reply). A pushback whose critique came but whose answer failed drops the
  critique with the failed run (`Library.drop_pushback/1`): the reviewed
  reply is last again and its card (`Usage.explain/2`'s, as any failed
  reply's) offers Ask for pushback again, not Try again, which would find
  no question to ask. The auto pushback runs only after a reply that
  ended with nothing queued; edits or preference changes that waited for
  that reply are made first (the loop is released and the pushback starts
  a fresh one), so the critic and the answer never see a deleted message.
- **Edits around a pushback.** A pushback's failure card goes once the
  session is edited (the reply it named may be gone; the Pushback button
  covers asking again). Deleting the answer to a critique offers no Ask
  again (it answered no question); deleting the critique as well puts the
  button back on the reviewed reply. The switch's refusal never replaces
  a toast holding a delete's Undo.
- **While a pushback streams, the chat hides only what follows the
  critique.** `without_stream` treats `:consult` like `:agent`, and for a
  pushback the run starts at the critique: the reviewed reply has no user
  message between it and the critique, so the old "everything after the
  last question" rule would have hidden it.
- **The CONSULT block's look is mob_bezalel's** (`UI.consult_block/5`,
  `markdown_style(:consult)`): the surface inside an accent hairline,
  "Pushback · <model>" in the accent over a two-line first line,
  collapsible. The ⋯ is `UI.bar_icon_button/4`.
- `ask_model` (`Rho.Tools.Consult`) is in the registry and the prompt has
  its rule (`ask_model: true`); `config :rho, :consult_system` points at
  `Bezalel.Agent.Pushback.system/1` so a critique asked for in words gets
  the same brief.

## Consequences

- Gemini works once the user adds a Gemini key; until then a Gemini critic
  or image model is listed but not choosable, and a stale choice is named
  in the toast and the conversation menu.
- A stopped critique keeps nothing (rho stores the critique only once it
  has come back); Stop during the answer keeps what streamed, as for any
  reply.
- A pushback stays one round per reply; the answer to a critique offers
  no button and the switch skips it (core's rules).
