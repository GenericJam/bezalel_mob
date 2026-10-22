defmodule Bezalel.Link.Merge do
  @moduledoc """
  A website's divergent transcript tail (a `conv.append` with `total` the
  phone answered `conflict`): staged away from the canonical file
  (`.link-conflict-*` in rho's sessions directory) until all of it
  arrives, then merged into the phone's session by
  `Bezalel.Library.Transcript.merge/3`.

  The stage is the website's file: the phone's up to where the tail starts
  (with the bytes of a torn line set aside, `Bezalel.Link.TornTail`), then
  the tail. The merge decodes the phone's session once and, of the stage,
  only the lines from the one the tail starts in: the lines before it are
  the phone's own bytes, counted and matched against the phone's active
  branch by their last entry. `Bezalel.Link.Serve.conflict/2` refuses a
  tail too long to decode on a phone before it gets here. All of it runs
  under the conversation's lock (`Bezalel.Link.Serve.locked/2`).
  """

  alias Bezalel.{Library, Models}
  alias Bezalel.Library.{Conversation, Transcript}
  alias Bezalel.Link.{TornTail, Wire}
  alias Rho.Session

  @block 65_536
  # How far back the line a tail starts in may begin, and the longest
  # header line.
  @max_line 16_777_216
  @max_header 8_192

  @type stage :: %{
          path: Path.t(),
          start: non_neg_integer(),
          next: non_neg_integer(),
          total: non_neg_integer()
        }

  @doc """
  Stages one chunk of the tail starting at `from` (`staged` nil for its
  first): `{:more, stage, next}` until all `total` bytes are here, then the
  merge's `{:reset, size}` (the phone's file size now) or `{:error,
  :conflict | :read_failed}`. The stage file goes once merged or refused.
  """
  @spec stage(Conversation.t(), non_neg_integer(), pos_integer(), binary(), stage() | nil) ::
          {:more, stage(), non_neg_integer()}
          | {:reset, non_neg_integer()}
          | {:error, :conflict | :read_failed}
  def stage(c, from, total, bytes, nil) do
    canonical = Library.session_path(c)
    path = Path.join(Session.dir(), ".link-conflict-" <> Wire.b64(:crypto.strong_rand_bytes(18)))

    {prefix, fragment} =
      case TornTail.pending(c.session_id, from) do
        {start, fragment, _size} -> {start, fragment}
        nil -> {from, nil}
      end

    with {:ok, %File.Stat{type: :regular, size: size}} <- File.lstat(canonical),
         true <- prefix <= size,
         {:ok, target} <- File.open(path, [:write, :exclusive, :raw, :binary]) do
      written =
        try do
          write_first(target, canonical, prefix, fragment, from, bytes)
        after
          File.close(target)
        end

      staged = %{path: path, start: from, next: from + byte_size(bytes), total: total}
      if written == :ok, do: finish(c, staged), else: refuse(path, :read_failed)
    else
      {:error, :eexist} -> {:error, :read_failed}
      _ -> {:error, :conflict}
    end
  end

  def stage(c, from, total, bytes, %{next: from, total: total} = staged) do
    case File.write(staged.path, bytes, [:append, :binary]) do
      :ok -> finish(c, %{staged | next: from + byte_size(bytes)})
      _ -> {:error, :read_failed}
    end
  end

  def stage(_c, _from, _total, _bytes, _staged), do: {:error, :conflict}

  defp write_first(target, canonical, prefix, fragment, from, bytes) do
    with :ok <- TornTail.copy(canonical, target, prefix),
         :ok <- if(fragment, do: TornTail.copy(fragment, target, from - prefix), else: :ok),
         :ok <- :file.write(target, bytes),
         do: :file.sync(target)
  end

  defp refuse(path, reason) do
    File.rm(path)
    {:error, reason}
  end

  defp finish(_c, %{next: next, total: total} = staged) when next < total,
    do: {:more, staged, next}

  # The stage goes whatever the merge does (raises included).
  defp finish(c, staged) do
    result = merge(c, staged)
    if match?({:reset, _}, result), do: TornTail.settle(c.session_id, staged.start)
    result
  after
    File.rm(staged.path)
  end

  defp merge(c, staged) do
    path = Library.session_path(c)
    # The merge appends to the phone's file: never after a torn line.
    :ok = TornTail.repair(c.session_id)

    case File.open(staged.path, [:read, :raw, :binary]) do
      {:ok, io} ->
        try do
          merge_from(io, c, path, staged)
        after
          File.close(io)
        end

      _ ->
        {:error, :read_failed}
    end
  end

  defp merge_from(io, c, path, staged) do
    with {:ok, server} <- read_server(io, staged, c.session_id),
         {:ok, phone, phone_branch} <- Session.open(path, Models.default()),
         true <- phone.id == c.session_id,
         {:ok, base} <- base_branch(phone_branch, server),
         true <- disjoint?(server.tail, base) do
      apply_plan(c, path, {phone, phone_branch}, base, server.tail)
    else
      _ -> {:error, :conflict}
    end
  end

  # What the stage holds: how many complete lines come before the line the
  # tail starts in, the id of the last of them, and the entries from that
  # line on.
  defp read_server(io, staged, uid) do
    with {:ok, cut} <- TornTail.line_start(io, staged.start, @max_line),
         {:ok, tail} <- :file.pread(io, cut, staged.total - cut),
         true <- String.ends_with?(tail, "\n"),
         {:ok, lines} <- count_lines(io, 0, cut, 0),
         :ok <- header(io, lines, uid),
         {:ok, leaf} <- last_id(io, cut, lines),
         {:ok, entries} <- decode_tail(tail, cut, uid) do
      {:ok, %{lines: lines, leaf: leaf, tail: entries}}
    end
  end

  defp count_lines(_io, pos, cut, n) when pos >= cut, do: {:ok, n}

  defp count_lines(io, pos, cut, n) do
    case :file.pread(io, pos, min(@block, cut - pos)) do
      {:ok, block} when block != "" ->
        count_lines(io, pos + byte_size(block), cut, n + length(:binary.matches(block, "\n")))

      _ ->
        :error
    end
  end

  defp header(_io, 0, _uid), do: :ok

  defp header(io, _lines, uid) do
    with {:ok, bytes} <- :file.pread(io, 0, @max_header),
         [line, _rest] <- :binary.split(bytes, "\n"),
         {:ok, %{"type" => "session", "id" => ^uid}} <- Jason.decode(line),
         do: :ok
  end

  # The last entry both copies had: the stage's last line before the tail's.
  defp last_id(_io, _cut, lines) when lines < 2, do: {:ok, nil}

  defp last_id(io, cut, _lines) do
    with {:ok, start} <- TornTail.line_start(io, cut - 1, @max_line),
         {:ok, line} <- :file.pread(io, start, cut - start),
         {:ok, %{"id" => id}} when is_binary(id) <- Jason.decode(line),
         do: {:ok, id}
  end

  defp decode_tail(tail, cut, uid) do
    lines = String.split(tail, "\n", trim: true)

    with {:ok, lines} <- without_header(lines, cut, uid),
         {:ok, entries} <- decode_lines(lines, []) do
      ids = Enum.map(entries, & &1["id"])
      if length(Enum.uniq(ids)) == length(ids), do: {:ok, entries}, else: :error
    end
  end

  # A tail from the very start carries the header.
  defp without_header([header | lines], 0, uid) do
    case Jason.decode(header) do
      {:ok, %{"type" => "session", "id" => ^uid}} -> {:ok, lines}
      _ -> :error
    end
  end

  defp without_header(_lines, 0, _uid), do: :error
  defp without_header(lines, _cut, _uid), do: {:ok, lines}

  defp decode_lines([], acc), do: {:ok, Enum.reverse(acc)}

  defp decode_lines([line | lines], acc) do
    case Jason.decode(line) do
      {:ok, %{"type" => type, "id" => id} = entry} when is_binary(type) and is_binary(id) ->
        decode_lines(lines, [entry | acc])

      _ ->
        :error
    end
  end

  # The part both copies had must be the phone's active branch up to its
  # last entry, every line of it (one that isn't on the branch, such as an
  # entry the phone has since deleted, makes the copies too far apart).
  defp base_branch(_phone_branch, %{lines: lines}) when lines < 2, do: {:ok, []}

  defp base_branch(phone_branch, %{lines: lines, leaf: leaf}) do
    case Enum.find_index(phone_branch, &(&1["id"] == leaf)) do
      index when index == lines - 2 -> {:ok, Enum.take(phone_branch, index + 1)}
      _ -> :error
    end
  end

  defp disjoint?(tail, base) do
    ids = MapSet.new(base, & &1["id"])
    not Enum.any?(tail, &MapSet.member?(ids, &1["id"]))
  end

  defp apply_plan(c, path, {phone, phone_branch}, base, tail) do
    server_branch = Session.branch(base ++ tail)

    case Transcript.merge(base, phone_branch, server_branch) do
      # A non-message tail must not disappear just because merge/3 only
      # counts conversation messages.
      :none ->
        held = MapSet.new(phone_branch, & &1["id"])

        if Enum.all?(tail, &MapSet.member?(held, &1["id"])),
          do: {:reset, File.stat!(path).size},
          else: {:error, :conflict}

      {:ok, {parent, copies}, _count} ->
        entries = if copies == [], do: [Transcript.marker()], else: copies
        _merged = Enum.reduce(entries, %{phone | leaf_id: parent}, &append/2)
        Library.touch(c.id)
        {:reset, File.stat!(path).size}
    end
  end

  defp append(entry, session) do
    {session, _entry} = Session.append(session, entry)
    session
  end
end
