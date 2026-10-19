defmodule Bezalel.Titles do
  @moduledoc """
  Names conversations: after each finished reply, bezalel_core's
  `Bezalel.Agent.Title` has the lead model's provider's small model
  (Claude Haiku, a GPT mini, Gemini Flash-Lite, ChatGPT's Luna) write the
  conversation's title and one-line summary from the conversation so far,
  refining the last ones, and the conversation keeps them
  (`Bezalel.Library.put_title/3`). The app's screen then hears
  `{:titled, conversation}` and shows them: the title in Study's header and
  on the Conversations tab, the summary under it there.

  It runs in a task of its own, after the reply is stored, so it never
  holds up or fails a reply: on any error the conversation keeps the name
  it had (the first question's, `Bezalel.Library.name_after/2`, until the
  first title comes). The call is on the same sign-in or key as the reply,
  and rho's usage record counts it (Settings → Usage).

  `config :bezalel, Bezalel.Titles, enabled: false` turns it off (the
  tests do, so the scripted model only answers the replies they script);
  `consult:` options go to `Rho.Consult.run/3` (a test's `:llm`).
  """

  alias Bezalel.Agent.{Reply, Title}
  alias Bezalel.Library
  alias Bezalel.Library.Conversation

  require Logger

  @doc """
  After `reply` finished in conversation `conversation_id`: names it in a
  task that tells `screen` `{:titled, conversation}` once it's renamed.
  `:skip` for a reply that didn't finish or when naming is off. Returns
  at once.
  """
  @spec after_reply(integer(), Reply.t(), pid()) :: {:ok, pid()} | :skip
  def after_reply(conversation_id, %Reply{status: :done, model: model}, screen)
      when is_binary(model) do
    if enabled?(),
      do: Task.start(fn -> tell(screen, name(conversation_id, model)) end),
      else: :skip
  end

  def after_reply(_conversation_id, _reply, _screen), do: :skip

  defp tell(screen, {:ok, conversation}), do: send(screen, {:titled, conversation})
  defp tell(_screen, _other), do: :ok

  @doc """
  Names conversation `conversation_id` after a reply from `lead` (a rho
  model spec), in the caller: `{:ok, conversation}` renamed, `:unchanged`,
  or `{:error, reason}` with the name left as it was (logged).
  """
  @spec name(integer(), String.t()) :: {:ok, Conversation.t()} | :unchanged | {:error, term()}
  def name(conversation_id, lead) do
    case rename(conversation_id, lead) do
      {:error, reason} = error ->
        Logger.warning("[titles] kept the conversation's name: #{inspect(reason)}")
        error

      result ->
        result
    end
  end

  defp rename(conversation_id, lead) do
    with %Conversation{} = c <- Library.get_conversation(conversation_id) || {:error, :gone},
         messages = Library.messages(c.id),
         {:ok, named} <- Title.run(lead, messages, current(c), consult: consult()) do
      cond do
        named.title == c.name and named.summary == c.summary -> :unchanged
        renamed = Library.put_title(c.id, named, length(messages)) -> {:ok, renamed}
        # Moved on (a newer reply, a delete) while the model wrote.
        true -> {:error, :moved_on}
      end
    end
  end

  defp current(%Conversation{name: name, summary: summary}), do: %{title: name, summary: summary}

  defp enabled?, do: Keyword.get(config(), :enabled, true)
  defp consult, do: Keyword.get(config(), :consult, [])
  defp config, do: Application.get_env(:bezalel, __MODULE__, [])
end
