defmodule Bezalel.WorkshopDynTest do
  # The Workshop on rho's Dyn layer: a scripted model (Bezalel.Test.FakeLLM)
  # writes a tool and its screen, the user approves it, the study agent
  # calls it, its panel draws its screen; crashes on probation revert it;
  # the check refuses what a tool may not call; a restart keeps it. The
  # Keeper is the app's, moved to this test's own directory
  # (Bezalel.Test.Dyn), and the screen runs in the test process, so the
  # loops', the host's and the Keeper's messages arrive here.
  use Mob.ScreenCase
  @moduletag :screen
  @moduletag :tmp_dir

  alias Bezalel.Agent.Live
  alias Bezalel.{AppScreen, Library, Repo, Workshop}
  alias Bezalel.Library.{Conversation, Tool}
  alias Bezalel.Test.{Dyn, FakeLLM, MemoryStore}
  alias Bezalel.Workshop.{Builder, Host, Prompt}
  alias Rho.Dyn.Approval.Biometric
  alias Rho.Dyn.Compiler

  setup %{tmp_dir: dir} do
    for schema <- [Tool, Conversation], do: Repo.delete_all(schema)

    for key <- [:bezalel_conversation, :bezalel_mode, :bezalel_model, :bezalel_study_preferences],
        do: Mob.State.delete(key)

    MemoryStore.clear()
    :ok = Rho.Auth.put_api_key(:anthropic, "sk-ant-api03-test-key-0123456789")
    :ok = Dyn.fresh(Path.join(dir, "dyn"))

    on_exit(fn ->
      Application.delete_env(:bezalel, Live)
      Application.delete_env(:bezalel, Builder)
      Bezalel.Agent.release_all()
    end)

    :ok
  end

  # A word-frequency card: the tool and its screen. `crash` makes the tool
  # raise for a reference ("boom") and the screen on the :boom tap.
  defp word_frequency(opts \\ []) do
    crash? = Keyword.get(opts, :crash, false)
    heading = Keyword.get(opts, :heading, "Most frequent words")

    """
    defmodule Bezalel.Dyn.WordFrequency do
      @behaviour Rho.Tool
      alias Bezalel.Workshop.Study

      @split [" ", ",", ".", ";", ":", "!", "?", "“", "”", "‘", "’", "(", ")"]

      def name, do: "word_frequency"
      def description, do: "The most frequent English (BSB) words of a passage, with counts."

      def parameter_schema,
        do: %{
          "type" => "object",
          "properties" => %{"reference" => %{"type" => "string"}},
          "required" => ["reference"]
        }

      #{if crash?, do: ~s|def run(%{"reference" => "boom"}, _ctx), do: raise("boom")|}

      def run(%{"reference" => ref}, _ctx) do
        with {:ok, p} <- Study.passage(ref), do: {:ok, format(counts(p))}
      end

      def counts(p) do
        p.verses
        |> Enum.flat_map(&String.split(String.downcase(&1.english), @split, trim: true))
        |> Enum.frequencies()
        |> Enum.sort_by(fn {w, n} -> {-n, w} end)
        |> Enum.take(5)
      end

      def format(counts), do: Enum.map_join(counts, ", ", fn {w, n} -> "\#{w} \#{n}" end)

      def selftest do
        p = %{verses: [%{english: "The Lord, the God."}]}
        if counts(p) == [{"the", 2}, {"god", 1}, {"lord", 1}], do: :ok, else: :error
      end
    end

    defmodule Bezalel.Dyn.WordFrequency.Screen do
      use Mob.Screen
      alias Bezalel.Dyn.WordFrequency
      alias Bezalel.Workshop.Study
      alias MobBezalel.UI

      def mount(_params, _session, socket),
        do: {:ok, Mob.Socket.assign(socket, ref: "Exodus 31:1-3", result: "")}

      def handle_info({:change, :ref, value}, socket),
        do: {:noreply, Mob.Socket.assign(socket, :ref, value)}

      #{if crash?, do: ~s|def handle_info({:tap, :boom}, _socket), do: raise("screen boom")|}

      def handle_info({:tap, :count}, socket) do
        result =
          case Study.passage(socket.assigns.ref) do
            {:ok, p} -> WordFrequency.format(WordFrequency.counts(p))
            {:error, message} -> message
          end

        {:noreply, Mob.Socket.assign(socket, :result, result)}
      end

      def handle_info(_message, socket), do: {:noreply, socket}

      def render(assigns) do
        ~MOB\"\"\"
        <Column gap={12} fill_width={true}>
          {UI.kicker(#{inspect(heading)})}
          <TextField value={@ref} on_change={{self(), :ref}} placeholder="A passage" />
          {UI.pill_button("Count", {self(), :count}, :primary)}
          <Text text={@result} font={:scripture} text_color={:on_surface} />
        </Column>
        \"\"\"
      end
    end
    """
  end

  defp script(key, replies) do
    {:ok, llm} = FakeLLM.start(replies)
    Application.put_env(:bezalel, key, llm: {FakeLLM, llm}, retry_base_ms: 1)
  end

  # The model writes `source` to word_frequency.ex, proposes it, then says `closing`.
  defp builds(source, closing \\ "It counts a passage's words.") do
    script(Builder, [
      [
        {:tool_call, "w1", "dyn_write", %{"path" => "word_frequency.ex", "content" => source}}
      ],
      [{:tool_call, "p1", "dyn_propose", %{"rationale" => "Adds a word-frequency card"}}],
      [{:text, closing}]
    ])
  end

  defp build(view, desc) do
    view
    |> render_info({:tap, {:tab, :workshop}})
    |> render_info({:change, :desc, desc})
    |> render_info({:tap, {:workshop, :build}})
    |> render_async(60_000)
  end

  defp approve(view) do
    view
    |> render_info({:tap, {:workshop, :review_approve}})
    |> render_info({:tap, {:workshop, :approve}})
  end

  # Approves generation `n` as the Workshop does after its sheet.
  defp approve!(n) do
    {:ok, {:review, review}} = Workshop.review(n, %{description: "A word-frequency card"})
    assert {:ok, tools} = Workshop.approve(review)
    tools
  end

  # The open panel's host painted.
  defp painted(view) do
    receive do
      {Host, _pid, {:view, _tree}} = message -> render_info(view, message)
    after
      5_000 -> flunk("the tool's screen didn't paint")
    end
  end

  defp host(view), do: assigns(view).tool_host.pid

  # Feeds the study loop's events to the screen until its run ends.
  defp until_done(view) do
    receive do
      {:rho, _session, event} = message ->
        view = render_info(view, message)
        if match?(%{type: :agent_end}, event), do: view, else: until_done(view)
    after
      5_000 -> flunk("the loop went quiet")
    end
  end

  defp ask(view, text) do
    view
    |> render_info({:tap, {:tab, :study}})
    |> render_info({:change, :draft, text})
    |> render_info({:tap, {:study, :send}})
    |> until_done()
  end

  defp offered(request), do: Enum.map(request.tools, & &1.name)

  # Drops the model calls made so far (a build's).
  defp flush_requests do
    receive do
      {:llm_request, _} -> flush_requests()
    after
      0 -> :ok
    end
  end

  # A tool, Probe, whose screen tries what a panel must not let through:
  # web content and remote images, a struct of its own in the view, an
  # exception (and an exit through a link) whose message/1 and Inspect
  # implementation report the process they run in, a view Mob can't draw,
  # and trapping exits while busy.
  defp probe do
    """
    defmodule Bezalel.Dyn.Probe do
      @behaviour Rho.Tool
      def name, do: "probe"
      def description, do: "A probe."
      def parameter_schema, do: %{"type" => "object", "properties" => %{}}
      def run(_args, _ctx), do: {:ok, "probe"}
      def selftest, do: :ok
    end

    defmodule Bezalel.Dyn.Probe.Hostile do
      defexception message: "hostile", loop: false

      def message(%{loop: true} = e), do: message(e)

      def message(_e) do
        send(self(), {:hostile, :message})
        "hostile message"
      end

      defimpl Inspect do
        def inspect(_e, _opts) do
          send(self(), {:hostile, :inspect})
          "#Hostile<>"
        end
      end
    end

    defmodule Bezalel.Dyn.Probe.Block do
      defstruct [:src]
    end

    defmodule Bezalel.Dyn.Probe.Screen do
      use Mob.Screen
      alias Bezalel.Dyn.Probe.{Block, Hostile}

      # A list renderer that returns a list: left unexpanded, never drawn.
      def mount(_params, _session, socket) do
        socket =
          socket
          |> Mob.Socket.assign(lines: nil, taps: 0)
          |> Mob.List.put_renderer(:outer, fn _item ->
            %{type: :list, props: %{id: :inner, items: [%{label: %{a: 1}}]}, children: []}
          end)

        {:ok, socket}
      end

      def handle_info({:tap, :raise}, _socket), do: raise(Hostile)
      def handle_info({:tap, :raise_loop}, _socket), do: raise(Hostile, loop: true)

      def handle_info({:tap, :forged_crash}, socket) do
        Process.exit(self(), {:rho_crash, <<255, 104>> <> String.duplicate("x", 100_000)})
        {:noreply, socket}
      end

      def handle_info({:tap, :improper}, socket) do
        spawn_link(fn -> exit({%Hostile{}, [:a | :b]}) end)
        Process.sleep(5_000)
        {:noreply, socket}
      end

      def handle_info({:tap, :link}, socket) do
        spawn_link(fn -> exit({%Hostile{}, [{__MODULE__, :link, 0, []}]}) end)
        Process.sleep(5_000)
        {:noreply, socket}
      end

      def handle_info({:tap, :bad_view}, socket),
        do: {:noreply, Mob.Socket.assign(socket, :lines, 0)}

      def handle_info({:tap, :many_taps}, socket),
        do: {:noreply, Mob.Socket.assign(socket, :taps, 2_100)}

      def handle_info({:tap, :spin}, _socket) do
        Process.flag(:trap_exit, true)
        spin()
      end

      def handle_info(_message, socket), do: {:noreply, socket}

      defp spin, do: spin()

      def render(assigns) do
        ~MOB\"\"\"
        <Column>
          <Text text="probe" max_lines={@lines} tag={%Hostile{}} />
          <WebView url="https://example.com/web" />
          <Video src="https://example.com/v.mp4" />
          <Image src="https://example.com/i.png?q=secret" />
          <Image src="HTTP://example.com/caps.png" />
          <Image src="ftp://example.com/f.png" />
          <Image src="data:image/png;base64,AAAA" />
          <Image src="/data/local/a.png" />
          <Image src="/data/local/b.png" ios={%{src: "https://example.com/ios.png"}} />
          {%{type: :image, props: %{style: %Mob.Style{props: %{src: "https://example.com/s.png"}}}, children: []}}
          {%{type: :image, props: %{"src" => "https://example.com/str.png"}, children: []}}
          <Image src="/data/local/c.png" android={%Block{src: "https://example.com/and.png"}} />
          {%{type: :image, props: %{style: %Mob.Style{props: %{ios: %Block{src: "https://example.com/sb.png"}}}}, children: []}}
          <Image src={:"https://example.com/atom.png"} />
          {%{type: :list, props: %{id: :outer, items: [1]}, children: []}}
          {for _ <- 1..@taps//1, do: %{type: :button, props: %{text: "b", on_tap: {self(), :b}}, children: []}}
        </Column>
        \"\"\"
      end
    end
    """
  end

  # Approves the probe (generation 1) and opens its panel.
  defp open_probe do
    [tool] = %{"probe.ex" => probe()} |> Dyn.propose!() |> approve!()

    AppScreen
    |> mount_screen()
    |> render_info({:tap, {:workshop, {:open_tool, tool.id}}})
    |> painted()
  end

  # Sends the panel's host `tap` and hands the screen the host's exit.
  defp host_exits(view, tap) do
    %{pid: pid, ref: ref} = assigns(view).tool_host
    send(pid, {:tap, tap})
    assert_receive {:DOWN, ^ref, :process, ^pid, reason}, 5_000
    {render_info(view, {:DOWN, ref, :process, pid, reason}), reason}
  end

  defp nodes(%{type: _, props: _, children: kids} = node),
    do: [node | Enum.flat_map(kids, &nodes/1)]

  defp structs(%Mob.Style{props: props}), do: structs(props)
  defp structs(%_{} = struct), do: [struct]
  defp structs(%{} = map), do: Enum.flat_map(map, fn {k, v} -> structs(k) ++ structs(v) end)
  defp structs(list) when is_list(list), do: Enum.flat_map(list, &structs/1)
  defp structs(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> structs()
  defp structs(_term), do: []

  test "a live build writes a tool and its screen; nothing runs until approved; then the panel draws it and the study agent calls it" do
    builds(word_frequency())
    view = AppScreen |> mount_screen() |> render_info({:tap, {:tab, :workshop}})
    assert Workshop.mode(assigns(view).account) == :live
    assert text(view) =~ "Build with"

    view = build(view, "A word-frequency card for a passage")

    # The model was asked to build what was described, with the Dyn rules.
    assert_received {:llm_request, first}
    assert hd(first.messages).content |> hd() |> Map.get(:text) =~ "word-frequency card"
    assert first.system_prompt =~ "Bezalel.Workshop.Study"
    assert "dyn_propose" in offered(first)

    # What it will add, before anything runs.
    assert {:review, review} = assigns(view).build

    assert [%{title: "Word Frequency", tool: "word_frequency", screen: "WordFrequency.Screen"}] =
             review.changes

    assert Enum.all?(review.selftests, & &1.ok)
    assert text(view) =~ "READY FOR YOUR APPROVAL"
    assert text(view) =~ "New tool · word_frequency · with a screen"
    assert text(view) =~ "It counts a passage's words."
    assert Rho.Dyn.tools() == []
    assert Library.list_tools() == []

    view = render_info(view, {:tap, {:workshop, :review_approve}})
    assert text(view) =~ "Add Word Frequency to Bezalel?"
    view = render_info(view, {:tap, {:workshop, :approve}})

    # Approved: on probation, on the shelf, its panel open on its screen.
    assert %{status: :probation} = Rho.Dyn.status()
    assert [{"word_frequency", _}] = Rho.Dyn.tools()
    assert [%Tool{kind: "dyn", name: "Word Frequency"} = tool] = Library.list_tools()
    assert %{"tool" => "word_frequency", "screen" => "WordFrequency.Screen"} = tool.data
    assert assigns(view).tab == :tool
    assert Workshop.status(tool) == :probation

    view = painted(view)
    assert text(view) =~ "MOST FREQUENT WORDS"
    assert text(view) =~ "BUILT BY YOU · ON PROBATION"
    send(host(view), {:change, :ref, "Exodus 31:2-3"})
    send(host(view), {:tap, :count})
    view = view |> painted() |> painted()
    assert text(view) =~ "the 3"
    assert_renderable(view)

    # The study agent offers it from its next model call, and runs it.
    flush_requests()

    script(Live, [
      [{:tool_call, "c1", "word_frequency", %{"reference" => "Exodus 31:2-3"}}],
      [{:text, "Counted."}]
    ])

    _view = ask(view, "Which words recur in Exodus 31:2-3?")
    assert_received {:llm_request, study}
    assert "word_frequency" in offered(study)
    refute "dyn_write" in offered(study)
    assert_received {:llm_request, after_tool}
    result = List.last(after_tool.messages)
    assert result.role == :tool
    assert hd(result.content).text =~ "the 3"
  end

  test "the check refuses a call a tool may not make: no proposal, and the Workshop says why" do
    forbidden = """
    defmodule Bezalel.Dyn.Notes do
      @behaviour Rho.Tool
      def name, do: "notes"
      def description, do: "Keeps notes."
      def parameter_schema, do: %{"type" => "object", "properties" => %{}}
      def run(_args, _ctx), do: {:ok, File.write!("notes.txt", "x")}
      def selftest, do: :ok
    end
    """

    script(Builder, [
      [{:tool_call, "w1", "dyn_write", %{"path" => "notes.ex", "content" => forbidden}}],
      [{:tool_call, "p1", "dyn_propose", %{"rationale" => "Adds notes"}}],
      [{:text, "The check refused File, so I couldn't build it."}]
    ])

    view = AppScreen |> mount_screen() |> build("A notes tool")
    assert {:failed, why} = assigns(view).build
    assert why =~ "No tool was proposed. The model said: The check refused File"
    assert Rho.Dyn.status().pending == nil

    # What the model was told, and what else Bezalel's config keeps out.
    for {call, refused} <- [
          {~s|File.write!("x", "y")|, "File"},
          {"Bezalel.Library.list_tools()", "Bezalel.Library"},
          {~s|Req.get!("https://example.com")|, "Req"},
          {~s|Exqlite.Sqlite3.open("x")|, "Exqlite"},
          {"Mob.State.put(:bezalel_model, 1)", "Mob.State"},
          {~s|:mob_nif.open_url("https://example.com")|, "mob_nif"},
          {~s|Mob.UI.webview(url: "https://example.com")|, "Mob.UI"}
        ] do
      :ok = Rho.Dyn.stage_reset()

      :ok =
        Rho.Dyn.stage_put("x.ex", """
        defmodule Bezalel.Dyn.X do
          def go, do: #{call}
        end
        """)

      assert {:error, %{stage: :check, reason: reason}} = Rho.Dyn.propose("x")
      assert reason =~ refused
    end
  end

  test "Change the tool builds on its generation; a change that crashes on probation is reverted to the version before, and the Workshop says so" do
    [tool] = word_frequency() |> then(&Dyn.propose!(%{"word_frequency.ex" => &1})) |> approve!()
    :ok = Rho.Dyn.subscribe()

    view =
      AppScreen
      |> mount_screen()
      |> render_info({:tap, {:workshop, {:open_tool, tool.id}}})
      |> painted()
      |> render_info({:tap, {:tool, :change}})

    assert assigns(view).tab == :workshop
    assert text(view) =~ "Changing Word Frequency"

    builds(word_frequency(crash: true, heading: "Word counts"), "Changed the heading.")
    view = build(view, "Call the heading Word counts")

    # The model was asked to change this tool, by module and file.
    assert_received {:llm_request, first}
    request = hd(first.messages).content |> hd() |> Map.get(:text)
    assert request =~ "Change the tool Bezalel.Dyn.WordFrequency"
    assert request =~ "word_frequency.ex"
    assert {:review, %{changes: [%{change: :changed}]}} = assigns(view).build
    assert text(view) =~ "Changed · word_frequency · with a screen"

    view = approve(view)
    assert %{generation: 2, parent: 1, status: :probation} = Rho.Dyn.status()
    assert [%Tool{id: id, data: %{"generation" => 2}}] = Library.list_tools()
    assert id == tool.id
    view = painted(view)
    assert text(view) =~ "WORD COUNTS"

    # The study agent calls the changed tool three times; it crashes each time.
    boom = %{"reference" => "boom"}

    script(Live, [
      [
        {:tool_call, "c1", "word_frequency", boom},
        {:tool_call, "c2", "word_frequency", boom},
        {:tool_call, "c3", "word_frequency", boom}
      ],
      [{:text, "It crashed."}]
    ])

    view = ask(view, "Count boom")
    reverted = Dyn.await(:reverted)
    assert %{from: 2, to: 1} = reverted
    view = render_info(view, {:rho_dyn, reverted})

    assert assigns(view).toast.text =~
             "Word Frequency crashed (3 crashes within 60 s on probation)"

    # The version before runs again, the shelf shows it (the request it was
    # built from, its generation), and the panel says what happened.
    assert %{generation: 1} = Rho.Dyn.status()
    shelved = Library.get_tool(tool.id)
    assert {:change_reverted, _why} = Workshop.status(shelved)
    assert %{description: "A word-frequency card", data: %{"generation" => 1}} = shelved
    view = render_info(view, {:tap, {:workshop, {:open_tool, tool.id}}}) |> painted()
    assert text(view) =~ "Your last change to this tool crashed while it was on probation"
    assert text(view) =~ "MOST FREQUENT WORDS"
    assert text(view) =~ "A word-frequency card"
    refute text(view) =~ "Call the heading Word counts"
  end

  test "a screen that crashes in the panel says so, and the crash counts against its generation" do
    [tool] =
      word_frequency(crash: true)
      |> then(&Dyn.propose!(%{"word_frequency.ex" => &1}))
      |> approve!()

    view = AppScreen |> mount_screen() |> render_info({:tap, {:workshop, {:open_tool, tool.id}}})
    view = painted(view)
    %{pid: pid, ref: ref} = assigns(view).tool_host
    send(pid, {:tap, :boom})
    assert_receive {:DOWN, ^ref, :process, ^pid, reason}, 5_000
    view = render_info(view, {:DOWN, ref, :process, pid, reason})

    assert {:crashed, why} = assigns(view).tool_view
    assert why =~ "screen boom"
    assert text(view) =~ "IT STOPPED WITH AN ERROR"
    assert %{type: :crash, gen: 1} = Dyn.await(:crash)

    view = view |> render_info({:tap, {:tool, :reopen}}) |> painted()
    assert text(view) =~ "MOST FREQUENT WORDS"
    # Leaving the panel stops its host, as an orderly exit.
    host = host(view)
    ref = Process.monitor(host)
    _view = render_info(view, {:tap, {:tab, :study}})
    assert_receive {:DOWN, ^ref, :process, ^host, :normal}, 5_000
  end

  test "a panel doesn't reach the network: web views, videos and remote images aren't drawn; on-phone images are" do
    view = open_probe()
    {:view, tree} = assigns(view).tool_view
    nodes = nodes(tree)

    refute Enum.any?(nodes, &(&1.type in [:web_view, :video]))
    refute inspect(tree) =~ "example.com"

    # Two notes (web view, video), and one for the list a list renderer
    # returned: left unexpanded, it isn't drawn, so the app's screen never
    # expands (and runs) it.
    assert [_, _, _] =
             for(
               %{type: :text, props: %{text: text}} <- nodes,
               text =~ "can't be drawn",
               do: text
             )

    refute Enum.any?(nodes, &(&1.type == :list))
    assert Mob.List.expand(tree, %{}, self()) == tree

    # Remote (any scheme) srcs are dropped, also from platform blocks (maps
    # or structs), styles (also their platform blocks) and string keys, and
    # atoms (they reach native as their names); on-phone paths stay.
    assert for(%{type: :image, props: props} <- nodes, do: props) == [
             %{},
             %{},
             %{},
             %{},
             %{src: "/data/local/a.png"},
             %{src: "/data/local/b.png", ios: %{}},
             %{style: %Mob.Style{props: %{}}},
             %{},
             %{src: "/data/local/c.png", android: %{}},
             %{style: %Mob.Style{props: %{ios: %{}}}},
             %{}
           ]

    # The view the app draws holds no struct of the screen's.
    assert structs(tree) == []
  end

  test "a panel with more controls than its share of the frame's tap handles crashes its host" do
    {view, _reason} = open_probe() |> host_exits(:many_taps)
    assert {:crashed, why} = assigns(view).tool_view
    assert why =~ "a tool's panel holds at most 2048"
  end

  test "a screen's exception is described in its own process: the app's screen never runs its message/1 or Inspect" do
    view = open_probe()

    # An exit that reaches the host through a link, which it can't describe:
    # inspected here without protocols. (The screen's message/1 and Inspect
    # send to self(): nothing of them may arrive here.)
    {view, reason} = host_exits(view, :link)
    refute_received {:hostile, _}
    assert {%{__exception__: true}, [_]} = reason
    assert {:crashed, "It exited: " <> raw} = assigns(view).tool_view
    assert raw =~ "Probe.Hostile"
    assert %{type: :crash, gen: 1} = Dyn.await(:crash)

    # A raise: the host describes it (message/1 runs in its helper) and
    # exits with the text, which the Keeper reports as it is.
    view = view |> render_info({:tap, {:tool, :reopen}}) |> painted()
    {view, reason} = host_exits(view, :raise)
    refute_received {:hostile, _}
    assert {:rho_crash, text} = reason
    assert {:crashed, ^text} = assigns(view).tool_view
    assert text =~ "hostile message"
    assert %{type: :crash, gen: 1, reason: ^text} = Dyn.await(:crash)

    # A message/1 that never returns: the host still exits, in about a
    # second, with the exception described.
    view = view |> render_info({:tap, {:tool, :reopen}}) |> painted()
    {view, {:rho_crash, text}} = host_exits(view, :raise_loop)
    assert text =~ ~r/^\*\* \(Bezalel\.Dyn\.G1\.Probe\.Hostile\) hostile/
    assert {:crashed, ^text} = assigns(view).tool_view
    refute_received {:hostile, _}
  end

  test "a host that exits with an improper stack through a link is a crash; the Keeper and the app's screen stay up" do
    keeper = Process.whereis(Rho.Dyn.Keeper)
    {view, {%{__exception__: true}, [:a | :b]}} = open_probe() |> host_exits(:improper)

    assert {:crashed, "It exited: ** (Bezalel.Dyn.G1.Probe.Hostile) hostile" <> _} =
             assigns(view).tool_view

    assert %{type: :crash, gen: 1, reason: "** (Bezalel.Dyn.G1.Probe.Hostile) hostile" <> _} =
             Dyn.await(:crash)

    assert Process.whereis(Rho.Dyn.Keeper) == keeper
    refute_received {:hostile, _}
  end

  test "crash text a screen forges itself reaches the panel capped and valid" do
    {view, {:rho_crash, _}} = open_probe() |> host_exits(:forged_crash)
    assert {:crashed, text} = assigns(view).tool_view
    assert String.valid?(text) and byte_size(text) <= 600
  end

  test "the helper describing a crash dies with the host" do
    view = open_probe()
    %{pid: host} = assigns(view).tool_host
    send(host, {:tap, :raise_loop})
    helper = await_helper(host)
    ref = Process.monitor(helper)
    Process.exit(host, :kill)
    assert_receive {:DOWN, ^ref, :process, ^helper, :killed}, 1_000
  end

  # The process the host monitors besides its owner (this test): its
  # describing helper.
  defp await_helper(host, tries \\ 100) do
    {:monitors, monitors} = Process.info(host, :monitors)

    case for({:process, pid} <- monitors, pid != self(), do: pid) do
      [helper] -> helper
      _ when tries > 0 -> Process.sleep(10) && await_helper(host, tries - 1)
      _ -> flunk("the host never started a helper")
    end
  end

  test "after a revert, an open panel running the reverted generation's code reopens on the version that runs" do
    [tool] = word_frequency() |> then(&Dyn.propose!(%{"word_frequency.ex" => &1})) |> approve!()
    :ok = Rho.Dyn.subscribe()

    # Generation 2 adds another tool; this one's version (its row's) stays 1.
    [_probe] =
      %{"word_frequency.ex" => word_frequency(), "probe.ex" => probe()}
      |> Dyn.propose!()
      |> approve!()

    view =
      AppScreen
      |> mount_screen()
      |> render_info({:tap, {:workshop, {:open_tool, tool.id}}})
      |> painted()

    pid = host(view)
    {1, module} = assigns(view).tool_screen
    assert Compiler.generation_of(module) == 2

    :ok = Biometric.confirm({:revert_to, 1})
    {:ok, token} = Rho.Dyn.request_approval({:revert_to, 1})
    assert {:ok, _} = Rho.Dyn.revert_to(1, token)
    assert %{from: 2, to: 1} = reverted = Dyn.await(:reverted)
    view = view |> render_info({:rho_dyn, reverted}) |> painted()

    refute host(view) == pid
    {1, module} = assigns(view).tool_screen
    assert Compiler.generation_of(module) == 1
    assert text(view) =~ "MOST FREQUENT WORDS"
  end

  test "a view Mob can't draw crashes the panel's host, not the app's frame" do
    {view, _reason} = open_probe() |> host_exits(:bad_view)
    assert {:crashed, why} = assigns(view).tool_view
    assert why =~ "max_lines must be an integer"
    assert text(view) =~ "IT STOPPED WITH AN ERROR"
  end

  test "a host whose owner exits is killed even while it traps exits in a busy callback, and that's no crash" do
    [_tool] = %{"probe.ex" => probe()} |> Dyn.propose!() |> approve!()
    {:ok, module} = Rho.Dyn.lookup({:screen, "Probe.Screen"})
    :ok = Rho.Dyn.subscribe()
    owner = spawn(fn -> receive do: (:stop -> :ok) end)
    {host, ref} = Host.start(owner, module, :android, %{})
    send(host, {:tap, :spin})
    await_trapping(host)

    send(owner, :stop)
    assert_receive {:DOWN, ^ref, :process, ^host, :killed}, 2_000
    refute_receive {:rho_dyn, %{type: :crash}}, 300
  end

  defp await_trapping(pid, tries \\ 100) do
    cond do
      Process.info(pid, :trap_exit) == {:trap_exit, true} -> :ok
      tries == 0 -> flunk("the screen never trapped exits")
      true -> Process.sleep(10) && await_trapping(pid, tries - 1)
    end
  end

  test "the open panel restarts only when its tool's version changes, not for another tool's activation" do
    [tool] = word_frequency() |> then(&Dyn.propose!(%{"word_frequency.ex" => &1})) |> approve!()
    :ok = Rho.Dyn.subscribe()

    view =
      AppScreen
      |> mount_screen()
      |> render_info({:tap, {:workshop, {:open_tool, tool.id}}})
      |> painted()

    pid = host(view)

    # Another tool is added (generation 2) and proven: the panel keeps running.
    [_probe] =
      %{"word_frequency.ex" => word_frequency(), "probe.ex" => probe()}
      |> Dyn.propose!()
      |> approve!()

    view = render_info(view, {:rho_dyn, Dyn.await(:activated)})
    view = render_info(view, {:rho_dyn, %{type: :proven, gen: 2}})
    assert host(view) == pid
    assert Process.alive?(pid)

    # This tool changes (generation 3): the panel runs the new version.
    n =
      Dyn.propose!(%{
        "word_frequency.ex" => word_frequency(heading: "Word counts"),
        "probe.ex" => probe()
      })

    {:ok, {:review, review}} = Workshop.review(n, %{description: "Word counts"})
    assert {:ok, _} = Workshop.approve(review)
    view = view |> render_info({:rho_dyn, Dyn.await(:activated)}) |> painted()
    refute host(view) == pid
    assert text(view) =~ "WORD COUNTS"
  end

  test "an approved tool is still there after the app restarts" do
    [tool] = word_frequency() |> then(&Dyn.propose!(%{"word_frequency.ex" => &1})) |> approve!()
    assert %{generation: 1, mode: :normal, reverted: nil} = Dyn.relaunch()

    assert [{"word_frequency", _}] = Rho.Dyn.tools()
    assert Workshop.status(tool) in [:probation, :running]

    view = AppScreen |> mount_screen() |> render_info({:tap, {:workshop, {:open_tool, tool.id}}})
    assert text(painted(view)) =~ "MOST FREQUENT WORDS"
  end

  test "Remove proposes a generation without the tool; approved, it and its shelf entry are gone" do
    [tool] = word_frequency() |> then(&Dyn.propose!(%{"word_frequency.ex" => &1})) |> approve!()

    view =
      AppScreen
      |> mount_screen()
      |> render_info({:tap, {:workshop, {:open_tool, tool.id}}})
      |> render_info({:tap, {:tool, :remove}})

    assert assigns(view).tab == :workshop

    assert {:review, %{changes: [%{change: :removed, title: "Word Frequency"}]}} =
             assigns(view).build

    # Still there until approved.
    assert [{"word_frequency", _}] = Rho.Dyn.tools()

    view = render_info(view, {:tap, {:workshop, :review_approve}})
    assert text(view) =~ "Remove Word Frequency?"
    view = render_info(view, {:tap, {:workshop, :approve}})

    assert Rho.Dyn.tools() == []
    assert Library.list_tools() == []
    assert assigns(view).toast.text =~ "Removes Word Frequency"
  end

  # Approves a Remove of `tool` from its panel; it leaves the shelf.
  defp remove!(tool) do
    AppScreen
    |> mount_screen()
    |> render_info({:tap, {:workshop, {:open_tool, tool.id}}})
    |> painted()
    |> render_info({:tap, {:tool, :remove}})
    |> approve()

    assert :error = Rho.Dyn.lookup({:tool, tool.data["tool"]})
    refute Enum.any?(Library.list_tools(), &(&1.id == tool.id))
  end

  test "a Remove reverted at the next boot (its launch died) puts the tool back on the shelf" do
    [tool] = word_frequency() |> then(&Dyn.propose!(%{"word_frequency.ex" => &1})) |> approve!()
    remove!(tool)

    assert %{reverted: %{from: 2, to: 1}} = Dyn.relaunch_after_crash()
    assert [{"word_frequency", _}] = Rho.Dyn.tools()
    assert Library.list_tools() == []

    # The app's screen mounting at start puts the shelf in line.
    view = mount_screen(AppScreen)

    assert [%Tool{id: id, description: "A word-frequency card"} = back] = Library.list_tools()
    assert id == tool.id
    assert %{"generation" => 1, "removed" => false, "tool" => "word_frequency"} = back.data
    assert {:removal_reverted, why} = Workshop.status(back)
    assert why =~ "never reached stable"

    view = render_info(view, {:tap, {:workshop, {:open_tool, id}}})
    view = painted(view)
    assert text(view) =~ "MOST FREQUENT WORDS"
    assert text(view) =~ "Removing this tool was undone"
  end

  test "a Remove reverted on probation puts the tool back on the shelf, and the toast says so" do
    boom = """
    defmodule Bezalel.Dyn.Boom do
      @behaviour Rho.Tool
      def name, do: "boom"
      def description, do: "Crashes."
      def parameter_schema, do: %{"type" => "object", "properties" => %{}}
      def run(_args, _ctx), do: raise("boom")
      def selftest, do: :ok
    end
    """

    tools =
      %{"word_frequency.ex" => word_frequency(), "boom.ex" => boom}
      |> Dyn.propose!()
      |> approve!()

    tool = Enum.find(tools, &(&1.name == "Word Frequency"))
    remove!(tool)
    :ok = Rho.Dyn.subscribe()

    # The generation without it crashes on probation: another tool in it does.
    script(Live, [
      [
        {:tool_call, "c1", "boom", %{}},
        {:tool_call, "c2", "boom", %{}},
        {:tool_call, "c3", "boom", %{}}
      ],
      [{:text, "It crashed."}]
    ])

    view = AppScreen |> mount_screen() |> ask("Crash it")
    assert %{from: 2, to: 1} = reverted = Dyn.await(:reverted)
    view = view |> render_info({:rho_dyn, reverted}) |> render_info({:tap, {:tab, :workshop}})

    assert assigns(view).toast.text =~ "Bezalel without Word Frequency crashed"
    back = Library.get_tool(tool.id)
    assert %{data: %{"generation" => 1, "removed" => false}} = back
    assert {:removal_reverted, _} = Workshop.status(back)
    assert text(view) =~ "Back: removing it was undone"
  end

  test "a tool that runs with no shelf entry gets one; a removal that runs keeps it off" do
    [tool] = word_frequency() |> then(&Dyn.propose!(%{"word_frequency.ex" => &1})) |> approve!()
    :ok = Library.delete_tool(tool)
    :ok = Workshop.reconcile()

    assert [%Tool{name: "Word Frequency", description: "test change"} = back] =
             Library.list_tools()

    assert %{"module" => "Bezalel.Dyn.WordFrequency", "generation" => 1} = back.data

    remove!(back)
    :ok = Workshop.reconcile()
    assert Library.list_tools() == []
  end

  test "the example in the guide the model reads passes the check, compiles and selftests" do
    guide = Prompt.dyn_guide()
    [_, example] = String.split(guide, "A small complete example (`verse_card.ex`):\n")

    source =
      example
      |> String.split("\n")
      |> Enum.map_join("\n", &String.replace_prefix(&1, "    ", ""))

    n = Dyn.propose!(%{"verse_card.ex" => source})
    [tool] = approve!(n)
    assert %{name: "Verse Card", data: %{"screen" => "VerseCard.Screen"}} = tool
    {:ok, module} = Rho.Dyn.lookup({:tool, "verse_card"})
    assert {:ok, text} = module.run(%{"reference" => "Exodus 31:2"}, %{})
    assert text =~ "Exodus 31:2"
  end
end
