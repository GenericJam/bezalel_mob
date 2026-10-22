defmodule Bezalel.Settings do
  @moduledoc """
  The user's choices, kept in `Mob.State` (survives restarts): theme mode,
  cover, text size, model (a `Bezalel.Models` id), which conversation is open,
  whether the study-pack download has been offered, and the study
  preferences (`Bezalel.Study.Preferences`: approach, scripture labels,
  sources switched off, results per list, translation), which bezalel_core's
  tools and system prompt read through `study_preferences/1` (`config
  :bezalel_core, :preferences`).
  Sign-ins and API keys aren't here: rho keeps them in the secure store
  (`Rho.Auth`).
  """

  alias Bezalel.Link.Dialer
  alias Bezalel.Study.Preferences

  @modes [:light, :dark, :night, :system]
  @covers [:leather, :paper]
  # Text size → Mob's theme `text_scale`, multiplied into every text size on
  # top of the phone's own font scale (decisions/2026-10-19-text-size.md).
  @text_sizes [small: 0.85, default: 1.0, large: 1.15, larger: 1.3, largest: 1.5]
  @text_size_names Keyword.keys(@text_sizes)

  @doc "Theme modes in the order the Theme control lists them."
  @spec modes() :: [atom()]
  def modes, do: @modes

  @doc "Bar treatments."
  @spec covers() :: [atom()]
  def covers, do: @covers

  @spec mode() :: atom()
  def mode, do: get(:mode, :dark, @modes)

  @spec cover() :: atom()
  def cover, do: get(:cover, :leather, @covers)

  @doc "Text sizes, smallest first, in the order Settings → Appearance lists them."
  @spec text_sizes() :: [atom()]
  def text_sizes, do: @text_size_names

  @doc "The user's text size (`:default` until chosen)."
  @spec text_size() :: atom()
  def text_size, do: get(:text_size, :default, @text_size_names)

  @doc "The factor a text size multiplies every text size by (Mob's `text_scale`)."
  @spec text_scale(atom()) :: float()
  def text_scale(size \\ text_size()), do: Keyword.fetch!(@text_sizes, size)

  @spec model() :: String.t()
  def model, do: Mob.State.get(:bezalel_model, Bezalel.Models.default())

  @spec conversation_id() :: integer() | nil
  def conversation_id, do: Mob.State.get(:bezalel_conversation, nil)

  def put_mode(mode) when mode in @modes, do: Mob.State.put(:bezalel_mode, mode)
  def put_cover(cover) when cover in @covers, do: Mob.State.put(:bezalel_cover, cover)

  def put_text_size(size) when size in @text_size_names,
    do: Mob.State.put(:bezalel_text_size, size)

  def put_model(id) when is_binary(id) do
    Mob.State.put(:bezalel_model, id)
    notify_link_preferences()
  end

  def put_conversation_id(id), do: Mob.State.put(:bezalel_conversation, id)

  @doc "Has the first-launch offer of the core study pack been shown?"
  @spec packs_offered?() :: boolean()
  def packs_offered?, do: Mob.State.get(:bezalel_packs_offered, false) == true

  def put_packs_offered, do: Mob.State.put(:bezalel_packs_offered, true)

  @doc "Are finished replies read aloud (Settings → Voice)? Off until the user turns it on."
  @spec read_aloud?() :: boolean()
  def read_aloud?, do: Mob.State.get(:bezalel_read_aloud, false) == true

  def put_read_aloud(on?) when is_boolean(on?), do: Mob.State.put(:bezalel_read_aloud, on?)

  @doc """
  The voice replies are read in (Settings → Voice): `%{id, name, language}`
  of a `Mob.Speech.voices/0` voice, or nil for the phone's default. The id
  is this phone's; on another one, or once the voice is removed, the
  platform falls back to a voice for its language or the default.
  """
  @spec voice() :: %{id: String.t(), name: String.t(), language: String.t()} | nil
  def voice do
    case Mob.State.get(:bezalel_voice) do
      %{"id" => id, "name" => name, "language" => language} ->
        %{id: id, name: name, language: language}

      _default ->
        nil
    end
  end

  def put_voice(nil), do: Mob.State.delete(:bezalel_voice)

  def put_voice(%{id: id, name: name, language: language}),
    do: Mob.State.put(:bezalel_voice, %{"id" => id, "name" => name, "language" => language})

  @doc "The `speak` options for the chosen voice (none for the default)."
  @spec voice_opts() :: keyword()
  def voice_opts do
    case voice() do
      %{id: id} -> [voice: id]
      nil -> []
    end
  end

  @doc """
  The study preferences, normalised (`Bezalel.Study.Preferences.new/1`):
  the defaults for whatever isn't set or isn't valid.
  """
  @spec study_preferences() :: Preferences.t()
  def study_preferences do
    case Mob.State.get(:bezalel_study_preferences) do
      stored when is_map(stored) -> Preferences.new(stored)
      _unset -> %Preferences{}
    end
  end

  @doc """
  The study preferences for a study tool call (`config :bezalel_core,
  :preferences`, called with the tool's ctx): one user per phone, so the
  same whatever the session.
  """
  @spec study_preferences(map()) :: Preferences.t()
  def study_preferences(_ctx), do: study_preferences()

  @doc """
  Stores `prefs` (a struct, map or keyword list), normalised, as a plain
  map (sources as a sorted list). Returns what was stored, as a struct.
  """
  @spec put_study_preferences(Preferences.t() | map() | keyword()) :: Preferences.t()
  def put_study_preferences(prefs) do
    prefs = Preferences.new(prefs)
    Mob.State.put(:bezalel_study_preferences, plain_study(prefs))
    notify_link_preferences()
    prefs
  end

  @doc "The phone-authoritative model and study preferences for linked computers."
  def link_preferences do
    %{
      "model" => model(),
      "study" => plain_study(study_preferences()),
      "updated_at" => Mob.State.get(:bezalel_prefs_updated_at, "1970-01-01T00:00:00Z")
    }
  end

  @doc "Applies a newer linked-computer preference snapshot without echoing it as a local edit."
  def apply_link_preferences(model, study, updated_at) do
    Mob.State.put(:bezalel_model, model)
    Mob.State.put(:bezalel_study_preferences, plain_study(Preferences.new(study)))
    Mob.State.put(:bezalel_prefs_updated_at, updated_at)
    Dialer.preferences_changed()
    :ok
  end

  defp plain_study(prefs) do
    prefs
    |> Map.from_struct()
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
    |> Map.update!("excluded_sources", &Enum.sort/1)
  end

  defp notify_link_preferences do
    Mob.State.put(:bezalel_prefs_updated_at, DateTime.to_iso8601(DateTime.utc_now()))
    Dialer.preferences_changed()
  end

  @doc "Applies `fun` to the study preferences and stores the result (`put_study_preferences/1`)."
  @spec update_study_preferences((Preferences.t() -> Preferences.t() | map())) :: Preferences.t()
  def update_study_preferences(fun), do: study_preferences() |> fun.() |> put_study_preferences()

  @doc """
  What to `Mob.Theme.set/1` for a mode: its theme module with the user's
  text size as Mob's `text_scale`. The `{module, overrides}` form keeps the
  text size when `MobBezalel.System` follows an OS light/dark flip.
  """
  @spec theme(atom()) :: {module(), keyword()}
  def theme(mode), do: {theme_module(mode), text_scale: text_scale()}

  defp theme_module(:system), do: MobBezalel.System
  defp theme_module(mode), do: MobBezalel.theme_module(mode)

  defp get(key, default, allowed) do
    value = Mob.State.get(:"bezalel_#{key}", default)
    if value in allowed, do: value, else: default
  end
end
