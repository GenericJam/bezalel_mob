# The Dead Sea Scrolls pack is optional on the phone

- Date: 2026-10-18
- Status: accepted

## Context

bezalel_core 6b44587 adds the `scrolls` pack (the Dead Sea Scrolls' 30 major
non-biblical works from 132 manuscripts for the ancient tools, and the
biblical manuscripts' readings for `compare_biblical_versions`; core's
decisions/2026-10-18-dead-sea-scrolls-pack.md), to be published with the
`translations` pack as data version 2. Its text is ETCBC/dss, CC BY-NC 4.0.

## Decision

- `Bezalel.Packs.Manifest` knows `scrolls`, listed after `ancient` (it
  extends the ancient sources); the study library calls it "Dead Sea
  Scrolls". It is optional, like every pack but core, and not part of the
  first-launch offer (which stays the core pack alone): the tools work
  without it and say the pack is missing.
- The DSS witnesses in `compare_biblical_versions` are core's source
  `manuscripts:dss` (on by default), shown in Settings → Study → Sources
  with the rest; the phone adds nothing for it.
- Credits: the Dead Sea Scrolls entry (Sources and licences, data/SOURCES.md)
  covers the whole scrolls pack and names the Leon Levy Dead Sea Scrolls
  Digital Library (IAA) as the source of the manuscript names and script
  periods; the non-commercial obligation now names the scrolls pack too.

## Consequences

Until the manifest lists `scrolls` (data version 2) the study library shows
no new pack; Settings → Study → Sources gains the Dead Sea Scrolls (biblical
manuscripts) toggle as soon as this pin lands. Making Bezalel commercial
would mean withdrawing the whole scrolls pack, not just excerpts of the
ancient pack.
