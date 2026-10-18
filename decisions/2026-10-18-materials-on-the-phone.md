# Materials on the phone

2026-10-18. Status: accepted; what happens to chips when the user moves to
another conversation ("Sending with materials") superseded by
`2026-10-18-chips-follow-the-composer.md`. Contracts: bezalel_core's
`decisions/2026-10-18-materials.md` (Kevin's decisions, the routing rule,
the store behaviour). Beads: bezalel-at6.6, .7, .8, .9 (and .10 in part).

## Context

Kevin asked for Materials: a + beside the question box (photo library,
files; take a photo, record a video, record audio), replies read aloud and
dictation, audio transcribed for models that can't take it, video only
after the notice, generated pictures kept. bezalel_core (f889d4d) and rho
(09cf5ae, GenericJam/rho#1) carry the shared parts; mob_media (6f9422d)
decodes compressed audio and video on the phone.

## Decisions

- **Store** (`Bezalel.MaterialStore`): a `materials` table (the Material's
  fields, keyed by the bytes' SHA-256) and `material_links` (material ↔ rho
  session id: "went with"); files under `materials/` in app support,
  **backed up** (the user's own files, unlike the packs). One user owns
  everything on the phone, so every ctx is that user's; the session id only
  links. `put/3` keeps `Materials.merge/2` of a repeat. Deleting a material
  deletes its transcripts/audio tracks/stills made from it alone, not a
  drawing made from it; deleting a conversation only unlinks.
- **Pictures for models** (`for_model/2`): one providers take as it is
  (JPEG/PNG/WebP, ≤ 1568 px, ≤ 3.75 MB) goes as it is; anything else as
  mob_photos' native downscaled JPEG (HEIC too), cached under the cache
  directory (rho resolves every picture of a conversation on every call);
  without the native thumbnail (host), the app's own PNG thumbnail.
- **Transcripts** (`Bezalel.Transcribe`): a 16-bit WAV is read in Elixir
  and converted with `MobMedia.PCM.convert/5`'s rule one block of whole
  resampling periods at a time (identical samples, bounded memory; that
  function is list-based); everything else (Android's recorder makes AAC
  whatever the format asked, m4a/mp3/ogg files, a video's audio track) goes
  through `MobMedia.audio_pcm/2`. Then Whisper; the transcript is a
  `:transcript` derivative. A recording is transcribed as soon as it's made
  (its words show under its chip); anything still missing is transcribed
  when the question is sent, and if that fails the question isn't sent and
  the user is told why.
- **Sending with materials** (`Bezalel.Views.Attach.prepare/4`): the
  question (words and chips) leaves the composer when Send is tapped, and
  its materials are made ready off the screen; ask or steer is decided
  again when they are. If they can't be, the words and chips come back
  before anything added meanwhile. Sending, Try again and Ask again wait
  while one is made ready; a transcript already being made is waited for,
  not made a second time. Try again with materials keeps the failed reply
  and its Try again until its materials are ready, and drops materials
  deleted since. A question (or something being added) goes only to the
  conversation it was started in: if the user has moved on, it isn't sent
  (or isn't added as a chip there), and they're told; materials stay in
  Materials either way.
- **Video**: the notice (`Materials.video_notice/0`) before the camera
  opens and before a picked video is kept; the video is kept and goes as the
  transcript of its audio track. The stills picker (bezalel-at6.10's rest)
  is a follow-up PR.
- **Dictation**: the platform recogniser (mob_speech) with partials into
  the box after what was typed; Whisper (mob_whisper) when the platform one
  isn't available, reports an error it can't recover from (language,
  service, network…), or heard nothing (then the next dictation uses
  Whisper). The model (60 MB) is fetched on first need, and the user is told.
- **Read aloud**: a speaker beside each reply reads
  `Bezalel.Speech.speakable/1` of its summary with `Mob.Speech`; Settings →
  Voice → "Read replies aloud" (off by default) reads each finished reply.
  `Mob.Speech` doesn't report the end, so the stop button shows for an
  estimate of the reading's length.
- **Native seam**: every native call goes through `Bezalel.Native`
  (`config :bezalel, :native`), so host tests drive the flows; Whisper is
  `config :bezalel, :whisper`, dictation engines `config :bezalel,
  :dictation`, mob_media's engine its own Fake in tests.
- **Five tabs**: Study, Conversations, Materials, Workshop, Settings
  (mob_bezalel compacts the bar for five; GenericJam/mob_bezalel#1).
- **Plugins**: mob_photos, mob_camera, mob_speech, mob_whisper from Hex
  (trusted key); mob_media pinned to a GitHub commit and acknowledged as
  unsigned until its Hex release, then moved to the trusted key. (Done
  2026-10-18: mob_media `~> 0.1` from Hex, 0.1.0 signed with the mob release
  key, in `:trusted_plugins` and off `:acknowledge_unsafe_plugins`; rho
  `~> 0.2` from Hex, 0.2.0 being the pinned 09cf5ae, its override dropped.)

## Consequences

- A conversation whose material was deleted tells the model it couldn't be
  loaded (rho's note); its words (a transcript) stay in the session.
- Steered messages dropped at a run's limit go back to the draft as text;
  their materials stay in Materials, not as chips.
- Videos are hashed whole in memory (core names a material by its bytes);
  files over 250 MB aren't kept.
