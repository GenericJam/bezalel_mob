defmodule Bezalel.Link.TornTail do
  @moduledoc """
  A session's torn last line: a website's append cut short (chunks are
  256 KiB, so a long line takes several; a dropped connection or a work
  parcel cut short leaves part of one), or a write of the phone's own cut
  short by a crash.

  The partial line stays in the file, so the website's resend from the
  size the phone acknowledged can finish it. Before the phone writes,
  `repair/1` sets it aside: the bytes go to `.link-torn-<uid>` in rho's
  sessions directory, their offset to `Mob.State`, and the file ends at
  its last complete line, so nothing the phone writes joins it. A resend
  into that line (`pending/2`) puts the bytes back when the phone wrote
  nothing since (`restore/2`); otherwise the website's divergent tail is
  staged from the phone's file up to the line plus the bytes set aside
  (its own file) and merged (`Bezalel.Link.Merge`). All of it runs under
  the conversation's lock (`Bezalel.Link.Serve.locked/2`).
  """

  import Ecto.Query

  alias Bezalel.{Library, Link, Repo}
  alias Bezalel.Library.Conversation
  alias Bezalel.Link.Shapes
  alias Rho.Session

  @key :bezalel_link_torn_tail
  @block 65_536

  @doc "Sets aside the session's torn last line, if it has one."
  @spec repair(String.t()) :: :ok
  def repair(uid) do
    with true <- Shapes.uid?(uid),
         [%Conversation{} = c] <- Repo.all(from c in Conversation, where: c.session_id == ^uid),
         path when is_binary(path) <- Library.session_path(c),
         {:ok, %File.Stat{type: :regular, size: size}} when size > 0 <- File.lstat(path),
         {:ok, cut} when cut < size <- complete_size(path, size),
         :ok <- set_aside(uid, path, cut) do
      Link.index_changed(c.id)
    end

    :ok
  end

  @doc """
  The line set aside for `uid` when a resend from `from` falls inside it
  (past its start, up to its end): `{start, fragment_path, size}`, or nil.
  """
  @spec pending(String.t(), non_neg_integer()) ::
          {non_neg_integer(), Path.t(), pos_integer()} | nil
  def pending(uid, from) do
    with start when is_integer(start) and from > start <- Mob.State.get({@key, uid}),
         {:ok, %File.Stat{type: :regular, size: size}} when from <= start + size <-
           File.lstat(path(uid)) do
      {start, path(uid), size}
    else
      _ -> nil
    end
  end

  @doc """
  Settles the line set aside for `uid` once a website's write from `from`
  reached into it or before it (an append, a merge): the website's copy
  and the phone's agree from there on.
  """
  @spec settle(String.t(), non_neg_integer()) :: :ok
  def settle(uid, from) do
    case Mob.State.get({@key, uid}) do
      start when is_integer(start) ->
        if from <= start + fragment_size(uid), do: forget(uid), else: :ok

      _ ->
        :ok
    end
  end

  @doc """
  Puts the line set aside back at the end of the session file `path`, if
  the file still ends where it was cut: `:ok`, or `{:error, :conflict}`
  when the phone wrote since.
  """
  @spec restore(String.t(), Path.t()) :: :ok | {:error, :conflict | :read_failed}
  def restore(uid, path) do
    with start when is_integer(start) <- Mob.State.get({@key, uid}),
         {:ok, %File.Stat{type: :regular, size: ^start}} <- File.lstat(path),
         {:ok, %File.Stat{size: size}} <- File.lstat(path(uid)),
         {:ok, io} <- File.open(path, [:append, :raw, :binary]) do
      restored =
        try do
          with :ok <- copy(path(uid), io, size), do: :file.sync(io)
        after
          File.close(io)
        end

      if restored == :ok, do: forget(uid), else: {:error, :read_failed}
    else
      _ -> {:error, :conflict}
    end
  end

  @doc "Drops what was set aside for `uid`."
  @spec forget(String.t()) :: :ok
  def forget(uid) do
    if Shapes.uid?(uid) do
      File.rm(path(uid))
      Mob.State.delete({@key, uid})
    end

    :ok
  end

  @doc "Copies the first `length` bytes of the file `source` to the open `target`."
  @spec copy(Path.t(), :file.io_device(), non_neg_integer()) :: :ok | :error
  def copy(source, target, length) do
    with {:ok, io} <- File.open(source, [:read, :raw, :binary]) do
      try do
        case :file.copy(io, target, length) do
          {:ok, ^length} -> :ok
          _ -> :error
        end
      after
        File.close(io)
      end
    end
  end

  @doc """
  Where the line that ends at `upto` in the open file starts (just past the
  newline before it, 0 for none), looking back at most `limit` bytes.
  """
  @spec line_start(:file.io_device(), non_neg_integer(), non_neg_integer()) ::
          {:ok, non_neg_integer()} | :error
  def line_start(io, upto, limit), do: scan_back(io, upto, max(upto - limit, 0))

  defp scan_back(_io, 0, _floor), do: {:ok, 0}
  defp scan_back(_io, pos, floor) when pos <= floor, do: :error

  defp scan_back(io, pos, floor) do
    from = max(pos - @block, floor)

    case :file.pread(io, from, pos - from) do
      {:ok, block} -> newline_in(io, block, from, floor)
      _ -> :error
    end
  end

  defp newline_in(io, block, from, floor) do
    case :binary.matches(block, "\n") do
      [] -> scan_back(io, from, floor)
      matches -> {:ok, from + elem(List.last(matches), 0) + 1}
    end
  end

  defp path(uid), do: Path.join(Session.dir(), ".link-torn-" <> uid)

  defp fragment_size(uid) do
    case File.lstat(path(uid)) do
      {:ok, %File.Stat{size: size}} -> size
      _ -> 0
    end
  end

  # The bytes past `cut` to the side, then the file cut there.
  defp set_aside(uid, path, cut) do
    with {:ok, io} <- File.open(path, [:read, :write, :raw, :binary]) do
      try do
        with :ok <- copy_rest(io, cut, uid),
             :ok <- Mob.State.put({@key, uid}, cut),
             {:ok, ^cut} <- :file.position(io, cut),
             :ok <- :file.truncate(io),
             do: :file.sync(io)
      after
        File.close(io)
      end
    end
  end

  defp copy_rest(io, from, uid) do
    with {:ok, target} <- File.open(path(uid), [:write, :raw, :binary]) do
      try do
        with {:ok, ^from} <- :file.position(io, from),
             {:ok, _} <- :file.copy(io, target),
             do: :file.sync(target)
      after
        File.close(target)
      end
    end
  end

  # The size up to the end of the file's last complete line.
  defp complete_size(path, size) do
    with {:ok, io} <- File.open(path, [:read, :raw, :binary]) do
      try do
        case :file.pread(io, size - 1, 1) do
          {:ok, "\n"} -> {:ok, size}
          {:ok, _} -> line_start(io, size, size)
          _ -> :error
        end
      after
        File.close(io)
      end
    end
  end
end
