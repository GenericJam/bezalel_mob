defmodule Bezalel.Packs do
  @moduledoc """
  The study library on this phone: which packs are installed, downloading
  them from the published manifest
  (https://bezalel.genericjam.com/packs/manifest.json, `data/README.md`
  "Publish"), checking for updates, removing optional packs.

  One process, started in `Bezalel.App.on_start/0`, outside any screen, so
  a download goes on when the user leaves Settings. Downloads run one at a
  time in a task (`Bezalel.Packs.Download`: resume, checksums, atomic
  install); the process keeps the queue, retries a dropped connection
  (resuming the partial file), and tells subscribers when anything changes:
  `{:bezalel_packs, :changed}`, and `{:bezalel_packs, {:notice, text}}`
  when a pack is ready, a download failed or a check finished.

  On disk, in the packs directory `Bezalel.Study.DB` reads:

    * `<pack>.sqlite`: the installed packs;
    * `installed.json`: what each came from (library `data_version`, raw
      size and sha256), and the packs queued for download, which resume
      when the app starts again (the OS may stop the app mid-download: iOS
      suspends it soon after it leaves the screen, Android may kill it);
    * `manifest.json`: the last manifest fetched, so Settings can list the
      packs offline;
    * `.download/`: partial downloads and unverified packs.

  A pack found without a record (copied on by hand, the `AGENTS.md` dev
  shortcut, or installed just before the app was killed) is shown as
  installed; "Check for updates" hashes it and keeps it if it matches the
  library, or replaces it.
  """
  use GenServer

  require Logger

  alias Bezalel.Packs.{Download, Manifest}
  alias Bezalel.Study.DB

  @manifest_url "https://bezalel.genericjam.com/packs/manifest.json"
  @retry_delays [2_000, 5_000, 15_000]

  @type pack_state ::
          :idle
          | :queued
          | :retrying
          | {:downloading | :installing, non_neg_integer(), pos_integer()}

  @type pack :: %{
          name: String.t(),
          description: String.t(),
          required: boolean(),
          size: non_neg_integer() | nil,
          raw_size: non_neg_integer() | nil,
          installed: %{data_version: pos_integer() | nil, size: non_neg_integer()} | nil,
          update: boolean(),
          state: pack_state(),
          error: String.t() | nil
        }

  @typedoc "`dir`: where the packs are, for a reader of an installed pack's contents."
  @type status :: %{
          packs: [pack()],
          data_version: pos_integer() | nil,
          checking: boolean(),
          notice: String.t() | nil,
          storage: non_neg_integer(),
          dir: Path.t()
        }

  # ── API ───────────────────────────────────────────────────────────────────

  @doc """
  Starts the manager. Options: `:name` (default `Bezalel.Packs`; `nil` for
  none), `:dir` (default `Bezalel.Study.DB.dir/0`), `:manifest_url`
  (default `config :bezalel, :packs_manifest_url`, else the published
  one), `:req_options`, `:retry_delays` (ms before each retry of a dropped
  download) and `:auto` (default true: fetch the manifest if none is
  stored, and resume queued downloads).
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @doc "Sends this process `{:bezalel_packs, …}` messages until it exits."
  @spec subscribe(GenServer.server()) :: :ok
  def subscribe(server \\ __MODULE__), do: GenServer.call(server, {:subscribe, self()})

  @doc "The library as Settings shows it."
  @spec status(GenServer.server()) :: status()
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @doc "Queues `name` for download (or its update)."
  @spec download(String.t(), GenServer.server()) :: :ok
  def download(name, server \\ __MODULE__), do: GenServer.call(server, {:download, name})

  @doc "Stops `name`'s download and deletes what it fetched."
  @spec cancel(String.t(), GenServer.server()) :: :ok
  def cancel(name, server \\ __MODULE__), do: GenServer.call(server, {:cancel, name})

  @doc "Deletes an optional pack from the phone."
  @spec remove(String.t(), GenServer.server()) :: :ok | {:error, String.t()}
  def remove(name, server \\ __MODULE__), do: GenServer.call(server, {:remove, name})

  @doc """
  Fetches the manifest and updates the installed packs it has newer
  versions of. The outcome arrives as a notice.
  """
  @spec check(GenServer.server()) :: :ok
  def check(server \\ __MODULE__), do: GenServer.call(server, {:check, :user})

  @doc """
  Fetches the manifest if none is held yet (the first-launch offer shows
  the sizes from it). Installs and updates nothing.
  """
  @spec load_manifest(GenServer.server()) :: :ok
  def load_manifest(server \\ __MODULE__), do: GenServer.call(server, :load_manifest)

  @doc """
  True when the phone is on a metered connection (mobile data or a
  hotspot), so the download offer can say so. False when unknown.
  """
  @spec metered?() :: boolean()
  def metered? do
    {m, f, a} = Application.get_env(:bezalel, :network_state, {Mob.Device, :network_state, []})

    case apply(m, f, a) do
      %{transport: :cellular} -> true
      %{expensive: true} -> true
      _ -> false
    end
  end

  # ── Server ────────────────────────────────────────────────────────────────

  @impl GenServer
  def init(opts) do
    dir = Keyword.get_lazy(opts, :dir, &DB.dir/0)
    File.mkdir_p!(dir)
    {:ok, sup} = Task.Supervisor.start_link()

    state = %{
      dir: dir,
      url: Keyword.get(opts, :manifest_url),
      req_options: Keyword.get(opts, :req_options, []),
      retry_delays: Keyword.get(opts, :retry_delays, @retry_delays),
      sup: sup,
      manifest: read_manifest(dir),
      checking: nil,
      notice: nil,
      queue: [],
      job: nil,
      errors: %{},
      subs: %{},
      shown: nil
    }

    if Keyword.get(opts, :auto, true),
      do: {:ok, state, {:continue, :start}},
      else: {:ok, state}
  end

  @impl GenServer
  def handle_continue(:start, state) do
    state = %{state | queue: read_installed(state.dir).pending}
    sweep(state)

    if state.manifest,
      do: {:noreply, next(state)},
      else: {:noreply, fetch(state, :startup)}
  end

  @impl GenServer
  def handle_call({:subscribe, pid}, _from, state) do
    subs = Map.put_new_lazy(state.subs, pid, fn -> Process.monitor(pid) end)
    {:reply, :ok, %{state | subs: subs}}
  end

  def handle_call(:status, _from, state), do: {:reply, build_status(state), state}

  def handle_call({:download, name}, _from, state) do
    cond do
      name not in Manifest.known() ->
        {:reply, :ok, state}

      busy?(state, name) ->
        {:reply, :ok, state}

      true ->
        state = %{state | queue: state.queue ++ [name], errors: Map.delete(state.errors, name)}
        persist_pending(state)

        state =
          cond do
            state.manifest -> next(state)
            state.checking -> state
            true -> fetch(state, :startup)
          end

        {:reply, :ok, changed(state)}
    end
  end

  def handle_call({:cancel, name}, _from, state) do
    state = state |> stop_job(name) |> Map.update!(:queue, &List.delete(&1, name))
    persist_pending(state)
    sweep(state)
    {:reply, :ok, state |> next() |> changed()}
  end

  def handle_call({:remove, name}, _from, state) do
    if required?(state, name) do
      {:reply, {:error, "The #{name} pack is needed for the study tools; it can't be removed."},
       state}
    else
      state = state |> stop_job(name) |> Map.update!(:queue, &List.delete(&1, name))
      File.rm(pack_path(state, name))
      installed = read_installed(state.dir)
      write_installed(state.dir, Map.delete(installed.packs, name), pending(state))
      sweep(state)
      {:reply, :ok, state |> next() |> changed()}
    end
  end

  def handle_call({:check, kind}, _from, state) do
    state = if state.checking, do: state, else: fetch(state, kind)
    {:reply, :ok, changed(state)}
  end

  def handle_call(:load_manifest, _from, state) do
    state = if state.checking || state.manifest, do: state, else: fetch(state, :startup)
    {:reply, :ok, changed(state)}
  end

  @impl GenServer
  def handle_info({:progress, pid, {phase, done, total}}, %{job: %{pid: pid} = job} = state) do
    {:noreply, progressed(%{state | job: %{job | phase: phase, done: done, total: total}})}
  end

  def handle_info({:progress, _pid, _progress}, state), do: {:noreply, state}

  def handle_info({ref, result}, %{job: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, finished(state, result)}
  end

  def handle_info({ref, result}, %{checking: {ref, kind}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, checked(%{state | checking: nil}, kind, result)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{job: %{ref: ref}} = state),
    do: {:noreply, finished(state, {:error, {:crash, reason}})}

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{checking: {ref, kind}} = state),
    do: {:noreply, checked(%{state | checking: nil}, kind, {:error, inspect(reason)})}

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state),
    do: {:noreply, %{state | subs: Map.delete(state.subs, pid)}}

  def handle_info({:retry, ref}, %{job: %{ref: ref, phase: :retrying} = job} = state),
    do: {:noreply, state |> start_job(job.name, job.attempts + 1) |> changed()}

  def handle_info(_message, state), do: {:noreply, state}

  # ── Manifest ──────────────────────────────────────────────────────────────

  defp fetch(state, kind) do
    url = state.url || Application.get_env(:bezalel, :packs_manifest_url, @manifest_url)
    req_options = state.req_options

    task =
      Task.Supervisor.async_nolink(state.sup, fn ->
        [url: url, retry: false, raw: true, receive_timeout: 30_000]
        |> Req.new()
        |> Req.merge(req_options)
        |> Req.request()
      end)

    %{state | checking: {task.ref, kind}}
  end

  defp checked(state, kind, {:ok, %{status: 200, body: body}}) do
    case Manifest.parse(body) do
      {:ok, manifest} ->
        write_atomic(Path.join(state.dir, "manifest.json"), body)
        state = %{state | manifest: manifest}
        state = if kind == :user, do: updates(state), else: state
        sweep(state)
        state |> next() |> changed()

      {:error, message} ->
        failed_check(state, kind, message)
    end
  end

  defp checked(state, kind, {:ok, %{status: status}}),
    do: failed_check(state, kind, "it answered #{status}")

  defp checked(state, kind, {:error, %{__exception__: true} = exception}),
    do: failed_check(state, kind, Exception.message(exception))

  defp checked(state, kind, {:error, reason}), do: failed_check(state, kind, inspect(reason))

  # Downloads waiting for the manifest can't start without it.
  defp failed_check(state, kind, reason) do
    text = "Couldn't reach the study library (#{reason}). Try again later."

    waiting =
      if state.manifest == nil,
        do: Map.new(state.queue, &{&1, text}),
        else: %{}

    state = %{state | errors: Map.merge(state.errors, waiting)}
    state = if state.manifest == nil, do: %{state | queue: []}, else: state
    persist_pending(state)

    if kind == :user or waiting != %{},
      do: notice(%{state | notice: text}, text),
      else: changed(state)
  end

  # Installed packs whose file changed in a newer library version are
  # queued; the old file stays in use until the new one has verified.
  defp updates(state) do
    %{packs: records} = read_installed(state.dir)
    version = state.manifest.data_version

    {records, queue} =
      Enum.reduce(state.manifest.packs, {records, []}, fn entry, {records, queue} ->
        record = records[entry.name]

        case plan(entry, record, File.regular?(pack_path(state, entry.name)), version) do
          :forget -> {Map.delete(records, entry.name), queue}
          :bump -> {Map.put(records, entry.name, %{record | "data_version" => version}), queue}
          :keep -> {records, queue}
          kind -> {records, [{kind, entry.name} | queue]}
        end
      end)

    queue = queue |> Enum.reverse() |> Enum.reject(fn {_, name} -> busy?(state, name) end)
    state = %{state | queue: state.queue ++ Enum.map(queue, &elem(&1, 1))}
    write_installed(state.dir, records, pending(state))

    text =
      case Enum.group_by(queue, &elem(&1, 0), &elem(&1, 1)) do
        %{update: updates, check: checks} ->
          "Updating #{list(updates)} and checking #{list(checks)} against study library version #{version}."

        %{update: names} ->
          "Updating #{list(names)} to study library version #{version}."

        %{check: names} ->
          "Checking #{list(names)} against study library version #{version}."

        _ ->
          "Up to date: study library version #{version}."
      end

    notice(%{state | notice: text}, text)
  end

  # What a check does with a pack the manifest lists: nothing; forget the
  # record of a file that's gone; hash a file that has no record; fetch a
  # changed file; or note that an unchanged one belongs to the new version.
  defp plan(_entry, _record, false = _present, _version), do: :forget
  defp plan(_entry, nil, true, _version), do: :check

  defp plan(entry, record, true, version) do
    cond do
      version <= record["data_version"] -> :keep
      record["raw_sha256"] != entry.raw_sha256 -> :update
      true -> :bump
    end
  end

  defp list(names), do: Enum.join(names, ", ")

  # ── Downloads ─────────────────────────────────────────────────────────────

  defp next(%{job: nil, queue: [name | rest], manifest: %{}} = state),
    do: start_job(%{state | queue: rest}, name, 0)

  defp next(state), do: state

  defp start_job(state, name, attempts) do
    case Manifest.entry(state.manifest, name) do
      nil ->
        state = %{
          state
          | job: nil,
            errors: Map.put(state.errors, name, "It isn't in the study library.")
        }

        persist_pending(state)
        next(state)

      entry ->
        server = self()
        dir = state.dir
        adopt = File.regular?(pack_path(state, name)) and installed_record(state, name) == nil
        opts = [adopt: adopt, req_options: state.req_options]

        task =
          Task.Supervisor.async_nolink(state.sup, fn ->
            me = self()
            Download.run(entry, dir, &send(server, {:progress, me, &1}), opts)
          end)

        job = %{
          name: name,
          entry: entry,
          ref: task.ref,
          pid: task.pid,
          attempts: attempts,
          phase: :downloading,
          done: 0,
          total: entry.size,
          version: state.manifest.data_version
        }

        state = %{state | job: job}
        persist_pending(state)
        state
    end
  end

  defp finished(%{job: job} = state, :ok) do
    entry = job.entry
    %{packs: records} = read_installed(state.dir)

    record = %{
      "data_version" => job.version,
      "raw_size" => entry.raw_size,
      "raw_sha256" => entry.raw_sha256
    }

    state = %{state | job: nil, errors: Map.delete(state.errors, job.name)}
    write_installed(state.dir, Map.put(records, job.name, record), pending(state))
    sweep(state)
    state |> next() |> notice("The #{job.name} pack is ready.")
  end

  defp finished(%{job: job} = state, {:error, reason}) do
    case retry_delay(state, job, reason) do
      nil ->
        text = "Couldn't download the #{job.name} pack: #{describe(reason)}."
        state = %{state | job: nil, errors: Map.put(state.errors, job.name, text)}
        persist_pending(state)
        sweep(state)
        state |> next() |> notice(text)

      delay ->
        Process.send_after(self(), {:retry, job.ref}, delay)
        changed(%{state | job: %{job | phase: :retrying}})
    end
  end

  # A dropped connection or a busy server is retried, resuming the part; a
  # checksum mismatch (the part was deleted) once, from scratch.
  defp retry_delay(state, job, reason) do
    case {reason, Enum.at(state.retry_delays, job.attempts)} do
      {_, nil} -> nil
      {{:transport, _}, delay} -> delay
      {{:http, status}, delay} when status >= 500 or status in [408, 429] -> delay
      {:range, _} -> 0
      {:checksum, _} when job.attempts == 0 -> 0
      _ -> nil
    end
  end

  defp describe({:transport, message}), do: "the connection failed (#{message})"
  defp describe({:http, status}), do: "the library answered #{status}"
  defp describe(:range), do: "the library couldn't resume it"
  defp describe(:checksum), do: "the download didn't match its checksum"
  defp describe(:raw_checksum), do: "the unpacked pack didn't match its checksum"
  defp describe({:file, :enospc}), do: "there isn't enough free space on the phone"
  defp describe({:file, reason}), do: "it couldn't be saved (#{reason})"
  defp describe({:crash, _reason}), do: "it stopped unexpectedly"

  defp stop_job(%{job: %{name: name} = job} = state, name) do
    Process.demonitor(job.ref, [:flush])
    Task.Supervisor.terminate_child(state.sup, job.pid)
    File.rm(Download.part(state.dir, job.entry))
    File.rm(Download.raw_part(state.dir, job.entry))
    %{state | job: nil}
  end

  defp stop_job(state, _name), do: state

  defp busy?(state, name), do: name in state.queue or match?(%{name: ^name}, state.job)

  # Removes partial files no queued or running download will continue.
  defp sweep(state) do
    staging = Download.staging_dir(state.dir)

    # The running job's own files (its entry, which a newer manifest may
    # have replaced since it started), and the parts of queued packs.
    running =
      if state.job,
        do: [
          Download.part(state.dir, state.job.entry),
          Download.raw_part(state.dir, state.job.entry)
        ],
        else: []

    queued =
      for name <- state.queue,
          entry = Manifest.entry(state.manifest, name),
          entry != nil,
          do: Download.part(state.dir, entry)

    # An unpacked file can't be resumed: only the running job's is kept.
    for file <- Path.wildcard(Path.join(staging, "*")),
        file not in running and file not in queued,
        do: File.rm(file)

    :ok
  end

  # ── Status ────────────────────────────────────────────────────────────────

  defp build_status(state) do
    %{packs: records} = read_installed(state.dir)

    names =
      case state.manifest do
        %{packs: packs} ->
          Enum.map(packs, & &1.name)

        nil ->
          Enum.filter(Manifest.known(), fn name ->
            File.regular?(pack_path(state, name)) or busy?(state, name) or
              Map.has_key?(state.errors, name)
          end)
      end

    %{
      packs: Enum.map(names, &pack_status(state, &1, records[&1])),
      data_version: state.manifest && state.manifest.data_version,
      checking: state.checking != nil,
      notice: state.notice,
      storage: storage(state),
      dir: state.dir
    }
  end

  defp pack_status(state, name, record) do
    # The download moves the verified file into place, then the server
    # writes its record when the job's result arrives: until then a first
    # install isn't done (an update keeps its old record meanwhile).
    landing? = record == nil and match?(%{name: ^name}, state.job)

    installed =
      case File.stat(pack_path(state, name)) do
        {:ok, %{type: :regular, size: size}} when not landing? ->
          %{data_version: record && record["data_version"], size: size}

        _ ->
          nil
      end

    base = %{
      name: name,
      description: "",
      required: required?(state, name),
      size: nil,
      raw_size: nil,
      installed: installed,
      update: false,
      state: pack_state(state, name),
      error: state.errors[name]
    }

    case Manifest.entry(state.manifest, name) do
      nil ->
        base

      entry ->
        update = plan(entry, record, installed != nil, state.manifest.data_version) == :update

        %{
          base
          | description: entry.description,
            size: entry.size,
            raw_size: entry.raw_size,
            update: update
        }
    end
  end

  defp pack_state(%{job: %{name: name, phase: :retrying}}, name), do: :retrying

  defp pack_state(%{job: %{name: name} = job}, name), do: {job.phase, job.done, job.total}

  defp pack_state(state, name), do: if(name in state.queue, do: :queued, else: :idle)

  defp required?(%{manifest: nil}, name), do: name == "core"

  defp required?(state, name) do
    case Manifest.entry(state.manifest, name) do
      nil -> name == "core"
      entry -> entry.required
    end
  end

  defp storage(state) do
    files =
      Enum.map(Manifest.known(), &pack_path(state, &1)) ++
        Path.wildcard(Path.join(Download.staging_dir(state.dir), "*"))

    files
    |> Enum.map(fn file ->
      case File.stat(file) do
        {:ok, %{type: :regular, size: size}} -> size
        _ -> 0
      end
    end)
    |> Enum.sum()
  end

  # ── Notifications ─────────────────────────────────────────────────────────

  defp changed(state) do
    broadcast(state, :changed)
    %{state | shown: shown(state)}
  end

  defp notice(state, text) do
    broadcast(state, {:notice, text})
    %{state | shown: shown(state)}
  end

  # Progress reaches the screen once per percent, not per chunk.
  defp progressed(state) do
    if shown(state) == state.shown, do: state, else: changed(state)
  end

  defp shown(%{job: %{phase: phase, done: done, total: total} = job}),
    do: {job.name, phase, div(done * 100, max(total, 1))}

  defp shown(_state), do: nil

  defp broadcast(state, event) do
    for pid <- Map.keys(state.subs), do: send(pid, {:bezalel_packs, event})
    :ok
  end

  # ── Files ─────────────────────────────────────────────────────────────────

  defp pack_path(state, name), do: Path.join(state.dir, name <> ".sqlite")

  defp installed_record(state, name), do: read_installed(state.dir).packs[name]

  defp pending(state), do: if(state.job, do: [state.job.name | state.queue], else: state.queue)

  defp persist_pending(state) do
    write_installed(state.dir, read_installed(state.dir).packs, pending(state))
  end

  defp read_installed(dir) do
    with {:ok, json} <- File.read(Path.join(dir, "installed.json")),
         {:ok, %{"packs" => packs, "pending" => pending}} when is_map(packs) and is_list(pending) <-
           JSON.decode(json) do
      %{packs: packs, pending: Enum.filter(pending, &(&1 in Manifest.known()))}
    else
      _ -> %{packs: %{}, pending: []}
    end
  end

  defp write_installed(dir, packs, pending) do
    write_atomic(
      Path.join(dir, "installed.json"),
      JSON.encode!(%{"packs" => packs, "pending" => Enum.uniq(pending)})
    )
  end

  defp read_manifest(dir) do
    with {:ok, json} <- File.read(Path.join(dir, "manifest.json")),
         {:ok, manifest} <- Manifest.parse(json) do
      manifest
    else
      _ -> nil
    end
  end

  # A failed write (a full disk) costs the record, not this process: a pack
  # without a record is checked again by the next "Check for updates".
  defp write_atomic(path, contents) do
    tmp = path <> ".tmp"

    case with(:ok <- File.write(tmp, contents), do: File.rename(tmp, path)) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Bezalel.Packs: couldn't write #{path}: #{inspect(reason)}")
    end
  end
end
