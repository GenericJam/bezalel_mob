defmodule Bezalel.MixProject do
  use Mix.Project

  def project do
    [
      app: :bezalel,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: false,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      aliases: aliases(),
      erlc_paths: ["src"],
      erlc_options: [:debug_info]
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      # 0.9.21+: Mob.Storage.exclude_from_backup/1 keeps the study packs out of
      # iCloud backup (bezalel-lac.3). 0.9.18+: the light/dark watcher follows
      # the OS (MOB-479) and <Scroll anchor="bottom"> renders on iOS (MOB-481).
      {:mob, "~> 0.9.21"},
      # 0.7.25+: bundles a style package's fonts (mob_bezalel's) in dev and
      # release builds (MOB-476, MOB-480).
      {:mob_dev, "~> 0.7.29", only: :dev, runtime: false},
      # The design plugin (style package): Bezalel's themes, palette, fonts,
      # icons and composites (the composer's + / mic slots and chips).
      sibling(:mob_bezalel, "GenericJam/mob_bezalel", "f5d2d5b77413b6c4c69603e36461e5fea48d7268"),
      # Native Markdown views (Markwon / Foundation) for replies and tool
      # results. Unreleased: pinned to a commit.
      sibling(
        :mob_markdown,
        "GenericJam/mob_markdown",
        "075ef619fc50e18e8482400c6f13304f93264f4e"
      ),
      {:ecto_sqlite3, "~> 0.18"},
      # The study tools, their pack access, the system prompt and the agent's
      # surface (reply blocks, passage card, transcript), Bezalel.Materials,
      # Bezalel.Speech and draw_image, shared with the website (bezalel_ca).
      # Unreleased: pinned to a commit.
      sibling(
        :bezalel_core,
        "GenericJam/bezalel_core",
        "f889d4d78c8061fd4f15b2a62c14765ed5c3dd87"
      ),
      # The agent core: models, sign-in, usage, Dyn. Pinned to a commit until
      # its next release carries attachments by reference (GenericJam/rho#1);
      # then {:rho, "~> 0.2"}. Overrides bezalel_core's pin of the same ref.
      sibling(:rho, "GenericJam/rho", "09cf5ae8a1f795c4a8780d795aff2e1e3a7be4bd", override: true),
      # Materials: the photo library, the camera, live dictation (the
      # platform recogniser) and Whisper on the phone (recordings, dictation's
      # fallback). Signed plugins from Hex, activated in mob.exs.
      {:mob_photos, "~> 0.2.2"},
      {:mob_camera, "~> 0.1.14"},
      {:mob_speech, "~> 0.1.1"},
      {:mob_whisper, "~> 0.1.2"},
      # A media file's length and size, its audio as 16 kHz PCM for Whisper
      # (compressed audio, a video's audio track) and a video's frames (the
      # stills). Unreleased: pinned to a commit.
      {:mob_media,
       github: "GenericJam/mob_media", ref: "6f9422d8c64d5a7c23d66f088786e7dbfbfbb91c"},
      # The platform secure store (Keychain / Keystore) rho keeps the
      # sign-ins and API keys in. Unreleased: pinned to a commit.
      sibling(
        :mob_secure_store,
        "GenericJam/mob_secure_store",
        "99a94bcbdfb4ed6f57c2286e994f885488e5886a"
      ),
      # The CA bundle Bezalel.Certs loads (phones have none OTP can find).
      {:castore, "~> 1.0"},
      # The study-pack downloads (Bezalel.Packs); rho's model calls use it too.
      {:req, "~> 0.7"},
      # The local pack server the download tests run against (mob_dev has
      # them in dev, so :only must include dev too).
      {:bandit, "~> 1.12", only: [:dev, :test]},
      {:plug, "~> 1.18", only: [:dev, :test]},
      # Code quality — Credo + ex_slop (catches AI-generated patterns
      # like blanket rescue, narrator docs, redundant Enum chains, etc).
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.4.2", only: [:dev, :test], runtime: false},
      # `mix mob.icon` (design/icon/ → platform icons).
      {:image, "~> 0.54", only: :dev, runtime: false}
    ]
  end

  # Shorthands for the common mob workflows — `mix deploy` is `mix mob.deploy`,
  # etc. Extra args pass through to the underlying task, so `mix deploy
  # --device <udid>` works as expected.
  defp aliases do
    [
      # First thing in a fresh clone or worktree: deps and the repo's git
      # hooks (.githooks: format/regex/build-output checks on commit, the full
      # gate on push, and beads' own hooks).
      setup: ["deps.get", "cmd git config core.hooksPath .githooks"],
      connect: ["mob.connect"],
      deploy: ["mob.deploy"],
      watch: ["mob.watch"],
      icon: ["mob.icon"],
      ios: ["mob.deploy --ios"],
      "ios.native": ["mob.deploy --native --ios"],
      android: ["mob.deploy --android"],
      "android.native": ["mob.deploy --native --android"]
    ]
  end

  # A dependency developed alongside Bezalel. Unreleased ones come from
  # GitHub, pinned to a commit, so a fresh clone builds. BEZALEL_LOCAL_DEPS
  # uses sibling checkouts (../bezalel_core, ../rho, ../mob_secure_store,
  # ../mob_bezalel, ../mob_markdown) instead, for working on them: 1 (or
  # true) for all of them, or a comma-separated list of apps
  # (BEZALEL_LOCAL_DEPS=bezalel_core,rho) for just those. `opts` go on the
  # GitHub pin (e.g. override: true for one another sibling also pins).
  defp sibling(app, repo, ref, opts \\ []) do
    if local_dep?(app),
      do: {app, path: "../#{app}", override: true},
      else: {app, [github: repo, ref: ref] ++ opts}
  end

  defp local_dep?(app) do
    case System.get_env("BEZALEL_LOCAL_DEPS") do
      nil -> false
      all when all in ["1", "true"] -> true
      apps -> Atom.to_string(app) in String.split(apps, ",", trim: true)
    end
  end
end
