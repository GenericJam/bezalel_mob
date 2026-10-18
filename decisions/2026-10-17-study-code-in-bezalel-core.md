# The study code moves to bezalel_core, shared by the phone app and the website
- Date: 2026-10-17
- Status: accepted; the point that `Bezalel.Agent.Patterns` is the app's is
  superseded by 2026-10-17-agent-surface-in-bezalel-core.md

## Context
The phone app was built first, so everything lived here, including the code
every Bezalel surface must share: the study tools, their pack access, the
corpus registry, the genre guidance and the system prompt
(`lib/bezalel/study/`, about 13k lines). A website (bezalel_ca, on rho
too) is being built, and a desktop app on rext may follow. The study code
already knew nothing of Mob except where the packs directory is
(`Bezalel.Packs.Storage`). Kevin wants the shared code in Elixir and doesn't
want to keep studybible-mcp's Python beyond the database it builds.

## Decision
- A new repository, bezalel_core (OTP app `:bezalel_core`), holds
  `lib/bezalel/study/**` with its tests, the fixture packs and the
  research-sources catalogue. Module names are unchanged (`Bezalel.Study.*`),
  so no caller changed; this app no longer defines any `Bezalel.Study.*`
  module.
- The host app names the packs directory: `config :bezalel_core, :packs_dir`,
  a path or `{m, f, a}` resolved on every call. Here it is
  `{Bezalel.Packs.Storage, :packs_dir, []}`, which keeps
  `config :bezalel, :study_packs_dir` for tests and host scripts. Nothing
  else crossed the line; settings storage gets an adapter when core first
  needs a setting (sources, labels, the editable prompt), not before.
- The reply and card regexes (`word_edges`, `first_sentence`, `md_*`) are
  the app's: `Bezalel.Agent.Patterns`, same run-time cache as
  `Bezalel.Study.Patterns`.
- The dependency is `sibling/3` (GitHub, pinned); `BEZALEL_LOCAL_DEPS` takes
  a comma-separated list of apps as well as `1`.
- Agreed layout for what follows: core and the data build in one repository
  (core at the root, the data build as its own Mix project inside, so its
  heavy dependencies never reach an app); the apps in their own: this one
  (to be renamed bezalel_mob), bezalel_ca, later a rext desktop app. The
  database built at studybible-mcp `38cef28` becomes a frozen, pinned base;
  new sources come in through Elixir importers; Python is replaced importer
  by importer when one needs to change.
- This app's OTP name stays `:bezalel` for now: it names on-device paths
  (Mob.State, the packs, mob_dev's runtime dirs) and a rename means a
  reinstall. Do it deliberately before store release (`bezalel-lac`).

## Consequences
- A change to the study tools is a commit in bezalel_core, then a pin bump
  here; run this app's suite against the checkout
  (`BEZALEL_LOCAL_DEPS=bezalel_core mix test`) before pushing core.
- This app's tests read the fixture packs from the dependency's checkout
  (`test/test_helper.exs`); `data/scripts/make_fixtures.py` writes them into
  `../bezalel_core/test/fixtures/packs`.
- The website depends on bezalel_core the same way and supplies its own
  `:packs_dir` (it may point every pack at one full database later; the
  pack-to-file mapping is `Bezalel.Study.DB.path/1`).
- The system prompt moved as it was, phone formatting included; separating
  the per-surface parts (formatting) from the shared ones is the prompt
  rework's job.
- rho's Dyn layer fixes its Core digest at boot from the host app's
  modules (`config :rho, :dyn, app: :bezalel`, a single app) plus the loaded
  ones under `Bezalel.`. With the study code in another app, only the
  modules loaded by then counted (1 of 40 in a host run), so a core change
  would not have re-checked the Workshop's built tools.
  `Bezalel.App.load_core/0` loads all of bezalel_core's modules before
  `Rho.Supervisor.start_link/1` (on start and in `test/test_helper.exs`).
  The clean fix is in rho: let `:app` name several applications
  (`core_digest/0` already wraps it in a list; `runtime/0` takes one).
