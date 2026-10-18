defmodule Bezalel.Views.Stills do
  @moduledoc """
  The stills picker (bezalel-at6.10): a sheet over a video with a scrubber
  across its length (`MobMedia.info/2`) and the frame at the scrubber's
  place (`MobMedia.frame/3`), made off the screen once the scrubber rests
  for a moment. **Keep this still** keeps the frame shown as a `:still`
  derivative of the video (`Bezalel.Materials.derive/4`, its time in
  `meta.at_ms`), linked to the open conversation. Opened from a video's
  detail in Materials, and right after a video is added to a question;
  then each still kept also waits as a chip, so it goes to the model as a
  picture (and the agent can draw from it, draw_image's `references`).

  `:stills` holds the picker's state: the video, a `ref` naming this
  opening's tasks (a result from an earlier opening is dropped), its
  length, where the scrubber is (`at_ms`, `seq` counting its moves), the
  frame shown (`nil`, `{:ok, %{at_ms, path}}` or `{:error, text}`) and
  whether a newer one is being made (`loading`), whether kept stills
  become chips, and what was kept. The previews are files in the cache's
  `stills/`: each removed once replaced, all when the picker closes
  (`close/1`, however it's closed) and at the screen's mount (`sweep/0`).
  """
  import Mob.Sigil

  alias Bezalel.{Materials, MaterialStore}
  alias Bezalel.Materials.Material
  alias Bezalel.Views.{Helpers, Images}
  alias Bezalel.Views.Materials, as: MaterialsView
  alias Mob.Socket
  alias MobBezalel.UI

  # The scrubber rests this long (ms) before its frame is made.
  @settle_ms 250
  # The frame's longest side: the preview, and the still kept from it.
  @max_px 1280

  @doc "The assigns this view keeps, for the screen's mount."
  def assigns, do: [stills: nil]

  @doc "Removes previews left by an earlier run (the screen's mount)."
  def sweep do
    File.rm_rf(dir())
    :ok
  end

  @doc """
  Opens the picker over `video`. `chip: true` (from the composer): each
  still kept also waits as a chip on the question.
  """
  def open(socket, %Material{kind: :video} = video, opts \\ []) do
    path = MaterialStore.path(video)
    ref = make_ref()

    socket
    |> close()
    |> Socket.assign(
      sheet: {:stills, video.id},
      stills: %{
        video: video,
        ref: ref,
        cid: socket.assigns.conversation.id,
        chip: Keyword.get(opts, :chip, false),
        duration_ms: nil,
        at_ms: 0,
        seq: 0,
        frame: nil,
        loading: true,
        kept: []
      }
    )
    |> Socket.start_async({:stills, :info, ref}, fn -> MobMedia.info(path) end)
  end

  @doc """
  Closes the picker, however it was closed (Done, a swipe, another tab):
  its tasks stop and its previews go.
  """
  def close(%{assigns: %{stills: %{ref: ref, video: video}}} = socket) do
    socket =
      socket
      |> Socket.cancel_async({:stills, :info, ref})
      |> Socket.cancel_async({:stills, :frame, ref})

    for file <- Path.wildcard(Path.join(dir(), video.id <> "-*")), do: File.rm(file)

    sheet = if match?({:stills, _}, socket.assigns.sheet), do: nil, else: socket.assigns.sheet
    Socket.assign(socket, sheet: sheet, stills: nil)
  end

  def close(socket), do: socket

  # ── View ─────────────────────────────────────────────────────────────────

  @doc "The sheet's content."
  def sheet(%{stills: %{} = s}) do
    keep = {self(), {:stills, :keep}}
    done = {self(), {:stills, :close}}

    [
      ~MOB(<Text text="Pick a still" font={:display} text_size={24} text_color={:on_background} />),
      ~MOB(<Text
  text={s.video.name <> " · move to the moment you want, then keep it. A still goes to the model as a picture."}
  text_size={13}
  line_height={1.5}
  text_color={:muted}
/>),
      preview(s.frame),
      scrubber(s),
      ~MOB"""
      <Row gap={10} fill_width={true}>
        {UI.pill_button("Keep this still", keep, :primary, weight: 1, height: 48)}
        {UI.pill_button("Done", done, :outline, weight: 1, height: 48)}
      </Row>
      """
    ] ++ kept(s.kept)
  end

  def sheet(_assigns), do: []

  # The frame shown stays while the next is made.
  defp preview({:ok, %{path: path}}) do
    ~MOB(<Image
  id="still-preview"
  src={path}
  height={240}
  fill_width={true}
  corner_radius={14}
  content_mode="fit"
/>)
  end

  defp preview({:error, text}), do: placeholder(text)
  defp preview(nil), do: placeholder("Finding the frame…")

  defp placeholder(text) do
    ~MOB"""
    <Box
      id="still-preview"
      background={:surface}
      border_color={:border}
      border_width={1}
      corner_radius={14}
      height={240}
      padding={12}
      align="center"
      fill_width={true}
    >
      <Text text={text} text_size={13} text_color={:muted} />
    </Box>
    """
  end

  defp scrubber(%{duration_ms: d} = s) when is_integer(d) and d > 0 do
    change = {self(), {:stills, :at}}
    at = s.at_ms * 1.0
    max = d * 1.0
    where = clock(s.at_ms) <> " of " <> clock(d)

    [
      ~MOB(<Slider id="still-scrubber" value={at} min={0.0} max={max} on_change={change} />),
      ~MOB(<Text text={where} text_size={12} text_color={:muted} />)
    ]
  end

  defp scrubber(_s), do: []

  defp kept([]), do: []

  defp kept(stills) do
    names = Enum.map_join(stills, ", ", & &1.name)
    [~MOB(<Text text={"Kept: " <> names} text_size={12} line_height={1.4} text_color={:muted} />)]
  end

  @doc "A time as m:ss.t (`75_300` is `1:15.3`)."
  def clock(ms) do
    s = div(ms, 1000)
    tenth = div(rem(ms, 1000), 100)
    "#{div(s, 60)}:#{String.pad_leading(Integer.to_string(rem(s, 60)), 2, "0")}.#{tenth}"
  end

  # ── Events ───────────────────────────────────────────────────────────────

  @doc """
  A tap in the picker (`{:tap, {:stills, event}}`). Keep keeps the frame
  shown once it's the one where the scrubber rests.
  """
  def handle(:keep, %{assigns: %{stills: %{frame: {:ok, frame}, loading: false} = s}} = socket)
      when frame.at_ms == s.at_ms,
      do: {:noreply, keep(socket, s, frame)}

  def handle(:keep, socket), do: {:noreply, socket}
  def handle(:close, socket), do: {:noreply, close(socket)}
  def handle(_event, socket), do: {:noreply, socket}

  @doc """
  The scrubber moved (`{:change, {:stills, :at}, ms}`): the frame there is
  made once it rests (`settle/2`).
  """
  def move(value, %{assigns: %{stills: %{duration_ms: d} = s}} = socket) when is_number(value) do
    at = value |> round() |> max(0) |> min(d || 0)
    seq = s.seq + 1
    Process.send_after(self(), {:stills, :settle, seq}, @settle_ms)
    Socket.assign(socket, :stills, %{s | at_ms: at, seq: seq})
  end

  def move(_value, socket), do: socket

  @doc "The scrubber rested (`{:stills, :settle, seq}`): its frame, unless it has moved since."
  def settle(seq, %{assigns: %{stills: %{seq: seq} = s}} = socket) do
    case s.frame do
      {:ok, %{at_ms: at}} when at == s.at_ms and not s.loading -> socket
      _ -> frame(socket)
    end
  end

  def settle(_seq, socket), do: socket

  # Made off the screen; a newer one takes the older's place.
  defp frame(%{assigns: %{stills: s}} = socket) do
    path = MaterialStore.path(s.video)
    at = s.at_ms
    out = Path.join(dir(), "#{s.video.id}-#{at}.jpg")

    socket
    |> Socket.assign(:stills, %{s | loading: true})
    |> Socket.start_async({:stills, :frame, s.ref}, fn ->
      with {:ok, jpeg} <- MobMedia.frame(path, at, max_px: @max_px),
           :ok <- File.mkdir_p(Path.dirname(out)),
           :ok <- File.write(out, jpeg),
           do: {:ok, %{at_ms: at, path: out}}
    end)
  end

  @doc """
  The video's length is known (`handle_async({:stills, :info, ref}, …)`):
  the first frame. A result for a picker since closed is dropped.
  """
  def info(ref, result, %{assigns: %{stills: %{ref: ref} = s}} = socket) do
    case result do
      {:ok, {:ok, %{has_video: true, duration_ms: d}}} ->
        socket |> Socket.assign(:stills, %{s | duration_ms: d || 0}) |> frame()

      {:ok, {:ok, %{has_video: false}}} ->
        failed(socket, "This video has no picture to take a still from.")

      {:ok, {:error, reason}} ->
        failed(socket, cant(reason))

      {:exit, reason} ->
        failed(socket, cant(reason))
    end
  end

  def info(_ref, _result, socket), do: socket

  @doc """
  A frame is made (`handle_async({:stills, :frame, ref}, …)`): it replaces
  the one shown, whose preview goes. A result for a picker since closed is
  dropped (with its file).
  """
  def framed(ref, result, %{assigns: %{stills: %{ref: ref} = s}} = socket) do
    case result do
      {:ok, {:ok, %{} = f}} ->
        with {:ok, %{path: old}} when old != f.path <- s.frame, do: File.rm(old)
        Socket.assign(socket, :stills, %{s | frame: {:ok, f}, loading: false})

      {:ok, {:error, reason}} ->
        failed(socket, cant(reason))

      {:exit, reason} ->
        failed(socket, cant(reason))
    end
  end

  def framed(_ref, {:ok, {:ok, %{path: path}}}, socket) do
    File.rm(path)
    socket
  end

  def framed(_ref, _result, socket), do: socket

  defp failed(%{assigns: %{stills: s}} = socket, text),
    do: Socket.assign(socket, :stills, %{s | frame: {:error, text}, loading: false})

  defp cant(:unsupported), do: "This phone can't read this video, so there's no still to take."
  defp cant(:no_video), do: "This video has no picture to take a still from."
  defp cant(:not_found), do: "The video's file is gone from the phone."
  defp cant(:unavailable), do: "Stills can't be taken in this build of Bezalel."
  defp cant(reason), do: "The frame couldn't be made (#{inspect(reason)})."

  # The frame shown, kept as the video's still, linked to the conversation
  # open; a chip too when the picker came from the composer there. The same
  # frame kept twice is one still (named by its bytes).
  defp keep(socket, s, frame) do
    ctx = %{session_id: socket.assigns.conversation.session_id}

    with {:ok, bytes} <- File.read(frame.path),
         still = Materials.derive(:still, s.video, bytes, meta: %{at_ms: frame.at_ms}),
         {:ok, still} <- MaterialStore.put(still, bytes, ctx) do
      kept = Enum.reject(s.kept, &(&1.id == still.id)) ++ [still]

      socket
      |> Socket.assign(:stills, %{s | kept: kept})
      |> chip(s, still)
      |> refresh_detail(s.video.id)
      |> Images.load(Images.material_images([still]))
      |> Helpers.toast("Kept “#{still.name}” in Materials.")
    else
      {:error, reason} ->
        Helpers.toast(socket, "The still couldn't be kept (#{inspect(reason)}).")
    end
  end

  defp chip(%{assigns: %{conversation: %{id: cid}}} = socket, %{chip: true, cid: cid}, still) do
    if Enum.any?(socket.assigns.attachments, &(&1.id == still.id)),
      do: socket,
      else: Socket.assign(socket, :attachments, socket.assigns.attachments ++ [still])
  end

  defp chip(socket, _s, _still), do: socket

  # The video's detail, open under the sheet, lists the new still.
  defp refresh_detail(%{assigns: %{tab: :materials, mat_open: %{material: %{id: id}}}} = s, id),
    do: MaterialsView.open(s, id)

  defp refresh_detail(socket, _id), do: socket

  defp dir, do: Path.join(MaterialStore.cache_dir(), "stills")
end
