defmodule Bezalel.App do
  @moduledoc "Application entry point for Bezalel."

  use Mob.App

  alias Bezalel.Agent.Live
  alias Bezalel.Packs.Storage

  require Logger

  @impl Mob.App
  def navigation(_platform) do
    stack(:main, root: Bezalel.AppScreen)
  end

  @impl Mob.App
  def on_start do
    # Configure BEAM's DNS path so Req / Finch / Mint / `gen_tcp:connect/3`
    # with a hostname work on iOS without per-host setup. Flips the lookup
    # chain from the iOS-broken `:native` (inet_gethost port program) path
    # to `[:file, :dns]` and seeds Google + Cloudflare as fallback
    # nameservers. Override with `nameservers:` if you need to (corporate
    # resolver, Quad9, etc.) — see `Mob.DNS.configure_pure_beam/1`.
    #
    # For hosts that need Apple's resolver (VPN-pushed DNS, mDNS,
    # captive portals, search-domain expansion) call `Mob.DNS.resolve/1`
    # for those specific hostnames here too. Both paths compose.
    Mob.DNS.configure_pure_beam()

    # The emulator (and some networks) drop outbound UDP :53, so pure DNS
    # can't find the sign-in token and model endpoints, or the study
    # library: seed them through the platform resolver.
    for host <-
          ~w(api.anthropic.com auth.openai.com chatgpt.com api.openai.com generativelanguage.googleapis.com bezalel.genericjam.com study.genericjam.com),
        do: Mob.DNS.resolve(host)

    :ok = Bezalel.Certs.install!()

    # rho (models, sign-in, usage, the agent loop, the Dyn layer). Mob
    # doesn't start a dep's Applications on device, so the HTTP stack is
    # started first. The registry holds the study tools; with Dyn on
    # (config :rho, :dyn) it adds the dyn_* tools the Workshop builds with
    # and the tools the user built (Bezalel.Workshop). Dyn's boot loads the
    # current generation (or reverts one whose launch died) before the
    # first screen, whose first frame starts its clock to "stable". Live
    # names its loops in its own Registry.
    {:ok, _} = Application.ensure_all_started(:req_llm)
    :ok = load_core()
    {:ok, _} = Rho.Supervisor.start_link(tools: Live.tools())
    boot = Rho.Dyn.boot()
    Logger.info("[dyn] boot: #{inspect(boot)}")
    {:ok, _} = Live.start_link()
    # The study library: fetches the pack list on first launch, resumes a
    # download the app was stopped in, and runs downloads outside the screen.
    # First its directory: out of iCloud backup, with what older builds
    # left in Documents moved in (Bezalel.Packs.Storage).
    :ok = Storage.prepare()
    {:ok, _} = Bezalel.Packs.start_link()

    {:ok, _} = Application.ensure_all_started(:ecto_sqlite3)
    {:ok, _} = Bezalel.Repo.start_link()

    Ecto.Migrator.with_repo(Bezalel.Repo, fn repo ->
      Ecto.Migrator.run(repo, migrations_dir(), :up, all: true)
    end)

    # Linked computers: dial the websites this phone has linked computers
    # on (Bezalel.Link; each dialer also resolves its host before connecting).
    {:ok, _} = Bezalel.Link.start_link()
    :ok = Bezalel.Link.resume()

    Mob.Screen.start_root(Bezalel.AppScreen)
    Mob.Dist.ensure_started(node: :"bezalel_android@127.0.0.1", cookie: :mob_secret)
  end

  @doc """
  Loads bezalel_core's modules (the study tools, the agent's surface and
  what they use). rho's
  Dyn layer fixes its Core digest when it boots (`Rho.Dyn.Compiler.runtime/0`),
  from the host app's modules (`config :rho, :dyn, app: :bezalel`) plus the
  loaded ones under `Bezalel.`. The study code is bezalel_core's, so it's
  loaded first: a change to any of it then re-checks the tools built in the
  Workshop, as when it lived in this app. Call it before
  `Rho.Supervisor.start_link/1`.
  """
  @spec load_core() :: :ok
  def load_core do
    _ = Application.load(:bezalel_core)

    case Application.spec(:bezalel_core, :modules) do
      nil ->
        Logger.warning(
          "[dyn] bezalel_core's .app isn't on the code path; its modules count when loaded"
        )

      modules ->
        Code.ensure_all_loaded!(modules)
    end
  end

  # Returns the path to the migrations directory for the current environment.
  #
  # WHY NOT Application.app_dir/2?
  #
  # Application.app_dir(app, "priv/repo/migrations") calls :code.priv_dir(app)
  # under the hood. That works in a normal `mix run` dev environment where the
  # app lives in $OTP_ROOT/lib/APP-VERSION/ebin/.
  #
  # On Android and iOS, Mob deploys .beam files to a flat -pa directory with no
  # versioned lib structure, so :code.priv_dir/1 returns {error, bad_name}.
  # Ecto.Migrator.run/3 silently finds zero migrations and logs "Migrations
  # already up" — tables are never created and any query against them crashes
  # the screen GenServer, making the screen appear frozen.
  #
  # The fix: mob_beam.c/mob_beam.m set MOB_BEAMS_DIR=beams_dir before erl_start.
  # The deployer pushes priv/ into beams_dir/priv/ and runs chmod -R 755 on it
  # (mkdir-as-root creates system:system drwxrwx--x dirs that the app process
  # can traverse but not list, breaking Path.wildcard). Here we read MOB_BEAMS_DIR
  # and pass the explicit path to Ecto.Migrator.run/4.
  defp migrations_dir do
    case System.get_env("MOB_BEAMS_DIR") do
      nil -> Application.app_dir(:bezalel, "priv/repo/migrations")
      beams_dir -> Path.join([beams_dir, "priv", "repo", "migrations"])
    end
  end
end
