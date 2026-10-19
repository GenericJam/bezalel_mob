defmodule Bezalel.Views.Images do
  @moduledoc """
  Pictures in Study: each message's (and the streaming reply's) images,
  downscaled to the chat's width on the phone (`Bezalel.Images`) and drawn
  from the cache; a placeholder while one is made, a note when it can't
  be. Tapping one opens the viewer: the picture full-screen, made again
  for the screen (up to twice its size) and zoomed natively (mob's
  `zoomable` image: pinch, double tap, pan while zoomed), with Save (to the
  phone's photos, `Bezalel.Views.SavePicture`); a long press offers the
  same. `:images` holds each picture's state by `{key, size}`:
  `:loading`, `{:ok, ready}` or `:error`; `:viewer` the picture open
  full-screen.
  """
  import Mob.Sigil

  alias Bezalel.{Images, Library}
  alias Bezalel.Views.SavePicture
  alias Mob.Socket
  alias MobBezalel.{Icons, Palette}

  # The viewer's picture is made at up to twice the screen (Bezalel.Images),
  # so zooming past 2× shows the made pixels larger.
  @max_zoom 4.0
  @double_tap_zoom 2.5

  # ── Loading ──────────────────────────────────────────────────────────────

  @doc """
  Starts making the open conversation's pictures that aren't made yet: the
  session's own and the materials' (`material_images/1`).
  """
  def load(socket) do
    images =
      Enum.flat_map(socket.assigns.messages, &(&1.images ++ material_images(&1.materials)))

    load(socket, images)
  end

  @doc "Starts making `images` (at the chat's size) that aren't made yet."
  def load(socket, images), do: Enum.reduce(images, socket, &start(&2, &1, :chat))

  @doc """
  The pictures among a message's materials (`Bezalel.Library.Message`'s
  `materials`, or `Bezalel.Materials.Material`s), as the chat's images:
  keyed `"material/<id>"`, read from `Bezalel.MaterialStore`.
  """
  def material_images(materials) do
    for %{kind: :image, id: id, mime: mime} <- materials, do: material_image(id, mime)
  end

  @doc "A material's picture as the chat's image."
  def material_image(id, mime), do: %{key: "material/" <> id, material: id, mime: mime}

  defp start(socket, %{key: key} = image, size) do
    if Map.has_key?(socket.assigns.images, {key, size}) do
      socket
    else
      socket
      |> Socket.assign(:images, Map.put(socket.assigns.images, {key, size}, :loading))
      |> Socket.start_async({:image, key, size}, fn -> make(image, size) end)
    end
  end

  # Runs in the async task: a session's picture is found by its key.
  defp make(%{material: _} = image, size), do: Images.prepare(nil, image, size)

  defp make(%{key: key} = image, size) do
    case key |> String.split("/") |> hd() |> Library.session_path_by_id() do
      nil -> {:error, :no_session}
      path -> Images.prepare(path, image, size)
    end
  end

  @doc "A picture is made (`handle_async({:image, key, size}, ...)`)."
  def loaded(key, size, result, socket) do
    state =
      case result do
        {:ok, {:ok, ready}} -> {:ok, ready}
        _ -> :error
      end

    Socket.assign(socket, :images, Map.put(socket.assigns.images, {key, size}, state))
  end

  # ── Chat ─────────────────────────────────────────────────────────────────

  @doc "A message's pictures, one under the other."
  def render([], _assigns), do: []
  def render(images, assigns), do: Enum.map(images, &picture(&1, assigns))

  defp picture(%{key: key}, assigns) do
    %{width: screen_w} = screen = Images.screen()
    avail = screen_w - 32

    case Map.get(assigns.images, {key, :chat}) do
      # Sized by the original, at one pixel per screen pixel, to fit the
      # chat: a file decoded smaller than its box is drawn as big.
      {:ok, %{path: path, original: {w, h}}} ->
        {dw, dh} = fit(w / screen.scale, h / screen.scale, avail, 420)
        tap = {self(), {:image, {:open, key}}}
        hold = {self(), {:image, {:menu, key}}}

        ~MOB"""
        <Box id={"image-" <> key} fill_width={true} align="center" on_tap={tap} on_long_press={hold}>
          <Image src={path} width={dw} height={dh} corner_radius={14} content_mode="fit" />
        </Box>
        """

      :error ->
        frame(key, "This picture can’t be shown.")

      _loading ->
        frame(key, "Preparing the picture…")
    end
  end

  # A width × height fitted inside max_w × max_h (never larger).
  defp fit(w, h, max_w, max_h) do
    scale = Enum.min([1.0, max_w / w, max_h / h])
    {Float.round(w * scale, 1), Float.round(h * scale, 1)}
  end

  defp frame(key, note) do
    mark = Icons.mark(40, :border, cutout: :surface)

    ~MOB"""
    <Box
      id={"image-" <> key}
      background={:surface}
      border_color={:border}
      border_width={1}
      corner_radius={14}
      height={160}
      padding={12}
      align="center"
      fill_width={true}
    >
      <Column gap={8} align={:center}>
        {mark}
        <Text text={note} text_size={12} text_color={:muted} />
      </Column>
    </Box>
    """
  end

  # ── Viewer ───────────────────────────────────────────────────────────────

  @doc "The full-screen viewer over everything, when a picture is open."
  def viewer(%{viewer: nil}), do: []

  def viewer(%{viewer: %{key: key}} = assigns) do
    sa = assigns[:safe_area] || %{top: 0, bottom: 0}

    ready =
      case Map.get(assigns.images, {key, :viewer}) do
        {:ok, ready} -> ready
        _ -> chat_ready(assigns.images, key)
      end

    close = {self(), {:image, :close}}
    save = {self(), {:image, {:save, key}}}
    save_label = if assigns[:saving] == key, do: "Saving…", else: "Save"
    o = Palette.overlay()
    {max_zoom, double_tap_zoom} = {@max_zoom, @double_tap_zoom}

    body =
      case ready do
        %{path: path} ->
          # The frame is the zoom viewport: the whole area under the bar, the
          # picture fitted inside it; the zoom, pan and double tap are native.
          ~MOB"""
          <Image
            id="viewer-image"
            src={path}
            zoomable={true}
            max_zoom={max_zoom}
            double_tap_zoom={double_tap_zoom}
            weight={1}
            fill_width={true}
          />
          """

        nil ->
          ~MOB(<Box weight={1} fill_width={true} align="center">
  <Text text="Preparing the picture…" text_size={13} text_color={o.on_popover} />
</Box>)
      end

    # Save and Done are fill_width={false}: a Box fills its row's width by
    # default on Android, which left the label and Done no room.
    ~MOB"""
    <Box fill_width={true} fill_height={true} background={o.popover}>
      <Column fill_width={true} fill_height={true} padding_top={sa.top} padding_bottom={sa.bottom}>
        <Row height={56} padding_left={16} padding_right={8} align={:center} fill_width={true}>
          <Text
            text="Pinch or double-tap to zoom"
            font={:ui_medium}
            text_size={13}
            text_color={o.on_popover}
            weight={1}
          />
          <Box id="viewer-save" padding={12} fill_width={false} on_tap={save}>
            <Text
              text={save_label}
              font={:ui_semibold}
              text_size={15}
              text_color={o.popover_action}
            />
          </Box>
          <Box id="viewer-close" padding={12} fill_width={false} on_tap={close}>
            <Text text="Done" font={:ui_semibold} text_size={15} text_color={o.popover_action} />
          </Box>
        </Row>
        {body}
      </Column>
    </Box>
    """
  end

  defp chat_ready(images, key) do
    case Map.get(images, {key, :chat}) do
      {:ok, ready} -> ready
      _ -> nil
    end
  end

  # ── Events ───────────────────────────────────────────────────────────────

  @doc "Handles a picture event: open, close, save."
  def handle({:open, key}, socket) do
    image = find(socket, key)

    socket = Socket.assign(socket, :viewer, %{key: key})
    socket = if image, do: start(socket, image, :viewer), else: socket
    {:noreply, socket}
  end

  def handle(:close, socket), do: {:noreply, Socket.assign(socket, :viewer, nil)}

  def handle({:save, key}, socket), do: {:noreply, SavePicture.save(socket, key)}

  def handle(_event, socket), do: {:noreply, socket}

  @doc """
  The picture known by `key`, or nil: a material's by its key alone (the
  chat's, the Materials tab's); a session's among the messages.
  """
  def find(_socket, "material/" <> id) do
    case Bezalel.MaterialStore.fetch(id, %{}) do
      {:ok, m} -> material_image(m.id, m.mime)
      :error -> nil
    end
  end

  def find(socket, key) do
    stream_images = Enum.flat_map(Map.values(socket.assigns.streams), & &1.images)

    socket.assigns.messages
    |> Enum.flat_map(& &1.images)
    |> Enum.concat(stream_images)
    |> Enum.find(&(&1.key == key))
  end
end
