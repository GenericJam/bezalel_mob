defmodule Bezalel.Link.Transcripts do
  @moduledoc """
  Reads one bounded chunk of a written, on-shelf rho session for a linked
  computer. The session UUID, not a client-supplied path, resolves the file.
  """

  alias Bezalel.Library
  alias Bezalel.Library.Conversation
  alias Bezalel.Link.{Shapes, Wire}
  alias Rho.Session

  @chunk_size Wire.chunk_size()

  @doc "Reads at most 256 KiB at `from`, returning the original JSONL bytes."
  @spec pull(term(), term()) ::
          {:ok, %{uid: String.t(), offset: non_neg_integer(), bytes: String.t(), eof: boolean()}}
          | {:error, :bad_request | :not_found | :read_failed}
  def pull(uid, from) do
    with true <- valid_uid?(uid) and is_integer(from) and from >= 0,
         [%Conversation{session_file: file}] <- Library.conversations_by_session([uid]),
         {:ok, path} <- path_for(file, uid),
         {:ok, %File.Stat{type: :regular}} <- File.lstat(path),
         {:ok, bytes, eof} <- read_chunk(path, from) do
      {:ok, %{uid: uid, offset: from, bytes: Base.url_encode64(bytes, padding: false), eof: eof}}
    else
      false -> {:error, :bad_request}
      [] -> {:error, :not_found}
      {:error, :enoent} -> {:error, :not_found}
      {:ok, _other} -> {:error, :not_found}
      {:error, reason} when reason in [:bad_request, :not_found] -> {:error, reason}
      _ -> {:error, :read_failed}
    end
  end

  defp valid_uid?(uid), do: Shapes.uid?(uid)

  defp path_for(file, uid) when is_binary(file) do
    if Path.basename(file) == file and String.ends_with?(file, "_" <> uid <> ".jsonl"),
      do: {:ok, Path.join(Session.dir(), file)},
      else: {:error, :not_found}
  end

  defp path_for(_file, _uid), do: {:error, :not_found}

  defp read_chunk(path, from) do
    case File.open(path, [:read, :binary, :raw]) do
      {:ok, io} ->
        try do
          with {:ok, size} <- :file.position(io, :eof),
               true <- from <= size,
               {:ok, ^from} <- :file.position(io, from),
               {:ok, bytes} <- chunk(:file.read(io, @chunk_size)) do
            {:ok, bytes, from + byte_size(bytes) >= size}
          else
            false -> {:error, :bad_request}
            _ -> {:error, :read_failed}
          end
        after
          File.close(io)
        end

      {:error, :enoent} ->
        {:error, :not_found}

      {:error, _} ->
        {:error, :read_failed}
    end
  end

  defp chunk({:ok, bytes}), do: {:ok, bytes}
  defp chunk(:eof), do: {:ok, ""}
  defp chunk(_error), do: {:error, :read_failed}
end
