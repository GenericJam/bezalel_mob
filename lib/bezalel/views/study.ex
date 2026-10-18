defmodule Bezalel.Views.Study do
  @moduledoc """
  The Study tab: the conversation with the agent, read from its session
  (`Bezalel.Library`). Replies fold to their type and first line; a cited
  passage's highlighted words open the Hebrew; pictures show at the chat's
  width and open full-screen (`Bezalel.Views.Images`); any message can be
  copied or deleted from its ⋯ menu (deleting further up asks first, and
  every delete can be undone).

  A live reply (`Bezalel.Agent.live?/1`) streams in: rho's loop events
  are folded into a `Bezalel.Agent.Reply` per conversation (`streams`,
  found by the loop's session id in `sessions`) and drawn below the stored
  messages, with a stop button in the composer; the loop writes it into
  the session as it goes. A message sent while it streams steers it; once
  the loop takes it in, the reply so far shows from the session, then the
  message, and the rest streams as the next reply. A failed reply stays as
  its error, with Try again (the question asked anew). A delete or undo
  made while a reply streams in that conversation waits for it to end (the
  loop holds the session), the deleted message hidden meanwhile
  (`edits`).
  """
  import Mob.Sigil

  alias Bezalel.{Agent, Library, MaterialStore, Models, Native, Scripture, Settings}
  alias Bezalel.Agent.{Card, Reply, Storyboard}
  alias Bezalel.Study.{DB, Lexicon}
  alias Bezalel.Views.{Attach, Helpers, Images, Sources}
  alias Bezalel.Views.Materials, as: MaterialsView
  alias Mob.Socket
  alias MobBezalel.{Icons, UI}
  alias Rho.Session

  # ── View ──────────────────────────────────────────────────────────────────

  @doc "The Study body: the scrolling conversation and the composer under it."
  def render(assigns) do
    model = Models.get(assigns.model_id)
    live? = Agent.live?(assigns.account)
    stream = Map.get(assigns.streams, assigns.conversation.id)
    live_blocks = if stream, do: Reply.blocks(stream), else: []

    assigns =
      Map.put(
        assigns,
        :markdown,
        markdown_keys(assigns.messages, {live_message(stream), live_blocks}, assigns.expanded)
      )

    rows = Enum.map(assigns.messages, &message(&1, assigns))
    draft_change = {self(), :draft}
    send_tap = {self(), {:study, :send}}
    build_tap = {self(), {:study, :build_from_chat}}
    hammer = Icons.icon(:hammer, 18, :secondary)

    stop = if Reply.running?(stream), do: [stop: {self(), {:study, :stop}}], else: []
    composer_opts = stop ++ Attach.composer_opts(assigns)

    ~MOB"""
    <Column weight={1} fill_width={true}>
      <Scroll id={"study-#{@conversation.id}"} anchor="bottom" weight={1} background={:background}>
        <Column
          padding_left={16}
          padding_right={16}
          padding_top={18}
          padding_bottom={16}
          gap={14}
          fill_width={true}
        >
          <Text
            text={@conversation.kicker}
            font={:ui_semibold}
            text_size={10}
            letter_spacing={1.4}
            text_color={:muted}
            text_align="center"
            fill_width={true}
          />
          <Text
            :if={@messages == [] and stream == nil}
            text="Ask about a passage to begin. Replies cite Scripture, and you can tap a highlighted word for its Hebrew."
            text_size={14}
            line_height={1.5}
            text_color={:muted}
          />
          {rows}
          {live(stream, live_blocks, assigns)}
          <Text
            :if={Helpers.replying?(assigns)}
            text={replying_label(stream)}
            font={:ui_medium}
            text_size={12}
            text_color={:muted}
          />
          {switch_note(@switched, model, live?)}
          <Box
            :if={@messages != []}
            border_color={:border}
            border_width={1}
            corner_radius={20}
            height={40}
            padding_left={12}
            padding_right={16}
            align="center"
            fill_width={false}
            on_tap={build_tap}
          >
            <Row gap={8} align={:center}>
              {hammer}
              <Text
                text="Build an outline tool from this"
                font={:ui_medium}
                text_size={14}
                text_color={:on_background}
              />
            </Row>
          </Box>
        </Column>
      </Scroll>
      {UI.composer(@draft, "Ask about this passage…", draft_change, send_tap, composer_opts)}
    </Column>
    """
  end

  defp replying_label(%Reply{status: :running} = r),
    do: r.retry || Models.get(r.model).name <> " is replying…"

  defp replying_label(_scripted), do: "Scripted reply on its way…"

  defp switch_note(false, _model, _live?), do: []

  defp switch_note(true, model, live?) do
    label =
      if live?,
        do: "Now answering with " <> model.name,
        else: model.name <> " chosen · replies stay scripted until you sign in or add a key"

    ~MOB"""
    <Box align="center" fill_width={true}>
      <Box
        background={:surface}
        border_color={:border}
        border_width={1}
        corner_radius={14}
        padding_left={12}
        padding_right={12}
        padding_top={6}
        padding_bottom={6}
        fill_width={false}
      >
        <Text text={label} font={:ui_medium} text_size={12} text_color={:muted} />
      </Box>
    </Box>
    """
  end

  defp message(%{role: :user} = m, assigns) do
    bubble = if m.text in [nil, ""], do: [], else: [UI.user_bubble(m.text)]

    ~MOB"""
    <Column gap={6} fill_width={true}>
      {bubble}
      {Images.render(m.images, assigns)}
      {MaterialsView.in_message(m.materials, assigns)}
      <Box align="top_trailing" fill_width={true}>
        {actions(m, assigns, nil)}
      </Box>
    </Column>
    """
  end

  defp message(%{role: :agent} = m, assigns) do
    blocks = Enum.map(m.blocks, &block(m, &1, assigns))

    ~MOB"""
    <Column gap={8} fill_width={true}>
      {blocks}
      {passage(m.passage)}
      {card(m.card)}
      {Images.render(m.images, assigns)}
      {MaterialsView.in_message(m.materials, assigns)}
      {image(m)}
      {Sources.render(m.id, m.citations, assigns.expanded)}
      {actions(m, assigns, Models.attribution(m.model))}
    </Column>
    """
  end

  # The reply streaming in (or failed): its blocks, card and pictures so
  # far (a drawing among them), the messages waiting to steer it, and its
  # error.
  defp live(nil, _blocks, _assigns), do: []

  defp live(r, blocks, assigns) do
    pseudo = live_message(r)
    blocks = Enum.map(blocks, &block(pseudo, &1, assigns))
    pending = Enum.map(r.pending, &queued/1)

    ~MOB"""
    <Column gap={8} fill_width={true}>
      {blocks}
      {card(r.card)}
      {Images.render(r.images, assigns)}
      {MaterialsView.in_message(r.materials, assigns)}
      {Sources.render(pseudo.id, Reply.sources(r), assigns.expanded)}
      {pending}
      {failure(r)}
    </Column>
    """
  end

  defp queued(text) do
    ~MOB"""
    <Column gap={4} fill_width={true}>
      {UI.user_bubble(text)}
      <Text
        text="Queued: the reply takes it in at its next step"
        text_size={11}
        text_color={:muted}
        text_align="right"
        fill_width={true}
      />
    </Column>
    """
  end

  defp failure(%Reply{status: :error, error: error}) do
    retry = {self(), {:study, :retry}}
    settings = {self(), {:tab, :settings}}
    button_opts = [height: 40, fill: false, text_size: 13]

    buttons =
      [UI.pill_button("Try again", retry, :outline, button_opts)] ++
        if (error || "") =~ "Settings",
          do: [UI.pill_button("Open Settings", settings, :outline, button_opts)],
          else: []

    UI.card(
      [
        UI.kicker("No reply", :error),
        ~MOB(<Text
  text={error || "The reply failed."}
  text_size={14}
  line_height={1.5}
  text_color={:on_surface}
/>),
        ~MOB(<Row gap={10} fill_width={true}>
  {buttons}
</Row>)
      ],
      padding: 16,
      gap: 10
    )
  end

  defp failure(_reply), do: []

  defp block(message, b, assigns) do
    key = Helpers.block_key(message, b)
    kind = if b["id"] == "sum", do: :summary, else: :aside
    open? = MapSet.member?(assigns.expanded, key)

    rest =
      if MapSet.member?(assigns.markdown, key),
        do: markdown(key, b["rest"], kind),
        else: b["rest"]

    UI.block(b["type"], b["first"], rest, open?, {self(), {:study, {:block, key}}}, kind)
  end

  # A block's body is Markdown (the model's, a tool's) in a native view
  # (mob_markdown), its id from the block's key: one atom per block shown.
  defp markdown(key, text, kind),
    do: MobMarkdown.view(String.to_atom("md:" <> key), text, UI.markdown_style(kind))

  # The open blocks with a body, newest first, up to the native views the
  # screen can hold: mob has 256 native component slots, and a view past
  # them renders nothing. A frame's new views take their slots before the
  # last frame's leave theirs (mob expands the tree, then reconciles), so
  # two frames' worth must fit: Expand all in a long study swaps most of
  # them at once. Older ones show their Markdown as text.
  @markdown_views 120

  @doc false
  def markdown_keys(messages, {live, live_blocks}, expanded) do
    stored = for %{role: :agent} = m <- messages, b <- m.blocks, do: {m, b}

    (stored ++ Enum.map(live_blocks, &{live, &1}))
    |> Enum.reverse()
    |> Enum.map(fn {m, b} -> {Helpers.block_key(m, b), b["rest"]} end)
    |> Enum.filter(fn {key, rest} -> rest not in [nil, ""] and MapSet.member?(expanded, key) end)
    |> Enum.take(@markdown_views)
    |> MapSet.new(&elem(&1, 0))
  end

  # The streaming reply's blocks are keyed under this stand-in message.
  defp live_message(nil), do: nil
  defp live_message(r), do: %{id: Helpers.live_id(r.conversation_id)}

  defp passage(nil), do: []

  defp passage(key) do
    p = Scripture.passage(key)

    words =
      for {token, word_key} <- Scripture.tokens(p) do
        if word_key,
          do: word_text(token, {self(), {:study, {:word, word_key}}}),
          else: plain_text(token)
      end

    passage_card(p.ref, p.version, [wrap(words)], "Tap a highlighted word for the Hebrew")
  end

  # A live reply's passage card (`Bezalel.Agent.Card`).
  defp card(nil), do: []

  defp card(c) do
    last = length(c["verses"]) - 1

    verses =
      for {v, i} <- Enum.with_index(c["verses"]) do
        ref =
          ~MOB(<Text text={v["ref"]} font={:ui_semibold} text_size={11} text_color={:muted} />)

        words = Enum.map(v["tokens"], &card_word(&1, c["words"]))
        wrap([ref | words] ++ if(i == last, do: net_link(c), else: []))
      end

    more =
      if c["more"] > 0,
        do: [
          ~MOB(<Text text={"+ #{c["more"]} more verses"} text_size={12} text_color={:muted} />)
        ],
        else: []

    hint = if c["words"] == %{}, do: nil, else: "Tap a highlighted word for the original"
    passage_card(c["title"], c["version"], verses ++ more, hint)
  end

  # The NET's terms: "(NET)" follows the quotation, linked to netbible.org.
  defp net_link(%{"version" => label, "version_url" => url}) when is_binary(url) do
    tap = {self(), {:study, {:open_url, url}}}
    text = "(" <> label <> ")"

    [
      ~MOB(<Text text={text} font={:ui_semibold} text_size={13} text_color={:secondary} on_tap={tap} />)
    ]
  end

  defp net_link(_card), do: []

  defp card_word([token, strongs], words) do
    case words[strongs] do
      nil -> plain_text(token)
      w -> word_text(token, {self(), {:study, {:lexeme, w}}})
    end
  end

  defp passage_card(ref, version, body, hint) do
    hint =
      if hint, do: [~MOB(<Text text={hint} text_size={12} text_color={:muted} />)], else: []

    UI.card(
      [
        ~MOB"""
        <Row fill_width={true}>
          {UI.kicker(ref)}
          <Spacer />
          {UI.kicker(version || "")}
        </Row>
        """
        | body ++ hint
      ],
      padding: 16,
      gap: 10
    )
  end

  defp wrap(words) do
    ~MOB"""
    <Wrap spacing={5} run_spacing={2} fill_width={true}>
      {words}
    </Wrap>
    """
  end

  defp word_text(token, tap) do
    ~MOB(<Text
  text={token}
  font={:scripture_semibold}
  text_size={19}
  text_color={:secondary}
  on_tap={tap}
/>)
  end

  defp plain_text(token),
    do: ~MOB(<Text text={token} font={:scripture} text_size={19} text_color={:on_surface} />)

  defp image(%{image: nil}), do: []

  # No model draws here yet: an image request shows its placeholder and
  # says so, whatever the chosen model.
  defp image(%{image: subject}) do
    caption = "#{subject}, Ex 37:17–24"
    mark = Icons.mark(64, :border, cutout: :surface)
    note = "Images are display-only for now: no model draws them here yet."

    ~MOB"""
    <Column gap={8} fill_width={true}>
      <Box
        background={:surface}
        border_color={:border}
        border_width={1}
        corner_radius={18}
        height={200}
        padding={12}
        align="center"
        fill_width={true}
      >
        {mark}
      </Box>
      <Text text={"image · " <> caption} font={:ui_medium} text_size={11} text_color={:muted} />
      <Text text={note} text_size={12} text_color={:muted} />
    </Column>
    """
  end

  defp actions(m, assigns, model_name) do
    more = Icons.icon(:more, 16, :muted)
    menu_tap = {self(), {:study, {:menu, m.id}}}
    open? = assigns.menu == m.id

    chips =
      if open?,
        do: [
          Helpers.action_chip("Copy", {self(), {:study, {:copy, m.id}}}, :on_surface),
          Helpers.action_chip("Delete", {self(), {:study, {:delete, m.id}}}, :error)
        ],
        else: []

    name =
      if model_name,
        do: [
          ~MOB(<Text text={model_name} font={:ui_medium} text_size={11} text_color={:muted} />)
        ],
        else: []

    tap_target =
      ~MOB(<Box width={32} height={28} align="center" fill_width={false} on_tap={menu_tap}>
  {more}
</Box>)

    items =
      if model_name,
        do: name ++ speaker(m, assigns) ++ [tap_target | chips],
        else: chips ++ [tap_target]

    ~MOB"""
    <Row gap={4} align={:center} fill_width={false}>
      {items}
    </Row>
    """
  end

  # Read aloud: a reply with a summary has a speaker beside its ⋯; while
  # it's being read, a stop.
  defp speaker(m, assigns) do
    if Enum.any?(m.blocks, &(&1["id"] == "sum")) do
      speaker_button(m, assigns)
    else
      []
    end
  end

  defp speaker_button(m, assigns) do
    speaking? = assigns.speaking == m.id
    glyph = Icons.icon(if(speaking?, do: :stop, else: :speaker), 16, :muted)
    tap = {self(), {:study, {:speak, m.id}}}

    [
      ~MOB(<Box id={"speak-" <> m.id} width={32} height={28} align="center" fill_width={false} on_tap={tap}>
  {glyph}
</Box>)
    ]
  end

  @doc "What reading `m` aloud says: its summary, made speakable (`Bezalel.Speech.speakable/1`)."
  def speakable(%{blocks: blocks}) do
    blocks
    |> Enum.filter(&(&1["id"] == "sum"))
    |> Enum.map_join("\n\n", &summary_text/1)
    |> Bezalel.Speech.speakable()
  end

  def speakable(_message), do: ""

  @doc """
  Reads `text` aloud (the platform's voice, `Bezalel.Native.speak/3`, in
  the voice chosen in Settings → Voice) as message `id`'s: what was being
  read stops first. Each utterance ends with one `{:speech, :done |
  :cancelled | :failed}` (`speech_ended/1`); `:speaking` clears when the
  last one outstanding has ended, so a stopped reading's `:cancelled`
  doesn't clear the one that replaced it.
  """
  def speak(socket, _id, ""), do: socket

  def speak(socket, id, text) do
    socket
    |> Native.stop_speaking()
    |> Native.speak(text, Settings.voice_opts())
    |> Socket.assign(speaking: id, speech_pending: socket.assigns.speech_pending + 1)
  end

  @doc "An utterance ended (`{:speech, :done | :cancelled | :failed}`)."
  def speech_ended(socket) do
    case max(socket.assigns.speech_pending - 1, 0) do
      0 -> Socket.assign(socket, speaking: nil, speech_pending: 0)
      n -> Socket.assign(socket, :speech_pending, n)
    end
  end

  # A finished live reply (found as `store/4` finds it), read aloud if the
  # user asked.
  defp read_aloud(socket, cid, %Reply{seen: [first | _]}) do
    with true <- socket.assigns.read_aloud,
         true <- cid == socket.assigns.conversation.id,
         %{} = m <- Enum.find(socket.assigns.messages, &(first in &1.entries)) do
      speak(socket, m.id, speakable(m))
    else
      _ -> socket
    end
  end

  defp read_aloud(socket, _cid, _reply), do: socket

  defp auto_speak(socket, message) do
    if socket.assigns.read_aloud, do: speak(socket, message.id, speakable(message)), else: socket
  end

  @doc "The top bar's trailing control: Expand all / Collapse all."
  def toggle_all_label(assigns) do
    keys = all_block_keys(assigns)

    if keys != [] and Enum.all?(keys, &MapSet.member?(assigns.expanded, &1)),
      do: "Collapse all",
      else: "Expand all"
  end

  defp all_block_keys(assigns) do
    stored = for m <- assigns.messages, b <- m.blocks, do: Helpers.block_key(m, b)

    case Map.get(assigns.streams, assigns.conversation.id) do
      nil ->
        stored

      r ->
        pseudo = %{id: live_id(r.conversation_id)}
        stored ++ for(b <- Reply.blocks(r), do: Helpers.block_key(pseudo, b))
    end
  end

  # Something is still being added, recorded, dictated or made ready.
  defp composer_busy?(a),
    do: a.preparing != nil or a.keeping > 0 or a.recorder != nil or a.dictation != nil

  defp still_sending(socket, what, opts \\ []),
    do: Helpers.toast(socket, "A question is still on its way. #{what} once it's gone.", opts)

  # ── Events ────────────────────────────────────────────────────────────────

  @doc """
  Handles a Study event. Sending while a live reply streams steers it;
  while a scripted reply is on its way it waits (the draft stays), so
  replies come back in the order they were asked. The question leaves the
  composer as it's sent; one with materials goes once they're ready for
  the model (`Bezalel.Views.Attach.prepare/4`, then `send_prepared/5`),
  and comes back to the composer if it can't go. Meanwhile, and while
  something is still being added, sending waits.
  """
  def handle(:send, socket) do
    text = String.trim(socket.assigns.draft)
    cid = socket.assigns.conversation.id
    a = socket.assigns

    cond do
      text == "" and a.attachments == [] ->
        {:noreply, socket}

      composer_busy?(a) ->
        {:noreply, socket}

      Reply.running?(a.streams[cid]) ->
        {:noreply, socket |> Socket.assign(draft: "", menu: nil) |> Attach.prepare(:steer, text)}

      Helpers.replying?(a) ->
        {:noreply, socket}

      true ->
        {:noreply, socket |> Socket.assign(draft: "", menu: nil) |> Attach.prepare(:ask, text)}
    end
  end

  # Read aloud (`Bezalel.Speech.speakable/1`); a second tap stops it.
  def handle({:speak, id}, %{assigns: %{speaking: id}} = socket) do
    {:noreply, socket |> Native.stop_speaking() |> Socket.assign(:speaking, nil)}
  end

  def handle({:speak, id}, socket) do
    case Enum.find(socket.assigns.messages, &(&1.id == id)) do
      nil -> {:noreply, socket}
      m -> {:noreply, speak(socket, id, speakable(m))}
    end
  end

  def handle(:stop, socket) do
    :ok = Agent.stop(socket.assigns.conversation.id)
    {:noreply, socket}
  end

  # Not while a question is being made ready: it goes first (and its
  # reply would take this one's place).
  def handle(:retry, socket) do
    cid = socket.assigns.conversation.id

    cond do
      Reply.running?(socket.assigns.streams[cid]) -> {:noreply, socket}
      socket.assigns.preparing != nil -> {:noreply, still_sending(socket, "Try again")}
      true -> {:noreply, respond(socket)}
    end
  end

  # Expand all opens every block and leaves open sources lists open;
  # Collapse all closes everything.
  def handle(:toggle_all, socket) do
    keys = all_block_keys(socket.assigns)
    expanded = socket.assigns.expanded
    all_open? = keys != [] and Enum.all?(keys, &MapSet.member?(expanded, &1))

    expanded =
      if all_open?, do: MapSet.new(), else: MapSet.union(expanded, MapSet.new(keys))

    {:noreply, Socket.assign(socket, :expanded, expanded)}
  end

  def handle({:block, key}, socket) do
    expanded = socket.assigns.expanded

    expanded =
      if MapSet.member?(expanded, key),
        do: MapSet.delete(expanded, key),
        else: MapSet.put(expanded, key)

    {:noreply, Socket.assign(socket, :expanded, expanded)}
  end

  def handle({:menu, id}, socket) do
    {:noreply, Socket.assign(socket, :menu, if(socket.assigns.menu == id, do: nil, else: id))}
  end

  def handle({:copy, id}, socket) do
    case Enum.find(socket.assigns.messages, &(&1.id == id)) do
      nil ->
        {:noreply, socket}

      m ->
        {:noreply,
         socket
         |> Mob.Clipboard.put(copy_text(m))
         |> Socket.assign(:menu, nil)
         |> Helpers.toast("Copied")}
    end
  end

  def handle({:delete, id}, socket) do
    case Enum.find(socket.assigns.messages, &(&1.id == id)) do
      # Already gone (a double tap, or an event queued across a switch).
      nil ->
        {:noreply, Socket.assign(socket, :menu, nil)}

      _m ->
        if last?(socket.assigns.messages, id),
          do: {:noreply, delete(socket, id)},
          else: {:noreply, Socket.assign(socket, sheet: {:confirm_delete, id}, menu: nil)}
    end
  end

  def handle({:confirm_delete, id}, socket),
    do: {:noreply, socket |> Socket.assign(:sheet, nil) |> delete(id)}

  # A delete still waiting for the reply in its conversation is just
  # dropped; a done one is undone now, or once that conversation's reply
  # ends.
  def handle(:undo, socket) do
    socket =
      case socket.assigns.toast do
        %{undo: {:pending, cid, id}} -> drop_edit(socket, cid, {:delete, [id]})
        %{undo: %Library.Undo{conversation_id: cid} = undo} -> edit(socket, cid, {:undo, undo})
        _ -> socket
      end

    {:noreply, socket |> Socket.assign(:toast, nil) |> Helpers.reload_messages()}
  end

  def handle(:ask_again, socket) do
    cond do
      socket.assigns.preparing != nil ->
        {:noreply, still_sending(socket, "Ask again", ask_again: true)}

      Helpers.replying?(socket.assigns) ->
        {:noreply, Socket.assign(socket, :toast, nil)}

      true ->
        {:noreply, socket |> Socket.assign(:toast, nil) |> respond()}
    end
  end

  def handle({:word, key}, socket),
    do: {:noreply, Socket.assign(socket, sheet: {:word, key}, menu: nil)}

  def handle({:ask_word, key}, socket) do
    w = Scripture.word(key)

    {:noreply,
     Socket.assign(socket, sheet: nil, tab: :study, draft: "Tell me about “#{w.translit}”")}
  end

  # A word of a live reply's card: the sheet opens on what the card holds;
  # the lexicon entry is read from the core pack beside it.
  def handle({:lexeme, w}, socket) do
    strongs = w["strongs"]

    {:noreply,
     socket
     |> Socket.assign(sheet: {:lexeme, w, nil}, menu: nil)
     |> Socket.start_async({:lexicon, strongs}, fn ->
       DB.with_pack(:core, &Lexicon.entry(&1, strongs))
     end)}
  end

  def handle({:ask_lexeme, w}, socket) do
    draft = "Tell me about #{w["word"]} (#{w["translit"]}, #{w["strongs"]})"
    {:noreply, Socket.assign(socket, sheet: nil, tab: :study, draft: draft)}
  end

  def handle(:build_from_chat, socket) do
    desc =
      "A passage outline helper for #{passage_ref(socket.assigns.messages)}: its main idea, its movements, and the key words of each."

    {:noreply, socket |> Socket.assign(desc: desc, build: nil) |> Helpers.go(:workshop)}
  end

  # A link in the chat (the NET's label on a passage card, a reply's sources).
  def handle({:open_url, url}, socket) do
    Rho.Config.open_url(url)
    {:noreply, socket}
  end

  @doc """
  The lexicon entry for the word sheet (`handle_async({:lexicon, strongs},
  ...)`), if the sheet is still on that word.
  """
  def lexicon(strongs, result, socket) do
    case socket.assigns.sheet do
      {:lexeme, %{"strongs" => ^strongs} = w, _} ->
        lex =
          case result do
            {:ok, {:ok, %{} = entry}} -> entry
            _ -> :none
          end

        Socket.assign(socket, :sheet, {:lexeme, w, lex})

      _ ->
        socket
    end
  end

  @doc """
  Sends a question whose materials are ready (`Bezalel.Views.Attach`):
  `mode` `:ask` (a new question), `:steer` (into the reply streaming) or
  `:again` (the last question asked anew, its materials sent again for the
  model chosen now). Ask or steer is decided again now: a reply may have
  started or ended while the materials were made ready. `cid` is the
  conversation it was asked in. A question asked again isn't sent if the
  user has moved on meanwhile (it keeps its Try again there), and they're
  told; a new question never gets here once they've moved on
  (`Attach.prepared/2` gives its chips back).
  """
  def send_prepared(socket, mode, text, attachments, cid \\ nil) do
    %{id: open} = conversation = socket.assigns.conversation

    cond do
      cid != nil and cid != open and mode == :again ->
        Helpers.toast(socket, "It wasn't asked again: you'd moved on. Try again from there.")

      mode == :again ->
        again(socket, attachments)

      Reply.running?(socket.assigns.streams[open]) ->
        steer(socket, open, text, attachments)

      true ->
        ask(socket, text, attachments, conversation)
    end
  end

  # Live, the loop writes the question into the session; scripted, it's
  # written here and the storyboard answers it. (The composer was cleared
  # when Send was tapped.)
  defp ask(socket, text, attachments, %{id: cid} = conversation) do
    socket = drop_stream(socket, cid)

    if Agent.live?(socket.assigns.account) do
      socket |> respond_live(text, attachments) |> Helpers.reload_messages()
    else
      socket = release(socket, cid)

      {:ok, _} =
        Library.add_message(conversation, %{role: :user, text: text, attachments: attachments})

      link(attachments, Library.get_conversation(cid))
      socket |> Helpers.reload_messages() |> respond_scripted()
    end
  end

  defp steer(socket, cid, text, attachments) do
    case Agent.steer(cid, text, attachments) do
      :ok ->
        reply = socket.assigns.streams[cid]
        link(attachments, reply.session_id)
        put_stream(socket, cid, %{reply | pending: reply.pending ++ [text]})

      # The loop is gone (released meanwhile): ask afresh.
      {:error, :idle} ->
        ask(socket, text, attachments, socket.assigns.conversation)
    end
  end

  # The materials a question went with also go with its conversation.
  defp link(attachments, %Library.Conversation{session_id: sid}), do: link(attachments, sid)

  defp link(attachments, session_id) when is_binary(session_id) do
    for %{ref: ref} <- attachments, do: MaterialStore.link(ref, session_id)
    :ok
  end

  defp link(_attachments, _none), do: :ok

  @doc """
  Asks again for the reply to the open conversation's last question (Try
  again, Ask again), bound to that conversation and the model chosen now:
  its result lands there even if the user has moved on. Live
  (`Bezalel.Agent.live?/1`), the question is taken back off the session
  and asked anew (its materials still kept made ready for the model first,
  `Bezalel.Views.Attach.prepare/4`; until they are, the failed reply and
  its Try again stay), and the reply streams as loop events
  (`agent_event/3`); without a model the storyboard's comes back through
  `handle_async({:reply, ...})` (`replied/3`). Each conversation has at
  most one reply in flight, and replies in different conversations run
  side by side.
  """
  def respond(socket) do
    cid = socket.assigns.conversation.id

    if Agent.live?(socket.assigns.account) do
      case Library.question(cid) do
        nil -> again(socket, [])
        question -> respond_again(socket, question)
      end
    else
      socket |> drop_stream(cid) |> respond_scripted()
    end
  end

  # A material deleted since goes without it; a question that was only
  # materials, all deleted, has nothing left to ask (its Try again stays).
  defp respond_again(socket, %{text: text, materials: ids}) do
    materials = for id <- ids, {:ok, m} <- [MaterialStore.fetch(id, %{})], do: m

    cond do
      materials != [] ->
        Attach.prepare(socket, :again, "", materials)

      ids != [] and String.trim(text) == "" ->
        Helpers.toast(
          socket,
          "Its materials were deleted from Materials: there's nothing to ask again."
        )

      true ->
        again(socket, [])
    end
  end

  defp again(socket, attachments) do
    cid = socket.assigns.conversation.id
    socket = socket |> release(cid) |> drop_stream(cid)

    case Library.take_question(cid) do
      {:ok, text} -> socket |> respond_live(text, attachments) |> Helpers.reload_messages()
      :none -> Helpers.reload_messages(socket)
    end
  end

  defp respond_live(socket, text, attachments) do
    %{id: cid} = socket.assigns.conversation
    model = Helpers.model(socket)

    if Models.available?(model, socket.assigns.account) do
      case Agent.ask(cid, text, model.id, self(), attachments) do
        {:ok, session_id} ->
          :ok = Library.touch(cid)
          link(attachments, session_id)

          socket
          |> Socket.assign(:sessions, Map.put(socket.assigns.sessions, session_id, cid))
          |> put_stream(cid, Reply.new(cid, model.id, session_id))

        {:error, reason} ->
          error = "The agent couldn't start: #{inspect(reason)}"

          socket
          |> keep_question(cid, text, attachments)
          |> put_stream(cid, Reply.failed(cid, model.id, error))
      end
    else
      error =
        "#{model.name} needs a #{Models.needs(model.provider)}. Add one in Settings → " <>
          "Account, or choose a model you have access to."

      socket
      |> keep_question(cid, text, attachments)
      |> put_stream(cid, Reply.failed(cid, model.id, error))
    end
  end

  # A question no loop took in stays in the conversation, for Try again.
  defp keep_question(socket, cid, text, attachments) do
    socket = release(socket, cid)

    with %Library.Conversation{} = conversation <- Library.get_conversation(cid),
         {:ok, _} <-
           Library.add_message(conversation, %{role: :user, text: text, attachments: attachments}) do
      link(attachments, Library.get_conversation(cid))
    end

    socket
  end

  defp respond_scripted(socket) do
    %{id: conversation_id} = socket.assigns.conversation
    messages = socket.assigns.messages
    model = Helpers.model(socket)
    replying = Map.update(socket.assigns.replying, conversation_id, 1, &(&1 + 1))
    # A loop left from before a sign-out would miss the scripted replies.
    socket
    |> release(conversation_id)
    |> Socket.assign(:replying, replying)
    |> Socket.start_async({:reply, conversation_id, make_ref()}, fn ->
      {model.id, Storyboard.reply(messages, model)}
    end)
  end

  @doc "Stores a scripted reply (`handle_async({:reply, conversation_id, _}, ...)`)."
  def replied(conversation_id, result, socket) do
    replying =
      Map.update(socket.assigns.replying, conversation_id, 0, &max(&1 - 1, 0))

    socket = Socket.assign(socket, :replying, replying)
    current? = socket.assigns.conversation.id == conversation_id

    with {:ok, {model_id, {:ok, reply}}} <- result,
         %Library.Conversation{} = conversation <- Library.get_conversation(conversation_id),
         {:ok, message} <-
           Library.add_message(conversation, %{
             role: :agent,
             blocks: reply.blocks,
             passage: reply.passage,
             model: reply[:by] || model_id
           }) do
      if current? do
        expanded = MapSet.union(socket.assigns.expanded, Helpers.summaries_open([message]))

        socket
        |> Socket.assign(:expanded, expanded)
        |> Helpers.reload_messages()
        |> Helpers.refresh()
        |> auto_speak(message)
      else
        Helpers.refresh(socket)
      end
    else
      # The conversation went away meanwhile: nothing to add it to.
      nil -> socket
      _failed when current? -> Helpers.toast(socket, "No reply this time.", ask_again: true)
      _failed -> socket
    end
  end

  @doc """
  A live loop's event (`{:rho, session_id, event}`), for whichever
  conversation it answers.
  """
  def agent_event(session_id, event, socket) do
    with cid when cid != nil <- socket.assigns.sessions[session_id],
         %Reply{status: :running, session_id: ^session_id} = reply <- socket.assigns.streams[cid] do
      on_event(cid, reply, event, socket)
    else
      _ -> socket
    end
  end

  defp on_event(
         cid,
         reply,
         %{type: :message_end, entry: %{"message" => %{"role" => "user"} = m}},
         socket
       ) do
    text = Session.typed(m)
    if text in reply.pending, do: steered(socket, cid, reply, text), else: socket
  end

  defp on_event(cid, reply, %{type: :agent_end} = event, socket),
    do: finish(socket, cid, Reply.apply(reply, event))

  defp on_event(cid, reply, event, socket) do
    reply = Reply.apply(reply, event)

    socket
    |> put_stream(cid, reply)
    |> Images.load(reply.images ++ Images.material_images(reply.materials))
  end

  # The loop took a steering message in: the reply so far is done (the
  # chat reads it from the session), the message follows it, and the run
  # goes on as the next reply.
  defp steered(socket, cid, reply, text),
    do: store(socket, cid, reply, Reply.continue(reply, text))

  # Messages sent as the run was ending: after a normal end the loop runs
  # them next, as a new run; at its limits (`:max_iterations`, `:cost_cap`)
  # it drops them, so they go back. A message steered in after the limit's
  # end may have started a run the screen won't follow: the loop goes too.
  # A finished reply in the open conversation is read aloud when the user
  # asked for that (Settings → Voice).
  defp finish(socket, cid, %Reply{status: :done, reason: reason} = reply)
       when reply.pending == [] or reason in [:max_iterations, :cost_cap] do
    socket = socket |> store(cid, reply, nil) |> read_aloud(cid, reply)

    socket =
      if reply.pending == [], do: release_if_unused(socket, cid), else: release(socket, cid)

    unsend(socket, cid, reply.pending)
  end

  defp finish(socket, cid, %Reply{status: :done} = reply) do
    socket
    |> store(cid, reply, %{Reply.continue(reply, "") | pending: reply.pending})
    |> read_aloud(cid, reply)
  end

  # Stopped: what streamed is kept (the loop wrote the cut-off turn). The
  # loop goes; the next question resumes the session.
  defp finish(socket, cid, %Reply{status: :stopped} = reply) do
    socket
    |> release(cid)
    |> store(cid, reply, nil)
    |> unsend(cid, reply.pending)
  end

  # Failed: the error stays in the chat, with Try again; the failed run's
  # entries leave the session's branch (the loop is idle), and Try again
  # asks the question anew.
  defp finish(socket, cid, %Reply{status: :error} = reply) do
    :ok = Library.drop_failed(cid)

    socket
    |> release(cid)
    |> drop_stream(cid)
    |> put_stream(cid, %{reply | pending: []})
    |> reload_if_open(cid)
    |> unsend(cid, reply.pending)
  end

  # Messages the loop didn't take in go back to the draft, or, for a
  # conversation that isn't open, into it as questions for the next reply.
  defp unsend(socket, _cid, []), do: socket

  defp unsend(%{assigns: %{conversation: %{id: cid}}} = socket, cid, texts) do
    draft = Enum.join(texts ++ [socket.assigns.draft], "\n\n") |> String.trim()
    Socket.assign(socket, :draft, draft)
  end

  defp unsend(socket, cid, texts) do
    case Library.get_conversation(cid) do
      nil ->
        socket

      conversation ->
        for text <- texts,
            String.trim(text) != "",
            do: {:ok, _} = Library.add_message(conversation, %{role: :user, text: text})

        Helpers.refresh(socket)
    end
  end

  # A reply (or the part of it before a steering message) is in the
  # session: the stream gives way to it (or to `next`, the run's next
  # reply), keeping which of its blocks were open.
  defp store(socket, cid, reply, next) do
    :ok = Library.touch(cid)
    prefix = live_id(cid) <> ":"
    open = for key <- socket.assigns.expanded, String.starts_with?(key, prefix), do: key

    socket = drop_stream(socket, cid)
    socket = if next, do: put_stream(socket, cid, next), else: socket
    socket = reload_if_open(socket, cid)

    stored =
      Enum.find(socket.assigns.messages, fn m ->
        cid == socket.assigns.conversation.id and reply.seen != [] and
          hd(reply.seen) in m.entries
      end)

    expanded =
      if stored,
        do:
          socket.assigns.expanded
          |> MapSet.union(MapSet.new(open, &String.replace_prefix(&1, prefix, "#{stored.id}:")))
          |> MapSet.union(Helpers.summaries_open([stored])),
        else: socket.assigns.expanded

    socket |> Socket.assign(:expanded, expanded) |> Helpers.refresh()
  end

  defp reload_if_open(%{assigns: %{conversation: %{id: cid}}} = socket, cid),
    do: Helpers.reload_messages(socket)

  defp reload_if_open(socket, _cid), do: socket

  # The loop of a conversation that's no longer open, or with edits
  # waiting for its reply, goes once its reply is done.
  defp release_if_unused(socket, cid) do
    if cid != socket.assigns.conversation.id or MapSet.member?(socket.assigns.stale, cid),
      do: release(socket, cid),
      else: socket
  end

  # A delete or an undo (`op`) rewrites the session, which a loop must not
  # be holding: with no reply streaming the loop goes and it's done now;
  # otherwise it waits for the reply to end (the chat already hides a
  # deleted message).
  defp edit(socket, cid, op) do
    socket =
      Socket.assign(socket, :edits, Map.update(socket.assigns.edits, cid, [op], &(&1 ++ [op])))

    if Reply.running?(socket.assigns.streams[cid]),
      do: Socket.assign(socket, :stale, MapSet.put(socket.assigns.stale, cid)),
      else: release(socket, cid)
  end

  defp drop_edit(socket, cid, op) do
    edits =
      case Map.get(socket.assigns.edits, cid, []) -- [op] do
        [] -> Map.delete(socket.assigns.edits, cid)
        ops -> Map.put(socket.assigns.edits, cid, ops)
      end

    Socket.assign(socket, :edits, edits)
  end

  @doc """
  Lets go of a conversation about to be deleted
  (`Bezalel.Views.Conversations`), so an Undo of the delete brings it back
  as the chat showed it: a reply streaming in it is stopped (what
  streamed is kept in the session, as Stop keeps it, and the messages
  sent meanwhile that it hadn't taken in are added as questions), its
  loop goes now, and the message deletes and undos that waited for that
  reply are made.
  """
  def let_go(socket, cid) do
    reply = socket.assigns.streams[cid]
    :ok = Agent.stop(cid)
    pending = if Reply.running?(reply), do: await_stopped(reply.session_id, reply.pending)
    socket = socket |> drop_stream(cid) |> release(cid)
    if Reply.running?(reply), do: keep_stopped(cid, pending)
    socket
  end

  # A stop answers at once while the model streams; with tools running,
  # the loop writes their results and ends once they finish. That's
  # waited for a moment, so the session holds the turn whole; past it the
  # loop is shut anyway (its next resume closes the open tool calls).
  # Returns `pending` without the messages the loop took in meanwhile
  # (events this screen hadn't handled yet): they're in the session. After
  # an end, what's already queued is read too: a run that ended on its
  # own may have been followed by one the stop ended.
  @stop_wait_ms 2_000

  defp await_stopped(session_id, pending, wait \\ @stop_wait_ms) do
    receive do
      {:rho, ^session_id, %{type: :agent_end}} ->
        await_stopped(session_id, pending, 0)

      {:rho, ^session_id, %{type: :message_end, entry: %{"message" => %{"role" => "user"} = m}}} ->
        await_stopped(session_id, List.delete(pending, Session.typed(m)), wait)
    after
      wait -> pending
    end
  end

  # What Stop does once the run ends (`finish/3`): the shelf counts the
  # cut-off turn, and the unsent messages go into the conversation.
  defp keep_stopped(cid, pending) do
    :ok = Library.touch(cid)

    with %Library.Conversation{} = conversation <- Library.get_conversation(cid) do
      for text <- pending,
          String.trim(text) != "",
          do: {:ok, _} = Library.add_message(conversation, %{role: :user, text: text})
    end

    :ok
  end

  # The conversation's loop goes, and with it its sessions and stale mark;
  # then the edits that waited for it are made.
  defp release(socket, cid) do
    :ok = Agent.release(cid)
    sessions = Map.reject(socket.assigns.sessions, fn {_, c} -> c == cid end)

    socket
    |> Socket.assign(sessions: sessions, stale: MapSet.delete(socket.assigns.stale, cid))
    |> apply_edits(cid)
  end

  defp apply_edits(socket, cid) do
    case Map.pop(socket.assigns.edits, cid) do
      {nil, _} ->
        socket

      {ops, edits} ->
        socket = Socket.assign(socket, :edits, edits)

        ops
        |> Enum.reduce(socket, &apply_edit(&2, cid, &1))
        |> reload_if_open(cid)
    end
  end

  defp apply_edit(socket, cid, {:delete, ids}) do
    case Library.delete_messages(cid, ids) do
      {:ok, undo} -> undo_ready(socket, cid, ids, undo)
      {:error, :not_found} -> socket
    end
  end

  defp apply_edit(socket, _cid, {:undo, undo}) do
    _ = Library.restore(undo)
    socket
  end

  # The toast's Undo of a delete that was waiting now undoes the done one.
  defp undo_ready(socket, cid, ids, undo) do
    case socket.assigns.toast do
      %{undo: {:pending, ^cid, id}} = toast ->
        if id in ids, do: Socket.assign(socket, :toast, %{toast | undo: undo}), else: socket

      _ ->
        socket
    end
  end

  # A reply starting (a new one, or the next after a steer) opens its
  # summary, as a stored reply's is.
  defp put_stream(socket, cid, reply) do
    expanded =
      if reply.items == [] and reply.summary == "" and reply.text == "",
        do: MapSet.put(socket.assigns.expanded, live_id(cid) <> ":sum"),
        else: socket.assigns.expanded

    Socket.assign(socket,
      streams: Map.put(socket.assigns.streams, cid, reply),
      expanded: expanded
    )
  end

  defp drop_stream(socket, cid) do
    prefix = live_id(cid) <> ":"
    expanded = MapSet.reject(socket.assigns.expanded, &String.starts_with?(&1, prefix))

    Socket.assign(socket,
      streams: Map.delete(socket.assigns.streams, cid),
      expanded: expanded
    )
  end

  defp live_id(cid), do: Helpers.live_id(cid)

  defp last?(messages, id), do: match?(%{id: ^id}, List.last(messages))

  # The toast's Undo starts as the waiting delete; made now (no reply
  # streaming), it becomes the done one's.
  defp delete(socket, id) do
    cid = socket.assigns.conversation.id
    messages = socket.assigns.messages

    case Enum.find(messages, &(&1.id == id)) do
      nil ->
        Helpers.reload_messages(socket)

      m ->
        text =
          if m.role == :agent,
            do: "Reply deleted. The agent won’t see it.",
            else: "Message deleted. The agent won’t see it."

        socket
        |> Socket.assign(:menu, nil)
        |> Helpers.toast(text,
          undo: {:pending, cid, id},
          ask_again: m.role == :agent and last?(messages, id)
        )
        |> edit(cid, {:delete, [id]})
        |> Helpers.reload_messages()
    end
  end

  @doc false
  def copy_text(%{role: :user, text: text}), do: text

  def copy_text(%{blocks: blocks, passage: passage, card: card, image: image}) do
    summary = for b <- blocks, b["id"] == "sum", do: summary_text(b)

    cited =
      cond do
        p = Scripture.passage(passage) -> ["#{p.text} (#{p.ref}, #{p.version})"]
        card -> [Card.text(card)]
        true -> []
      end

    drawing = if image, do: ["Image request: #{image}, Ex 37:17–24"], else: []
    Enum.join(summary ++ cited ++ drawing, "\n\n")
  end

  # The model's Markdown as it wrote it; a scripted reply's header and
  # rest (a cut header repeats the whole text under it).
  defp summary_text(%{"text" => text}), do: text
  defp summary_text(%{"cut" => true, "rest" => rest}), do: rest
  defp summary_text(%{"first" => first, "rest" => rest}), do: String.trim(first <> " " <> rest)

  defp passage_ref(messages) do
    Enum.find_value(messages, "this passage", fn m ->
      cond do
        p = Scripture.passage(m.passage) -> p.ref
        m.card -> m.card["title"]
        true -> nil
      end
    end)
  end
end
