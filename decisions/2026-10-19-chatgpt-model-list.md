# The ChatGPT sign-in's models are the ones it accepts

Date: 2026-10-19
Status: accepted

## Context

The model sheet listed rho's shipped ChatGPT catalog (omp's), which named
models the Codex backend refuses for a ChatGPT account: a reply on
`openai_codex:gpt-5.5` failed with HTTP 400 "not supported when using
Codex with a ChatGPT account". A phone that had chosen GPT-5.5 could not
get a ChatGPT reply at all.

## Decision

- rho 0.5.1 lists the sign-in's own models (`Rho.Models.Codex`: Codex's
  `GET /backend-api/codex/models`, kept and fetched again in the
  background). `Bezalel.Models` builds the ChatGPT group from it each time
  (Claude's, OpenAI's and Gemini's are still built once), so the sheet
  follows the list without a restart.
- A chosen ChatGPT model the list no longer has shows as the sign-in's
  default (the first Codex lists), not as Claude Sonnet, and the next
  question makes that the choice, with a toast saying so
  (`Bezalel.Models.replacement/1`, `Helpers.accept_model/1`). The reply
  goes through instead of failing.
- A conversation whose session is on a refused model (the list said yes, the
  backend said no) is moved by rho's loop itself: the call is made again on
  the default, with a notice in the conversation.
- A message from a model the catalog no longer has is attributed by its id
  ("gpt-5.5"), not by the default model's name.

## Consequences

- The sheet can change while the app runs (a refresh every 6 hours).
- The toast is the only explanation a user sees for a choice that changed
  when the list did; the conversation's notice covers the refused case.
