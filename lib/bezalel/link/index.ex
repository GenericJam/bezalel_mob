defmodule Bezalel.Link.Index do
  @moduledoc """
  The phone's canonical, transcript-free shelf index. Only conversations with
  a written session file are listed; an index delta reads one conversation,
  while a reconnect snapshot walks the whole shelf.
  """
  import Ecto.Query

  alias Bezalel.{Library, Repo}
  alias Bezalel.Library.Conversation
  alias Rho.Session

  @doc "All written conversations currently on the shelf."
  @spec snapshot() :: [map()]
  def snapshot do
    Repo.all(
      from c in Conversation,
        where: is_nil(c.deleted_at) and not is_nil(c.session_id) and not is_nil(c.session_file)
    )
    |> Enum.flat_map(&List.wrap(entry_for(&1)))
  end

  @doc "The current index entry for a conversation id, or nil if it isn't on the shelf."
  @spec entry(integer()) :: map() | nil
  def entry(id), do: id |> Library.get_conversation() |> entry_for()

  @doc "The session id only if its file has been written, including a soft-deleted conversation."
  @spec written_uid(Conversation.t()) :: String.t() | nil
  def written_uid(%Conversation{} = c), do: if(file_size(c), do: c.session_id)

  defp entry_for(nil), do: nil

  defp entry_for(%Conversation{} = c) do
    case file_size(c) do
      nil -> nil
      size -> indexed(c, size)
    end
  end

  defp file_size(%Conversation{session_id: nil}), do: nil
  defp file_size(%Conversation{session_file: nil}), do: nil

  defp file_size(%Conversation{session_id: uid, session_file: file}) do
    # Never follow a stored filename outside rho's session directory, or a
    # symlink in it. A session made but not yet written isn't an index entry.
    if Path.basename(file) == file and Path.extname(file) == ".jsonl" and
         String.ends_with?(Path.rootname(file), "_" <> uid) do
      case File.lstat(Path.join(Session.dir(), file)) do
        {:ok, %File.Stat{type: :regular, size: size}} when size > 0 -> size
        _ -> nil
      end
    end
  end

  defp indexed(c, size) do
    last_reply =
      c.id
      |> Library.messages()
      |> Enum.reduce(nil, fn message, last ->
        if message.role == :agent, do: message, else: last
      end)

    preview =
      case last_reply do
        %{blocks: blocks} when is_list(blocks) ->
          blocks
          |> Enum.find(&(&1["id"] == "sum" or &1["type"] == "SUMMARY"))
          |> summary_text()
          |> String.trim()
          |> cap(140)

        _ ->
          ""
      end

    %{
      uid: c.session_id,
      session_file: c.session_file,
      name: cap(c.name, 256),
      summary: if(is_binary(c.summary), do: cap(c.summary, 500), else: nil),
      kicker: cap(c.kicker, 64),
      kind: cap(c.kind, 64),
      pushback: c.pushback,
      message_count: c.message_count,
      updated_at: DateTime.to_iso8601(c.updated_at),
      size: size,
      preview: preview
    }
  end

  defp summary_text(nil), do: ""

  defp summary_text(block) do
    case {block["first"], block["rest"], block["cut"]} do
      {_, rest, true} when is_binary(rest) -> rest
      {first, rest, _} when is_binary(first) and is_binary(rest) -> first <> " " <> rest
      {first, _, _} when is_binary(first) -> first
      {_, rest, _} when is_binary(rest) -> rest
      _ -> ""
    end
  end

  defp cap(value, max), do: String.slice(value, 0, max)
end
