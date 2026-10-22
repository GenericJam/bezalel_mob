defmodule Bezalel.Link.Serve do
  @moduledoc """
  Serves the phone's canonical material bytes and imports a linked computer's
  session without allowing its filenames to choose paths outside rho's sessions.

  Every write to a conversation's session (a website's append, create,
  metadata, delete, divergent tail; a phone turn's start; a phone edit
  through `Bezalel.Library`) runs under that conversation's lock
  (`locked/2`). A website's last line torn by a dropped connection or a
  parcel cut short stays in the file so its resend can finish it
  (`Bezalel.Link.TornTail`); a divergent tail is merged by
  `Bezalel.Link.Merge`.
  """

  import Ecto.Query

  alias Bezalel.{Library, Link, Materials, MaterialStore, Repo}
  alias Bezalel.Library.Conversation
  alias Bezalel.Link.{Merge, Shapes, TornTail, Turns, Wire}
  alias Rho.Session

  @max_offset 9_007_199_254_740_991
  @max_conflict_size 268_435_456
  # A divergent tail is decoded whole to merge it: what a phone's memory
  # takes. Past it the website is answered `too_large`.
  @max_conflict_tail 16_777_216
  @tombstones :bezalel_link_conversation_tombstone
  @stages [".link-mat-", ".link-conflict-", ".link-art-"]

  @doc """
  Runs `fun` holding the lock on conversation `uid` (one holder at a time,
  any process; not re-entrant).
  """
  @spec locked(String.t(), (-> result)) :: result when result: term()
  def locked(uid, fun), do: :global.trans({{__MODULE__, uid}, self()}, fun, [node()])

  @doc """
  Deletes what an app killed mid-transfer left staged: material and
  artifact uploads and divergent tails (`.link-mat-*`, `.link-art-*`,
  `.link-conflict-*`). Run at start, before any dialer.
  """
  @spec sweep() :: :ok
  def sweep do
    artifacts = Path.join(Rho.Config.data_dir(), "artifacts")

    dirs =
      [MaterialStore.dir(), Session.dir()] ++
        case File.ls(artifacts) do
          {:ok, uids} -> Enum.map(uids, &Path.join(artifacts, &1))
          _ -> []
        end

    for dir <- dirs,
        {:ok, %File.Stat{type: :directory}} <- [File.lstat(dir)],
        {:ok, names} <- [File.ls(dir)],
        name <- names,
        String.starts_with?(name, @stages),
        do: File.rm(Path.join(dir, name))

    :ok
  end

  @doc "Apply a newer web preference snapshot; phone settings remain authoritative."
  def preferences(%{"model" => model, "study" => study, "updated_at" => stamp}) do
    with true <- is_binary(stamp) and byte_size(stamp) <= 40,
         {:ok, incoming, 0} <- DateTime.from_iso8601(stamp),
         true <-
           is_binary(model) and byte_size(model) <= 150 and
             Bezalel.Models.get(model).id == model,
         true <- is_map(study) and byte_size(Jason.encode!(study)) <= 8192 do
      current = Bezalel.Settings.link_preferences()
      {:ok, present, 0} = DateTime.from_iso8601(current["updated_at"])

      if DateTime.compare(incoming, present) == :gt do
        Bezalel.Settings.apply_link_preferences(model, study, stamp)
        {:ok, true}
      else
        {:ok, false}
      end
    else
      _ -> {:error, :bad_request}
    end
  end

  def preferences(_), do: {:error, :bad_request}

  @doc "Applies a web metadata change only if it is newer than the phone's metadata."
  def meta(%{"uid" => uid, "fields" => fields, "updated_at" => stamp}) do
    with true <- valid_uid?(uid) and valid_fields?(fields),
         {:ok, at} <- stamp(stamp) do
      locked(uid, fn -> meta_locked(uid, fields, at) end)
    else
      _ -> {:error, :bad_request}
    end
  end

  def meta(_), do: {:error, :bad_request}

  defp valid_fields?(fields),
    do: is_map(fields) and map_size(fields) > 0 and Enum.all?(fields, &valid_field?/1)

  defp valid_field?({"name", value}), do: valid_label?(value, 256)
  defp valid_field?({key, value}) when key in ["kicker", "kind"], do: valid_label?(value, 64)
  defp valid_field?({"pushback", value}), do: is_boolean(value)
  defp valid_field?({"summary", value}), do: valid_summary?(value)
  defp valid_field?(_field), do: false

  defp meta_locked(uid, fields, at) do
    case Repo.one(from c in Conversation, where: c.session_id == ^uid) do
      %Conversation{deleted_at: nil} = c -> update_meta(c, fields, at)
      _ -> {:error, :not_found}
    end
  end

  defp update_meta(c, fields, at) do
    if DateTime.compare(at, c.updated_at) == :gt do
      set = Enum.map(fields, fn {key, value} -> {String.to_existing_atom(key), value} end)

      {1, _} =
        Repo.update_all(from(x in Conversation, where: x.id == ^c.id),
          set: [{:updated_at, at} | set]
        )

      Link.index_changed(c.id)
      {:ok, c.id, true}
    else
      {:ok, c.id, false}
    end
  end

  @doc """
  Deletes after the web Undo window: `{:ok, id}` with the purged
  conversation's id, `{:ok, nil}` for a uid the phone doesn't have. The
  purge leaves a permanent uid tombstone (`tombstone/1`) so a retry can't
  revive it; a uid the phone never had leaves none. `{:error,
  :held_by_phone}` while the phone answers in it.
  """
  def delete(%{"uid" => uid}) do
    if valid_uid?(uid),
      do: locked(uid, fn -> delete_locked(uid) end),
      else: {:error, :bad_request}
  end

  def delete(_), do: {:error, :bad_request}

  defp delete_locked(uid) do
    case Repo.one(from c in Conversation, where: c.session_id == ^uid) do
      nil -> {:ok, nil}
      c -> if Turns.phone?(uid), do: {:error, :held_by_phone}, else: delete_row(c)
    end
  end

  defp delete_row(c) do
    deleted =
      case c.deleted_at do
        nil ->
          {:ok, deleted} = Library.delete_conversation(c.id)
          deleted

        at ->
          %Library.Deleted{conversation_id: c.id, name: c.name, deleted_at: at}
      end

    :ok = Library.purge(deleted)
    {:ok, c.id}
  end

  @doc """
  Records that conversation `uid` is gone for good (purged here, by the
  phone or a website): a later `conv.create` of it, live or from a work
  parcel, is refused. One key per uid.
  """
  @spec tombstone(String.t()) :: :ok
  def tombstone(uid) when is_binary(uid), do: Mob.State.put({@tombstones, uid}, true)

  defp tombstoned?(uid), do: Mob.State.get({@tombstones, uid}) == true

  @doc "Returns a SHA-addressed material's record and one bounded chunk."
  def material(sha, from) do
    with true <- valid_sha?(sha) and valid_offset?(from),
         {:ok, material} <- MaterialStore.fetch(sha, %{}),
         {:ok, bytes, eof} <- MaterialStore.read_chunk(material, from, %{}) do
      {:ok,
       %{
         sha: sha,
         offset: from,
         bytes: Wire.b64(bytes),
         eof: eof,
         record: Materials.to_map(material)
       }}
    else
      false -> {:error, :bad_request}
      :error -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Receives one bounded upload chunk; the SHA and record are verified before import."
  def put_material(%{"record" => record, "from" => from, "bytes" => encoded} = request, staged) do
    uid = Map.get(request, "uid")

    with {:ok, material} <- decode_material(record),
         true <- is_nil(uid) or valid_uid?(uid),
         true <-
           valid_offset?(from) and from <= material.size and
             is_binary(encoded) and byte_size(encoded) <= 350_000,
         {:ok, bytes} <- Wire.unb64(encoded),
         true <-
           byte_size(bytes) <= Wire.chunk_size() and Wire.b64(bytes) == encoded and
             from + byte_size(bytes) <= material.size and
             (byte_size(bytes) > 0 or material.size == 0) do
      receive_material(material, uid, record, from, bytes, staged)
    else
      _ -> {:error, :bad_request}
    end
  end

  def put_material(_, _), do: {:error, :bad_request}

  defp receive_material(m, uid, record, 0, bytes, nil) do
    path = Path.join(MaterialStore.dir(), ".link-mat-" <> Wire.b64(:crypto.strong_rand_bytes(18)))

    with :ok <- File.mkdir_p(MaterialStore.dir()),
         {:ok, io} <- File.open(path, [:write, :exclusive, :raw, :binary]) do
      result =
        try do
          with :ok <- :file.write(io, bytes), do: :file.sync(io)
        after
          File.close(io)
        end

      if result == :ok do
        staged = %{path: path, next: byte_size(bytes), record: record, uid: uid}
        finish_material(m, staged)
      else
        File.rm(path)
        {:error, :read_failed}
      end
    else
      _ -> {:error, :read_failed}
    end
  end

  defp receive_material(
         m,
         uid,
         record,
         from,
         bytes,
         %{next: from, record: record, uid: uid} = staged
       ) do
    case File.write(staged.path, bytes, [:append, :binary]) do
      :ok -> finish_material(m, %{staged | next: from + byte_size(bytes)})
      _ -> {:error, :read_failed}
    end
  end

  defp receive_material(_, _, _, _, _, _), do: {:error, :conflict}

  defp finish_material(%{size: size}, %{next: next} = stage) when next < size,
    do: {:more, stage, next}

  defp finish_material(%{size: size} = material, %{next: size} = stage) do
    result = MaterialStore.put_file(material, stage.path, %{session_id: stage.uid})
    File.rm(stage.path)

    case result do
      {:ok, kept} -> {:ok, kept, size}
      _ -> {:error, :id_mismatch}
    end
  end

  defp decode_material(
         %{
           "id" => id,
           "size" => size,
           "name" => name,
           "mime" => mime,
           "meta" => meta,
           "derived_from" => parents
         } = record
       ) do
    if valid_sha?(id) and valid_material_size?(size) and valid_text?(name) and
         valid_text?(mime) and is_map(meta) and valid_parents?(parents),
       do: material_from(record),
       else: {:error, :bad_request}
  end

  defp decode_material(_), do: {:error, :bad_request}

  defp valid_material_size?(size), do: is_integer(size) and size in 0..268_435_456
  defp valid_text?(text), do: is_binary(text) and byte_size(text) in 1..256

  defp valid_parents?(parents),
    do:
      is_list(parents) and Enum.count_until(parents, 65) <= 64 and
        Enum.all?(parents, &valid_sha?/1)

  # `Bezalel.Materials.from_map/1` raises on a value it doesn't know (a
  # kind, a source, a date).
  defp material_from(record) do
    {:ok, Materials.from_map(record)}
  rescue
    _ in [ArgumentError, MatchError, FunctionClauseError] -> {:error, :bad_request}
  end

  @doc "Deletes a SHA-addressed material after the website's Undo period."
  def delete_material(%{"sha" => sha}) do
    if valid_sha?(sha) do
      :ok = MaterialStore.delete(sha)
      {:ok, sha}
    else
      {:error, :bad_request}
    end
  end

  def delete_material(_), do: {:error, :bad_request}

  @doc """
  Imports a shelf row for an as-yet unwritten session, without reviving a
  deletion. `updated_at` and `inserted_at` (optional, ISO 8601, the latter
  not after the former) keep an exported conversation's own dates.
  """
  def create(
        %{
          "uid" => uid,
          "session_file" => file,
          "name" => name,
          "kicker" => kicker,
          "kind" => kind,
          "pushback" => pushback
        } = request
      ) do
    row = %{
      uid: uid,
      file: file,
      name: name,
      kicker: kicker,
      kind: kind,
      pushback: pushback,
      summary: Map.get(request, "summary")
    }

    with true <- valid_row?(row),
         {:ok, stamps} <- create_stamps(request) do
      locked(uid, fn -> create_locked(Map.merge(row, stamps)) end)
    else
      _ -> {:error, :bad_request}
    end
  end

  def create(_), do: {:error, :bad_request}

  @doc """
  Appends exactly at the current file size; a resend is acknowledged where
  it matches what the file holds, and what it has past the file's end is
  appended. A complete line moves the conversation to its own `timestamp`,
  never back. `{:error, :held_by_phone}` while the phone answers in it;
  `{:error, :conflict}` for a resend into a torn line the phone has since
  written after (`Bezalel.Link.TornTail`).
  """
  def append(%{"uid" => uid, "from" => from, "bytes" => encoded}) do
    with true <-
           valid_uid?(uid) and valid_offset?(from) and
             is_binary(encoded) and byte_size(encoded) <= 350_000,
         {:ok, bytes} <- Wire.unb64(encoded),
         true <- byte_size(bytes) in 1..Wire.chunk_size() and Wire.b64(bytes) == encoded do
      locked(uid, fn -> append_locked(uid, from, bytes) end)
    else
      false -> {:error, :bad_request}
      :error -> {:error, :bad_request}
    end
  end

  def append(_), do: {:error, :bad_request}

  @doc """
  Stages a divergent server tail away from the canonical file until the
  entire tail arrives, then merges it. A tail longer than a phone can
  decode is `{:error, :too_large}`.
  """
  def conflict(%{"uid" => uid, "from" => from, "total" => total, "bytes" => encoded}, staged) do
    with true <-
           valid_uid?(uid) and valid_offset?(from) and valid_offset?(total) and
             total <= @max_conflict_size and is_binary(encoded) and
             byte_size(encoded) <= 350_000,
         {:ok, bytes} <- Wire.unb64(encoded),
         true <-
           byte_size(bytes) in 1..Wire.chunk_size() and Wire.b64(bytes) == encoded and
             from + byte_size(bytes) <= total,
         :ok <- tail_fits(total, if(staged, do: staged.start, else: from)) do
      locked(uid, fn -> conflict_locked(uid, from, total, bytes, staged) end)
    else
      {:error, :too_large} = error -> error
      _ -> {:error, :bad_request}
    end
  end

  def conflict(_, _), do: {:error, :bad_request}

  defp tail_fits(total, start) when total - start > @max_conflict_tail, do: {:error, :too_large}
  defp tail_fits(_total, _start), do: :ok

  defp conflict_locked(uid, from, total, bytes, staged) do
    case Repo.one(from c in Conversation, where: c.session_id == ^uid and is_nil(c.deleted_at)) do
      %Conversation{session_file: file} = conversation when is_binary(file) ->
        cond do
          not (valid_file?(file, uid) and regular_session?(file)) -> {:error, :not_found}
          Turns.phone?(uid) -> {:error, :held_by_phone}
          true -> Merge.stage(conversation, from, total, bytes, staged)
        end

      _ ->
        {:error, :not_found}
    end
  end

  defp create_locked(%{uid: uid, file: file} = row) do
    case Repo.all(from c in Conversation, where: c.session_id == ^uid or c.session_file == ^file) do
      [] -> create_new(row)
      [%Conversation{deleted_at: nil} = conversation] -> created_before(conversation, row)
      _ -> {:error, :conflict}
    end
  end

  defp created_before(conversation, %{uid: uid, file: file}) do
    if conversation.session_id == uid and conversation.session_file == file and
         regular_session?(file),
       do: {:ok, conversation, false},
       else: {:error, :conflict}
  end

  defp create_new(row) do
    if tombstoned?(row.uid), do: {:error, :conflict}, else: insert_new(row)
  end

  defp insert_new(row) do
    path = Path.join(Session.dir(), row.file)

    with :ok <- ensure_session_dir(),
         {:error, :enoent} <- File.lstat(path),
         {:ok, io} <- File.open(path, [:write, :exclusive, :raw, :binary]) do
      File.close(io)

      changeset =
        %Conversation{}
        |> Conversation.changeset(Map.take(row, [:name, :kicker, :kind]))
        |> Ecto.Changeset.change(
          session_id: row.uid,
          session_file: row.file,
          pushback: row.pushback,
          summary: row.summary,
          updated_at: row.updated_at,
          inserted_at: row.inserted_at
        )

      case Repo.insert(changeset) do
        {:ok, conversation} ->
          {:ok, conversation, true}

        {:error, _} ->
          File.rm(path)
          {:error, :conflict}
      end
    else
      {:ok, _} -> {:error, :conflict}
      {:error, :eexist} -> {:error, :conflict}
      _ -> {:error, :read_failed}
    end
  end

  defp append_locked(uid, from, bytes) do
    case Repo.all(from c in Conversation, where: c.session_id == ^uid) do
      [%Conversation{deleted_at: nil} = conversation] ->
        append_checked(conversation, uid, from, bytes)

      _ ->
        {:error, :not_found}
    end
  end

  defp append_checked(%Conversation{session_file: file} = conversation, uid, from, bytes) do
    cond do
      not valid_file?(file, uid) ->
        {:error, :not_found}

      Turns.phone?(uid) ->
        {:error, :held_by_phone}

      true ->
        with :ok <- resume_torn(uid, file, from),
             do: append_resumed(conversation, file, uid, from, bytes)
    end
  end

  defp append_resumed(conversation, file, uid, from, bytes) do
    written = append_file(file, uid, from, bytes)
    if match?({:ok, _, true}, written), do: TornTail.settle(uid, from)
    append_written(conversation, file, written, bytes)
  end

  defp append_written(conversation, file, {:ok, size, true}, bytes) do
    complete_line? = String.ends_with?(bytes, "\n")

    if complete_line?,
      do: Library.touch(conversation.id, last_stamp(Path.join(Session.dir(), file)))

    {:ok, conversation, size, complete_line?}
  end

  defp append_written(conversation, _file, {:ok, size, false}, _bytes),
    do: {:ok, conversation, size, false}

  defp append_written(_conversation, _file, error, _bytes), do: error

  # A resend into a line the phone set aside: with nothing written after
  # it meanwhile the line's bytes go back (the resend then appends as
  # usual, comparing what overlaps); otherwise it is a divergent tail
  # (`conflict/2`).
  defp resume_torn(uid, file, from) do
    case TornTail.pending(uid, from) do
      nil -> :ok
      _line -> TornTail.restore(uid, Path.join(Session.dir(), file))
    end
  end

  # The time of the entries a website appended: the last line's own
  # `timestamp` (rho's ISO 8601), or nil.
  defp last_stamp(path) do
    with {:ok, %File.Stat{size: size}} when size > 1 <- File.stat(path),
         {:ok, io} <- File.open(path, [:read, :raw, :binary]) do
      try do
        with {:ok, start} <- TornTail.line_start(io, size - 1, @max_conflict_tail),
             {:ok, line} <- :file.pread(io, start, size - start),
             {:ok, %{"timestamp" => stamp}} when is_binary(stamp) <- Jason.decode(line),
             {:ok, at, _offset} <- DateTime.from_iso8601(stamp) do
          usec(at)
        else
          _ -> nil
        end
      after
        File.close(io)
      end
    else
      _ -> nil
    end
  end

  defp append_file(file, uid, from, bytes) do
    path = Path.join(Session.dir(), file)

    with {:ok, %File.Stat{type: :directory}} <- File.lstat(Session.dir()),
         {:ok, %File.Stat{type: :regular} = before} <- File.lstat(path),
         {:ok, io} <- File.open(path, [:read, :write, :raw, :binary]) do
      try do
        with {:ok, record} <- :file.read_file_info(io),
             %File.Stat{type: :regular} = opened <- File.Stat.from_record(record),
             {:ok, %File.Stat{type: :regular} = current} <- File.lstat(path),
             true <- same_file?(before, opened) and same_file?(opened, current),
             {:ok, size} <- :file.position(io, :eof) do
          append_at(io, uid, size, from, bytes)
        else
          _ -> {:error, :read_failed}
        end
      after
        File.close(io)
      end
    else
      {:error, :enoent} -> {:error, :not_found}
      {:ok, _} -> {:error, :not_found}
      _ -> {:error, :read_failed}
    end
  end

  defp append_at(io, uid, size, from, bytes) when size == from do
    with :ok <- valid_header(uid, size, bytes),
         :ok <- :file.write(io, bytes),
         :ok <- :file.sync(io) do
      {:ok, size + byte_size(bytes), true}
    else
      {:error, :bad_request} = error -> error
      _ -> {:error, :read_failed}
    end
  end

  # A resend: what the file holds past `from` must be where `bytes` starts;
  # whatever `bytes` has beyond the file's end is appended.
  defp append_at(io, _uid, size, from, bytes) when from < size do
    held = min(size - from, byte_size(bytes))

    case :file.pread(io, from, held) do
      {:ok, same} when same == binary_part(bytes, 0, held) ->
        append_rest(io, size, binary_part(bytes, held, byte_size(bytes) - held))

      _ ->
        {:error, :conflict}
    end
  end

  defp append_at(_io, _uid, _size, _from, _bytes), do: {:error, :conflict}

  defp append_rest(_io, size, ""), do: {:ok, size, false}

  defp append_rest(io, size, rest) do
    with :ok <- :file.pwrite(io, size, rest),
         :ok <- :file.sync(io) do
      {:ok, size + byte_size(rest), true}
    else
      _ -> {:error, :read_failed}
    end
  end

  defp valid_header(_uid, size, _bytes) when size > 0, do: :ok

  defp valid_header(uid, 0, bytes) do
    case :binary.split(bytes, "\n") do
      [header, _rest] when byte_size(header) <= 8192 ->
        case Jason.decode(header) do
          {:ok, %{"type" => "session", "id" => ^uid}} -> :ok
          _ -> {:error, :bad_request}
        end

      _ ->
        {:error, :bad_request}
    end
  end

  defp ensure_session_dir do
    case File.lstat(Session.dir()) do
      {:ok, %File.Stat{type: :directory}} ->
        :ok

      {:error, :enoent} ->
        with :ok <- File.mkdir_p(Session.dir()),
             {:ok, %File.Stat{type: :directory}} <- File.lstat(Session.dir()) do
          :ok
        else
          _ -> {:error, :read_failed}
        end

      _ ->
        {:error, :read_failed}
    end
  end

  defp regular_session?(file) do
    match?({:ok, %File.Stat{type: :directory}}, File.lstat(Session.dir())) and
      match?({:ok, %File.Stat{type: :regular}}, File.lstat(Path.join(Session.dir(), file)))
  end

  defp same_file?(a, b),
    do:
      a.inode == b.inode and a.major_device == b.major_device and
        a.minor_device == b.minor_device and a.size == b.size

  defp optional_stamp(nil), do: {:ok, nil}
  defp optional_stamp(value), do: stamp(value)

  defp stamp(value) when is_binary(value) and byte_size(value) <= 40 do
    case DateTime.from_iso8601(value) do
      {:ok, date, 0} -> {:ok, usec(date)}
      _ -> {:error, :bad_request}
    end
  end

  defp stamp(_value), do: {:error, :bad_request}

  # An exported conversation's dates: `inserted_at` not after `updated_at`
  # (now, without one).
  defp create_stamps(request) do
    with {:ok, at} <- optional_stamp(Map.get(request, "updated_at")),
         {:ok, inserted} <- optional_stamp(Map.get(request, "inserted_at")),
         true <- is_nil(inserted) or DateTime.compare(inserted, at || DateTime.utc_now()) != :gt,
         do: {:ok, %{updated_at: at, inserted_at: inserted}}
  end

  # The shelf keeps microseconds (`:utc_datetime_usec`).
  defp usec(%DateTime{microsecond: {us, _}} = date), do: %{date | microsecond: {us, 6}}

  defp valid_sha?(sha), do: Shapes.sha?(sha)
  defp valid_uid?(uid), do: Shapes.uid?(uid)

  @doc "A request id the phone answers: 1..128 bytes, or a JSON-safe non-negative integer."
  def valid_request_id?(id) when is_binary(id), do: byte_size(id) in 1..128
  def valid_request_id?(id) when is_integer(id), do: id in 0..@max_offset
  def valid_request_id?(_id), do: false

  defp valid_file?(file, uid), do: Shapes.session_file?(file, uid)

  defp valid_label?(value, max),
    do: is_binary(value) and byte_size(value) in 1..max and String.valid?(value)

  defp valid_row?(row) do
    valid_uid?(row.uid) and valid_file?(row.file, row.uid) and valid_label?(row.name, 256) and
      valid_label?(row.kicker, 64) and valid_label?(row.kind, 64) and is_boolean(row.pushback) and
      valid_summary?(row.summary)
  end

  defp valid_summary?(value),
    do: is_nil(value) or (is_binary(value) and byte_size(value) <= 500 and String.valid?(value))

  defp valid_offset?(from), do: is_integer(from) and from in 0..@max_offset
end
