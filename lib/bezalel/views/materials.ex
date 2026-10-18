defmodule Bezalel.Views.Materials do
  @moduledoc """
  The Materials tab, and materials as the chat shows them.

  **The tab** (`render/1`): everything sent to the agent and every drawing
  it made (`Bezalel.MaterialStore.list/1`), newest first, as a grid,
  filtered by kind (`:mat_kind`). Each card has an × in its corner: Delete,
  as in the detail. A material opens its detail
  (`:mat_open`): the picture, a player for a recording, its transcript and
  what else was made from it, the conversations it went with (each opens
  in Study), **Ask about this** (it waits as a chip in Study's composer)
  and **Delete** (after a question: a conversation that sent it then
  says it couldn't be loaded).

  **In the chat** (`in_message/2`): a message's materials
  (`Bezalel.Library.Message`'s and the live reply's `materials`): pictures
  through the chat's picture pipeline (`Bezalel.Views.Images`), the rest
  as a card naming it, with a play button for a recording; a card opens the
  material in the tab.
  """
  import Mob.Sigil

  alias Bezalel.{Library, MaterialStore, Native}
  alias Bezalel.Materials.Material
  alias Bezalel.Views.{Attach, Helpers, Images, Stills}
  alias Mob.Socket
  alias MobBezalel.{Icons, UI}

  @kinds [
    {nil, "All"},
    {:image, "Pictures"},
    {:audio, "Audio"},
    {:video, "Video"},
    {:document, "Files"}
  ]

  @doc "The assigns this view keeps, for the screen's mount."
  def assigns, do: [mat_kind: nil, mat_list: [], mat_open: nil, playing: nil]

  @doc "Loads the grid (`Bezalel.Helpers.go/2` on the way to the tab)."
  def load(socket) do
    list = MaterialStore.list(kind: socket.assigns.mat_kind)

    socket
    |> Socket.assign(:mat_list, list)
    |> Images.load(Images.material_images(list))
  end

  # ── The tab ──────────────────────────────────────────────────────────────

  @doc "The Materials body: the grid, or one material."
  def render(%{mat_open: %{} = open} = assigns), do: detail(open, assigns)

  def render(assigns) do
    filter =
      for {kind, label} <- @kinds, do: {label, {self(), {:materials, {:kind, kind}}}}

    index = Enum.find_index(@kinds, fn {kind, _} -> kind == assigns.mat_kind end)
    tiles = Enum.map(assigns.mat_list, &grid_tile(&1, assigns))

    body =
      if tiles == [],
        do: [empty(assigns.mat_kind)],
        else: [~MOB(<Wrap spacing={8} run_spacing={8} fill_width={true}>
  {tiles}
</Wrap>)]

    ~MOB"""
    <Scroll weight={1} background={:background}>
      <Column
        padding_left={18}
        padding_right={18}
        padding_top={18}
        padding_bottom={28}
        gap={14}
        fill_width={true}
      >
        {UI.segmented(filter, index)}
        {body}
      </Column>
    </Scroll>
    """
  end

  defp empty(nil) do
    ~MOB(<Text
  text="Nothing here yet. Photos, recordings and files you add to a question, and the pictures Bezalel draws, are kept here. Tap + beside the question box to add one."
  text_size={14}
  line_height={1.5}
  text_color={:muted}
/>)
  end

  defp empty(_kind),
    do: ~MOB(<Text text="None of this kind yet." text_size={14} text_color={:muted} />)

  # A grid card: the square, with an × over its top-right corner that
  # deletes it (after the same question as the detail's Delete).
  defp grid_tile(m, assigns) do
    delete = {self(), {:materials, {:delete, m.id}}}
    x = Icons.icon(:close, 14, :on_surface)

    ~MOB"""
    <Box width={104} height={104} align="top_trailing" fill_width={false}>
      {tile(m, assigns)}
      <Box
        id={"delete-material-" <> m.id}
        width={36}
        height={36}
        padding={5}
        fill_width={false}
        accessibility_label={"Delete " <> m.name}
        on_tap={delete}
      >
        <Box
          width={26}
          height={26}
          corner_radius={13}
          background={:surface}
          border_color={:border}
          border_width={1}
          align="center"
          fill_width={false}
        >
          {x}
        </Box>
      </Box>
    </Box>
    """
  end

  # A grid square: the picture itself, or the kind's icon and the name.
  defp tile(%Material{kind: :image} = m, assigns) do
    tap = {self(), {:materials, {:open, m.id}}}

    inner =
      case Map.get(assigns.images, {"material/" <> m.id, :chat}) do
        {:ok, %{path: path}} ->
          ~MOB(<Image src={path} width={104} height={104} corner_radius={12} content_mode="fill" />)

        _ ->
          Icons.icon(:image, 24, :muted)
      end

    ~MOB"""
    <Box
      id={"material-" <> m.id}
      width={104}
      height={104}
      corner_radius={12}
      background={:surface}
      border_color={:border}
      border_width={1}
      align="center"
      fill_width={false}
      on_tap={tap}
    >
      {inner}
    </Box>
    """
  end

  defp tile(m, _assigns) do
    tap = {self(), {:materials, {:open, m.id}}}
    glyph = Icons.icon(Attach.icon(m.kind), 24, :secondary)

    ~MOB"""
    <Box
      id={"material-" <> m.id}
      width={104}
      height={104}
      corner_radius={12}
      background={:surface}
      border_color={:border}
      border_width={1}
      padding={10}
      fill_width={false}
      on_tap={tap}
    >
      <Column gap={8} fill_width={true}>
        {glyph}
        <Text text={m.name} font={:ui_medium} text_size={12} text_color={:on_surface} max_lines={3} />
      </Column>
    </Box>
    """
  end

  # One material: what it is, what was made from it, where it went.
  defp detail(%{material: m} = open, assigns) do
    ask = {self(), {:materials, {:ask, m.id}}}
    delete = {self(), {:materials, {:delete, m.id}}}

    ~MOB"""
    <Scroll weight={1} background={:background}>
      <Column
        padding_left={18}
        padding_right={18}
        padding_top={18}
        padding_bottom={28}
        gap={14}
        fill_width={true}
      >
        {preview(m, assigns)}
        <Text text={m.name} font={:display} text_size={22} text_color={:on_background} />
        <Text
          text={Bezalel.Materials.about(m) <> " · " <> day(m.inserted_at)}
          text_size={12}
          text_color={:muted}
        />
        {transcript(m, open, assigns)}
        {stills(m, open, assigns)}
        {drawn_from(open)}
        {conversations(open.conversations)}
        <Row gap={10} fill_width={true}>
          {UI.pill_button("Ask about this", ask, :primary, weight: 1, height: 48)}
          {UI.pill_button("Delete", delete, :danger, weight: 1, height: 48)}
        </Row>
      </Column>
    </Scroll>
    """
  end

  defp preview(%Material{kind: :image} = m, assigns),
    do: Images.render([Images.material_image(m.id, m.mime)], assigns)

  defp preview(m, assigns), do: card(to_item(m), assigns)

  defp transcript(%Material{kind: kind} = m, open, assigns) when kind in [:audio, :video] do
    working = assigns.transcripts[m.id] == :working

    case open.transcript do
      nil when working ->
        [~MOB(<Text text="Transcribing…" text_size={13} text_color={:muted} />)]

      nil ->
        tap = {self(), {:materials, {:transcribe, m.id}}}

        [
          ~MOB(<Text
  text="No transcript yet: it's made when you send it, or now."
  text_size={13}
  text_color={:muted}
/>),
          UI.pill_button("Transcribe now", tap, :outline, height: 40, fill: false, text_size: 13)
        ]

      text ->
        transcript_card(text)
    end
  end

  defp transcript(_m, %{transcript: text}, _assigns) when is_binary(text),
    do: transcript_card(text)

  defp transcript(_m, _open, _assigns), do: []

  defp transcript_card(text) do
    body = if text == "", do: "(Nothing was said.)", else: text

    [
      UI.card(
        [
          UI.kicker("Transcript"),
          ~MOB(<Text text={body} text_size={14} line_height={1.5} text_color={:on_surface} />)
        ],
        padding: 16,
        gap: 8
      )
    ]
  end

  # A video's stills: each opens, or goes on the question as a chip.
  defp stills(%Material{kind: :video} = m, open, assigns) do
    pick = {self(), {:materials, {:stills, m.id}}}

    tiles =
      for s <- open.stills do
        ask = {self(), {:materials, {:ask, s.id}}}

        ~MOB"""
        <Column gap={6} fill_width={false}>
          {tile(s, assigns)}
          {UI.pill_button("Ask", ask, :outline, height: 30, fill: false, text_size: 12)}
        </Column>
        """
      end

    list =
      if tiles == [],
        do: [],
        else: [~MOB(<Wrap spacing={8} run_spacing={8} fill_width={true}>
  {tiles}
</Wrap>)]

    [UI.kicker("Stills")] ++
      list ++
      [UI.pill_button("Pick a still", pick, :outline, height: 40, fill: false, text_size: 13)]
  end

  defp stills(_m, _open, _assigns), do: []

  defp drawn_from(%{drawings: []}), do: []

  defp drawn_from(%{drawings: drawings}) do
    rows = Enum.map(drawings, &link_row(&1.name, {self(), {:materials, {:open, &1.id}}}))
    [UI.kicker("Drawn from it") | rows]
  end

  defp conversations([]), do: []

  defp conversations(list) do
    rows = for c <- list, do: link_row(c.name, {self(), {:materials, {:conversation, c.id}}})
    [UI.kicker("Went with") | rows]
  end

  defp link_row(label, tap) do
    ~MOB(<Text
  text={label}
  font={:ui_medium}
  text_size={14}
  text_color={:secondary}
  padding={4}
  on_tap={tap}
/>)
  end

  defp day(%DateTime{} = at), do: Calendar.strftime(at, "%-d %b %Y")

  # ── In the chat ──────────────────────────────────────────────────────────

  @doc """
  A message's materials: pictures as pictures, the rest as cards
  (`Bezalel.Library.Message`'s `%{id, kind, mime, name, about}`).
  """
  def in_message([], _assigns), do: []

  def in_message(materials, assigns) do
    {pictures, others} = Enum.split_with(materials, &(&1.kind == :image))

    Images.render(Images.material_images(pictures), assigns) ++
      Enum.map(others, &card(&1, assigns))
  end

  defp to_item(%Material{} = m),
    do: %{id: m.id, kind: m.kind, mime: m.mime, name: m.name, about: Bezalel.Materials.about(m)}

  # A recording, a video, a file: its kind, name and what's known, and a
  # play button for sound.
  defp card(item, assigns) do
    open = {self(), {:materials, {:open, item.id}}}
    glyph = Icons.icon(Attach.icon(item.kind), 22, :secondary)

    ~MOB"""
    <Box
      id={"material-card-" <> item.id}
      background={:surface}
      border_color={:border}
      border_width={1}
      corner_radius={14}
      padding_left={12}
      padding_right={8}
      padding_top={10}
      padding_bottom={10}
      fill_width={true}
    >
      <Row gap={12} align={:center} fill_width={true}>
        <Box width={28} align="center" fill_width={false} on_tap={open}>
          {glyph}
        </Box>
        <Column gap={2} weight={1} on_tap={open}>
          <Text
            text={item.name}
            font={:ui_medium}
            text_size={14}
            text_color={:on_surface}
            max_lines={2}
          />
          <Text text={item.about || ""} text_size={12} text_color={:muted} max_lines={2} />
        </Column>
        {play(item, assigns)}
      </Row>
    </Box>
    """
  end

  defp play(%{kind: :audio} = item, assigns) do
    playing? = assigns.playing == item.id
    tap = {self(), {:materials, {:play, item.id, item.mime}}}
    [UI.icon_button(if(playing?, do: :stop, else: :play), tap, id: "play-" <> item.id)]
  end

  defp play(_item, _assigns), do: []

  # ── Events ───────────────────────────────────────────────────────────────

  @doc "A tap in the tab or on a material in the chat (`{:tap, {:materials, event}}`)."
  def handle({:kind, kind}, socket),
    do: {:noreply, socket |> Socket.assign(:mat_kind, kind) |> load()}

  def handle({:open, id}, socket), do: {:noreply, open(socket, id)}

  def handle(:close, socket),
    do: {:noreply, socket |> Socket.assign(:mat_open, nil) |> load()}

  def handle({:ask, id}, socket) do
    case MaterialStore.fetch(id, %{}) do
      {:ok, m} ->
        attachments = Enum.reject(socket.assigns.attachments, &(&1.id == id)) ++ [m]

        {:noreply,
         socket
         |> Socket.assign(attachments: attachments, mat_open: nil)
         |> Helpers.go(:study)}

      :error ->
        {:noreply, socket}
    end
  end

  def handle({:delete, id}, socket),
    do: {:noreply, Socket.assign(socket, :sheet, {:delete_material, id})}

  # Its chip goes, and the chips of what was deleted with it (its stills).
  def handle({:confirm_delete, id}, socket) do
    :ok = MaterialStore.delete(id)

    chips =
      Enum.filter(socket.assigns.attachments, &match?({:ok, _}, MaterialStore.fetch(&1.id, %{})))

    {:noreply,
     socket
     |> Socket.assign(sheet: nil, mat_open: nil, attachments: chips)
     |> load()
     |> Helpers.toast("Deleted from Materials.")}
  end

  def handle({:conversation, cid}, socket) do
    case Library.get_conversation(cid) do
      nil -> {:noreply, socket}
      c -> {:noreply, socket |> Socket.assign(:mat_open, nil) |> Helpers.open_conversation(c)}
    end
  end

  def handle({:stills, id}, socket) do
    case MaterialStore.fetch(id, %{}) do
      {:ok, %Material{kind: :video} = m} -> {:noreply, Stills.open(socket, m)}
      _ -> {:noreply, socket}
    end
  end

  def handle({:transcribe, id}, socket) do
    case MaterialStore.fetch(id, %{}) do
      {:ok, m} -> {:noreply, Attach.transcribe(socket, m)}
      :error -> {:noreply, socket}
    end
  end

  def handle({:play, id, _mime}, %{assigns: %{playing: id}} = socket),
    do: {:noreply, socket |> Native.stop_playback() |> Socket.assign(:playing, nil)}

  def handle({:play, id, mime}, socket) do
    {:noreply, socket |> Native.play(MaterialStore.file(id, mime)) |> Socket.assign(:playing, id)}
  end

  def handle(_event, socket), do: {:noreply, socket}

  @doc "Playback ended or failed (`{:audio, :playback_finished | :playback_error, _}`)."
  def played(socket), do: Socket.assign(socket, :playing, nil)

  @doc "Opens one material in the tab (from the grid, the chat or a link)."
  def open(socket, id) do
    case MaterialStore.fetch(id, %{}) do
      {:ok, m} ->
        made = MaterialStore.derivatives(id, %{})

        open = %{
          material: m,
          transcript: transcript(m, made),
          drawings: for(d <- made, d.derivation == :generated, do: d),
          stills: for(d <- made, d.derivation == :still, do: d),
          conversations: Library.conversations_by_session(MaterialStore.sessions(id))
        }

        socket
        |> Socket.assign(mat_open: open, tab: :materials)
        |> Images.load(Images.material_images([m | open.drawings ++ open.stills]))

      :error ->
        socket |> Socket.assign(:mat_open, nil) |> Helpers.toast("That material is gone.")
    end
  end

  # The newest transcript made from `m` (a transcript is its own).
  defp transcript(%Material{kind: :transcript} = m, _made), do: read(m)

  defp transcript(_m, made) do
    made
    |> Enum.filter(&(&1.kind == :transcript))
    |> Enum.max_by(& &1.inserted_at, DateTime, fn -> nil end)
    |> then(&(&1 && read(&1)))
  end

  defp read(m) do
    case MaterialStore.read(m, %{}) do
      {:ok, text} -> text
      {:error, _} -> nil
    end
  end

  @doc "A transcript was made: the open material shows it."
  def transcribed(id, %{assigns: %{mat_open: %{material: %{id: id}}}} = socket),
    do: open(socket, id)

  def transcribed(_id, socket), do: socket
end
