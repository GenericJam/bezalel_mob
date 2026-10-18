# bezalel_mob — Agent Instructions

You're in **bezalel_mob** (the Bezalel phone app; the OTP app is still
`:bezalel`), a free Bible-study app for Android and iOS built with
[Mob](https://hexdocs.pm/mob): Elixir on the BEAM, running on the phone,
rendering native SwiftUI / Jetpack Compose views, with an on-phone agent
(rho) and Hebrew/Greek study tools over downloaded SQLite packs. Read this
file in full before you change anything. Its policies come from mob's
AGENTS.md, adapted for an app; `~/AGENTS.md` (devices, Codex review, CI,
Muster) applies on top.

> **Keep this file up to date** in the same commit as the change it
> describes. See "Keep this file up to date" at the end.

## Repo topology

| Repo | What | Where it comes from in `mix.exs` |
|---|---|---|
| **bezalel_mob** (this, GitHub GenericJam/bezalel_mob, public; was GenericJam/bezalel) | the phone app; `data/` builds the study packs | — |
| **bezalel_core** (GenericJam/bezalel_core) | the study tools, their pack access, the corpus registry and the system prompt; the agent's surface (reply fold, passage card, transcript reading and branch moves); shared with the website (bezalel_ca); the fixture packs | GitHub, pinned (`sibling/3`) |
| **mob_bezalel** (GenericJam/mob_bezalel) | the style package: themes, palette, fonts, UI composites | GitHub, pinned (`sibling/3`) |
| **rho** (GenericJam/rho) | agent core: loop, sessions, tools, sign-in, Dyn | Hex, `~> 0.2` (attachments by reference) (`sibling/2`) |
| **mob_secure_store** (GenericJam/mob_secure_store) | Keychain / Keystore secrets plugin | GitHub, pinned until on Hex |
| **mob_markdown** (GenericJam/mob_markdown) | native Markdown views (replies, tool results) | GitHub, pinned until on Hex |
| mob_photos, mob_camera, mob_speech, mob_whisper, mob_media | photo library, camera, dictation, Whisper on the phone; media info, audio to PCM, video frames (Materials) | Hex (signed) |
| mob, mob_dev | the framework | Hex |

`BEZALEL_LOCAL_DEPS=1` uses the sibling checkouts (`../bezalel_core`,
`../rho` etc.) instead of the pins and Hex; a comma-separated list
(`BEZALEL_LOCAL_DEPS=bezalel_core`) uses just those. Push the sibling, then
bump the SHA (or, for rho, release it and bump the requirement). Study data
is published to R2 at https://bezalel.genericjam.com/packs/manifest.json
(`data/README.md`). What lives where, and why:
`decisions/2026-10-17-study-code-in-bezalel-core.md`.

## Issue tracking

- **This app: beads** (`bd ready`, `bd show <id>`, `bd create`). The plan is
  `PLAN.md`; its epics are listed under "The plan" below.
- **A gap in mob / mob_dev / mob_new** found while working here: a Linear
  issue (MOB-*, API key in `~/code/mob/.env`, see `~/AGENTS.md`). Linear's
  free tier was full on 2026-10-15; if `issueCreate` fails with
  `USAGE_LIMIT_EXCEEDED`, file a GitHub issue on the framework repo and a
  bead here pointing at it.
- **A gap in rho, mob_bezalel, mob_secure_store**: a bead here (they have no
  tracker of their own yet), labelled with the repo.

## Worktrees and parallel agents

Several agents often work in this tree at once (the orchestrator splits work
by area). The rules that keep them from damaging each other:

- **Stay in your area.** Before editing a file another agent owns, message it.
- **Commit with a pathspec, always:** `git add <your paths>`, check
  `git diff --cached --stat`, then `git commit -m "…" -- <your paths>`. Never
  `git commit -a`, `git add -A`, or a bare `git commit`: a bare commit takes
  everything staged, including another agent's staged work (this happened:
  a deps commit swept up a staged deletion from the data agent and left a
  commit whose `data/build.sh` read a file it had deleted). The pre-commit
  hook prints what you're about to commit; read it.
- **Pushing** is done by the orchestrator or the human after review, not by
  each agent, unless told otherwise.
- For long work with no parallel agents, a git worktree
  (`git worktree add ../bezalel-worktrees/<name> -b <branch>`) is fine; run
  `mix setup` in it (hooks are per worktree).

## Verification fidelity ladder

Run every applicable lower rung, plus the highest rung the change reaches.
Then say which rung you stopped at. "Tests pass" is not a claim about a device.

1. **Static.** `mix format --check-formatted`, `mix credo --strict` (ExSlop
   included), `mix compile --warnings-as-errors`.
2. **Host.** `mix test`. Proves the Elixir logic, nothing about rendering,
   NIFs, the native build or either platform.
3. **Emulator and simulator, both platforms.** Deployed, attached over dist,
   driven through `Mob.Test` (read `assigns/1` back after the action). For
   UI, a screenshot as well.
4. **Physical device.** Kevin's phones (e.g. moto g power 2021, ZY22DP6HFL);
   lease first. An API-level crash on an old Android or a real-device-only
   iOS behaviour is invisible below this rung.
5. **Release build.** Different linkage and packaging (iOS release links
   NIFs by a separate path).
6. **Published artifact.** What the store or the pack host serves, not the
   working tree (`data/scripts/publish.py` verifies the served packs for
   this reason).

- **Never substitute a lower rung because a higher one is slow or broken.**
  Say plainly that the rung was unavailable and why.
- **Verify effects, not exit codes.** After a deploy, prove the app is up and
  answering (the screen module over dist, the md5 of a changed module)
  before believing anything else. A `&&` chain after `mix test` is not a
  gate unless `mix test`'s exit code is what decides.

## When the ladder can't be climbed, propose the missing readback

If you can't see a state as text (an iOS file attribute, a native view's
layout, a download's progress), don't settle for a screenshot or "looks
right". Ask for the smallest readback that would expose it (a NIF, a
`Mob.Test` helper, a query function) and file it where it belongs (Issue
tracking above). If it's small, ship it with the work that revealed the gap.
When you build a subsystem here (the packs manager, the image pipeline),
design its introspection up front: status functions, events a test can
subscribe to.

## Trust the instrument last

- A number better than the theory allows is a bug in the measurement.
- Make a probe fail loudly when its own precondition doesn't hold (a check
  that passes against the previously installed build proves nothing).
- Corroborate against something you didn't build: logcat, the platform's own
  counters, a download served by the real host.
- When you report a number that turns out wrong, retract it in place.

## Pre-empt-failure rules

Things that already bit this app. Not optional.

1. **No compile-time `~r` regex in `lib/`.** A regex compiled into a module is
   tied to the OTP that compiled it; phones run another. Compile at run time
   (in bezalel_core: `Bezalel.Study.Patterns` for the study tools,
   `Bezalel.Agent.Patterns` for replies and cards: cached in `:persistent_term` under a key that
   includes a hash of the sources so a hot load picks up changes). The
   pre-commit hook and CI reject new ones, here and in bezalel_core.
2. **Commit with a pathspec** (Worktrees above).
3. **Tests that change global state are not async.** `Application.put_env`,
   `System.put_env`, `:persistent_term`, the shared in-memory credential store
   (`Bezalel.Test.MemoryStore`), `Mob.State`: a module that changes one runs
   `async: false` and restores it, and a module that reads one clears or sets
   it in its own setup instead of trusting the previous module. Two flakes
   came from this (a packs test repointing `:study_packs_dir` under async
   study tests; an API key left by LiveAgentTest showing a "Remove" button in
   StudyLibraryTest).
4. **A stopped process can still be in the Registry for a moment.**
   `Registry.lookup` right after a `terminate_child` may return the dead pid;
   check `Process.alive?` (see `Bezalel.Agent.Live.whereis/1`).
5. **Phone SQLite is exqlite's build with exqlite's defines** (MOB-487, from
   mob_dev 0.7.29 / mob_new 0.6.13; Android's own `build.zig` and
   `CMakeLists.txt` carry the list). That includes `SQLITE_DQS=0`:
   double-quoted string literals are an error on the phone as on the host.
   Before MOB-487 FTS5 was missing on device: a host test passing proves
   nothing about a SQLite feature on the phone.
6. **On iOS `Mob.data_dir()` is Documents, which iCloud backs up.** Never put
   re-downloadable data there (Apple rejects it). The packs live in
   `Mob.Storage.dir(:app_support)/packs`, excluded from backup at every start
   (`Bezalel.Packs.Storage`, `bezalel-lac.3`); do the same for any other
   downloaded data.
7. **A native reinstall clears the app's data**, packs included.
8. **Default arguments evaluate eagerly** (from mob): `System.get_env("X",
   Path.expand("~/…"))` calls `System.user_home!()` every time, which raises
   on Android. Use `case`/`||`.
9. **iOS simulators share one BEAM directory per app on the Mac**
   (`~/.mob/runtime/ios-sim/bezalel/`). Two agents deploying to different
   simulators from different checkouts overwrite each other's BEAMs
   (GenericJam/mob_dev#144; it happened on 2026-10-15). Deploy with your own
   `MOB_SIM_RUNTIME_DIR=/tmp/<you>-ios-runtime` whenever another agent might
   use a simulator, and prove the build on the node after a deploy.

10. **Don't promise a sandbox for built tools.** rho's Dyn check and the
   panel host are a best-effort guard against the model's mistakes, not
   against hostile code (Kevin, 2026-10-15). Copy and docs say what's
   checked ("written to read only your study library and draw on screen;
   checked before it runs; put back if it keeps crashing"), never "safe" or
   "no network" outright.

## Tests are part of the change

New behaviour ships with a test unless a test would only restate the change
(a rename, a doc string). The bar: **would this test fail if the fix were
reverted?** Check by reverting it. A test that passes either way is worse than
none, because it is claimed as evidence. For a flake, find the cause; a retry
or a sleep is not a fix. Run the full suite in a loop (10+ runs) after a
change to anything concurrent.

## Commit workflow

### Before every commit

```bash
mix format
mix credo --strict                # whole tree; new issues (tests too) must be fixed
mix compile --warnings-as-errors
mix test                          # full suite; name any pre-existing flake explicitly
```

Native changes (`ios/`, `android/`, a plugin's NIF): `mix mob.deploy
--native` on both platforms and verify on device before committing. Changes
under `data/`: `data/build.sh` (or say why not) and the pack checks.

### Decision log

Non-obvious decisions (tradeoffs, workarounds, conventions, "why X and not
Y") go in `decisions/`, one file each, `YYYY-MM-DD-short-slug.md`, with
Context / Decision / Consequences. Append; never rewrite a decision (add a
new file and mark the old `Status: superseded by <file>`; correct a factual
error in place with a note). Before committing ask both: does this need a new
record, and does it **invalidate** an existing one (grep `decisions/` for the
mechanism you changed)?

### Adversarial review before the commit

Non-trivial work gets a review by a **separate agent** before it's committed:
Codex first (`codex exec -s read-only -C <repo> -o /tmp/<name>-review.md -
< prompt.md`, per `~/AGENTS.md`), a `reviewer` subagent if Codex fails. Give
it the exact diff (with its base), what the change claims, and what you're
least sure of; ask for `file:line`, blocking / should-fix / nitpick, and
SHIP / DO NOT SHIP. Fix and re-review until clean, and say which reviewer
gave the verdict. Skip it only for mechanical changes (formatting, a typo, a
changelog line). Size is not a reason to skip.

### Before a push

- The pre-push hook passed (it runs the full gate).
- The branch isn't behind origin/master (the hook says).
- **Cross-repo claims are true now**: a pin or a doc naming a sibling's
  commit or version requires that commit pushed or that version published.
- After the push, watch CI (`gh run list -R GenericJam/bezalel_mob -L 1`,
  `gh run watch <id> --exit-status`) and fix red before moving on.

## Hooks and CI

`mix setup` (deps plus `git config core.hooksPath .githooks`) once per clone
or worktree. `.githooks/`:

- **pre-commit** (blocking, seconds): format check on staged Elixir files; no
  new compile-time `~r` in `lib/`; no build output or local state staged
  (`.wrangler/`, `data/out/`, `data/work/`, `*.sqlite` outside
  `test/fixtures/`); prints the staged paths.
- **pre-push** (blocking): format, `credo --strict`, compile with warnings as
  errors, `mix test`; advisory notes on staleness and code-without-tests.
- Each hook runs beads' own hook first (`.githooks/_beads` →
  `.beads/hooks/`), so `bd` keeps working with the custom hooks path.

CI (`.github/workflows/test.yml`) runs the same gate on every push and PR.
`--no-verify` is for emergencies you report, not for convenience.

## Releases

Bezalel isn't published to a store yet; store readiness is epic
`bezalel-lac` (bundle id, iCloud backup, review notes). Framework releases
(mob, mob_dev, mob_new) follow mob's RELEASE.md and need Kevin's go-ahead.
Study data releases: `data/scripts/publish.py` (immutable `packs/v<N>/`, the
manifest last).

## Where Mob's docs are

Read the docs for the mob version this app actually uses, in this order:

1. **`deps/mob/guides/*.md` and `deps/mob/usage-rules.md`**, after `mix deps.get`.
   These match the installed version exactly. (With a `path:` dependency on
   mob, read that checkout's `guides/` instead.)
2. **https://hexdocs.pm/mob/llms.txt**, the index of every page. Each page is
   also served as Markdown at `https://hexdocs.pm/mob/<page>.md`, e.g.
   https://hexdocs.pm/mob/screen_lifecycle.md. Hexdocs shows the latest
   release; check `mix.lock` if behaviour differs.
3. **`mix hex.docs fetch mob`** for offline docs, written to
   `~/.hex/docs/hexpm/mob/<version>/`.
4. **IEx**: `iex -S mix`, then `h Mob.Socket.start_async` (any module or
   function).

Guides to start with: `getting_started`, `screen_lifecycle` (including async
loading with `start_async/3` / `handle_async/3`), `components`, `events`,
`navigation`, `testing` (`Mob.ScreenCase`), `coming_from_liveview`.

## Rules for this app

- Load data asynchronously with `Mob.Socket.start_async/3` and handle the result
  in `handle_async/3` (LiveView's `start_async`; `assign_async` is a `:loading`
  assign plus `start_async`). Never a bare `Task.async` in a screen.
- Long or paginated lists use `<LazyList>` with `on_end_reached`. Mob has no
  `stream`.
- Write UI with the `~MOB` sigil.
- Test screens with `Mob.ScreenCase` (`mount_screen`, `render_event`,
  `render_info`, `render_async`).

## The design

- The source of truth is the Claude Design project "Bezalel Brand Foundation"
  (https://claude.ai/design/p/0eb39018-24f4-41b6-9643-8735d3de5a8e), copied to
  `design/`. `Bezalel Core Screens v2.dc.html` is the screen spec;
  `Bezalel Brand.dc.html` the brand. The `_ds/organic-…` system attached to the
  project is not used.
- The look comes from the **mob_bezalel** style package (GenericJam/mob_bezalel,
  activated in `mob.exs`): themes, `MobBezalel.Palette` for colors with no
  theme slot, font tokens (`font: :display`, `:scripture`, `:hebrew`, …), and
  `MobBezalel.UI` composites (bars, cards, pills, segmented control, blocks,
  composer, sheet style). Use those; don't hard-code hex or sizes in screens.
  Fix look problems in mob_bezalel, not per screen.
- `Bezalel.DesignGalleryScreen` (Settings → Design specimen) shows every
  plugin piece; `mix run --no-start scripts/design_tour.exs /tmp/tour <node>...`
  captures it in every theme × cover over dist.
- `android/.../MobBridge.kt` carries mob_new's MOB-477 (rounded clip,
  flexing `<Spacer/>`) and MOB-481 (`<Scroll anchor="bottom">`, which Study
  uses to open at and follow the newest message), from mob_new 0.6.10. Keep
  them if you regenerate the native project. The iOS side of MOB-481 is in
  mob 0.9.18.
- `mix mob.deploy --native` regenerates what the plugins add to the native
  project: `priv/generated/`, `MobPluginBootstrap.kt`, the plugins' bridges
  under `android/app/src/main/java/io/mob/<plugin>/` and the manifest's
  `mob:plugin-permissions` block. They're committed (as for mob_markdown and
  mob_secure_store), in the same commit as the plugin change that made them,
  so the checked-in native project matches `mix.lock`.

## The plan

- `PLAN.md` is the agreed plan for the real agent (rho, the study database
  and tools, Dyn). Its work is tracked in beads: `bd ready` for what's next,
  `bd show <id>` for details. Epics: phase 1 `bezalel-23s` (rho), 2
  `bezalel-e47` (database), 3 `bezalel-czj` (tools), 4 `bezalel-y77` (app),
  5 `bezalel-lac` (store review), 6 `bezalel-qyv` (Workshop on Dyn).

## The app

- bezalel_core, mob_secure_store, mob_bezalel and mob_markdown are GitHub
  deps pinned to commits in `mix.exs` (`sibling/3`), so a fresh clone
  builds; rho comes from Hex (`sibling/2`). To work on one alongside the
  app, run with `BEZALEL_LOCAL_DEPS=1` (uses `../bezalel_core`, `../rho`,
  `../mob_secure_store`, `../mob_bezalel`, `../mob_markdown`) or a list of
  just those you have checked out (`BEZALEL_LOCAL_DEPS=bezalel_core`); once
  the change is pushed, bump the pinned commit, or for rho release it (its
  release workflow publishes on a `@version` bump, with Kevin's OK) and bump
  the requirement if needed.

- `Bezalel.AppScreen` is the whole app: Study, Conversations, Materials,
  Workshop (and a built tool), Settings under one top bar and tab bar, plus
  the sheets and the toast. It holds the state; each tab's view and events
  are in `lib/bezalel/views/`. Events are `{:tap, {tab, event}}` tuples
  routed there.
- **Materials** (decisions/2026-10-18-materials-on-the-phone.md; core's
  `Bezalel.Materials`): `Bezalel.MaterialStore` (table + files under
  `materials/` in app support, backed up; models' picture copies and
  thumbnails in the cache dir), the composer's + menu, chips, recorder and
  dictation (`Bezalel.Views.Attach`), the tab and materials in messages
  (`Bezalel.Views.Materials`), transcripts (`Bezalel.Transcribe`: WAV in
  Elixir, the rest through mob_media, then Whisper), video stills
  (`Bezalel.Views.Stills`: a scrubber over `MobMedia.frame/3`, a still is a
  `:still` derivative; decisions/2026-10-18-video-stills.md), read aloud
  (Study's speaker, Settings → Voice). Native calls go through
  `Bezalel.Native`; tests use `test/support/materials_fakes.ex`, MobSpeech's
  and MobMedia's Fake engines. A stored question's materials are sent again
  on Try again. Chips belong to the composer, not a conversation: they stay
  across conversation switches until sent or removed, and a material is
  linked ("went with") only when its question is sent; each grid card
  deletes with its × (decisions/2026-10-18-chips-follow-the-composer.md).
- Data: `Bezalel.Library`: each conversation's transcript is its rho
  session (JSONL in `Rho.Session.dir/0`, read by bezalel_core's
  `Bezalel.Library.Transcript`; Delete and Undo are branch moves), SQLite
  keeps the shelf (name, kind, kicker, session id and file, message count)
  and the built tools; seeds the design's Exodus 31 study on first run.
  Deleting a conversation (its ⋯ on the Conversations tab) marks its row
  (`deleted_at`: off the shelf, writes to it do nothing) and purges it,
  with its session file and the files kept under rho's data dir for its
  session id (`images/`, `artifacts/`, `todos/`), when its Undo window
  ends or at the next start
  (`decisions/2026-10-16-conversation-delete-undo-then-purge.md`). A new
  file kept per session belongs in `Library.purge/1`.
  Pictures in the chat (a tool's, a model's, an attachment's: image parts
  in the session) are downscaled on the phone and cached
  (`Bezalel.Images`, `Bezalel.Views.Images`, with a full-screen viewer).
  Preferences: `Bezalel.Settings`
  (`Mob.State`; the study preferences too, below). Scripture and lexicon: `Bezalel.Scripture` (Exodus 31
  sample). Models: `Bezalel.Models` (rho's catalog for the providers the
  user has access to; a model id is its req_llm spec). Sign-ins, API keys
  and token usage: `Bezalel.Account`, over rho.
- **Study tools** (`Bezalel.Study.*`, in **bezalel_core**): studybible-mcp's
  tools ported to Elixir as rho tool modules over the study packs
  (`data/`), with the system prompt (`Bezalel.Study.Prompt`); the live agent
  runs them. They know nothing of Mob: the app names the packs directory
  through `config :bezalel_core, :packs_dir`
  (`{Bezalel.Packs.Storage, :packs_dir, []}`) and the user's study
  preferences through `config :bezalel_core, :preferences`
  (`{Bezalel.Settings, :study_preferences, []}`, called with the tool's
  ctx appended). Their tests and the fixture
  packs (cut here by `data/scripts/make_fixtures.py`, written into
  `../bezalel_core`) are bezalel_core's; this app's tests read the fixtures
  from the dependency (`test/test_helper.exs`). `Bezalel.App.load_core/0`
  loads them before rho starts, so rho's Dyn Core digest counts them (it
  only knows the `:bezalel` app's own modules). How they were ported, the
  pack access and the differences from studybible-mcp: bezalel_core's
  `docs/study_tools.md`.
- **rho** (GenericJam/rho, on Hex, https://hexdocs.pm/rho) is the agent core:
  `Rho.Supervisor` starts in `Bezalel.App.on_start`, configured in
  `config/config.exs` (`config :rho`: data dir from `Mob.data_dir/0`, the
  secure store, `Mob.Device.open_url/1`, app name and hints). Read rho's
  README and AGENTS.md for its seams.
- **mob_secure_store** (GenericJam/mob_secure_store, unreleased, pinned) keeps the
  sign-ins and API keys in the Keychain / Keystore. It's activated in
  `mob.exs` with `:acknowledge_unsafe_plugins` until it's signed; it has a
  NIF, so adding or changing it needs `mix mob.deploy --native`. The iOS
  simulator's Keychain needs `ios/simulator_entitlements.plist` (linked by
  `ios/build.zig`); change its bundle id along with the app's.
- **mob_markdown** (GenericJam/mob_markdown, unreleased, pinned) renders
  block bodies (summary, thinking, tool results) as native Markdown views
  styled by `MobBezalel.UI.markdown_style/1`; tables scroll sideways at
  their natural width. Activated with `:acknowledge_unsafe_plugins`; a
  change to it needs `mix mob.deploy --native` on both platforms. The chat
  keeps at most 120 open blocks in native views (two frames' worth of mob's
  256 component slots, `Bezalel.Views.Study.markdown_keys/3`), one atom per
  block shown; older ones show their Markdown as text
  (`decisions/2026-10-15-markdown-tables-scroll.md`).
- Signing in during development: Settings → Account. "Sign in" opens the
  provider's page in the phone's browser; it comes back to a listener on
  localhost inside the app (Claude: port 54545; ChatGPT: 1455). If Claude's
  page shows a code instead, paste it into the field under Claude and tap
  "Use code". Or paste an API key (Anthropic, OpenAI, Gemini) and Save; a
  key replaces a sign-in to the same provider. On the host, tests use an
  in-memory store and a fake browser (`test/support/fakes.ex`, set in
  `config/test.exs`); they never reach the network.
- **The agent** (`Bezalel.Agent`): live once the user has a sign-in or an
  API key for any provider. `Bezalel.Agent.Live` runs one rho loop per
  conversation being answered (study prompt, the study tools, the model
  from Settings) on the conversation's session (resumed: the model sees
  what earlier loops sent and got), released when the conversation is left,
  before Bezalel writes the session itself (a delete or undo, a question
  asked again), when a reply is stopped or fails, or the screen mounts.
  Its events stream into bezalel_core's `Bezalel.Agent.Reply` (THINKING /
  TOOL CALL / SUMMARY, the passage card from `lookup_verse` / `word_study`'s
  data, `Bezalel.Agent.Card`; pure, shared with the website,
  decisions/2026-10-17-agent-surface-in-bezalel-core.md) in
  `Bezalel.Views.Study`: stop button while it
  streams, a message sent meanwhile steers it, errors stay as a card with
  Try again (and Open Settings for sign-in problems). Without a credential,
  replies are the design's storyboard (`Bezalel.Agent.Storyboard`), and
  Settings and Study say so. Tests drive Live with a scripted model
  (`test/support/fake_llm.ex`, `test/bezalel/live_agent_test.exs`). Study's
  loop takes rho's registry (the study tools, plus the tools built in the
  Workshop) and withholds the `dyn_*` tools and the study tools whose every
  source the user switched off (Settings → Study, below).
- **Settings → Study** (`Bezalel.Views.Settings`; decisions/2026-10-17-study-preferences.md):
  the user's `Bezalel.Study.Preferences`, kept in `Mob.State` under
  `:bezalel_study_preferences` as a plain map (`Bezalel.Settings.study_preferences/0,1`,
  `put_study_preferences/1`, `update_study_preferences/1`, normalised by
  `Preferences.new/1`). On the tab: Translation (NET, the default, or BSB;
  the NET needs the translations pack, "NET Bible" in the study library and
  in `Bezalel.Packs.Manifest.known/0`, optional,
  and without it the tools quote the BSB and say so), Results per list
  (4 / 8 / 12 / 20), Scripture labels (Show / Hide), and two rows opening
  pushed screens, both pushed with `%{app: self()}` and telling the app's
  screen `{:study_preferences, :changed}` when they store a change:
  `Bezalel.ApproachScreen` (the editable approach in a multi-line field,
  Save / Restore default, the fixed part shown read-only under "Always
  included") and `Bezalel.StudySourcesScreen` (bezalel_core's
  `Bezalel.Study.Sources` by group, each On/Off). A change applies from
  the next question: `Bezalel.Views.Helpers.release_idle/1` releases the
  idle loops, the open conversation's too, and marks a streaming one
  stale (it goes when its reply ends). `Bezalel.Agent.Live` builds each
  loop's prompt with `Prompt.system_prompt(prefs, surface: …)`, the
  surface being the phone's formatting section, which lives in the app
  (`Live.phone_formatting/0`; core has no platform formatting), and
  withholds `Bezalel.Study.Tools.withheld(prefs)` beside the `dyn_*`
  tools. The passage card labels the translation the tool quoted
  (`result.translation`) and, for the NET, ends its last verse with
  "(NET)" linked to netbible.org, as its terms ask.
  Tests: `test/bezalel/settings_test.exs` ("study"),
  `test/bezalel/live_agent_test.exs` ("study preferences"); a test that
  mounts the app clears `:bezalel_study_preferences` in its setup.
- **The Workshop** (`Bezalel.Workshop`, decisions/2026-10-15-workshop-on-dyn.md)
  builds tools through rho's Dyn layer (`config :rho, :dyn`): with a model,
  a rho loop (`Bezalel.Workshop.Builder`, prompt `Bezalel.Workshop.Prompt`)
  writes `Bezalel.Dyn.<Name>` (a `Rho.Tool`) and `Bezalel.Dyn.<Name>.Screen`
  and proposes a generation; the Workshop shows what it adds, the approval
  sheet activates it (`Rho.Dyn.Approval.Biometric` fed by the tap), it runs
  on probation (three crashes in a minute revert it; the Workshop says so).
  Built code may call only `Bezalel.Workshop.Study` of Bezalel (read-only
  study data) and Mob's/MobBezalel's drawing modules (network and storage
  modules are on the check's deny-list). The check is rho's best-effort guard
  against the model's mistakes, not a sandbox against hostile code (Kevin,
  2026-10-15; decisions/2026-10-15-workshop-on-dyn.md): copy never promises
  "no network" or "safe", only what's checked. A tool's screen runs in its own process in the panel
  (`Bezalel.Workshop.Host`), which sends the app plain data only: no web
  views, videos or remote images (an image's `src` must be an on-phone
  path), its crashes described in its own process
  (decisions/2026-10-15-workshop-panel-sandbox.md). Without a model it's
  still the storyboard sample. Generations live in `dyn/` under rho's data
  dir; the shelf (`tools` rows, one version per approved change) follows
  the generation that runs (`Bezalel.Workshop.reconcile/0`, when the app's
  screen mounts and on every
  revert), so a reverted change or Remove shows what runs again. Tests:
  `test/bezalel/workshop_dyn_test.exs`; tests that build tools move the
  Keeper to their own dir (`test/support/dyn.ex`). On a device, let the
  app run ten seconds after its first frame before restarting or
  redeploying while a tool is on probation: a quicker restart counts as a
  failed launch (the generation is reverted at the next boot; two in a row
  start without built tools). Driving a build on a device without an
  account: the stand-in below, scripted to answer the Workshop's prompt
  with `dyn_write` and `dyn_propose` calls.
- **The study library** (`Bezalel.Packs`, `Bezalel.Views.StudyLibrary`):
  the packs are downloaded from
  https://bezalel.genericjam.com/packs/manifest.json (`data/README.md`,
  "Publish") into `packs` under the app support directory (iOS
  `Library/Application Support/packs`, excluded from iCloud backup; Android
  `files/packs`), where the tools read them; `Bezalel.Packs.Storage.packs_dir/0`
  names it (bezalel_core's `Bezalel.Study.DB.dir/0` returns it), and
  `Bezalel.Packs.Storage` moves what older builds left in
  `Documents/packs` at startup. On
  first launch a sheet offers the core pack (26 MB download, 182 MB on the
  phone); Settings → Study library downloads, updates ("Check for
  updates") and removes packs (the optional ones: NET Bible, notes,
  Septuagint, ancient sources, Dead Sea Scrolls (`scrolls`, from data
  version 2; decisions/2026-10-18-scrolls-pack-optional.md), people and
  places), shows storage used, and opens Sources and
  licences (`Bezalel.AttributionsScreen`, laying out bezalel_core's
  `Bezalel.Study.Credits`, from `data/SOURCES.md`; change both together). `Bezalel.Packs` runs outside the screen: one download at
  a time, resumed with a Range request after a dropped connection or a
  restart, both checksums verified, the new file renamed over the old only
  once it verifies (`Bezalel.Packs.Download`). There is no background
  keep-alive: iOS suspends the app soon after it leaves the screen and
  Android may stop it; the download resumes when the app runs again. Host
  tests serve their own library (`test/support/pack_server.ex`) and never
  reach the network.
  - On a dev device the real path is Settings → Study library → Download
    (or the first-launch sheet).
  - Shortcut without the network, from a `data/build.sh` build: push
    `data/out/core.sqlite` (and the others only if you need them; disk is
    tight, delete them when done). Settings shows it as installed with the
    version not checked; "Check for updates" hashes it and keeps it if it
    matches the published one.
    - Android (debug build): `adb -s <serial> push data/out/core.sqlite /data/local/tmp/ && adb -s <serial> shell "run-as com.example.bezalel mkdir -p files/packs && run-as com.example.bezalel cp /data/local/tmp/core.sqlite files/packs/ && rm /data/local/tmp/core.sqlite"`
    - iOS simulator: `d=$(xcrun simctl get_app_container <udid> com.example.bezalel data) && mkdir -p "$d/Library/Application Support/packs" && cp data/out/core.sqlite "$d/Library/Application Support/packs/"`
      (check `Bezalel.Study.DB.dir()` on the node if it differs)
    - Remove: Settings → Remove for the optional packs; or
      `run-as com.example.bezalel rm -r files/packs` / `rm -r "$d/Library/Application Support/packs"`
      (core can only be removed this way).
  A native redeploy that reinstalls the app clears its data, packs included.
  Without a pack the tools return an error naming it; the model sees it and
  the reply still lands.
- **Trying a full live turn without a real account**: point req_llm at a
  local stand-in for the provider on the node,
  `Application.put_env(:req_llm, :anthropic, base_url: "http://10.0.2.2:PORT")`
  (Android emulator; `http://127.0.0.1:PORT` on the iOS simulator), with
  any Anthropic API key saved in Settings. `Application.delete_env(:req_llm,
  :anthropic)` (or a restart) goes back to the real API.
- To try an unreleased mob fix here first, point the dep at the checkout
  (`{:mob, path: "../mob", override: true}`) and set `mob_dir` to it in the
  gitignored `mob.local.exs` (native builds read mob's sources from there);
  go back to the Hex version once it ships.
- Check changes on devices: deploy, then
  `mix run --no-start scripts/app_tour.exs /tmp/app <node>...` walks every tab
  and the main interactions and saves screenshots. Android sheets are separate
  windows the in-app capture misses; use `adb exec-out screencap` for those.
- Host tests (`mix test`) mount the screen with `Mob.ScreenCase` against a
  temp database and temp `Mob.State`.

If you use [usage_rules](https://hexdocs.pm/usage_rules), `mix usage_rules.sync`
picks up `deps/mob/usage-rules.md`.

## Keep this file up to date

The next agent's first decision comes from this file. When you change
something it describes (topology, a convention, a gotcha, a workflow, a dev
step), update it in the same commit, not in a follow-up. When something bites
you that should have been a pre-empt rule, add it with a one-line summary and
the commit or test that shows it.

## Beads profile for this repo

The managed beads blocks below describe bd's defaults. Here: agents use `bd`
for tracking (the orchestrator may keep it read-only for subagents), commit
their own paths after the gates and review (Commit workflow above), and leave
pushing and Dolt sync to the orchestrator or the human unless told otherwise.

<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:6cd5cc61 -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export. See https://github.com/gastownhall/beads/blob/main/docs/SYNC_CONCEPTS.md for details and anti-patterns.

## Agent Context Profiles

The managed Beads block is task-tracking guidance, not permission to override repository, user, or orchestrator instructions.

- **Conservative (default)**: Use `bd` for task tracking. Do not run git commits, git pushes, or Dolt remote sync unless explicitly asked. At handoff, report changed files, validation, and suggested next commands.
- **Minimal**: Keep tool instruction files as pointers to `bd prime`; use the same conservative git policy unless active instructions say otherwise.
- **Team-maintainer**: Only when the repository explicitly opts in, agents may close beads, run quality gates, commit, and push as part of session close. A current "do not commit" or "do not push" instruction still wins.

## Session Completion

This protocol applies when ending a Beads implementation workflow. It is subordinate to explicit user, repository, and orchestrator instructions.

1. **File issues for remaining work** - Create beads for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **Handle git/sync by active profile**:
   ```bash
   # Conservative/minimal/default: report status and proposed commands; wait for approval.
   git status

   # Team-maintainer opt-in only, unless current instructions forbid it:
   git pull --rebase
   git push
   git status
   ```
5. **Hand off** - Summarize changes, validation, issue status, and any blocked sync/commit/push step

**Critical rules:**
- Explicit user or orchestrator instructions override this Beads block.
- Do not commit or push without clear authority from the active profile or the current user request.
- If a required sync or push is blocked, stop and report the exact command and error.
<!-- END BEADS INTEGRATION -->

<!-- BEGIN BEADS CODEX SETUP: generated by bd setup codex -->
## Beads Issue Tracker

Use Beads (`bd`) for durable task tracking in repositories that include it. Use the `beads` skill at `.agents/skills/beads/SKILL.md` (project install) or `~/.agents/skills/beads/SKILL.md` (global install) for Beads workflow guidance, then use the `bd` CLI for issue operations.

### Quick Reference

```bash
bd ready                # Find available work
bd show <id>            # View issue details
bd update <id> --claim  # Claim work
bd close <id>           # Complete work
bd prime                # Refresh Beads context
```

### Rules

- Use `bd` for all task tracking; do not create markdown TODO lists.
- Run `bd prime` when Beads context is missing or stale. Codex 0.129.0+ can load Beads context automatically through native hooks; use `/hooks` to inspect or toggle them.
- Keep persistent project memory in Beads via `bd remember`; do not create ad hoc memory files.

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export. See https://github.com/gastownhall/beads/blob/main/docs/SYNC_CONCEPTS.md for details and anti-patterns.
<!-- END BEADS CODEX SETUP -->
