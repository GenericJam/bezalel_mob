import Config

# Register the Repo so Mix tasks (mix ecto.create, mix ecto.migrate) can
# discover it. The actual database path is configured at runtime in
# Bezalel.Repo.init/2 via the MOB_DATA_DIR environment variable.
config :bezalel, ecto_repos: [Bezalel.Repo]

# Wire the Repo into Mob.ScreenState so screens using `vsn:` get automatic
# state persistence. Remove this line to disable screen state persistence.
config :mob, :repo, Bezalel.Repo

# Where the study packs are, for bezalel_core's study tools and the pack
# downloads alike: Bezalel.Packs.Storage.packs_dir/0, resolved at run time
# (on Android the app-support directory needs the activity).
config :bezalel_core, :packs_dir, {Bezalel.Packs.Storage, :packs_dir, []}

# The user's study preferences (approach, sources, translation, ...), which
# the study tools and the system prompt follow: Settings → Study, kept in
# Mob.State (Bezalel.Settings).
config :bezalel_core, :preferences, {Bezalel.Settings, :study_preferences, []}

# Materials (photos, recordings, files, drawings) are kept by the app's
# store (Bezalel.MaterialStore: a table and files in app support); rho
# fetches a sent picture's bytes through bezalel_core's resolver when it
# calls a model (sessions keep references, not bytes).
config :bezalel_core, :materials, Bezalel.MaterialStore

# rho, the agent core (models, sign-in, usage). It keeps its files in the
# app's data dir and the sign-ins and API keys in the platform's secure store.
config :rho,
  data_dir: {Mob, :data_dir, []},
  credential_store: MobSecureStore,
  app_name: "Bezalel",
  namespace: "bezalel",
  open_url: {Mob.Device, :open_url, []},
  hints: [
    sign_in: "in Bezalel's Settings",
    switch_model: "in Bezalel's Settings",
    approve: "in the Workshop, where they see what it adds and tap Approve"
  ]

config :rho, :resolve_attachment, {Bezalel.Materials, :resolve, []}

# Another model's critique (Pushback, bezalel_core's Bezalel.Agent.Pushback):
# a critique the lead asks for itself (rho's ask_model, "have Gemini push
# back") gets the same study critic's brief as the Pushback button and the
# per-conversation switch.
config :rho, :consult_system, {Bezalel.Agent.Pushback, :system, []}

# The Dyn layer: the study tools the Workshop builds (Bezalel.Workshop,
# decisions/2026-10-15-workshop-on-dyn.md). The namespace names the
# generations on disk, so it stays. Built code may read the study library
# through Bezalel.Workshop.Study and draw with Mob's and MobBezalel's UI;
# nothing else of Bezalel (the Library, the packs, the settings), no
# network, no storage.
config :rho, :dyn,
  enabled: true,
  namespace: Bezalel.Dyn,
  app: :bezalel,
  core: [Bezalel],
  allowed: [Bezalel.Workshop.Study],
  check: [
    # Of Mob, what a study tool's screen draws with: not the theme (it's the
    # app's), the stored settings (Mob.State holds Bezalel's), the device,
    # files, notifications, wake-ups or a web view. Nor Mob.UI's web view
    # and camera preview nodes: a panel doesn't draw them, nor a remote
    # image (Bezalel.Workshop.Host), and the check says so up front.
    gated: %{
      "Mob" => ~w(Mob.Screen Mob.Socket Mob.Sigil Mob.UI Mob.Style Mob.SizeClass Mob.List Mob.Font
           Mob.Motion Mob.Haptic Mob.Clipboard Mob.Alert Mob.Share Mob.Event Mob.Canvas
           Mob.Speech)
    },
    partial: %{Mob.UI => [:webview, :camera_preview]},
    banned: %{
      Req => "reaches the network (built tools work offline)",
      ReqLLM => "calls models with the user's sign-in",
      Finch => "reaches the network",
      Mint => "reaches the network",
      Exqlite =>
        "opens databases directly (read the study library through Bezalel.Workshop.Study)",
      Ecto => "reaches Bezalel's database"
    },
    banned_erlang: %{
      httpc: "reaches the network",
      gen_tcp: "reaches the network",
      gen_udp: "reaches the network",
      gen_sctp: "reaches the network",
      ssl: "reaches the network",
      inet: "reaches the network",
      socket: "reaches the network",
      dets: "opens files on disk",
      disk_log: "opens files on disk",
      inet_tcp: "reaches the network",
      inet6_tcp: "reaches the network",
      inet_udp: "reaches the network",
      prim_inet: "reaches the network",
      prim_socket: "reaches the network",
      inet_res: "reaches the network",
      zip: "writes files",
      erl_tar: "writes files"
      # Mob's native layer, :mob_nif, is in rho's defaults.
    }
  ],
  screens: Bezalel.Workshop.Screens,
  guide: {Bezalel.Workshop.Prompt, :dyn_guide, []}

if config_env() == :test, do: import_config("test.exs")
