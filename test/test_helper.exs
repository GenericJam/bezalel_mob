# Host tests run against throwaway state: the Repo on a temp database
# (config/test.exs), Mob.State on a temp dets file.
data_dir =
  Path.join(
    System.tmp_dir!(),
    "bezalel_test_#{System.pid()}_#{System.unique_integer([:positive])}"
  )

File.mkdir_p!(data_dir)
System.put_env("MOB_DATA_DIR", data_dir)

# The study tools read bezalel_core's fixture packs (cut by
# data/scripts/make_fixtures.py), never the real ones in data/out. They ship
# in the dependency's checkout, so the path is found at run time.
Application.put_env(
  :bezalel,
  :study_packs_dir,
  Path.join(Mix.Project.deps_paths()[:bezalel_core], "test/fixtures/packs")
)

{:ok, _} = Application.ensure_all_started(:ecto_sqlite3)
{:ok, _} = Bezalel.Repo.start_link()

Ecto.Migrator.run(Bezalel.Repo, Application.app_dir(:bezalel, "priv/repo/migrations"), :up,
  all: true,
  log: false
)

# The processes AppScreen talks to on device. Both run without the native
# layer: Mob.Device treats the missing NIF as a host run.
{:ok, _} = Mob.State.start_link()
{:ok, _} = Mob.Device.start_link()

# The study library AppScreen subscribes to, on its own empty directory
# (the tools' fixture packs stay untouched). It fetches nothing by itself;
# the first-launch offer counts as shown, except in the test about it.
{:ok, _} =
  Bezalel.Packs.start_link(dir: Path.join(data_dir, "packs"), auto: false, retry_delays: [0])

Bezalel.Settings.put_packs_offered()

# rho with in-memory sign-ins and a browser that only records the URL
# (config/test.exs); usage.json lands in the temp data dir.
Bezalel.Test.MemoryStore.start()
Bezalel.Test.Browser.start()
# The sign-in listener on a free port, not the providers' fixed ones (an
# omp or a dev app on this machine may hold 54545 / 1455).
redirect = fn provider ->
  %URI{path: path} = provider |> Rho.Auth.OAuthFlow.default_redirect() |> URI.parse()
  "http://localhost:0" <> path
end

# As the app starts it (Bezalel.App): bezalel_core's modules loaded (rho's
# Dyn Core digest counts them), the study tools in the registry, and the Dyn
# layer (config :rho, :dyn) on the temp data dir's dyn/, at generation 0.
# Tests that build tools move it to a dir of their own (Bezalel.Test.Dyn).
:ok = Bezalel.App.load_core()

{:ok, _} =
  Rho.Supervisor.start_link(tools: Bezalel.Agent.Live.tools(), login: [redirect: redirect])

%{generation: 0, mode: :normal} = Rho.Dyn.boot()
{:ok, _} = Bezalel.Agent.Live.start_link()

ExUnit.start()
