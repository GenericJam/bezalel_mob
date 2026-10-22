defmodule Bezalel.LibraryTest do
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Bezalel.Library
  alias Bezalel.Library.{Conversation, Tool}
  alias Bezalel.Repo
  alias Rho.Session

  # The rows go after each test too: they include agent messages with bare
  # blocks (no "first" or "rest"), and a later screen test's mount opens the
  # latest conversation in this shared database.
  setup do
    clear = fn -> for schema <- [Tool, Conversation], do: Repo.delete_all(schema) end
    clear.()
    on_exit(clear)
    :ok
  end

  defp conversation!(name \\ "Romans 12") do
    {:ok, c} =
      Library.create_conversation(%{name: name, kicker: "SERMON PREP", kind: "Sermon prep"})

    c
  end

  defp texts(c), do: c.id |> Library.messages() |> Enum.map(&(&1.text || hd(&1.blocks)["first"]))

  test "an undone delete puts the message back in its place, with its id" do
    c = conversation!()
    {:ok, first} = Library.add_message(c, %{role: :user, text: "one"})

    {:ok, middle} =
      Library.add_message(c, %{role: :agent, blocks: [%{"id" => "sum"}], model: "haiku"})

    {:ok, last} = Library.add_message(c, %{role: :user, text: "three"})

    {:ok, undo} = Library.delete_messages(c.id, [middle.id])
    # What came after it is copied onto the new branch (new ids)...
    assert [%{id: first_id}, %{text: "three"}] = Library.messages(c.id)
    assert first_id == first.id
    assert [%{id: id}] = undo.messages
    assert id == middle.id

    :ok = Library.restore(undo)
    restored = Library.messages(c.id)
    assert Enum.map(restored, & &1.id) == [first.id, middle.id, last.id]
    assert Enum.at(restored, 1).blocks == [%{"id" => "sum"}]
  end

  test "a message added after a delete stays when the delete is undone, after the restored one" do
    c = conversation!()
    {:ok, _} = Library.add_message(c, %{role: :user, text: "one"})
    {:ok, two} = Library.add_message(c, %{role: :user, text: "two"})
    {:ok, _} = Library.add_message(c, %{role: :user, text: "three"})
    {:ok, undo} = Library.delete_messages(c.id, [two.id])
    assert texts(c) == ["one", "three"]
    {:ok, _} = Library.add_message(c, %{role: :user, text: "four"})

    :ok = Library.restore(undo)
    assert texts(c) == ["one", "two", "three", "four"]
  end

  test "undoing the delete of the last message after a new one keeps both, in order" do
    c = conversation!()
    {:ok, _} = Library.add_message(c, %{role: :user, text: "one"})
    {:ok, two} = Library.add_message(c, %{role: :user, text: "two"})
    {:ok, undo} = Library.delete_messages(c.id, [two.id])
    {:ok, _} = Library.add_message(c, %{role: :user, text: "three"})

    :ok = Library.restore(undo)
    assert texts(c) == ["one", "two", "three"]
  end

  test "a delete and its undo are branches of the session; the file only grows" do
    c = conversation!()
    {:ok, _} = Library.add_message(c, %{role: :user, text: "one"})
    {:ok, two} = Library.add_message(c, %{role: :user, text: "two"})
    path = Library.session_path(c.id)
    lines = fn -> path |> File.read!() |> String.split("\n", trim: true) |> length() end
    before = lines.()

    {:ok, undo} = Library.delete_messages(c.id, [two.id])
    assert lines.() == before + 1
    # The model reading the session doesn't see the deleted message.
    {:ok, _session, branch} = Session.open(path, "anthropic:claude-sonnet-4-5")
    assert [%{content: [%{text: "one"}]}] = Session.context(branch)

    :ok = Library.restore(undo)
    assert lines.() == before + 2
    {:ok, _session, branch} = Session.open(path, "anthropic:claude-sonnet-4-5")
    assert [_one, _two] = Session.context(branch)
  end

  test "an undo after the session moved on another way is refused, and changes nothing" do
    c = conversation!()
    {:ok, _} = Library.add_message(c, %{role: :user, text: "one"})
    {:ok, two} = Library.add_message(c, %{role: :user, text: "two"})
    {:ok, _} = Library.add_message(c, %{role: :user, text: "three"})
    {:ok, undo} = Library.delete_messages(c.id, [two.id])
    # "three" was copied onto the new branch; deleting it moves past the first undo.
    [_, three] = Library.messages(c.id)
    {:ok, _} = Library.delete_messages(c.id, [three.id])

    assert Library.restore(undo) == {:error, :gone}
    assert texts(c) == ["one"]
  end

  test "the shelf pages" do
    for n <- 1..5, do: conversation!("Study #{n}")
    first = Library.list_conversations(limit: 3)
    rest = Library.list_conversations(limit: 3, offset: 3)

    assert [_, _, _] = first
    assert [_, _] = rest
    ids = Enum.map(first ++ rest, & &1.conversation.id)
    assert ids == Enum.map(Library.list_conversations(), & &1.conversation.id)
  end

  test "a user message needs text" do
    c = conversation!()
    assert {:error, :empty} = Library.add_message(c, %{role: :user, text: nil})
    assert {:error, :empty} = Library.add_message(c, %{role: :user, text: ""})
  end

  test "the shelf lists the most recently active conversation first, with message counts" do
    older = conversation!("Psalm 119")
    newer = conversation!("Ruth")
    {:ok, _} = Library.add_message(newer, %{role: :user, text: "ḥesed?"})
    # Activity in the older one moves it to the top.
    Repo.update_all(Conversation, set: [updated_at: ~U[2026-01-01 00:00:00Z]])
    {:ok, _} = Library.add_message(older, %{role: :user, text: "lamp"})
    {:ok, _} = Library.add_message(older, %{role: :user, text: "path"})

    assert [
             %{conversation: %{name: "Psalm 119"}, message_count: 2},
             %{conversation: %{name: "Ruth"}, message_count: 1}
           ] =
             Library.list_conversations()

    assert Library.latest_conversation().id == older.id
  end

  test "the first-run study is stored once, then the latest conversation is opened" do
    seeded = Library.seed!()
    assert seeded.name == "Exodus 31 · Bezalel"
    assert seeded.session_id
    assert File.exists?(Library.session_path(seeded))

    assert [
             %{role: :user},
             %{role: :agent, passage: "exodus-31-2-3", model: "storyboard"},
             %{role: :user},
             %{role: :agent, image: "lampstand"}
           ] =
             Library.messages(seeded.id)

    assert Library.seed!().id == seeded.id
    assert Library.conversation_count() == 1
    assert [%{message_count: 4}] = Library.list_conversations()
  end

  test "an unknown message id is reported, not raised" do
    c = conversation!()
    assert Library.delete_messages(c.id, ["nope"]) == {:error, :not_found}
    {:ok, _} = Library.add_message(c, %{role: :user, text: "one"})
    assert Library.delete_messages(c.id, ["nope"]) == {:error, :not_found}
  end

  # How many times `fun` reads a session file (`Rho.Session.open/2`), in
  # this process. The tracer is a process of its own: a process doesn't
  # receive its own trace messages.
  defp session_reads(fun) do
    me = self()
    tracer = spawn_link(fn -> count_reads(0) end)
    session = :trace.session_create(:library_reads, tracer, [])
    1 = :trace.process(session, me, true, [:call])
    1 = :trace.function(session, {Session, :open, 2}, true, [])

    try do
      fun.()
    after
      ref = :trace.delivered(session, me)
      receive do: ({:trace_delivered, ^me, ^ref} -> :ok)
      :trace.session_destroy(session)
    end

    send(tracer, {:reads, me})
    receive do: ({:reads, n} -> n)
  end

  defp count_reads(n) do
    receive do
      {:trace, _pid, :call, {Session, :open, _}} -> count_reads(n + 1)
      {:reads, to} -> send(to, {:reads, n})
    end
  end

  test "a store or a delete reads the session once, and the chat's reload doesn't read it again" do
    c = conversation!()
    {:ok, _} = Library.add_message(c, %{role: :user, text: "one"})
    {:ok, two} = Library.add_message(c, %{role: :agent, blocks: [%{"id" => "sum"}]})
    {:ok, _} = Library.add_message(c, %{role: :user, text: "three"})

    assert session_reads(fn ->
             {:ok, _} = Library.add_message(c, %{role: :user, text: "four"})
             :ok = Library.touch(c.id)
             Library.messages(c.id)
           end) == 1

    assert session_reads(fn ->
             {:ok, _} = Library.delete_messages(c.id, [two.id])
             Library.messages(c.id)
           end) == 1

    assert texts(c) == ["one", "three", "four"]
    assert [%{message_count: 3}] = Library.list_conversations()

    # A loop writes the session without Bezalel: the next look reads it.
    {:ok, session, _} = Library.session(c.id, "anthropic:claude-sonnet-4-5")
    Session.append(session, Session.user("five"))

    assert session_reads(fn ->
             :ok = Library.touch(c.id)
             assert texts(c) == ["one", "three", "four", "five"]
           end) == 1

    assert [%{message_count: 4}] = Library.list_conversations()
  end

  test "after a torn last line the next write starts a line of its own: nothing is lost" do
    c = conversation!()
    {:ok, _} = Library.add_message(c, %{role: :user, text: "one"})
    path = Library.session_path(c.id)
    File.write!(path, ~s({"type":"mess), [:append])

    # The torn line is set aside (Bezalel.Link.TornTail.repair/1), so
    # the append doesn't join it.
    {:ok, _} = Library.add_message(c, %{role: :user, text: "two"})
    assert texts(c) == ["one", "two"]
    assert [%{message_count: 2}] = Library.list_conversations()
    refute File.read!(path) =~ ~s({"type":"mess{)
  end

  describe "deleting a conversation" do
    # What's kept for a conversation's session besides its file: the
    # picture cache and rho's spilled tool output and todo list.
    defp side_files(c) do
      data = Rho.Config.data_dir()

      [
        Path.join([Bezalel.Images.dir(), c.session_id, "e1-0-100x100.10x10.png"]),
        Path.join([data, "artifacts", c.session_id, "call1.txt"]),
        Path.join([data, "todos", c.session_id <> ".json"])
      ]
    end

    defp with_files!(name) do
      c = conversation!(name)
      {:ok, _} = Library.add_message(c, %{role: :user, text: "#{name}?"})
      c = Library.get_conversation(c.id)

      for path <- side_files(c) do
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, "x")
      end

      c
    end

    test "takes it off the shelf, and Undo puts it back in its place with its messages" do
      ruth = conversation!("Ruth")
      psalms = with_files!("Psalm 119")
      john = conversation!("John 1")

      Repo.update_all(from(c in Conversation, where: c.id == ^ruth.id),
        set: [updated_at: ~U[2026-01-01 00:00:00.000000Z]]
      )

      shelf = Enum.map(Library.list_conversations(), & &1.conversation.id)
      assert shelf == [john.id, psalms.id, ruth.id]
      shown = Library.messages(psalms.id)

      {:ok, deleted} = Library.delete_conversation(psalms.id)
      assert deleted.name == "Psalm 119"
      assert Enum.map(Library.list_conversations(), & &1.conversation.id) == [john.id, ruth.id]
      assert Library.get_conversation(psalms.id) == nil
      assert Library.conversation_count() == 2
      assert Library.messages(psalms.id) == []
      # A picture still being made reads it until the purge.
      assert Library.session_path_by_id(psalms.session_id) == Library.session_path(psalms)
      # Writes to it do nothing meanwhile (a scripted reply landing late).
      :ok = Library.touch(psalms.id)
      assert {:error, :not_found} = Library.delete_conversation(psalms.id)
      # Kept until it's purged.
      assert File.exists?(Library.session_path(psalms))

      :ok = Library.undelete(deleted)
      assert Enum.map(Library.list_conversations(), & &1.conversation.id) == shelf
      assert Library.messages(psalms.id) == shown
      assert [_, %{message_count: 1}, _] = Library.list_conversations()
      assert Enum.all?(side_files(psalms), &File.exists?/1)
    end

    test "a purge removes its row, its session and the files kept for it, and nothing of another's" do
      gone = with_files!("Ruth")
      kept = with_files!("Psalm 119")
      {:ok, deleted} = Library.delete_conversation(gone.id)

      :ok = Library.purge(deleted)
      refute Repo.get(Conversation, gone.id)
      refute File.exists?(Library.session_path(gone))
      refute Enum.any?(side_files(gone), &File.exists?/1)
      refute File.exists?(Path.join(Bezalel.Images.dir(), gone.session_id))
      assert File.exists?(Library.session_path(kept))
      assert Enum.all?(side_files(kept), &File.exists?/1)
      assert {:error, :gone} = Library.undelete(deleted)
    end

    test "a purge leaves a conversation that was put back, or deleted again since" do
      c = with_files!("Ruth")
      {:ok, first} = Library.delete_conversation(c.id)
      :ok = Library.undelete(first)
      :ok = Library.purge(first)
      assert Library.get_conversation(c.id)

      {:ok, second} = Library.delete_conversation(c.id)
      :ok = Library.purge(first)
      :ok = Library.undelete(second)
      assert texts(c) == ["Ruth?"]
    end

    test "what's still deleted at start is purged" do
      c = with_files!("Ruth")
      kept = conversation!("Psalm 119")
      {:ok, _} = Library.delete_conversation(c.id)

      :ok = Library.purge_deleted()
      refute Repo.get(Conversation, c.id)
      refute File.exists?(Library.session_path(c))
      assert Library.get_conversation(kept.id)
    end

    test "a tool built from a conversation purged meanwhile is saved without it" do
      c = conversation!()
      {:ok, deleted} = Library.delete_conversation(c.id)
      :ok = Library.purge(deleted)

      assert {:ok, %Tool{conversation_id: nil}} =
               Library.create_tool(%{
                 name: "Outline",
                 kind: "outline",
                 description: "An outline",
                 data: %{},
                 conversation_id: c.id
               })
    end
  end

  describe "a live reply, read back from the session" do
    # What rho's loop writes for a question answered with a tool call that
    # returned a picture and a passage card, then the answer.
    defp live_session!(c) do
      {:ok, session, _branch} = Library.session(c.id, "anthropic:claude-sonnet-4-5")
      png = "png-bytes"

      entries = [
        Session.user("Who is Bezalel?"),
        Session.assistant(
          %{
            thinking: "Find the verse.",
            text: "Let me look.",
            tool_calls: [
              %{
                "id" => "c1",
                "name" => "lookup_verse",
                "arguments" => %{"reference" => "Ex 31:2"}
              }
            ],
            stop_reason: "toolUse"
          },
          "anthropic:claude-sonnet-4-5"
        ),
        "lookup_verse"
        |> then(
          &Session.tool_result("c1", &1, "Exodus 31:2 …", false, images: [{"image/png", png}])
        )
        |> put_in(["message", "details"], %{"title" => "Exodus 31:2", "verses" => []}),
        Session.assistant(
          %{text: "Bezalel is **filled** with the Spirit.", stop_reason: "stop"},
          "anthropic:claude-sonnet-4-5"
        )
      ]

      _session = Enum.reduce(entries, session, &elem(Session.append(&2, &1), 0))
      :ok = Library.touch(c.id)
    end

    test "draws as the stream did: THINKING, TOOL CALL, SUMMARY, the kept card and the picture" do
      c = conversation!()
      live_session!(c)

      assert [%{role: :user, text: "Who is Bezalel?"}, reply] = Library.messages(c.id)
      assert Enum.map(reply.blocks, & &1["type"]) == ["THINKING", "TOOL CALL", "SUMMARY"]
      assert Enum.find(reply.blocks, &(&1["type"] == "THINKING"))["rest"] =~ "Let me look."
      assert Enum.find(reply.blocks, &(&1["id"] == "sum"))["first"] =~ "Bezalel is filled"
      assert reply.card == %{"title" => "Exodus 31:2", "verses" => []}
      assert reply.model == "anthropic:claude-sonnet-4-5"
      assert [%{index: 1, mime: "image/png", key: key}] = reply.images
      assert key == "#{Library.get_conversation(c.id).session_id}/#{hd(tl(reply.entries))}/1"
      assert [_assistant, _tool_result, _answer] = reply.entries
      assert [%{message_count: 2}] = Library.list_conversations()
    end

    test "deleting the question leaves the reply, a reply of its own" do
      c = conversation!()

      {:ok, _} =
        Library.add_message(c, %{role: :agent, blocks: [%{"id" => "sum", "first" => "Earlier."}]})

      live_session!(c)
      [earlier, question, reply] = Library.messages(c.id)

      {:ok, _} = Library.delete_messages(c.id, [question.id])
      assert [^earlier, %{role: :agent, blocks: blocks}] = Library.messages(c.id)
      assert blocks == reply.blocks
    end

    test "a question taken back to ask again, and a failed run dropped after its question" do
      c = conversation!()
      live_session!(c)
      reply = c.id |> Library.messages() |> List.last()
      {:ok, _} = Library.delete_messages(c.id, [reply.id])

      # The failed run's notice after the question goes; the question stays.
      {:ok, session, _} = Library.session(c.id, "anthropic:claude-sonnet-4-5")
      Session.append(session, Session.custom(:error, "401"))
      :ok = Library.drop_failed(c.id)
      assert [%{role: :user}] = Library.messages(c.id)

      assert Library.take_question(c.id) == {:ok, "Who is Bezalel?"}
      assert Library.messages(c.id) == []
      assert Library.take_question(c.id) == :none
    end
  end
end
