defmodule Bezalel.Views.Conversations do
  @moduledoc """
  The Conversations tab: a shelf of studies, one open at a time.

  Each row's ⋯ menu deletes it: the row goes at once and the toast offers
  Undo, which puts it back in its place (and open again, if it was). The
  conversation is purged once the Undo is gone (`purge/2`, when its window
  ends; `Bezalel.Library.purge_deleted/0` at start). A reply streaming in
  it is cut off first (`Bezalel.Views.Study.let_go/2`). Deleting the open
  one opens the latest left, or a new study when none is.
  """
  import Mob.Sigil

  alias Bezalel.Library
  alias Bezalel.Library.Deleted
  alias Bezalel.Views.{Helpers, Study}
  alias Mob.Socket
  alias MobBezalel.{Icons, UI}

  @page 30

  @doc """
  Loads the shelf: as many rows as are already paged in, at least one page
  (on entering the tab, or when something changed underneath it).
  """
  def load(socket) do
    limit = max(length(socket.assigns.shelf), @page)
    shelf = Library.list_conversations(limit: limit)
    Socket.assign(socket, shelf: shelf, shelf_done: length(shelf) < limit)
  end

  @doc "The Conversations body: a lazy list, paged in as it scrolls."
  def render(assigns) do
    rows = Enum.map(assigns.shelf, &row(&1, assigns.conversation.id, assigns.menu))
    new_tap = {self(), {:convs, :new}}
    more = {self(), {:convs, :more}}

    ~MOB"""
    <LazyList weight={1} background={:background} on_end_reached={more}>
      <Column
        id="shelf-head"
        padding_left={18}
        padding_right={18}
        padding_top={22}
        padding_bottom={8}
        gap={14}
        fill_width={true}
      >
        <Row align={:center} fill_width={true}>
          <Text
            text="Conversations"
            font={:display}
            text_size={30}
            text_color={:on_background}
            weight={1}
          />
          {UI.pill_button("New", new_tap, :outline, height: 36, fill: false, text_size: 13)}
        </Row>
        <Text
          text="Each week’s prep gets its own conversation. Shelve it when you’re done; pull it back out whenever you need it."
          text_size={13}
          line_height={1.5}
          text_color={:muted}
        />
      </Column>
      {rows}
    </LazyList>
    """
  end

  defp row(%{conversation: c, message_count: n}, open_id, menu) do
    open? = c.id == open_id

    {border, state, state_color} =
      if open?, do: {:secondary, "OPEN", :secondary}, else: {:border, "SHELVED", :muted}

    meta = "#{c.kind} · #{Helpers.count(n, "message")}"
    summary = if c.summary in [nil, ""], do: [], else: [summary_line(c.summary)]
    tap = {self(), {:convs, {:open, c.id}}}
    id = "conversation-#{c.id}"
    more_id = "conversation-more-#{c.id}"
    more = Icons.icon(:more, 16, :muted)
    menu_tap = {self(), {:convs, {:menu, c.id}}}

    # The menu takes the state's place while it's open.
    trailing =
      if menu == {:conversation, c.id},
        do: Helpers.action_chip("Delete", {self(), {:convs, {:delete, c.id}}}, :error),
        else: UI.kicker(state, state_color)

    ~MOB"""
    <Box
      id={id}
      padding_left={18}
      padding_right={18}
      padding_top={7}
      padding_bottom={7}
      fill_width={true}
    >
      <Box
        background={:surface}
        border_color={border}
        border_width={1.5}
        corner_radius={18}
        padding={14}
        fill_width={true}
        on_tap={tap}
      >
        <Row gap={14} align={:center} fill_width={true}>
          <Column gap={3} weight={1}>
            {UI.kicker(Helpers.when_label(c.inserted_at))}
            <Text text={c.name} font={:display} text_size={18} text_color={:on_surface} />
            {summary}
            <Text text={meta} text_size={12} text_color={:muted} />
          </Column>
          <Row gap={4} align={:center} fill_width={false}>
            {trailing}
            <Box
              id={more_id}
              width={32}
              height={28}
              align="center"
              fill_width={false}
              on_tap={menu_tap}
            >
              {more}
            </Box>
          </Row>
        </Row>
      </Box>
    </Box>
    """
  end

  # The summary its model wrote with its title (`Bezalel.Titles`).
  defp summary_line(text),
    do: ~MOB(<Text text={text} text_size={13} line_height={1.4} text_color={:on_surface} />)

  @doc """
  A conversation got its title and summary (`Bezalel.Titles`): Study's
  header shows it when it's the open one, and the shelf when it's on
  screen.
  """
  def titled(%Library.Conversation{id: id, name: name, summary: summary}, socket) do
    # Only the name and summary: a Pushback switch flipped meanwhile stays.
    socket =
      if socket.assigns.conversation.id == id,
        do:
          Socket.assign(socket, :conversation, %{
            socket.assigns.conversation
            | name: name,
              summary: summary
          }),
        else: socket

    Helpers.refresh(socket)
  end

  @doc "Handles a Conversations event."
  def handle(:more, %{assigns: %{shelf_done: true}} = socket), do: {:noreply, socket}

  def handle(:more, socket) do
    page = Library.list_conversations(limit: @page, offset: length(socket.assigns.shelf))

    {:noreply,
     Socket.assign(socket,
       shelf: socket.assigns.shelf ++ page,
       shelf_done: length(page) < @page
     )}
  end

  def handle({:menu, id}, socket) do
    menu = if socket.assigns.menu == {:conversation, id}, do: nil, else: {:conversation, id}
    {:noreply, Socket.assign(socket, :menu, menu)}
  end

  def handle({:delete, id}, socket) do
    socket = Socket.assign(socket, :menu, nil)

    case Library.get_conversation(id) do
      # Already gone (a double tap).
      nil -> {:noreply, load(socket)}
      c -> {:noreply, delete(socket, c)}
    end
  end

  def handle(:undo, socket) do
    case socket.assigns.toast do
      %{undo: {:conversation, deleted, instead}} ->
        {:noreply, socket |> Socket.assign(:toast, nil) |> undelete(deleted, instead)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle({:open, id}, socket) do
    case Library.get_conversation(id) do
      nil -> {:noreply, socket}
      c -> {:noreply, Helpers.open_conversation(socket, c)}
    end
  end

  def handle(:new, socket) do
    {:ok, c} = new_study()
    {:noreply, Helpers.open_conversation(socket, c)}
  end

  @doc """
  A deleted conversation's Undo window ended (`Helpers.toast_ms/0` after
  the delete): it's purged, and its toast goes now if it's still up.
  """
  def purge(%Deleted{} = deleted, socket) do
    :ok = Library.purge(deleted)

    case socket.assigns.toast do
      %{undo: {:conversation, ^deleted, _}} -> Socket.assign(socket, :toast, nil)
      _ -> socket
    end
  end

  @doc """
  A linked computer deleted conversation `id` (its row and session are
  already purged): its loop goes, the shelf follows, and if it was the open
  one the latest left opens instead (a new study when none is), on the tab
  the user is on.
  """
  def removed(socket, id) do
    socket = Study.let_go(socket, id)

    socket =
      if socket.assigns.conversation.id == id,
        do: open_here(socket, latest_or_new()),
        else: socket

    load(socket)
  end

  defp latest_or_new do
    with nil <- Library.latest_conversation() do
      {:ok, c} = new_study()
      c
    end
  end

  # The loop goes first (a delete writes nothing to the session, but the
  # purge removes it); the open one gives way to the latest left, or to a
  # new study when there's none. `instead` is what was opened in its
  # place, for Undo.
  defp delete(socket, c) do
    socket = Study.let_go(socket, c.id)
    {:ok, deleted} = Library.delete_conversation(c.id)
    Process.send_after(self(), {:purge, deleted}, Helpers.toast_ms())

    {socket, instead} =
      if socket.assigns.conversation.id == c.id, do: open_instead(socket), else: {socket, nil}

    socket
    |> Helpers.go(:convs)
    |> Helpers.toast("Deleted “#{c.name}”", undo: {:conversation, deleted, instead})
  end

  defp open_instead(socket) do
    case Library.latest_conversation() do
      nil ->
        {:ok, c} = new_study()
        {Helpers.open_conversation(socket, c), {:created, c.id}}

      c ->
        {Helpers.open_conversation(socket, c), {:opened, c.id}}
    end
  end

  # Back on the shelf; open again if it was open and what replaced it
  # still is, and the new study made in its place goes if nothing was
  # written to it.
  defp undelete(socket, deleted, instead) do
    case Library.undelete(deleted) do
      :ok -> socket |> reopen(deleted.conversation_id, instead) |> Helpers.refresh()
      {:error, :gone} -> socket
    end
  end

  defp reopen(socket, _id, nil), do: socket

  defp reopen(socket, id, {how, other}) do
    socket =
      if socket.assigns.conversation.id == other,
        do: open_here(socket, Library.get_conversation(id)),
        else: socket

    if how == :created and socket.assigns.conversation.id != other,
      do: :ok = Library.discard_unwritten(other)

    socket
  end

  # Opens the conversation in Study, staying on the tab the user is on.
  defp open_here(socket, c) do
    tab = socket.assigns.tab
    socket = Helpers.open_conversation(socket, c)

    if tab == :tool,
      do: Helpers.open_tool(socket, socket.assigns.tool.id),
      else: Helpers.go(socket, tab)
  end

  defp new_study,
    do: Library.create_conversation(%{name: "New study", kicker: "STUDY", kind: "Study"})
end
