defmodule Bezalel.Link.Artifacts do
  @moduledoc """
  Transfers rho's `artifacts/<session uuid>/<call id>.txt` side files.
  Names and UUIDs are checked before making a path. Incoming chunks stage in
  that directory and only become visible after their SHA-256 verifies.
  """

  alias Bezalel.Link.{Shapes, Wire}

  @max_size 268_435_456

  def list(uid) do
    if valid_uid?(uid) do
      files =
        case File.ls(folder(uid)) do
          {:ok, names} -> names
          {:error, :enoent} -> []
          _ -> []
        end

      entries =
        for name <- files,
            valid_name?(name),
            {:ok, %File.Stat{type: :regular, size: size}} <- [File.lstat(path(uid, name))],
            size <= @max_size,
            {:ok, sha} <- [digest(path(uid, name))],
            do: %{"name" => name, "sha" => sha, "size" => size}

      {:ok, entries}
    else
      {:error, :bad_request}
    end
  end

  def chunk(uid, name, from) do
    with true <-
           valid_uid?(uid) and valid_name?(name) and
             is_integer(from) and from >= 0,
         {:ok, %File.Stat{type: :regular, size: size}} <- File.lstat(path(uid, name)),
         true <- from <= size,
         {:ok, io} <- File.open(path(uid, name), [:read, :raw, :binary]) do
      try do
        case :file.pread(io, from, Wire.chunk_size()) do
          {:ok, bytes} ->
            {:ok,
             %{
               "uid" => uid,
               "name" => name,
               "from" => from,
               "bytes" => Wire.b64(bytes),
               "eof" => from + byte_size(bytes) >= size
             }}

          :eof ->
            {:ok, %{"uid" => uid, "name" => name, "from" => from, "bytes" => "", "eof" => true}}

          _ ->
            {:error, :read_failed}
        end
      after
        File.close(io)
      end
    else
      false -> {:error, :bad_request}
      {:error, :enoent} -> {:error, :not_found}
      _ -> {:error, :read_failed}
    end
  end

  def put(
        %{
          "uid" => uid,
          "name" => name,
          "sha" => sha,
          "total" => total,
          "from" => from,
          "bytes" => encoded
        },
        stage
      ) do
    with true <-
           valid_uid?(uid) and valid_name?(name) and Shapes.sha?(sha) and
             valid_range?(total, from) and is_binary(encoded) and byte_size(encoded) <= 350_000,
         {:ok, bytes} <- Wire.unb64(encoded),
         true <- Wire.b64(bytes) == encoded and valid_chunk?(bytes, from, total) do
      write_chunk(uid, name, sha, total, from, bytes, stage)
    else
      _ -> {:error, :bad_request}
    end
  end

  def put(_, _), do: {:error, :bad_request}

  defp valid_range?(total, from),
    do: is_integer(total) and total in 0..@max_size and is_integer(from) and from in 0..total

  defp valid_chunk?(bytes, from, total),
    do:
      byte_size(bytes) <= Wire.chunk_size() and from + byte_size(bytes) <= total and
        (bytes != "" or total == 0)

  defp write_chunk(uid, name, sha, total, 0, bytes, nil) do
    temp = Path.join(folder(uid), ".link-art-" <> Wire.b64(:crypto.strong_rand_bytes(18)))

    with :ok <- File.mkdir_p(folder(uid)),
         {:ok, io} <- File.open(temp, [:write, :exclusive, :raw, :binary]) do
      result =
        try do
          with :ok <- :file.write(io, bytes), do: :file.sync(io)
        after
          File.close(io)
        end

      if result == :ok do
        stage = %{
          path: temp,
          uid: uid,
          name: name,
          sha: sha,
          total: total,
          next: byte_size(bytes)
        }

        finish(stage)
      else
        File.rm(temp)
        {:error, :read_failed}
      end
    else
      _ -> {:error, :read_failed}
    end
  end

  defp write_chunk(
         uid,
         name,
         sha,
         total,
         from,
         bytes,
         %{uid: uid, name: name, sha: sha, total: total, next: from} = stage
       ) do
    case File.write(stage.path, bytes, [:append, :binary]) do
      :ok -> finish(%{stage | next: from + byte_size(bytes)})
      _ -> {:error, :read_failed}
    end
  end

  defp write_chunk(_, _, _, _, _, _, _), do: {:error, :conflict}

  defp finish(%{next: next, total: total} = stage) when next < total,
    do: {:more, stage, next}

  defp finish(%{next: total, total: total, sha: sha} = stage) do
    result =
      with {:ok, ^sha} <- digest(stage.path) do
        target = path(stage.uid, stage.name)

        case File.lstat(target) do
          {:error, :enoent} -> File.rename(stage.path, target)
          {:ok, %File.Stat{type: :regular}} -> File.rename(stage.path, target)
          _ -> {:error, :read_failed}
        end
      end

    File.rm(stage.path)
    if result == :ok, do: {:ok, total}, else: {:error, :id_mismatch}
  end

  defp digest(path) do
    with {:ok, %File.Stat{type: :regular}} <- File.lstat(path),
         {:ok, io} <- File.open(path, [:read, :raw, :binary]) do
      try do
        hash(io, :crypto.hash_init(:sha256))
      after
        File.close(io)
      end
    end
  end

  defp hash(io, state) do
    case :file.read(io, 262_144) do
      {:ok, bytes} -> hash(io, :crypto.hash_update(state, bytes))
      :eof -> {:ok, Base.encode16(:crypto.hash_final(state), case: :lower)}
      {:error, _} = error -> error
    end
  end

  defp valid_uid?(uid), do: Shapes.uid?(uid)
  defp valid_name?(name), do: Shapes.artifact?(name)
  defp folder(uid), do: Path.join([Rho.Config.data_dir(), "artifacts", uid])
  defp path(uid, name), do: Path.join(folder(uid), name)
end
