# Usage on the phone

2026-10-18. Status: accepted. Contracts: bezalel_core's
`decisions/2026-10-18-usage.md` (`Bezalel.Usage`: summary, meter,
preflight, explain, reply usage).

## Context

Kevin: "We also need to show usage so if the user is out of tokens it's
not a mystery what happened. How many tokens left, etc." rho records
every call's limit headers, tokens and cost (`Rho.Usage`), and can ask a
subscription's usage endpoint (`Rho.Usage.Fetch`). Settings only showed
tokens per model, all time; a failed reply showed rho's error text, and
"Open Settings" only when that text happened to contain "Settings".

## Decision

- **One assign, rho's record** (`usage`, `Account.usage/0`), re-read on
  `{:rho_usage, :changed}`, which rho sends after every call and refresh.
  Every view derives from it with core's `Bezalel.Usage`, passing
  `auth: assigns.account` so a render doesn't read the secure store.
- **Settings → Usage** replaces "Token usage": per signed-in provider,
  a subscription's windows (percent, "Resets in", plan, when checked) or
  an API key's spend today and this week with a billing-page button
  (providers don't tell apps a key's balance; the copy says so), then
  tokens per model today and this week, a model's aliases counted as the
  catalog's model (as before). The all-time total is gone: a week is what
  limits and bills are about. Refresh asks the subscriptions' endpoints in
  `start_async` (a slow endpoint doesn't freeze the screen); a failure is
  a toast naming the provider and the endpoint's reason.
- **The meter sits above Study's composer field**, not in the top bar:
  the top bar holds the tab's title and Expand all, and the composer is
  where the user is about to spend. It shows nothing without a credential
  for the model, or for a subscription before its first figures (an API
  key always shows its spend today); amber from 80 %, red when used up,
  and it taps to Settings.
- **Preflight blocks the send** when core says the limit is used up for
  more than a minute: the question stays (Try again), and the card says
  when it resets with Choose a model. A send that would fail on the
  provider costs a round trip and comes back as a 429 the user can't read.
  Stale figures can't block forever: an exhausted window counts only until
  its reset time, and Refresh replaces it.
- **Explanations of failures made before sending** (no credential, a
  used-up limit) are kept per error text in `explained`, so the card shows
  them as written instead of re-classifying Bezalel's own wording. A
  used-up limit's is worked out again at every render (its countdown
  stays true; once the limit lifts the card says to try again), and the
  map keeps only the failed replies still shown. A provider's failure is
  explained from its text by `Bezalel.Usage.explain/2`.
  The card's buttons follow the explanation's action (Choose a model,
  Billing page, Open Settings) beside Try again; the provider's own words
  stay under the message, smaller, except where they'd repeat it.
- **A reply's usage is in its ⋯ menu** (`Message.usage`, from its session
  entries): it's a detail for the curious, not something every reply
  should carry.

## Consequences

- `Account.usage/1` (tokens per model, all time) and
  `Views.Settings.tokens/1` are gone; core's `Bezalel.Usage.tokens/1` and
  `money/1` format figures.
- The Refresh path's only test seam is `config :bezalel, :usage_fetch`
  (options passed to `Rho.Usage.Fetch.refresh/3`; tests set `:respond`).
- A reply streaming when the record changes re-renders with the new meter;
  nothing else follows usage.
