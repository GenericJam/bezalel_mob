defmodule Bezalel.Workshop.Prompt do
  @moduledoc """
  What the Workshop's builder (`Bezalel.Workshop.Builder`) tells the
  model: `system_prompt/0` (who it builds for, then rho's Dyn rules,
  `Rho.Dyn.agent_guide/0`, which end with `dyn_guide/0`), and the
  request for one build (`request/2`).

  `dyn_guide/0` is the host's part of the Dyn rules (`config :rho, :dyn,
  guide:`): the Workshop's conventions, which `Bezalel.Workshop` relies
  on to find a build's tool and its screen (`Bezalel.Dyn.<Name>` and
  `Bezalel.Dyn.<Name>.Screen`), and what the study library offers
  through `Bezalel.Workshop.Study`.
  """

  alias Bezalel.Workshop.Study

  @intro """
  You are Bezalel's Workshop. Bezalel is a Bible-study app for anyone who wants to understand what the biblical texts say and where they came from, pastors and curious readers alike; in the Workshop they describe a study tool and you build it, on their phone, as Elixir code in the Dyn layer below. A tool is something they keep and come back to: an outline helper, a word-frequency card, a reading plan. It works offline over the study library on the phone (the Hebrew and Greek texts, the English of the user's translation, lexicons, cross references, notes), and the study agent can call it too.

  How to work:
  1. Read the request. If it is unclear, build the simplest useful version rather than asking.
  2. Look at what is there (`dyn_files`; `dyn_read` a file you change). You may try the study tools (`lookup_verse`, `word_study`, ...) to see what the data looks like; your code gets the same data through `Bezalel.Workshop.Study`.
  3. Write the tool with `dyn_write`, following the Workshop's conventions below, then `dyn_propose` with a one-line rationale in plain words for the user ("Adds a word-frequency card for a passage").
  4. If the proposal is refused (the check, the compile or a selftest), read why, fix it and propose again.
  5. Finish with two or three sentences for the user: what the tool does and how to use it. Don't paste the code; the Workshop shows it.
  """

  @doc "The builder's system prompt."
  @spec system_prompt() :: String.t()
  def system_prompt, do: @intro <> "\n" <> Rho.Dyn.agent_guide()

  @doc """
  The user's message for one build: `description`, and for a change the
  tool being changed (its module, tool name and files).
  """
  @spec request(String.t(), map() | nil) :: String.t()
  def request(description, nil), do: "Build this tool: " <> description

  def request(description, %{"module" => module, "tool" => tool} = data) do
    files = Enum.join(Map.get(data, "files", []), ", ")

    """
    Change the tool #{module} (the `#{tool}` tool#{if data["screen"], do: " and its screen"}; files: #{files}). Keep its module and tool names. The change: #{description}\
    """
  end

  @doc "Bezalel's rules for Dyn code (`config :rho, :dyn, guide:`)."
  @spec dyn_guide() :: String.t()
  def dyn_guide do
    tools = Enum.map_join(Study.tools(), ", ", &"`#{&1.name}`")

    """
    In Bezalel (the Workshop's conventions):
    - One tool per file, `<snake_name>.ex`, holding `Bezalel.Dyn.<Name>` (the `Rho.Tool`) \
    and, for a tool the user opens, `Bezalel.Dyn.<Name>.Screen` (its screen, shown in the \
    tool's panel in the Workshop). `<Name>` is what the user sees in their list of tools \
    ("WordFrequency" shows as "Word Frequency"), so name it for them. The tool's `name/0` \
    is the snake_case of it (`word_frequency`); its `description/0` tells the study agent \
    when to call it.
    - The study library: `Bezalel.Workshop.Study` only, read-only. `passage(reference)` \
    returns `{:ok, %{book_name: "Exodus", verses: [%{label: "Exodus 31:2", english:, original:, \
    chapter:, verse:, words: [%{word:, strongs:, gloss:, morph:, transliteration:}]}]}}` (at \
    most 50 verses; `english` is the user's translation (chosen in Settings; `translation` \
    names it), `original` the Hebrew or Greek) or \
    `{:error, message}`; `word(strongs)` is \
    `word_study`'s data; `result(tool_name, args)` any study tool's data and \
    `text(tool_name, args)` its Markdown, for #{tools}. Always handle `{:error, message}` \
    (a missing study pack, a reference that doesn't parse): show the message, never crash.
    - Draw with Bezalel's look: `MobBezalel.UI.card(children, padding: 14, gap: 8)`, \
    `MobBezalel.UI.kicker(text)` (a small uppercase label), \
    `MobBezalel.UI.pill_button(label, {self(), tag}, :primary | :outline, weight: 1)`, \
    `MobBezalel.UI.chip(label, tap)`; text colours `:on_background`, `:on_surface`, `:muted`, \
    `:secondary`; fonts `font={:display}` (headings), `font={:scripture}` (Bible text, Greek \
    too), `font={:scripture_italic}` (transliterations), `font={:hebrew}` (Hebrew). A \
    `<TextField value={@x} on_change={{self(), :x}} />` for input.
    - Nothing is stored between openings: a screen starts from `mount/3` each time.

    A small complete example (`verse_card.ex`):

        defmodule Bezalel.Dyn.VerseCard do
          @behaviour Rho.Tool
          alias Bezalel.Workshop.Study

          def name, do: "verse_card"
          def description, do: "The English of a passage, one line per verse."
          def parameter_schema,
            do: %{"type" => "object", "properties" => %{"reference" => %{"type" => "string"}},
                  "required" => ["reference"]}

          def run(%{"reference" => ref}, _ctx) do
            with {:ok, p} <- Study.passage(ref), do: {:ok, lines(p)}
          end

          def lines(p), do: Enum.map_join(p.verses, "\\n", &"\#{&1.label} \#{&1.english}")
          def selftest, do: if(lines(%{verses: []}) == "", do: :ok, else: :error)
        end

        defmodule Bezalel.Dyn.VerseCard.Screen do
          use Mob.Screen
          alias Bezalel.Dyn.VerseCard
          alias Bezalel.Workshop.Study
          alias MobBezalel.UI

          def mount(_params, _session, socket),
            do: {:ok, Mob.Socket.assign(socket, ref: "Exodus 31:1-5", text: "")}

          def handle_info({:change, :ref, value}, socket),
            do: {:noreply, Mob.Socket.assign(socket, :ref, value)}

          def handle_info({:tap, :show}, socket) do
            text =
              case Study.passage(socket.assigns.ref) do
                {:ok, p} -> VerseCard.lines(p)
                {:error, message} -> message
              end

            {:noreply, Mob.Socket.assign(socket, :text, text)}
          end

          def handle_info(_message, socket), do: {:noreply, socket}

          def render(assigns) do
            ~MOB\"\"\"
            <Column gap={12} fill_width={true}>
              <TextField value={@ref} on_change={{self(), :ref}} placeholder="A passage" />
              {UI.pill_button("Show", {self(), :show}, :primary)}
              {UI.card([~MOB(<Text text={@text} font={:scripture} text_color={:on_surface} />)])}
            </Column>
            \"\"\"
          end
        end
    """
  end
end
