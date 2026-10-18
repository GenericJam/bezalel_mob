defmodule Bezalel.Agent do
  @moduledoc """
  The study agent: answers a conversation's question as the design's
  blocks (THINKING / TOOL CALL / SUMMARY) and, when it cites one, a
  passage.

  Replies are live once the user has a model: a sign-in or an API key for
  any provider (`live?/1`). The live agent is picked by
  `config :bezalel, :agent` (`Bezalel.Agent.Live`, rho's loop with the
  study tools); it streams rho's loop events (`{:rho, session_id, event}`,
  `Rho.Events`) to the screen, which folds them into blocks
  (`Bezalel.Agent.Reply`). Without a model, or with `:agent` set to nil,
  replies come from the design's script (`Bezalel.Agent.Storyboard`), and
  the screens say so.
  """

  @doc """
  Asks `text` in `conversation_id`: the question goes into the
  conversation's session after what's there, and the reply follows it.
  `model` is a `Bezalel.Models` id. The loop's events go to `subscriber`.
  `attachments` are rho's (`Bezalel.Materials.attachments/4`: materials by
  reference, with their texts). Returns the loop's session id, which the
  events carry.
  """
  @callback ask(
              conversation_id :: integer(),
              text :: String.t(),
              model :: String.t(),
              subscriber :: pid(),
              attachments :: [map()]
            ) :: {:ok, String.t()} | {:error, term()}

  @doc """
  Adds `text` (and `attachments`) to the reply in progress (rho's
  steering); `{:error, :idle}` without one.
  """
  @callback steer(conversation_id :: integer(), text :: String.t(), attachments :: [map()]) ::
              :ok | {:error, :idle}

  @doc "Stops the reply in progress, if any."
  @callback stop(conversation_id :: integer()) :: :ok

  @doc """
  Lets go of the conversation's loop (its session stays), so the session
  can be written by Bezalel (a delete, an undo) or once it's no longer
  open; the next question resumes the session as stored.
  """
  @callback release(conversation_id :: integer()) :: :ok

  @doc "Forgets every conversation's agent state."
  @callback release_all() :: :ok

  @doc """
  Whether replies come from a model: a live agent is configured and
  `account` (`Bezalel.Account.status/0`) has a sign-in or an API key.
  """
  @spec live?(map()) :: boolean()
  def live?(account) do
    impl() != nil and Enum.any?(account, fn {_provider, access} -> access.signed_in end)
  end

  @doc "See the `c:ask/5` callback."
  @spec ask(integer(), String.t(), String.t(), pid(), [map()]) ::
          {:ok, String.t()} | {:error, term()}
  def ask(conversation_id, text, model, subscriber, attachments \\ []),
    do: impl().ask(conversation_id, text, model, subscriber, attachments)

  @doc "See the `c:steer/3` callback."
  @spec steer(integer(), String.t(), [map()]) :: :ok | {:error, :idle}
  def steer(conversation_id, text, attachments \\ []),
    do: impl().steer(conversation_id, text, attachments)

  @doc "See the `c:stop/1` callback."
  @spec stop(integer()) :: :ok
  def stop(conversation_id), do: impl().stop(conversation_id)

  @doc "See the `c:release/1` callback; nothing without a live agent."
  @spec release(integer()) :: :ok
  def release(conversation_id) do
    if impl(), do: impl().release(conversation_id), else: :ok
  end

  @doc "See the `c:release_all/0` callback; nothing without a live agent."
  @spec release_all() :: :ok
  def release_all, do: if(impl(), do: impl().release_all(), else: :ok)

  defp impl, do: Application.get_env(:bezalel, :agent, Bezalel.Agent.Live)
end
