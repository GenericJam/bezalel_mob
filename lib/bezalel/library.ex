defmodule Bezalel.Library do
  @moduledoc """
  What the app keeps on the phone: the shelf of conversations, each one's
  transcript, and the tools built in the Workshop.

  A conversation's transcript is its rho session (`Rho.Session`, a JSONL
  file in `Rho.Session.dir/0`); the conversations table is the shelf
  (name, kind, kicker, the session's id and file, the message count).
  The live agent's loop writes the session while it answers
  (`Bezalel.Agent.Live` resumes it); everything else (scripted replies,
  Delete and Undo as branch moves, a question taken back to ask again) is
  written here, only while the conversation has no loop: the caller
  releases it first, since a loop keeps its own place in the file. How
  the messages are read off the session and what the moves are:
  `Bezalel.Library.Transcript`.

  A deleted conversation leaves the shelf at once but is kept, marked,
  while its Undo is offered (`delete_conversation/1`, `undelete/1`); then
  it's purged with its session and the files kept for it (`purge/1`, and
  `purge_deleted/0` for any a closed app left).
  """
  import Ecto.Query

  alias Bezalel.Agent.Storyboard
  alias Bezalel.{Images, MaterialStore, Models, Repo}
  alias Bezalel.Library.{Conversation, Message, Tool, Transcript}
  alias Rho.Session

  defmodule Undo do
    @moduledoc """
    What a delete needs to be undone: the conversation, the leaf before
    the delete (`before`) and after it (`after`), and the deleted messages.
    """
    @type t :: %__MODULE__{
            conversation_id: integer(),
            before: String.t() | nil,
            after: String.t() | nil,
            messages: [Bezalel.Library.Message.t()]
          }
    defstruct [:conversation_id, :before, :after, messages: []]
  end

  defmodule Deleted do
    @moduledoc """
    A deleted conversation, for its Undo (`Bezalel.Library.undelete/1`) or
    its purge once the Undo is gone (`Bezalel.Library.purge/1`).
    `deleted_at` tells this delete from a later one of the same
    conversation (deleted, put back, deleted again).
    """
    @type t :: %__MODULE__{
            conversation_id: integer(),
            name: String.t(),
            deleted_at: DateTime.t()
          }
    defstruct [:conversation_id, :name, :deleted_at]
  end

  # The conversations on the shelf: not the deleted ones waiting for their
  # purge.
  defp shelf, do: from(c in Conversation, where: is_nil(c.deleted_at))

  # ── Conversations ─────────────────────────────────────────────────────────

  @doc """
  Conversations, most recently active first, each with its message count.
  `opts`: `:limit`, `:offset` (paging the shelf).
  """
  @spec list_conversations(keyword()) :: [
          %{conversation: Conversation.t(), message_count: non_neg_integer()}
        ]
  def list_conversations(opts \\ []) do
    from(c in shelf(),
      order_by: [desc: c.updated_at, desc: c.id],
      select: %{conversation: c, message_count: c.message_count}
    )
    |> limit(^Keyword.get(opts, :limit, -1))
    |> offset(^Keyword.get(opts, :offset, 0))
    |> Repo.all()
  end

  @doc "A conversation on the shelf by id, or nil (also once it's deleted)."
  @spec get_conversation(integer() | nil) :: Conversation.t() | nil
  def get_conversation(nil), do: nil
  def get_conversation(id), do: Repo.one(from(c in shelf(), where: c.id == ^id))

  @doc "The most recently active conversation, or nil when there are none."
  @spec latest_conversation() :: Conversation.t() | nil
  def latest_conversation do
    Repo.one(from(c in shelf(), order_by: [desc: c.updated_at, desc: c.id], limit: 1))
  end

  @doc "Starts a conversation (its session is created when it's first written)."
  @spec create_conversation(map()) :: {:ok, Conversation.t()} | {:error, Ecto.Changeset.t()}
  def create_conversation(attrs) do
    %Conversation{} |> Conversation.changeset(attrs) |> Repo.insert()
  end

  @doc "How many conversations are on the shelf."
  @spec conversation_count() :: non_neg_integer()
  def conversation_count, do: Repo.aggregate(shelf(), :count)

  @doc "The conversations on the shelf whose sessions are `session_ids`, in that order."
  @spec conversations_by_session([String.t()]) :: [Conversation.t()]
  def conversations_by_session(session_ids) do
    found =
      from(c in shelf(), where: c.session_id in ^session_ids)
      |> Repo.all()
      |> Map.new(&{&1.session_id, &1})

    Enum.flat_map(session_ids, &List.wrap(found[&1]))
  end

  @doc """
  Turns the conversation's Pushback switch on or off: when on, each
  finished reply in it is pushed back on (`Bezalel.Agent.auto/4`). Leaves
  its place on the shelf alone. Returns the conversation as it is now (nil
  once it's off the shelf).
  """
  @spec put_pushback(integer(), boolean()) :: Conversation.t() | nil
  def put_pushback(id, on?) when is_boolean(on?) do
    Repo.update_all(from(c in shelf(), where: c.id == ^id), set: [pushback: on?])
    get_conversation(id)
  end

  @doc """
  Deletes a conversation: it's off the shelf now (the reads above don't
  see it, writes to it do nothing) and kept until `purge/1`, so
  `undelete/1` can put it back as it was. The conversation must have no
  loop.
  """
  @spec delete_conversation(integer()) :: {:ok, Deleted.t()} | {:error, :not_found}
  def delete_conversation(id) do
    now = DateTime.utc_now()

    case Repo.one(from(c in shelf(), where: c.id == ^id)) do
      nil ->
        {:error, :not_found}

      c ->
        Repo.update_all(from(x in Conversation, where: x.id == ^id), set: [deleted_at: now])
        {:ok, %Deleted{conversation_id: id, name: c.name, deleted_at: now}}
    end
  end

  @doc """
  Puts a deleted conversation back on the shelf, where it was (its place
  is its last activity, which the delete leaves alone). `{:error, :gone}`
  once it's purged.
  """
  @spec undelete(Deleted.t()) :: :ok | {:error, :gone}
  def undelete(%Deleted{conversation_id: id, deleted_at: at}) do
    case Repo.update_all(deleted(id, at), set: [deleted_at: nil]) do
      {1, _} -> :ok
      {0, _} -> {:error, :gone}
    end
  end

  @doc """
  Purges a deleted conversation: its row, its session file, and what was
  kept by session under rho's data dir (cached pictures, spilled tool
  output, the todo list). Nothing when it was put back (or deleted again
  since: that delete's own purge comes later).
  """
  @spec purge(Deleted.t()) :: :ok
  def purge(%Deleted{conversation_id: id, deleted_at: at}) do
    id |> deleted(at) |> Repo.all() |> Enum.each(&purge_one/1)
  end

  @doc """
  Purges every deleted conversation, at start: a delete whose Undo was
  still offered when the app closed stays deleted.
  """
  @spec purge_deleted() :: :ok
  def purge_deleted do
    from(c in Conversation, where: not is_nil(c.deleted_at))
    |> Repo.all()
    |> Enum.each(&purge_one/1)
  end

  @doc """
  Deletes a conversation for good if nothing was ever written to it (a
  new study nobody asked anything in); otherwise leaves it.
  """
  @spec discard_unwritten(integer()) :: :ok
  def discard_unwritten(id) do
    Repo.delete_all(from(c in shelf(), where: c.id == ^id and is_nil(c.session_file)))
    :ok
  end

  defp deleted(id, at), do: from(c in Conversation, where: c.id == ^id and c.deleted_at == ^at)

  # The files first: a purge cut short leaves the row, so the next start
  # finishes it. The paths under rho's data dir are rho's layout
  # (`Rho.Artifacts`, `Rho.Tools.Todo`), which keep a session id like
  # rho's own (letters, digits, `-`, `_`) as it is; any other id isn't
  # made into a path.
  defp purge_one(%Conversation{} = c) do
    with path when is_binary(path) <- session_path(c), do: File.rm(path)

    if path_segment?(c.session_id) do
      data = Rho.Config.data_dir()
      File.rm_rf(Path.join(Images.dir(), c.session_id))
      File.rm_rf(Path.join([data, "artifacts", c.session_id]))
      File.rm(Path.join([data, "todos", c.session_id <> ".json"]))
    end

    # Its materials stay in Materials (the user's own files); they just no
    # longer say they went with it.
    if c.session_id, do: MaterialStore.unlink_session(c.session_id)

    Repo.delete_all(from(x in Conversation, where: x.id == ^c.id))
    :ok
  end

  defp path_segment?(id) when is_binary(id) and id != "" do
    id
    |> String.to_charlist()
    |> Enum.all?(&(&1 in ?a..?z or &1 in ?A..?Z or &1 in ?0..?9 or &1 in [?-, ?_]))
  end

  defp path_segment?(_id), do: false

  # ── Sessions ──────────────────────────────────────────────────────────────

  @doc """
  The conversation's session for a loop to resume, with the entries on
  its active branch; a new one (recorded on the shelf, written by its
  first entry) for a conversation that has none. `model` is the req_llm
  spec a new session starts on.
  """
  @spec session(integer(), String.t()) ::
          {:ok, Session.t(), [Session.entry()]} | {:error, :not_found}
  def session(conversation_id, model) do
    case get_conversation(conversation_id) do
      nil ->
        {:error, :not_found}

      conversation ->
        {session, branch} = open(conversation, model)
        {:ok, session, branch}
    end
  end

  @doc "Where a conversation's session is, or nil before it has one."
  @spec session_path(Conversation.t() | integer()) :: String.t() | nil
  def session_path(%Conversation{session_file: nil}), do: nil
  def session_path(%Conversation{session_file: file}), do: Path.join(Session.dir(), file)
  def session_path(id), do: id |> get_conversation() |> then(&(&1 && session_path(&1)))

  @doc """
  The session file of the conversation whose session is `session_id`, or
  nil. A deleted conversation's too, until it's purged: a picture still
  being made when it was deleted is made all the same, for its Undo.
  """
  @spec session_path_by_id(String.t()) :: String.t() | nil
  def session_path_by_id(session_id) do
    Repo.one(from(c in Conversation, where: c.session_id == ^session_id, limit: 1))
    |> then(&(&1 && session_path(&1)))
  end

  # ── Messages ──────────────────────────────────────────────────────────────

  # The messages last read or written, per process (the screen's, in the
  # app): one session's, with the file's size, mtime and inode when they
  # were read. A session only grows, so any write (a loop's too, which
  # Bezalel doesn't see) changes the size and the next read decodes the
  # file again; Bezalel's own writes leave the messages of the branch they
  # made. Edits always read the file: they need the entries, not the
  # messages.
  @memo {__MODULE__, :shown}

  @doc """
  A conversation's messages in order, read off its session's active
  branch. Reading them again before the session changes doesn't decode
  the file again (the last session read or written in this process is
  remembered).
  """
  @spec messages(integer()) :: [Message.t()]
  def messages(conversation_id) do
    case get_conversation(conversation_id) do
      %Conversation{session_file: file} = c when is_binary(file) -> shown(c)
      _ -> []
    end
  end

  defp shown(%Conversation{} = c) do
    path = session_path(c)
    # Before reading: a write during the read makes the next look miss.
    stamp = stamp(path)

    case Process.get(@memo) do
      {^path, ^stamp, messages} when stamp != nil ->
        messages

      _ ->
        {session, branch} = open(c, Models.default())
        remember(path, stamp, Transcript.messages(branch, session.id))
    end
  end

  defp remember(_path, nil, messages), do: messages

  defp remember(path, stamp, messages) do
    Process.put(@memo, {path, stamp, messages})
    messages
  end

  defp stamp(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{size: size, mtime: mtime, inode: inode}} -> {size, mtime, inode}
      {:error, _} -> nil
    end
  end

  @doc """
  Records that the conversation's loop wrote to its session: the shelf's
  message count follows, and the conversation moves to the top.
  """
  @spec touch(integer()) :: :ok
  def touch(conversation_id) do
    shelve(conversation_id, length(messages(conversation_id)), true)
  end

  @doc """
  Appends a message and marks the conversation active. `attrs` takes
  `:role` plus `:text` and `:attachments` (user: rho's attachments,
  `Bezalel.Materials.attachments/4`; a message may be only those), or
  `:blocks`, `:passage`, `:card`, `:image`, `:model` (a reply Bezalel
  writes: the storyboard's). Returns the message as the chat reads it. The
  conversation must have no loop.
  """
  @spec add_message(Conversation.t(), map()) :: {:ok, Message.t()} | {:error, :empty}
  def add_message(%Conversation{} = conversation, %{role: :user} = attrs) do
    text = attrs[:text] || ""
    attachments = attrs[:attachments] || []

    if text == "" and attachments == [],
      do: {:error, :empty},
      else: append(conversation, [Transcript.user(text, attachments: attachments)])
  end

  def add_message(%Conversation{} = conversation, %{role: :agent} = attrs),
    do: append(conversation, [Transcript.reply(attrs)])

  # The row is read again: the caller's copy may predate its session.
  defp append(%Conversation{id: id}, entries) do
    {session, branch} = open(get_conversation(id), Models.default())
    {session, added} = write(session, entries)
    {:ok, id |> written(session, extend(branch, added), true) |> List.last()}
  end

  @doc """
  Deletes messages (by `Bezalel.Library.Message` id): the conversation's
  session branches without their entries. Returns what Undo needs. The
  conversation must have no loop.
  """
  @spec delete_messages(integer(), [String.t()]) :: {:ok, Undo.t()} | {:error, :not_found}
  def delete_messages(conversation_id, ids) do
    with %Conversation{session_file: file} = c when is_binary(file) <-
           get_conversation(conversation_id),
         {session, branch} = open(c, Models.default()),
         shown = Transcript.messages(branch, session.id),
         [_ | _] = gone <- Enum.filter(shown, &(&1.id in ids)),
         {parent, copies} <- Transcript.delete(branch, Enum.flat_map(gone, & &1.entries)) do
      {moved, added} = move(session, parent, copies)
      written(conversation_id, moved, extend(branch, added), false)

      {:ok,
       %Undo{
         conversation_id: conversation_id,
         before: session.leaf_id,
         after: moved.leaf_id,
         messages: gone
       }}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Undoes a delete: the branch from before it, with anything added since
  copied after. `{:error, :gone}` when the session moved on another way.
  The conversation must have no loop.
  """
  @spec restore(Undo.t()) :: :ok | {:error, :gone}
  def restore(%Undo{conversation_id: id, before: before, after: after_leaf}) do
    with %Conversation{session_file: file} = c when is_binary(file) <- get_conversation(id),
         {session, branch} = open(c, Models.default()),
         {parent, copies} <- Transcript.undo(branch, before, after_leaf) do
      {moved, added} = move(session, parent, copies)
      # The branch it goes back to isn't the one read: read again.
      written(id, moved, extend(branch, added), false)
      :ok
    else
      _ -> {:error, :gone}
    end
  end

  @doc """
  Takes the last question back off the session, to ask it again (Try
  again, Ask again): `{:ok, text}`, or `:none` when the conversation
  doesn't end in one; its materials (`question/1`) are the
  caller's to send again. The conversation must have no loop.
  """
  @spec take_question(integer()) :: {:ok, String.t()} | :none
  def take_question(conversation_id) do
    with %Conversation{session_file: file} = c when is_binary(file) <-
           get_conversation(conversation_id),
         {session, branch} = open(c, Models.default()),
         {{parent, copies}, text} <- Transcript.take_question(branch) do
      {moved, added} = move(session, parent, copies)
      written(conversation_id, moved, extend(branch, added), false)
      {:ok, text}
    else
      _ -> :none
    end
  end

  @doc """
  The conversation's last question: its typed text and the ids of the
  materials it sent (what asking it again sends again), or `nil` when there
  is none. Reads only.
  """
  @spec question(integer()) :: %{text: String.t(), materials: [String.t()]} | nil
  def question(conversation_id) do
    with %Conversation{session_file: file} = c when is_binary(file) <-
           get_conversation(conversation_id),
         {_session, branch} = open(c, Models.default()),
         %{"message" => m} = entry <- last_question(branch) do
      %{text: Session.typed(m), materials: [entry] |> Transcript.materials() |> Enum.map(& &1.id)}
    else
      _ -> nil
    end
  end

  defp last_question(branch),
    do: branch |> Enum.reverse() |> Enum.find(&match?(%{"message" => %{"role" => "user"}}, &1))

  @doc """
  Drops a failed reply's entries (after the last question) from the
  session: the chat shows the failure until it's asked again. The
  conversation must have no loop.
  """
  @spec drop_failed(integer()) :: :ok
  def drop_failed(conversation_id) do
    with %Conversation{session_file: file} = c when is_binary(file) <-
           get_conversation(conversation_id),
         {session, branch} = open(c, Models.default()),
         {parent, copies} <- Transcript.drop_after_question(branch) do
      {moved, added} = move(session, parent, copies)
      written(conversation_id, moved, extend(branch, added), false)
      :ok
    else
      _ -> :ok
    end
  end

  # The conversation's session and its active branch.
  defp open(%Conversation{session_file: nil} = c, model) do
    session = Session.new(Session.dir(), model, Rho.Config.data_dir())

    Repo.update_all(from(x in Conversation, where: x.id == ^c.id),
      set: [session_id: session.id, session_file: Path.basename(session.path)]
    )

    {session, []}
  end

  defp open(%Conversation{} = c, model) do
    path = session_path(c)

    case Session.open(path, model) do
      {:ok, session, branch} ->
        {session, branch}

      # Recorded but never written (a loop that started and wrote nothing).
      {:error, _} ->
        {%Session{id: c.session_id, path: path, cwd: Rho.Config.data_dir(), model: model}, []}
    end
  end

  # Appends `entries`; returns the session and the entries as written, or
  # nil for them when the file ended in a torn line (an append joins it, so
  # neither reads back: what the file holds is read again).
  defp write(session, entries) do
    torn? = torn?(session)

    {session, added} =
      Enum.reduce(entries, {session, []}, fn entry, {s, added} ->
        {s, entry} = Session.append(s, entry)
        {s, [entry | added]}
      end)

    {session, if(torn?, do: nil, else: Enum.reverse(added))}
  end

  defp torn?(%Session{written?: false}), do: false

  defp torn?(%Session{path: path}) do
    with {:ok, %File.Stat{size: size}} when size > 0 <- File.stat(path),
         {:ok, last} <- File.open(path, [:read, :binary], &:file.pread(&1, size - 1, 1)) do
      last != {:ok, "\n"}
    else
      _ -> false
    end
  end

  # Puts the leaf under `parent` and appends `copies`; a marker when there
  # is nothing to copy.
  defp move(session, parent, copies) do
    write(%{session | leaf_id: parent}, if(copies == [], do: [Transcript.marker()], else: copies))
  end

  # The branch once `added` is appended, as far as the messages go: up to
  # the first one's parent on `branch`, then `added`. A new session's first
  # entries follow the model change it starts with, which shows no
  # message. nil when the parent isn't on `branch` (Undo goes back to
  # another branch) or what was appended isn't known.
  defp extend(_branch, nil), do: nil

  defp extend(branch, [first | _] = added) do
    case {first["parentId"], branch} do
      {nil, _} ->
        added

      {_parent, []} ->
        added

      {parent, branch} ->
        case Enum.split_while(branch, &(&1["id"] != parent)) do
          {before, [at | _]} -> before ++ [at | added]
          {_, []} -> nil
        end
    end
  end

  # After a write: the messages on the new branch (read off the file when
  # it isn't known), remembered, and the shelf's count; `active?` moves the
  # conversation to the top.
  defp written(conversation_id, _session, nil, active?) do
    messages = conversation_id |> get_conversation() |> shown()
    shelve(conversation_id, length(messages), active?)
    messages
  end

  defp written(conversation_id, session, branch, active?) do
    messages =
      remember(session.path, stamp(session.path), Transcript.messages(branch, session.id))

    shelve(conversation_id, length(messages), active?)
    messages
  end

  defp shelve(conversation_id, count, active?) do
    set = if active?, do: [updated_at: DateTime.utc_now()], else: []

    Repo.update_all(from(c in shelf(), where: c.id == ^conversation_id),
      set: [message_count: count] ++ set
    )

    :ok
  end

  # ── Tools ─────────────────────────────────────────────────────────────────

  @doc """
  Built tools on the shelf, newest first; `list_tools(:all)` also those a
  removal took off it (a Workshop tool's row stays, so a revert of the
  removal brings it back, `Bezalel.Workshop.reconcile/0`).
  """
  @spec list_tools(:shelf | :all) :: [Tool.t()]
  def list_tools(which \\ :shelf)
  def list_tools(:shelf), do: Enum.filter(list_tools(:all), &Tool.shelved?/1)

  def list_tools(:all),
    do: Repo.all(from(t in Tool, order_by: [desc: t.inserted_at, desc: t.id]))

  @doc "A tool on the shelf by id, or nil."
  @spec get_tool(integer() | nil) :: Tool.t() | nil
  def get_tool(nil), do: nil

  def get_tool(id) do
    case Repo.get(Tool, id) do
      %Tool{} = tool -> if Tool.shelved?(tool), do: tool
      nil -> nil
    end
  end

  @doc """
  Saves a built tool. A conversation it came from that's been purged
  meanwhile (deleted while the tool was built) isn't recorded.
  """
  @spec create_tool(map()) :: {:ok, Tool.t()} | {:error, Ecto.Changeset.t()}
  def create_tool(attrs),
    do: %Tool{} |> Tool.changeset(from_conversation(attrs)) |> Repo.insert()

  defp from_conversation(%{conversation_id: id} = attrs) when is_integer(id) do
    if Repo.exists?(from(c in Conversation, where: c.id == ^id)),
      do: attrs,
      else: %{attrs | conversation_id: nil}
  end

  defp from_conversation(attrs), do: attrs

  @doc "Changes a built tool (a Workshop change to its code)."
  @spec update_tool(Tool.t(), map()) :: {:ok, Tool.t()} | {:error, Ecto.Changeset.t()}
  def update_tool(tool, attrs), do: tool |> Tool.changeset(attrs) |> Repo.update()

  @doc "Forgets a built tool (its code, for a Workshop tool, goes with a Dyn generation)."
  @spec delete_tool(Tool.t()) :: :ok
  def delete_tool(tool) do
    Repo.delete_all(from(t in Tool, where: t.id == ^tool.id))
    :ok
  end

  @doc "How many tools are on the shelf."
  @spec tool_count() :: non_neg_integer()
  def tool_count, do: length(list_tools())

  # ── First run ─────────────────────────────────────────────────────────────

  @doc """
  On first run (no conversations yet) stores the design's opening study,
  Exodus 31 · Bezalel, so the app opens on a worked example. Does nothing
  once any conversation exists. Returns the conversation to open.
  """
  @spec seed!() :: Conversation.t()
  def seed! do
    latest_conversation() || seed_exodus_31!()
  end

  defp seed_exodus_31! do
    {:ok, c} =
      create_conversation(%{
        name: "Exodus 31 · Bezalel",
        kicker: "STUDY · EXODUS 31",
        kind: "Study"
      })

    {:ok, _} =
      append(c, [
        Transcript.user("Help me study Bezalel — what’s the heart of the passage?"),
        Transcript.reply(%{
          model: "storyboard",
          passage: "exodus-31-2-3",
          blocks: Storyboard.opening_blocks()
        }),
        Transcript.user("Show me the lampstand he made."),
        Transcript.reply(%{model: "storyboard", image: "lampstand"})
      ])

    get_conversation(c.id)
  end
end
