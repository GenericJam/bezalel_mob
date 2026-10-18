defmodule Bezalel.Packs.Storage do
  @moduledoc """
  Where the study packs live on the phone, and getting them there.

  The packs (182-607 MB) can be downloaded again, so Apple rejects an app
  that backs them up to iCloud. They live in `packs` under the app support
  directory (`Mob.Storage.dir(:app_support)`: Library/Application Support on
  iOS, `filesDir` on Android), and on iOS that directory is excluded from
  backup. `packs_dir/0` is the one function that names the directory;
  bezalel_core reads it through `config :bezalel_core, :packs_dir`
  (config/config.exs), so `Bezalel.Study.DB.dir/0`, which `Bezalel.Packs`
  and the study tools both use, returns it.

  Builds before `bezalel-lac.3` kept the packs in `Mob.data_dir()/packs`,
  which on iOS is Documents (backed up). `prepare/1` moves them at startup;
  on Android both directories are `filesDir`, so there is nothing to move.
  """

  require Logger

  alias Bezalel.Study.DB

  @root_key {__MODULE__, :root}
  @partial ".migrating"

  @doc """
  The directory the packs directory is in: the app support directory on the
  phone, `Mob.data_dir/0` off it (host runs have no app support directory).
  Resolved once per run: on Android the resolution needs the activity, which
  a tool call made while the app is in the background may not have.
  """
  @spec root() :: Path.t()
  def root do
    case :persistent_term.get(@root_key, nil) do
      nil ->
        root = resolve_root()
        :persistent_term.put(@root_key, root)
        root

      root ->
        root
    end
  end

  defp resolve_root do
    if Code.ensure_loaded?(:mob_nif),
      do: Mob.Storage.dir(:app_support),
      else: Mob.data_dir()
  end

  @doc """
  The packs directory: `config :bezalel, :study_packs_dir` when set (tests,
  host scripts), else `packs` under `root/0`.
  """
  @spec packs_dir() :: Path.t()
  def packs_dir do
    Application.get_env(:bezalel, :study_packs_dir) || Path.join(root(), "packs")
  end

  @doc "Where builds before `bezalel-lac.3` kept the packs."
  @spec legacy_dir() :: Path.t()
  def legacy_dir, do: Path.join(Mob.data_dir(), "packs")

  @doc """
  Readies the packs directory, at every start (`Bezalel.App.on_start/0`):
  creates it, excludes it from backup, then moves in what an older build
  left in `legacy_dir/0` (`migrate/3`). Excluded first, so a pack is never
  in a backed-up directory under its new name, even if the app is killed
  mid-move. The exclusion is set at every launch, not once: a restore or a
  move to a new phone can drop it.

  A pack that can't be moved stays where it was and is moved at the next
  start; that, and an exclusion that returns an error, is logged and the
  app starts anyway (a library in a backed-up directory beats none). It
  raises when the packs directory can't be created, which `Bezalel.Packs`
  couldn't run without either, and passes on an exception from the
  exclusion (a bug, not a condition). Options (tests): `:from` (default
  `legacy_dir/0`, none when `config :bezalel, :study_packs_dir` is set),
  `:to` (default `Bezalel.Study.DB.dir/0`), `:exclude` (default
  `Mob.Storage.exclude_from_backup/1`), `:rename` (default `File.rename/2`).
  """
  @spec prepare(keyword()) :: :ok
  def prepare(opts \\ []) do
    to = Keyword.get_lazy(opts, :to, &DB.dir/0)
    from = Keyword.get_lazy(opts, :from, &default_from/0)
    exclude = Keyword.get(opts, :exclude, &Mob.Storage.exclude_from_backup/1)
    rename = Keyword.get(opts, :rename, &File.rename/2)

    File.mkdir_p!(to)

    case exclude.(to) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("packs: can't exclude #{to} from backup: #{inspect(reason)}")
    end

    if from, do: log_failures(migrate(from, to, rename))
    :ok
  end

  defp default_from do
    if Application.get_env(:bezalel, :study_packs_dir), do: nil, else: legacy_dir()
  end

  defp log_failures(:ok), do: :ok

  defp log_failures({:error, failures}) do
    for {path, reason} <- failures,
        do:
          Logger.warning("packs: can't move #{path} out of the old directory: #{inspect(reason)}")

    :ok
  end

  @doc """
  Moves everything in `from` (packs, `installed.json`, `manifest.json`,
  `.download/` with its partial downloads) into `to`, then removes `from`.

  Each file is renamed into place (one volume: atomic, so an interrupted
  move leaves every file whole in one directory or the other). When rename
  can't cross volumes, a regular file is copied to `<name>.migrating` beside
  its destination, checked against the source's size, renamed into place,
  and only then is the source deleted. Run again after an interruption, it
  carries on: a file already in `to` wins over its copy left in `from` (the
  newer build may have written it), and a half-copied `.migrating` file is
  copied again. Entries are compared by their own type, not their target's
  (a symlink is moved as a link); a destination of another type than its
  source is a failure, and both are left alone.

  Returns `:ok`, or `{:error, [{path, reason}]}` for what couldn't be moved
  (`from` is then left in place). Nothing to move (no `from`, or `from ==
  to`) is `:ok`.
  """
  @spec migrate(Path.t(), Path.t(), (Path.t(), Path.t() -> :ok | {:error, term()})) ::
          :ok | {:error, [{Path.t(), term()}]}
  def migrate(from, to, rename \\ &File.rename/2) do
    if Path.expand(from) == Path.expand(to) or type(from) != :directory do
      :ok
    else
      failures =
        case File.mkdir_p(to) do
          :ok -> move_dir(from, to, rename)
          {:error, reason} -> [{to, reason}]
        end

      if failures == [], do: :ok, else: {:error, failures}
    end
  end

  defp move_dir(from, to, rename) do
    case File.ls(from) do
      {:ok, names} ->
        names
        |> Enum.flat_map(&move(Path.join(from, &1), Path.join(to, &1), rename))
        |> remove_when_empty(from)

      {:error, reason} ->
        [{from, reason}]
    end
  end

  # Only once everything in it moved; a failure leaves the rest for the next
  # start.
  defp remove_when_empty([], dir) do
    case File.rmdir(dir) do
      :ok -> []
      {:error, reason} -> [{dir, reason}]
    end
  end

  defp remove_when_empty(failures, _dir), do: failures

  defp move(src, dst, rename) do
    case {type(src), type(dst)} do
      {{:error, reason}, _} -> [{src, reason}]
      {_, {:error, reason}} -> [{dst, reason}]
      {:directory, :none} -> make_dir_and_move(src, dst, rename)
      {:directory, :directory} -> move_dir(src, dst, rename)
      {:directory, _} -> [{src, :eexist}]
      {leaf, :none} -> move_leaf(leaf, src, dst, rename)
      {same, same} -> drop(src)
      {_, _} -> [{src, :eexist}]
    end
  end

  defp make_dir_and_move(src, dst, rename) do
    case File.mkdir(dst) do
      :ok -> move_dir(src, dst, rename)
      {:error, reason} -> [{dst, reason}]
    end
  end

  defp move_leaf(leaf, src, dst, rename) do
    case rename.(src, dst) do
      :ok -> []
      {:error, :exdev} when leaf == :regular -> copy(src, dst)
      {:error, reason} -> [{src, reason}]
    end
  end

  # The entry's own type: lstat, so a symlink is a link, not its target.
  defp type(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: type}} -> type
      {:error, :enoent} -> :none
      {:error, reason} -> {:error, reason}
    end
  end

  defp drop(src) do
    case File.rm(src) do
      :ok -> []
      {:error, reason} -> [{src, reason}]
    end
  end

  defp copy(src, dst) do
    partial = dst <> @partial

    with {:ok, %{size: size}} <- File.stat(src),
         :ok <- File.cp(src, partial),
         {:ok, %{size: ^size}} <- File.stat(partial),
         :ok <- File.rename(partial, dst) do
      drop(src)
    else
      {:ok, %File.Stat{}} ->
        File.rm(partial)
        [{src, :size_mismatch}]

      {:error, reason} ->
        File.rm(partial)
        [{src, reason}]
    end
  end
end
