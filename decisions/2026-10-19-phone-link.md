# Linking computers: the phone dials the website, pairing by QR code

Status: accepted (2026-10-19)

## Context

Kevin's 2026-10-19 request: the Bezalel website (study.genericjam.com)
stops holding accounts; the phone is the account, and a browser is linked
by scanning a QR code with the app, as in WhatsApp Web. The design
(phase 1, "the link and pairing") puts the protocol in bezalel_core
(`Bezalel.Link.Handshake`, `Wire`, `Pairing`, decided there in
2026-10-19-link-wire-protocol.md) and leaves the socket, the device key
and the screens to the apps. Kevin's answers: anyone with the app may
link (the website rate-limits), no push wake for now (the website asks
the user to open Bezalel on the phone when it needs it).

Checked first on the moto g power 2021 (Android 12, OTP 29, OpenSSL
3.4.0) and the iPhone 17 simulator (iOS 27), over dist on the running
app: `:crypto` Ed25519 key generation, sign and verify, X25519,
AES-256-GCM, and a verified TLS connection (`verify_peer`, castore's
bundle as `Bezalel.Certs` loads it) to study.genericjam.com, whose chain
is Google Trust Services (WE1 → GTS Root R4) and needs no workaround,
unlike sloppy_joe's Let's Encrypt chain with the expired ISRG Root X2.

## Decision

- **The device key** (`Bezalel.Link.Identity`): Ed25519, made the first
  time it's needed, its seed kept in the secure store rho keeps sign-ins
  in (`MobSecureStore`; Keychain `AfterFirstUnlockThisDeviceOnly`,
  Keystore). It is the account. A store that can't be read is an error,
  never "no key", so a locked Keychain can't make a new account.
- **The connection** (`Bezalel.Link.Dialer`, one per website, under
  `Bezalel.Link`'s supervisor): the phone dials
  `wss://<host>/link/phone` with `Mint.WebSocket` (new dependency
  `mint_web_socket`), keeping sloppy_joe's dial-out fixes (HTTP/1.1 only,
  no permessage-deflate, `Mob.DNS.resolve/1` before each connect, a ping
  every 30 s) and not its two flaws: the connection is authenticated by
  the handshake (the device signs this server key, origin and connection's
  keys), and reconnects back off with jitter from 1 s to 60 s. Every
  frame after the handshake is sealed (Cloudflare terminates TLS).
- **When it dials**: only for a website with linked computers or a
  log-out to send, or during a pairing (3 minutes at most; the website closes a quiet
  pairing socket with 4408 then). Coming to the
  foreground or back online connects at once; in the background the
  socket is closed after 30 s and nothing is dialled until the
  foreground. iOS suspends the app within seconds and Android freezes a
  background app's network, so holding the socket open longer would only
  hide the phone's absence from the website; `mob_background` stays
  rejected (2026-10-15-packs-download-no-background.md). A switch to the
  scanner's own activity on Android (the app goes to the background for a
  moment) stays within the 30 s.
- **Pinning**: the website's key is pinned per origin when the first
  computer is linked (the QR code carries its fingerprint, checked against
  the handshake before the phone signs anything). A different key later is
  "this website's identity changed": the phone stops dialling it and a
  code with another key is refused while computers are linked there. With
  nothing linked there, a scanned code's new key replaces the pin (a
  website set up again); the code is what the user just chose to trust.
- **Pairing** (`Bezalel.Link.claim/1`, `approve/1`, `reject/1`): the claim
  sends only the HMAC binding the code's secret to this device key; the
  website answers with the browser, IP, place and time it was asked from,
  shown with the warning to continue only if the user opened the page just
  now. Nothing is linked without the tap. The scanner is mob_scanner
  (CameraX + ML Kit, AVFoundation; the camera permission is mob_camera's).
- **Payloads** agreed with the website's side (LinkServer, bezalel_ca):
  `welcome {account, account_id, sessions, fingerprint}`; `account_id`
  must match the authenticated device key; a session is `{id, browser,
  ip, place, linked_at, last_seen_at}`; `pair.claim {p, proof}` →
  `pair.info {browser, ip, place, requested_at}`; `pair.approve {p}` →
  `ack {session}`; `pair.reject {p}`; `sessions.revoke {session: id |
  "all"}` → `ack`; `sessions.changed {sessions}` from the website; errors
  are `Wire.error` codes (`expired`, `claimed`, `bad_proof`,
  `rate_limited`, `not_claimed`, `bad_request`, `unknown_op`). Close codes
  4400/4401 (bad handshake), 4409 (replaced by a newer socket), 4429 (too
  many connects: the phone waits the longest backoff).
- **The list** (`Bezalel.Link.Store`, in `Mob.State`, nothing secret): per
  origin the pinned key, the website's list as it last sent it (shown
  offline) and log-outs made offline, sent on the next connect and dropped
  from the list at once. The website's list replaces the phone's on every
  `welcome` and `sessions.changed`; an empty one ends the dialling.
- Times are shown as "how long ago" (the phone's BEAM has no time zone
  database).

## Phase 2: credentials on the authenticated link

The phone's `Rho.Auth` remains the durable source of sign-ins in
`MobSecureStore`. `Bezalel.Link.Creds` subscribes to rho changes and keeps
only provider hashes, Unix-millisecond change times and deletion tombstones
in `Mob.State`, never credential values. All dialers of the phone's account
observe these changes; each sends a sealed `cred.set` or `cred.delete` once
connected. The provider names are checked against `Rho.Auth.providers/0`
before accepting a server update. A failed secure-store read is not treated
as a sign-out.

After authenticated `welcome` with `account_id` and fingerprint matching
the phone's device key, the server sends queued `cred.rotated`, `cred.set`
or `cred.delete` first and finishes with `cred.sync`. The phone ignores
credential operations until it has a linked session (not merely a scanned
code or an unapproved pairing). Only then does it send timestamped provider
changes and `cred.snapshot` (`creds` keyed by rho's provider names), including
at the post-approval `cred.sync` when the first browser creates the account.
An empty server vault is thus replenished on reconnect without a stale phone
snapshot undoing a queued refresh. A snapshot fills absent providers on the
server, not an existing API key or deletion tombstone. Incoming OAuth
updates with a later `expires` win over older OAuth updates; equal expiry,
API keys and deletions use `updated_at` (Unix milliseconds). An incoming
write goes through `Rho.Auth.put/2` or `delete/1`; on failure it is not
acknowledged as saved. `cred.refresh` runs `Rho.Auth.credential/1` off the
socket process and answers with an independent `cred.set`, only on the
connection that requested it. Credentials are never logged or sent before
welcome.

## Consequences

- Phase 3 (conversations) adds more ops on this connection; the dialer
  answers an op it doesn't know with `unknown_op`.
- With the app in the background the website shows the phone offline
  within about 30 s (Android) or when iOS suspends it; it comes back when
  the app is opened.
- Host tests run the whole link against a fake website
  (`test/support/link_server.ex`: core's handshake on Bandit).

## 2026-10-22: work parcels when the last session expires

Kevin's answer to Q2: when the website expires a browser session (24 h
idle, or 14 days without the phone) while it still holds web work the
phone hasn't acknowledged (transcript tails, conversation metadata and
deletions, materials, artifacts, preferences), that work is kept for up to
7 days, sealed so only the phone can read it, and delivered on the
phone's next connection; everything else is purged on time. Before this,
the website deferred the expiry indefinitely instead.

- **Sealing** (the website): one record per request frame the website would
  have sent live, each sealed to the phone's mailbox key (the credential
  mailbox's X25519 key) with a fresh ephemeral key; context
  "bezalel work mailbox v1", AES-256-GCM with `account_id:parcel:seq` as
  associated data, at most 512 KiB of plaintext. Only the parcel id, the
  position and the record count are outside the cipher.
- **On the phone** (`Bezalel.Link.Mailbox.open_work/2`, the dialer):
  `welcome`'s `work_count` keeps the phone connected with no session left.
  The flag is kept per origin in `Bezalel.Link.Store` (`:work`, only
  under the pinned key; forgotten with the pin), so `dial?/1` counts it
  and an app killed mid-delivery dials again at the next launch for the
  rest. A `work.envelope` is opened only for the
  authenticated account and only for the web's write ops (`mat.put`,
  `mat.delete`, `artifact.put`, `conv.create`, `conv.append`, `conv.meta`,
  `conv.delete`, `prefs.set`; never a read such as `conv.pull`). Its inner
  request goes through the same code as a live one, without the
  linked-session check (the envelope authorizes it). It is answered `ack` with
  `durable` (applied and nothing of it left staged, i.e. not a material
  or artifact upload or a divergent transcript tail awaiting more
  chunks) or with the error (`held_by_phone`, `bad_envelope`, …), which
  the website retries on the next connection. Records arrive one at a
  time; the ops were already idempotent against resends. `work.done`
  ends it and the phone stops dialling if nothing else links it.
- **Nothing goes back to an account with no computer.** Connected with no
  linked session (only for a log-out, sealed mail or a work parcel), the
  phone answers `cred.sync` with its queued log-outs only: no
  `cred.mailbox`, credentials, `cred.snapshot`, `index.snapshot` or
  `prefs.snapshot`. Later credential, index and preference changes, and
  the index/preference notices of a served work record, aren't sent
  either. A `cred.refresh` is answered `forbidden`.
- **Limits**: the website deletes a parcel when it's delivered or 7 days
  after sealing, whichever comes first. A phone that's away longer loses
  that work, as Kevin decided.

## 2026-10-22: conversation writes: locks, torn tails, the turns registry

From the pre-commit review of phase 3 (conversations):

- **Locks**: every write to a conversation's session (a website's create,
  append, metadata, divergent tail, delete; a phone turn's start; the
  phone's own edits through `Bezalel.Library`) runs under that
  conversation's lock, `Bezalel.Link.Serve.locked/2`
  (`:global.trans({{Serve, uid}, self()}, …)`: the uid is the resource,
  the caller the requester). The first version had them the other way
  round (one resource for every uid, the uid as requester), so the same
  uid wasn't excluded across websites, different uids waited on each
  other, and a `conv.delete` deadlocked on its own nested tombstone lock.
  Tombstones are one `Mob.State` key per uid, written by the purge
  (`Library.purge_one/1`): a delete made on the phone tombstones too, so a
  website (live, or a work parcel sealed before it heard of the delete)
  can't create the conversation again; a `conv.delete` for a uid the
  phone never had leaves none.
- **Phone turns and website holds** live in `Bezalel.Link.Turns` (an ETS
  table `Bezalel.Link` owns, with monitors on the turns' owners and the
  holding dialers), not in each dialer: a turn starts without calling a
  dialer (one busy connecting no longer makes it "held by the web"), the
  dialers hear of it by message, and one started mid-turn sends
  `conv.hold` at its `welcome`. A turn and a website's hold or write
  exclude each other under the lock. `artifact.put` now refuses like the
  other writes: `held_by_phone` during a turn, `not_found` for a
  conversation not on the shelf.
- **Torn tails** (`Bezalel.Link.TornTail`): a website's append can end
  mid-line (chunks of 256 KiB), and a dropped connection or a parcel cut
  short leaves that partial line in the canonical file so the website's
  resend from the size the phone acknowledged can finish it. Before the
  phone writes (a turn's start, a `Library` write, a merge),
  `TornTail.repair/1` sets the partial line aside (`.link-torn-<uid>` in
  the sessions directory, its offset in `Mob.State`) and cuts the file at
  its last complete line, so nothing the phone writes joins it. A resend
  from anywhere inside that line (its last ack may have been lost) puts
  the bytes back when the phone wrote nothing since, and `conv.append`
  then compares what overlaps and appends the rest (an append that
  overlaps the file's end is accepted where the overlap matches);
  otherwise it is answered `conflict` and the website's divergent tail
  (`total`) is staged from the phone's file up to that line plus the
  bytes set aside up to `from` (the website's own file) and merged as
  usual (`conv.reset`). What was set aside goes once a website's write
  reaches into it.
- **Loops**: a website's write to a conversation (`{:conversation_changed,
  id}`) releases its idle Rho loop (`Study.session_changed/2`), or marks
  it stale while a reply streams, as the phone's own edits do; a loop
  keeps its leaf in memory and would otherwise branch around the web turn.
  A website's `conv.delete` is broadcast as `{:conversation_removed, id}`:
  the screen lets go of the loop, drops it from the shelf and, if it was
  open, opens the latest left (`Conversations.removed/2`).
- **Bounds and cleanup**: a divergent tail over 16 MiB is refused
  `too_large`, and the merge (`Bezalel.Link.Merge`) decodes the phone's
  session once and, of the stage, only the lines from the one the tail
  starts in (the lines before it are the phone's own bytes, counted and
  matched against its active branch), so its memory follows the tail and
  the phone's session, not the stage. Staged uploads and tails
  (`.link-mat-*`, `.link-conflict-*`, `artifacts/*/.link-art-*`) are swept
  when `Bezalel.Link` starts, and a merge that fails removes its stage.
  `welcome`'s `mailbox_count` may be up to the number of rho's providers.
  A linked computer's names (uid, SHA, session file, artifact) are checked
  byte by byte (`Bezalel.Link.Shapes`), not with compiled regexes.
- **Credentials before `cred.sync`**: a `cred.refresh` is answered
  `forbidden` until the barrier and with no linked session (no token is
  refreshed for it), a refresh's answer waits for the barrier, and a
  stale update before it is only acknowledged (the snapshot at `cred.sync`
  carries the phone's newer value).
- **Dates**: a website's complete append moves the conversation to the
  appended entries' own `timestamp` (never back) instead of now, and
  `conv.create` takes an optional `inserted_at` (ISO 8601, not after
  `updated_at`), so an exported conversation keeps its own dates.
