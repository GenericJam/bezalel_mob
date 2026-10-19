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
  `welcome {account, sessions, fingerprint}`; a session is `{id, browser,
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

## Consequences

- Phase 2 (credentials from the phone) and phase 3 (conversations) add
  ops on this connection; the dialer answers an op it doesn't know with
  `unknown_op` until then.
- With the app in the background the website shows the phone offline
  within about 30 s (Android) or when iOS suspends it; it comes back when
  the app is opened.
- Host tests run the whole link against a fake website
  (`test/support/link_server.ex`: core's handshake on Bandit).
