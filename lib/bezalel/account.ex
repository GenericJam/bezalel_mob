defmodule Bezalel.Account do
  @moduledoc """
  What Settings shows of the user's model access, read from rho: per
  provider, the sign-in or API key (`Rho.Auth`, kept in the secure store),
  and rho's usage record (`Rho.Usage`), which bezalel_core's
  `Bezalel.Usage` lays out. Keys never leave here whole: `status/0`
  carries a masked form only.
  """

  alias Rho.Auth
  alias Rho.Usage.Fetch

  @subscriptions [:anthropic, :openai_codex]
  @api_keys [:anthropic, :openai, :google]

  @type access :: %{
          signed_in: boolean(),
          type: :oauth | :api_key | nil,
          email: String.t() | nil,
          masked: String.t() | nil
        }

  @doc "The providers a subscription signs in to, in the order Settings lists them."
  @spec subscriptions() :: [Auth.provider()]
  def subscriptions, do: @subscriptions

  @doc "The providers that take an API key, in the order Settings lists them."
  @spec api_keys() :: [Auth.provider()]
  def api_keys, do: @api_keys

  @doc ~s(The subscription's name: "Claude", "ChatGPT".)
  @spec subscription_name(Auth.provider()) :: String.t()
  def subscription_name(:anthropic), do: "Claude"
  def subscription_name(:openai_codex), do: "ChatGPT"

  @doc ~s(The API key's provider: "Anthropic", "OpenAI", "Google Gemini".)
  @spec key_name(Auth.provider()) :: String.t()
  def key_name(:anthropic), do: "Anthropic"
  def key_name(:openai), do: "OpenAI"
  def key_name(:google), do: "Google Gemini"

  @doc """
  Per provider (`Rho.Auth.providers/0`): signed in or not, how, the
  sign-in's email, and an API key masked to its first and last characters.
  Also what `Bezalel.Models.groups/1` takes.
  """
  @spec status() :: %{Auth.provider() => access()}
  def status do
    Map.new(Auth.providers(), fn provider ->
      case Auth.get(provider) do
        {:ok, %{"type" => "api_key", "key" => key}} ->
          {provider, %{signed_in: true, type: :api_key, email: nil, masked: mask(key)}}

        {:ok, creds} ->
          {provider, %{signed_in: true, type: :oauth, email: creds["email"], masked: nil}}

        :error ->
          {provider, %{signed_in: false, type: nil, email: nil, masked: nil}}
      end
    end)
  end

  @doc """
  A key as Settings shows it: its first 6 and last 4 characters
  (`sk-ant…WXYZ`), or dots alone for a key too short to show any of.
  """
  @spec mask(String.t()) :: String.t()
  def mask(key) when byte_size(key) >= 16,
    do: String.slice(key, 0, 6) <> "…" <> String.slice(key, -4, 4)

  def mask(_key), do: "••••••••"

  @doc """
  rho's usage record (`Rho.Usage.load/1` of its data dir): the providers'
  limit windows, the last rate limit, tokens and cost per model per day.
  What `Bezalel.Usage`'s functions take as `state`.
  """
  @spec usage() :: map()
  def usage, do: Rho.Usage.load(Rho.Config.data_dir())

  @doc """
  Asks each signed-in subscription's usage endpoint for its windows now
  (`Rho.Usage.Fetch.refresh/3`; an API key has none). The record changes
  (and `{:rho_usage, :changed}` follows) for each that answers; the rest
  are `{provider, reason}` in the result. `config :bezalel, :usage_fetch`
  is passed on as `Rho.Usage.Fetch`'s options (host tests answer for the
  endpoint with `:respond`).
  """
  @spec refresh_usage(%{Auth.provider() => access()}) :: [{Auth.provider(), String.t()}]
  def refresh_usage(status) do
    opts = Application.get_env(:bezalel, :usage_fetch, [])

    for provider <- @subscriptions,
        match?(%{signed_in: true, type: :oauth}, status[provider]),
        {:error, reason} <- [Fetch.refresh(Rho.Config.data_dir(), provider, opts)],
        do: {provider, reason}
  end
end
