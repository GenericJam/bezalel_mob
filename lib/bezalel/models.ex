defmodule Bezalel.Models do
  @moduledoc """
  The models the user can pick from (the design's model sheet): rho's
  catalog (`Rho.Models`) for the providers the user has a sign-in or an API
  key for, grouped by provider. A model's id is its req_llm spec
  (`"anthropic:claude-sonnet-5-5"`); that's what `Bezalel.Settings` keeps.

  `images: true` marks the models the catalog says take pictures. Nothing
  draws: images in Bezalel are display-only for now.
  """

  alias Rho.Auth

  # Provider dots, from the design's model sheet.
  @dots %{
    anthropic: 0xFFC67139,
    openai_codex: 0xFF5E8C6A,
    openai: 0xFF5E8C6A,
    google: 0xFF4A6FA5
  }

  @type model :: %{
          id: String.t(),
          provider: Auth.provider(),
          group: String.t(),
          name: String.t(),
          note: String.t(),
          dot: integer(),
          tags: [String.t()],
          images: boolean()
        }

  @doc """
  The default model id, used until the user picks one: the newest Claude
  Sonnet in the catalog (careful with sources, as the design has it).
  """
  @spec default() :: String.t()
  def default, do: get(nil).id

  @doc """
  What `provider`'s models need, in the model sheet and Settings:
  "Claude sign-in or Anthropic API key".
  """
  @spec needs(Auth.provider()) :: String.t()
  def needs(:anthropic), do: "Claude sign-in or Anthropic API key"
  def needs(:openai_codex), do: "ChatGPT sign-in"
  def needs(:openai), do: "OpenAI API key"
  def needs(:google), do: "Gemini API key"

  @doc """
  The models of the providers signed in to in `status` (`Rho.Auth.status/0`),
  grouped: `[{group, [model]}]`, in rho's provider order. Empty when the
  user has no sign-in and no API key.
  """
  @spec groups(map()) :: [{String.t(), [model()]}]
  def groups(status) do
    for provider <- Auth.providers(),
        match?(%{signed_in: true}, status[provider]),
        models = catalog(provider),
        models != [],
        do: {group(provider), models}
  end

  @doc """
  Every provider's models, signed in or not: `[{provider, group,
  [model]}]`, in rho's provider order (Settings → Models, Pushback from,
  which shows what a model needs before it can be chosen).
  """
  @spec all_groups() :: [{Auth.provider(), String.t(), [model()]}]
  def all_groups do
    for provider <- Auth.providers(),
        models = catalog(provider),
        models != [],
        do: {provider, group(provider), models}
  end

  @doc "Whether `model` can be used with the credentials in `status`."
  @spec available?(model(), map()) :: boolean()
  def available?(model, status), do: match?(%{signed_in: true}, status[model.provider])

  @doc """
  A model by id, from the whole catalog (signed in or not, so a choice made
  before signing out still has its name). A ChatGPT model the sign-in no
  longer lists is the sign-in's default (`replacement/1`: the next question
  makes it the choice, with a toast); any other unknown id, such as one
  from before the catalog, is the default.
  """
  @spec get(String.t() | nil) :: model()
  def get(id) when is_binary(id) do
    case Auth.provider_for_model(id) do
      {:ok, :openai_codex} ->
        models = catalog(:openai_codex)
        Enum.find(models, &(&1.id == id)) || List.first(models) || get(nil)

      {:ok, provider} ->
        Enum.find(catalog(provider), &(&1.id == id)) || get(nil)

      :error ->
        get(nil)
    end
  end

  def get(_id) do
    models = catalog(:anthropic)
    Enum.find(models, &(&1.name =~ "Sonnet")) || hd(models)
  end

  @doc """
  What a chosen ChatGPT model `id` gives way to when the sign-in no longer
  offers it (rho's list, `Rho.Models.Codex`): `{default_id, notice}`, the
  sign-in's default and rho's one-line notice. nil for a model still
  offered and for other providers' models.
  """
  @spec replacement(String.t() | nil) :: {String.t(), String.t()} | nil
  def replacement("openai_codex:" <> _ = id) do
    case get(id) do
      %{id: ^id} -> nil
      %{id: other} -> {other, Rho.Models.Codex.replaced_notice(id, other)}
    end
  end

  def replacement(_id), do: nil

  @doc """
  The catalog's model for a spec rho recorded usage under, matching an
  alias or a dated snapshot too (`claude-haiku-4-5` is
  `claude-haiku-4-5-20251001`); nil when the catalog doesn't have it (a
  model since retired, a provider rho doesn't list).
  """
  @spec lookup(String.t()) :: model() | nil
  def lookup(id) do
    case Auth.provider_for_model(id) do
      {:ok, provider} ->
        canonical = canonical(id)
        Enum.find(catalog(provider), &(&1.id == canonical or Rho.Models.same?(&1.id, id)))

      :error ->
        nil
    end
  end

  # The spec of the model llm_db resolves `id` (an alias, say) to.
  defp canonical(id) do
    case LLMDB.model(id) do
      {:ok, %{provider: provider, id: model_id}} -> "#{provider}:#{model_id}"
      _ -> id
    end
  end

  @doc "A provider's dot color."
  @spec dot(Auth.provider() | nil) :: integer() | nil
  def dot(provider), do: @dots[provider]

  @doc """
  Who a message or tool is attributed to: the model's name, or "Scripted
  reply" for the design's storyboard. A model the catalog no longer has
  (a ChatGPT model the sign-in stopped offering) is named by its id.
  """
  @spec attribution(String.t() | nil) :: String.t()
  def attribution("storyboard"), do: "Scripted reply"

  def attribution(id) when is_binary(id) do
    case {lookup(id), Auth.provider_for_model(id)} do
      {%{name: name}, _} -> name
      {nil, {:ok, _provider}} -> id |> String.split(":", parts: 2) |> List.last()
      {nil, :error} -> get(nil).name
    end
  end

  def attribution(nil), do: get(nil).name

  # Claude's, OpenAI's and Gemini's catalogs don't change while the app
  # runs: built once per provider. ChatGPT's is the sign-in's current list
  # (`Rho.Models.Codex`, fetched again in the background), built each time.
  defp catalog(:openai_codex),
    do: Enum.map(Rho.Models.catalog(:openai_codex), &model(:openai_codex, &1))

  defp catalog(provider) do
    key = {__MODULE__, provider}

    case :persistent_term.get(key, nil) do
      nil ->
        models = Enum.map(Rho.Models.catalog(provider), &model(provider, &1))
        :persistent_term.put(key, models)
        models

      models ->
        models
    end
  end

  defp model(provider, %{spec: spec, name: name}) do
    images = Rho.Models.images?(spec)

    %{
      id: spec,
      provider: provider,
      group: group(provider),
      name: name,
      note: needs(provider),
      dot: @dots[provider],
      tags: if(images, do: ["IMAGES"], else: []),
      images: images
    }
  end

  defp group(provider), do: provider |> Auth.label() |> String.upcase()
end
