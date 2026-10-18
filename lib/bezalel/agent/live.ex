defmodule Bezalel.Agent.Live do
  @moduledoc """
  The live study agent: rho's loop (`Rho.Loop`) with the study system
  prompt (`Bezalel.Study.Prompt.system_prompt/2` for the user's study
  preferences, `Bezalel.Settings.study_preferences/0`, with the phone's
  formatting section, `phone_formatting/0`), the study tools
  (`Bezalel.Study.Tools.all/0`, plus rho's `read_artifact` for a result
  too long to send whole) and the tools the user built in the Workshop
  (the current Dyn generation's, `Rho.Dyn.Source`, from the next model
  call after one is approved or reverted), on the model chosen in Settings.
  The loop takes its tools from rho's registry, which the app starts with
  `tools/0` (the Dyn layer adds its `dyn_*` tools there, for the
  Workshop; Study withholds them, `withheld/0`, and the study tools whose
  every source the user switched off, `Bezalel.Study.Tools.withheld/1`).
  The prompt and the withheld tools are fixed when a loop starts: a change
  of preferences releases the idle loops
  (`Bezalel.Views.Helpers.release_idle/1`), so it applies from the next
  question.

  **The conversation's session is the loop's.** A conversation's
  transcript is its rho session (`Bezalel.Library`); a loop resumes it
  (`Bezalel.Library.session/2`: the entries on its active branch, so the
  model sees exactly what earlier loops sent and got, tool results
  included) and writes the question and the reply into it as they happen.
  Pictures stay in the session as the tools and models gave them; of a
  `lookup_verse` or `word_study` result's details, the passage card
  (`Bezalel.Agent.Card`) is kept with the result (`:keep_details`), so the
  chat draws it again from the session.

  **One loop per conversation being answered**, started on its first
  question and registered under the conversation's id
  (`Bezalel.Agent.Live`'s `Registry`, which the app starts). It stays
  while the conversation is open, so later questions skip reopening the
  session. The screen releases it (`release/1`) when the conversation is
  left and its reply is done, before Bezalel itself writes to the session
  (a delete, an undo, a scripted reply, a question asked again: a loop
  keeps its own place in the file), and when a reply is stopped or fails;
  mounting the screen releases them all. Releasing only stops the
  process; the session stays.

  Loop options from `config :bezalel, Bezalel.Agent.Live` are added to
  the loop's (tests set `:llm` to a scripted model).
  """
  @behaviour Bezalel.Agent

  alias Bezalel.Agent.Card
  alias Bezalel.{Library, Settings}
  alias Bezalel.Study.{Prompt, Tools}
  alias Rho.Dyn.Source
  alias Rho.Loop

  @registry __MODULE__

  @phone_formatting """
  ## Formatting for a phone

  Your answer is read on a phone, in a column about 40 characters wide. Markdown renders (headings, lists, bold and italic, links, short code), but anything wide does not fit:

  - **Tables**: at most three columns, with a word or two per cell. Anything wider or wordier is unreadable there: use a list instead, one item per row, with the details beneath it (e.g. "**H7307 rûaḥ**: spirit, wind, breath").
  - **No long lines that can't wrap**: wide code blocks, ASCII diagrams, long unbroken strings.
  - **Short paragraphs and short headings.** Lead with the point; one idea per paragraph.
  """

  @doc "Starts the registry the loops are named in (the app does, after `Rho.Supervisor`)."
  @spec start_link() :: {:ok, pid()} | {:error, term()}
  def start_link, do: Registry.start_link(keys: :unique, name: @registry)

  @doc "The core tools the app starts rho's registry with (`Rho.Supervisor`)."
  @spec tools() :: [module()]
  def tools, do: Tools.all() ++ [Rho.Tools.ReadArtifact]

  @doc "The registry's tools Study never offers: the ones that write Dyn code."
  @spec withheld() :: [String.t()]
  def withheld, do: Enum.map(Source.core_tools(), & &1.name())

  @doc """
  The phone's section of the study prompt (bezalel_core's `surface:`): how
  the chat renders answers, in a narrow column.
  """
  @spec phone_formatting() :: String.t()
  def phone_formatting, do: @phone_formatting

  @doc "The study system prompt for `prefs` (`Bezalel.Study.Preferences`) on the phone."
  @spec system_prompt(Bezalel.Study.Preferences.t()) :: String.t()
  def system_prompt(prefs), do: Prompt.system_prompt(prefs, surface: @phone_formatting)

  @doc """
  What a tool result keeps of its details in the session: the passage
  card, for the tools that name a passage; nothing for the rest.
  """
  @spec keep_details(String.t(), term()) :: map() | nil
  def keep_details(name, details), do: Card.from_tool(name, details)

  @impl true
  def ask(conversation_id, text, model, subscriber) do
    with {:ok, loop} <- loop(conversation_id, model),
         :ok <- Loop.subscribe(loop, subscriber),
         :ok <- use_model(loop, model),
         :ok <- Loop.prompt(loop, text) do
      {:ok, Loop.config(loop).session.id}
    end
  end

  @impl true
  def steer(conversation_id, text) do
    case whereis(conversation_id) do
      nil -> {:error, :idle}
      loop -> Loop.steer(loop, text)
    end
  end

  @impl true
  def stop(conversation_id) do
    case whereis(conversation_id) do
      nil -> :ok
      loop -> Loop.stop(loop)
    end
  end

  @impl true
  def release(conversation_id) do
    case whereis(conversation_id) do
      nil -> :ok
      loop -> shut(loop)
    end
  end

  @impl true
  def release_all do
    # `:"$_"` would be `{key, {pid, value}}`: select the pids.
    for loop <- Registry.select(@registry, [{{:_, :"$1", :_}, [], [:"$1"]}]), do: shut(loop)

    :ok
  end

  @doc "Whether a loop is running for the conversation."
  @spec running?(term()) :: boolean()
  def running?(conversation_id), do: whereis(conversation_id) != nil

  # The Registry drops a stopped loop's name only when it processes the DOWN,
  # so just after a release the lookup can still return the dead pid: treat
  # it as gone (a new start re-registers over a dead holder).
  defp whereis(conversation_id) do
    case Registry.lookup(@registry, conversation_id) do
      [{pid, _}] -> if Process.alive?(pid), do: pid
      [] -> nil
    end
  end

  defp loop(conversation_id, model) do
    case whereis(conversation_id) do
      nil -> start(conversation_id, model)
      loop -> {:ok, loop}
    end
  end

  defp start(conversation_id, model) do
    prefs = Settings.study_preferences()

    with {:ok, session, entries} <- Library.session(conversation_id, model) do
      opts =
        [
          session: session,
          entries: entries,
          name: {:via, Registry, {@registry, conversation_id}},
          system_prompt: system_prompt(prefs),
          tools: :registry,
          withhold_tools: withheld() ++ Tools.withheld(prefs),
          keep_details: &keep_details/2
        ] ++ Application.get_env(:bezalel, __MODULE__, [])

      case Rho.start_loop(opts) do
        {:ok, loop} -> {:ok, loop}
        # Asked twice at once: the other call's loop.
        {:error, {:already_started, loop}} -> {:ok, loop}
        {:error, _} = error -> error
      end
    end
  end

  defp use_model(loop, model) do
    if Loop.config(loop).session.model == model,
      do: :ok,
      else: Loop.set_model(loop, model)
  end

  defp shut(loop) do
    _ = DynamicSupervisor.terminate_child(Rho.LoopSup, loop)
    :ok
  catch
    # Gone already (it ended, or another caller shut it).
    :exit, _ -> :ok
  end
end
