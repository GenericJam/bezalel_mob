defmodule Bezalel.Views.Attach do
  @moduledoc """
  What the composer adds to a question (Materials, bezalel_core's
  `Bezalel.Materials`; decisions/2026-10-18-materials-on-the-phone.md):

    * **The + menu** (`:attach` sheet): the photo library (mob_photos), the
      camera for a photo or a video (mob_camera; a video only after
      `Bezalel.Materials.video_notice/0`), a recording (`Mob.Audio`, with
      the recorder line over the field) and files (`Mob.Files`). What comes
      back is kept in `Bezalel.MaterialStore` at once (they are the user's
      materials whether or not the question is sent) and waits as a chip
      over the field (`:attachments`). A recording is transcribed straight
      away (`Bezalel.Transcribe`), so its words show under its chip.
    * **Sending** (`prepare/4`): the chips' materials as rho attachments for
      the model chosen now (`Bezalel.Materials.attachments/4`); audio and
      video still without a transcript are transcribed first, then the
      question goes (`Bezalel.Views.Study.send_prepared/4`). Until then the
      composer says what it's doing and holds the question.
    * **Dictation** (the mic): the platform's recogniser (mob_speech), its
      partial text landing in the box after what was typed; where it isn't
      available, or once it heard nothing, Whisper on the phone
      (mob_whisper), whose text lands when the mic is tapped again.
      `config :bezalel, :dictation` (`primary:` / `fallback:`, each
      `{engine, opts}`) names the engines; tests script them.

  The native calls go through `Bezalel.Native`; the permission each needs
  (`Mob.Permissions`) is asked for first, and the action waits for it
  (`:pending`).
  """
  import Mob.Sigil

  alias Bezalel.{Materials, MaterialStore, Models, Native, Transcribe}
  alias Bezalel.Materials.Material
  alias Bezalel.Views.{Helpers, Images, Stills, Study}
  alias Mob.Socket
  alias MobBezalel.UI

  # A file larger than this isn't kept: its bytes are read whole to name it.
  @max_bytes 250_000_000

  @doc "The assigns this view keeps, for the screen's mount."
  def assigns do
    [
      attachments: [],
      keeping: 0,
      pending: nil,
      recorder: nil,
      dictation: nil,
      dictation_fallback: false,
      dictation_choice: nil,
      preparing: nil,
      transcripts: %{}
    ]
  end

  # ── View ─────────────────────────────────────────────────────────────────

  @doc """
  The composer's extras for `MobBezalel.UI.composer/5`: the + button, the
  mic, what shows over the field (chips, the recorder, what's being done)
  and whether send is live.
  """
  def composer_opts(assigns) do
    dictating? = assigns.dictation != nil
    busy? = assigns.preparing != nil or assigns.keeping > 0

    [
      leading: [UI.icon_button(:plus, {self(), {:attach, :menu}}, id: "attach-menu")],
      actions: [
        UI.icon_button(:mic, {self(), {:attach, :mic}}, id: "dictate", active: dictating?)
      ],
      above: above(assigns),
      send_enabled:
        not busy? and assigns.recorder == nil and assigns.dictation == nil and
          (String.trim(assigns.draft) != "" or assigns.attachments != [])
    ]
  end

  defp above(assigns) do
    chips =
      for m <- assigns.attachments do
        UI.attachment_chip(icon(m.kind), m.name, {self(), {:attach, {:remove, m.id}}})
      end

    chips =
      if chips == [],
        do: [],
        else: [~MOB(<Wrap spacing={6} run_spacing={6} fill_width={true}>
  {chips}
</Wrap>)]

    heard = Enum.flat_map(assigns.attachments, &heard(assigns.transcripts[&1.id], &1))

    chips ++ heard ++ recorder(assigns.recorder) ++ status(assigns)
  end

  defp heard(nil, _m), do: []
  defp heard(:working, m), do: [note("Transcribing #{m.name}…")]
  defp heard({:error, message}, _m), do: [note(message)]
  defp heard("", m), do: [note("Nothing was said in #{m.name}.")]
  defp heard(text, _m), do: [note("“" <> String.slice(text, 0, 160) <> "”")]

  defp recorder(nil), do: []

  defp recorder(%{seconds: s}) do
    stop = {self(), {:attach, :stop_recording}}
    cancel = {self(), {:attach, :cancel_recording}}
    clock = "#{div(s, 60)}:#{String.pad_leading(Integer.to_string(rem(s, 60)), 2, "0")}"

    [
      ~MOB"""
      <Row id="recorder" gap={10} align={:center} fill_width={true}>
        <Box width={10} height={10} corner_radius={5} background={:error} fill_width={false} />
        <Text
          text={"Recording · " <> clock}
          font={:ui_medium}
          text_size={13}
          text_color={:on_background}
          weight={1}
        />
        {UI.pill_button("Cancel", cancel, :outline, height: 32, fill: false, text_size: 12)}
        {UI.pill_button("Stop", stop, :primary, height: 32, fill: false, text_size: 12)}
      </Row>
      """
    ]
  end

  defp status(%{preparing: %{label: label}}), do: [note(label)]
  defp status(%{keeping: n}) when n > 0, do: [note("Adding to Materials…")]

  defp status(%{dictation: %{engine: :fallback}}),
    do: [note("Listening on the phone. Tap the mic when you're done.")]

  defp status(%{dictation: %{}}), do: [note("Listening… tap the mic to finish.")]
  defp status(_assigns), do: []

  defp note(text) do
    ~MOB(<Text text={text} text_size={12} line_height={1.4} text_color={:muted} max_lines={3} />)
  end

  @doc "The icon for a kind of material (`MobBezalel.Icons`)."
  def icon(:image), do: :image
  def icon(:audio), do: :audio
  def icon(:video), do: :video
  def icon(_kind), do: :file

  @doc "The + menu's sheet."
  def menu_sheet do
    tap = &{self(), {:attach, &1}}

    [
      ~MOB(<Text text="Add to your question" font={:display} text_size={24} text_color={:on_background} />),
      ~MOB(<Text
  text="What you add is kept in Materials. Bezalel sees pictures and PDFs, and a transcript of what's said in a recording."
  text_size={13}
  line_height={1.5}
  text_color={:muted}
/>),
      UI.menu_row(:image, "Photo library", "A photo or screenshot", tap.(:photos)),
      UI.menu_row(:camera, "Take a photo", "A page, an inscription, a map", tap.(:camera)),
      UI.menu_row(
        :video,
        "Record a video",
        "What's said in it, and stills you pick",
        tap.(:video)
      ),
      UI.menu_row(:audio, "Record audio", "A thought, a reading, a sermon", tap.(:record)),
      UI.menu_row(:file, "Files", "A PDF, a text file, a recording", tap.(:files))
    ]
  end

  @doc """
  The video notice, before a video is recorded or added
  (`Bezalel.Materials.video_notice/0`). `source` is `:camera` or the
  picked files (kept only if the user goes on).
  """
  def video_sheet(source) do
    go = {self(), {:attach, {:video_ok, source}}}
    back = {self(), {:attach, {:video_no, source}}}
    label = if source == :camera, do: "Record a video", else: "Add the video"
    notice = Materials.video_notice()

    [
      ~MOB(<Text text="About videos" font={:display} text_size={24} text_color={:on_background} />),
      ~MOB(<Text text={notice} text_size={14.5} line_height={1.55} text_color={:on_background} />),
      ~MOB(<Text
  text="The video stays in Materials with its transcript. Next, pick stills from it to show Bezalel."
  text_size={13}
  line_height={1.5}
  text_color={:muted}
/>),
      ~MOB"""
      <Row gap={10} fill_width={true}>
        {UI.pill_button(label, go, :primary, weight: 1, height: 48)}
        {UI.pill_button("Not now", back, :outline, weight: 1, height: 48)}
      </Row>
      """
    ]
  end

  # ── Events ───────────────────────────────────────────────────────────────

  @doc "A tap from the composer or its sheets (`{:tap, {:attach, event}}`)."
  def handle(:menu, socket), do: {:noreply, Socket.assign(socket, sheet: :attach, menu: nil)}

  def handle(:photos, socket),
    do: {:noreply, socket |> close_sheet() |> Native.pick_photos(max: 4, types: [:image, :video])}

  def handle(:files, socket), do: {:noreply, socket |> close_sheet() |> Native.pick_files([])}
  def handle(:camera, socket), do: {:noreply, socket |> close_sheet() |> ask(:photo, [:camera])}

  def handle(:record, socket),
    do: {:noreply, socket |> close_sheet() |> ask(:record, [:microphone])}

  def handle(:video, socket),
    do: {:noreply, Socket.assign(socket, :sheet, {:video_notice, :camera})}

  def handle({:video_ok, :camera}, socket),
    do: {:noreply, socket |> close_sheet() |> ask(:video, [:camera, :microphone])}

  def handle({:video_ok, items}, socket), do: {:noreply, socket |> close_sheet() |> keep(items)}
  def handle({:video_no, _source}, socket), do: {:noreply, close_sheet(socket)}

  # Its transcript stays known: one being made is still being made.
  def handle({:remove, id}, socket) do
    {:noreply,
     Socket.assign(socket, :attachments, Enum.reject(socket.assigns.attachments, &(&1.id == id)))}
  end

  def handle(:stop_recording, %{assigns: %{recorder: %{}}} = socket),
    do: {:noreply, Native.stop_recording(socket)}

  def handle(:cancel_recording, %{assigns: %{recorder: %{} = r}} = socket) do
    {:noreply,
     socket |> Socket.assign(:recorder, %{r | cancelled: true}) |> Native.stop_recording()}
  end

  def handle(:mic, %{assigns: %{dictation: nil}} = socket) do
    {engine, opts} = dictation_engine(socket)
    socket = Socket.assign(socket, :dictation_choice, {engine, opts})
    {:noreply, ask(socket, :dictate, MobSpeech.permissions(engine))}
  end

  def handle(:mic, socket), do: {:noreply, MobSpeech.stop(socket)}

  def handle(_event, socket), do: {:noreply, socket}

  defp close_sheet(socket), do: Socket.assign(socket, :sheet, nil)

  # ── Permissions, then the action ─────────────────────────────────────────

  # Asks for each capability in turn; the action runs once all are granted.
  defp ask(socket, action, []), do: run(socket, action)

  defp ask(socket, action, [cap | _] = caps) do
    socket
    |> Socket.assign(:pending, %{action: action, caps: caps})
    |> Native.request_permission(cap)
  end

  @doc "A permission's answer (`{:permission, capability, result}`)."
  def permission(
        cap,
        :granted,
        %{assigns: %{pending: %{caps: [cap | rest], action: action}}} = s
      ),
      do: s |> Socket.assign(:pending, nil) |> ask(action, rest)

  def permission(cap, _denied, %{assigns: %{pending: %{caps: [cap | _]}}} = socket) do
    socket
    |> Socket.assign(:pending, nil)
    |> Helpers.toast("Bezalel needs the #{what(cap)} for that. Allow it in the phone's Settings.")
  end

  def permission(_cap, _result, socket), do: socket

  defp what(:camera), do: "camera"
  defp what(:speech), do: "speech recognition"
  defp what(_microphone), do: "microphone"

  defp run(socket, :photo), do: Native.capture_photo(socket, quality: :high)
  defp run(socket, :video), do: Native.capture_video(socket, max_duration: 600)

  defp run(socket, :record) do
    tick(self())

    socket
    |> Socket.assign(:recorder, %{started: now_s(), seconds: 0, cancelled: false})
    |> Native.start_recording()
  end

  defp run(socket, :dictate) do
    {engine, opts} = choice = socket.assigns.dictation_choice || dictation_engine(socket)
    fallback? = choice == engines()[:fallback]

    socket =
      if fallback? and not Transcribe.model_ready?() do
        Transcribe.prefetch(self())

        Helpers.toast(
          socket,
          "Bezalel is fetching its speech model (60 MB) for dictation on the phone. Talk now; the words come when it's ready."
        )
      else
        socket
      end

    socket
    |> Socket.assign(
      dictation: %{
        engine: if(fallback?, do: :fallback, else: :primary),
        base: socket.assigns.draft
      },
      dictation_choice: nil
    )
    |> MobSpeech.listen([engine: engine] ++ opts)
  end

  defp tick(pid), do: Process.send_after(pid, {:attach, :tick}, 1000)

  defp now_s, do: System.monotonic_time(:second)

  @doc "The recorder's clock (`{:attach, :tick}`, every second while recording)."
  def tick_recorder(%{assigns: %{recorder: %{started: t} = r}} = socket) do
    tick(self())
    Socket.assign(socket, :recorder, %{r | seconds: now_s() - t})
  end

  def tick_recorder(socket), do: socket

  # ── Dictation ────────────────────────────────────────────────────────────

  defp engines do
    defaults = [primary: {:platform, [partial_results: true]}, fallback: {MobWhisper, []}]
    Keyword.merge(defaults, Application.get_env(:bezalel, :dictation, []))
  end

  # The platform's recogniser while it's there and hearing; Whisper after.
  defp dictation_engine(socket) do
    {primary, _} = p = engines()[:primary]

    if socket.assigns.dictation_fallback or not MobSpeech.available?(primary),
      do: engines()[:fallback],
      else: p
  end

  @doc "A recogniser event (`{:speech, kind, value}`)."
  def speech(:partial, text, %{assigns: %{dictation: %{base: base}}} = socket),
    do: Socket.assign(socket, :draft, join(base, text))

  def speech(:final, text, %{assigns: %{dictation: %{base: base, engine: engine}}} = socket) do
    socket = Socket.assign(socket, draft: join(base, text), dictation: nil)

    if String.trim(text) == "" and engine == :primary do
      socket
      |> Socket.assign(:dictation_fallback, true)
      |> Helpers.toast(
        "Nothing came through. The next dictation uses Bezalel's own recogniser on the phone."
      )
    else
      socket
    end
  end

  # Heard nothing: the next dictation uses Whisper (the mic doesn't reopen
  # by itself).
  def speech(:error, :no_speech, %{assigns: %{dictation: %{engine: :primary}}} = socket) do
    socket
    |> Socket.assign(dictation: nil, dictation_fallback: true)
    |> Helpers.toast(
      "Nothing came through. The next dictation uses Bezalel's own recogniser on the phone."
    )
  end

  # The platform's recogniser can't (no service, no language, no access):
  # Whisper takes over now, while the user is still talking.
  def speech(:error, reason, %{assigns: %{dictation: %{engine: :primary}}} = socket)
      when reason in [:unavailable, :language, :service_permission, :client, :server, :network] do
    {engine, _} = engines()[:fallback]

    socket
    |> Socket.assign(dictation: nil, dictation_fallback: true)
    |> Socket.assign(:dictation_choice, engines()[:fallback])
    |> ask(:dictate, MobSpeech.permissions(engine))
  end

  def speech(:error, reason, %{assigns: %{dictation: %{}}} = socket) do
    socket
    |> Socket.assign(:dictation, nil)
    |> Helpers.toast(speech_error(reason))
  end

  def speech(_kind, _value, socket), do: socket

  defp speech_error(:permission), do: "Bezalel needs the microphone to take dictation."

  defp speech_error(:no_speech),
    do: "Nothing came through. Try again a little closer to the phone."

  defp speech_error(:network),
    do: "The speech model couldn't download. Try again with a connection."

  defp speech_error(:busy), do: "The microphone is busy. Try again in a moment."
  defp speech_error(reason), do: "Dictation stopped (#{inspect(reason)})."

  defp join(base, text) do
    case {String.trim_trailing(base), String.trim(text)} do
      {"", t} -> t
      {b, ""} -> b
      {b, t} -> b <> " " <> t
    end
  end

  @doc "Whisper's model fetched for dictation or transcripts (`{:mob_whisper, :model, result}`)."
  def model(:ready, socket), do: Helpers.toast(socket, "Bezalel's speech model is ready.")

  def model({:error, :network}, socket),
    do: Helpers.toast(socket, "The speech model couldn't download. Try again with a connection.")

  def model({:error, _}, socket),
    do: Helpers.toast(socket, "Bezalel's speech recogniser isn't working on this phone.")

  # ── What comes back from the pickers ─────────────────────────────────────

  @doc """
  What a picker, the camera or the recorder sends back (`{:photos, …}`,
  `{:camera, …}`, `{:files, …}`, `{:audio, …}`).
  """
  def picked({:photos, :picked, items}, socket), do: offer(socket, Enum.map(items, &photo_item/1))
  def picked({:files, :picked, items}, socket), do: offer(socket, Enum.map(items, &file_item/1))

  def picked({:camera, :photo, %{path: path} = info}, socket) do
    meta = Map.take(info, [:width, :height])
    keep(socket, [%{path: path, name: stamp("Photo", path), meta: meta}])
  end

  def picked({:camera, :video, %{path: path} = info}, socket) do
    meta =
      if is_number(info[:duration]), do: %{duration_ms: round(info.duration * 1000)}, else: %{}

    keep(socket, [%{path: path, name: stamp("Video", path), meta: meta}])
  end

  def picked({:audio, :recorded, %{path: path} = info}, %{assigns: %{recorder: r}} = socket) do
    socket = Socket.assign(socket, :recorder, nil)

    if r && r.cancelled do
      File.rm(path)
      socket
    else
      meta =
        if is_number(info[:duration]), do: %{duration_ms: round(info.duration * 1000)}, else: %{}

      keep(socket, [%{path: path, name: stamp("Recording", path), meta: meta}])
    end
  end

  def picked({:audio, :error, reason}, socket) do
    socket
    |> Socket.assign(:recorder, nil)
    |> Helpers.toast("The recording didn't work (#{inspect(reason)}).")
  end

  def picked(_cancelled, socket), do: socket

  # Videos wait for the notice; the rest are kept now.
  defp offer(socket, items) do
    {videos, others} = Enum.split_with(items, &(Materials.kind(item_mime(&1)) == :video))
    socket = keep(socket, others)
    if videos == [], do: socket, else: Socket.assign(socket, :sheet, {:video_notice, videos})
  end

  defp photo_item(%{path: path} = item) do
    name = item[:name] || Path.basename(path)
    name = if Path.extname(name) == "", do: name <> Path.extname(path), else: name
    %{path: path, name: name, meta: Map.take(item, [:width, :height]) |> positive()}
  end

  defp file_item(%{path: path} = item) do
    mime = if item[:mime] in [nil, "", "application/octet-stream"], do: nil, else: item[:mime]
    name = Path.basename(item[:name] || path)

    name =
      if Path.extname(name) == "" and mime,
        do: name <> "." <> Materials.extension(mime),
        else: name

    %{path: path, name: name, mime: mime, meta: %{}}
  end

  defp positive(meta), do: Map.reject(meta, fn {_k, v} -> not (is_integer(v) and v > 0) end)

  defp item_mime(item), do: item[:mime] || Materials.mime(item.name)

  defp stamp(what, path) do
    at = NaiveDateTime.local_now() |> Calendar.strftime("%-d %b %H.%M")
    "#{what} #{at}#{Path.extname(path)}"
  end

  # Kept off the screen's process: a file is read whole and hashed. The
  # chips are for the conversation open now (`kept/3`).
  defp keep(socket, []), do: socket

  defp keep(socket, items) do
    ctx = ctx(socket)
    cid = socket.assigns.conversation.id

    socket
    |> Socket.assign(:keeping, socket.assigns.keeping + 1)
    |> Socket.start_async({:keep, cid, make_ref()}, fn ->
      Enum.map(items, &keep_item(&1, ctx))
    end)
  end

  defp keep_item(item, ctx) do
    with {:ok, %File.Stat{size: size}} <- File.stat(item.path),
         :ok <- if(size <= @max_bytes, do: :ok, else: {:error, :too_large}),
         {:ok, bytes} <- File.read(item.path),
         attrs = [
           name: item.name,
           mime: item[:mime] || Materials.mime(item.name),
           meta: item.meta
         ],
         {:ok, m} <- MaterialStore.put(Materials.new(bytes, attrs), bytes, ctx) do
      {:ok, m}
    else
      {:error, reason} -> {:error, item.name, reason}
    end
  end

  @doc """
  Materials kept from the pickers for conversation `cid`
  (`handle_async({:keep, cid, _}, …)`): chips there if it's still open;
  if the user has moved on, they're only in Materials, and told so.
  """
  def kept(cid, result, socket) do
    socket = Socket.assign(socket, :keeping, max(socket.assigns.keeping - 1, 0))

    case result do
      {:ok, results} ->
        materials = for {:ok, m} <- results, do: m
        failed = for {:error, name, reason} <- results, do: {name, reason}

        socket
        |> add_chips(cid, materials)
        |> keep_failed(failed)

      {:exit, reason} ->
        Helpers.toast(socket, "That couldn't be added (#{inspect(reason)}).")
    end
  end

  defp add_chips(socket, _cid, []), do: socket

  defp add_chips(%{assigns: %{conversation: %{id: cid}}} = socket, cid, materials) do
    known = MapSet.new(socket.assigns.attachments, & &1.id)
    added = Enum.reject(materials, &MapSet.member?(known, &1.id))

    socket
    |> Socket.assign(:attachments, socket.assigns.attachments ++ added)
    |> Images.load(Images.material_images(added))
    |> transcribe_recordings(added)
    |> offer_stills(added)
  end

  defp add_chips(socket, _cid, _materials) do
    Helpers.toast(
      socket,
      "It's kept in Materials. It wasn't added here: you'd moved to another conversation."
    )
  end

  # A video just added: its stills picker, each still kept also a chip;
  # unless the user has gone on to something else meanwhile (another
  # sheet, another tab), then only a word of where its stills are.
  defp offer_stills(socket, added) do
    case Enum.find(added, &(&1.kind == :video)) do
      nil ->
        socket

      video when socket.assigns.sheet == nil and socket.assigns.tab == :study ->
        Stills.open(socket, video, chip: true)

      video ->
        Helpers.toast(socket, "#{video.name} is added. Pick stills from it in Materials.")
    end
  end

  defp keep_failed(socket, []), do: socket

  defp keep_failed(socket, [{name, :too_large} | _]),
    do: Helpers.toast(socket, "#{name} is too large to keep on the phone (250 MB at most).")

  defp keep_failed(socket, [{name, reason} | _]),
    do: Helpers.toast(socket, "#{name} couldn't be added (#{inspect(reason)}).")

  # A recording shows its words before it's sent.
  defp transcribe_recordings(socket, materials) do
    Enum.reduce(materials, socket, fn
      %Material{kind: :audio} = m, socket -> transcribe(socket, m)
      _m, socket -> socket
    end)
  end

  @doc """
  Transcribes `m` in the background, its words then shown (`transcribed/3`);
  once at a time.
  """
  def transcribe(%{assigns: %{transcripts: t}} = socket, %Material{id: id})
      when is_map_key(t, id) and :erlang.map_get(id, t) == :working,
      do: socket

  def transcribe(socket, %Material{} = m) do
    ctx = ctx(socket)

    socket =
      if Transcribe.model_ready?(),
        do: socket,
        else:
          Helpers.toast(
            socket,
            "The first transcript takes a while: Bezalel fetches its speech model (60 MB)."
          )

    socket
    |> Socket.assign(:transcripts, Map.put(socket.assigns.transcripts, m.id, :working))
    |> Socket.start_async({:transcribe, m.id}, fn -> Transcribe.transcribe(m, ctx) end)
  end

  @doc """
  A transcript is made (`handle_async({:transcribe, id}, …)`); a question
  waiting for it goes on.
  """
  def transcribed(id, result, socket) do
    value =
      case result do
        {:ok, {:ok, t}} -> transcript_text(t)
        {:ok, {:error, reason}} -> {:error, transcribe_error(reason)}
        {:exit, reason} -> {:error, transcribe_error(reason)}
      end

    socket
    |> Socket.assign(:transcripts, Map.put(socket.assigns.transcripts, id, value))
    |> start_prepare()
  end

  defp transcript_text(t) do
    case MaterialStore.read(t, %{}) do
      {:ok, text} -> text
      {:error, _} -> ""
    end
  end

  @doc "What to tell the user when a transcript couldn't be made."
  def transcribe_error(:network),
    do: "Bezalel's speech model couldn't download. Try again with a connection."

  def transcribe_error(:unavailable),
    do: "This phone can't transcribe it here, so it can't go to a model that doesn't take audio."

  def transcribe_error(:unsupported),
    do:
      "Bezalel can't read this kind of audio, so it can't go to a model that doesn't take audio."

  def transcribe_error(reason), do: "It couldn't be transcribed (#{inspect(reason)})."

  # ── Sending ──────────────────────────────────────────────────────────────

  @doc """
  Sends `text` as `mode` (`:ask`, `:steer`, `:again`) with the chips'
  materials, or with `materials` (a question asked again takes its own):
  at once without materials, else once they're attachments for the model
  chosen now (`prepared/2`), transcribing what must be first. The chips
  leave the composer as the question does (the screen clears the draft);
  if it can't go, both come back. A transcript already being made is
  waited for, not made twice (`transcribed/3`).
  """
  def prepare(socket, mode, text, materials \\ nil)

  def prepare(socket, mode, text, nil) do
    chips = socket.assigns.attachments
    socket |> Socket.assign(:attachments, []) |> prepare(mode, text, chips)
  end

  def prepare(socket, mode, text, []), do: Study.send_prepared(socket, mode, text, [])

  def prepare(socket, mode, text, materials) do
    preparing = %{
      cid: socket.assigns.conversation.id,
      mode: mode,
      text: text,
      materials: materials,
      model: Helpers.model(socket).id,
      ctx: ctx(socket),
      started: false,
      label: preparing_label(materials)
    }

    socket |> Socket.assign(:preparing, preparing) |> start_prepare()
  end

  # Starts making the attachments once no transcript they need is still
  # being made.
  defp start_prepare(%{assigns: %{preparing: %{started: false} = p}} = socket) do
    if Enum.any?(p.materials, &(socket.assigns.transcripts[&1.id] == :working)) do
      socket
    else
      ids = Enum.map(p.materials, & &1.id)
      inputs = Rho.Models.inputs(p.model)

      socket
      |> Socket.assign(:preparing, %{p | started: true})
      |> Socket.start_async({:prepare, p.cid}, fn -> attachments(ids, inputs, p.ctx) end)
    end
  end

  defp start_prepare(socket), do: socket

  defp preparing_label(materials) do
    sound? = Enum.any?(materials, &(&1.kind in [:audio, :video]))

    cond do
      sound? and not Transcribe.model_ready?() ->
        "Transcribing… the first time, Bezalel fetches its speech model (60 MB)."

      sound? ->
        "Transcribing what's said…"

      true ->
        "Preparing your materials…"
    end
  end

  @doc """
  The rho attachments for `ids`, transcribing the audio and video still
  without a transcript first. Blocks: run it off the screen.
  """
  def attachments(ids, inputs, ctx) do
    case Materials.attachments(ids, inputs, ctx) do
      {:missing, missing} ->
        case Enum.find_value(missing, &failed(Transcribe.transcribe(&1, ctx), &1)) do
          nil -> Materials.attachments(ids, inputs, ctx)
          error -> error
        end

      result ->
        result
    end
  end

  defp failed({:ok, _}, _m), do: nil
  defp failed({:error, reason}, m), do: {:error, {:transcribe, m, reason}}

  @doc "The question's attachments are ready (`handle_async({:prepare, _}, …)`)."
  def prepared(result, %{assigns: %{preparing: %{} = p}} = socket) do
    socket = Socket.assign(socket, :preparing, nil)

    case result do
      {:ok, {:ok, atts}} ->
        socket
        |> forget_transcripts(p.materials)
        |> Study.send_prepared(p.mode, p.text, atts, p.cid)

      {:ok, {:error, reason}} ->
        not_sent(socket, p, reason)

      {:exit, reason} ->
        not_sent(socket, p, reason)
    end
  end

  def prepared(_result, socket), do: socket

  # The transcripts shown under chips that went (one being made stays known).
  defp forget_transcripts(socket, materials) do
    transcripts =
      Enum.reduce(materials, socket.assigns.transcripts, fn m, acc ->
        if acc[m.id] == :working, do: acc, else: Map.delete(acc, m.id)
      end)

    Socket.assign(socket, :transcripts, transcripts)
  end

  # The question didn't go: in the conversation still open, its words and
  # chips come back (before what was added meanwhile; a deleted material's
  # chip doesn't); a question asked again keeps its Try again.
  defp not_sent(%{assigns: %{conversation: %{id: cid}}} = socket, %{cid: cid} = p, reason) do
    message = send_error(reason, p.mode, socket)

    case p.mode do
      :again ->
        Helpers.toast(socket, message, ask_again: socket.assigns.streams[cid] == nil)

      _ask_or_steer ->
        gone = with {:not_found, id} <- reason, do: id
        chips = Enum.reject(p.materials, &(&1.id == gone))
        known = MapSet.new(chips, & &1.id)
        added = Enum.reject(socket.assigns.attachments, &MapSet.member?(known, &1.id))

        # A dictation started meanwhile writes over the box from its base:
        # the question goes back before both.
        dictation =
          with %{base: base} = d <- socket.assigns.dictation,
               do: %{d | base: before(p.text, base)}

        socket
        |> Socket.assign(
          attachments: chips ++ added,
          draft: before(p.text, socket.assigns.draft),
          dictation: dictation
        )
        |> Helpers.toast(message)
    end
  end

  defp not_sent(socket, p, reason), do: Helpers.toast(socket, send_error(reason, p.mode, socket))

  defp before(text, typed) do
    case String.trim(typed) do
      "" -> text
      typed -> String.trim(text <> "\n\n" <> typed)
    end
  end

  defp send_error({:transcribe, m, reason}, _mode, socket) do
    model = Models.get(socket.assigns.model_id).name
    "#{m.name}: #{transcribe_error(reason)} (#{model} reads its transcript.)"
  end

  defp send_error({:not_found, _id}, :again, _socket),
    do: "One of its materials was deleted meanwhile. Try again to ask without it."

  defp send_error({:not_found, _id}, _mode, _socket),
    do: "One of the materials was deleted before it was sent; it's off the question. Send again."

  defp send_error(reason, _mode, _socket),
    do: "The materials couldn't be sent (#{inspect(reason)})."

  defp ctx(socket), do: %{session_id: socket.assigns.conversation.session_id}
end
