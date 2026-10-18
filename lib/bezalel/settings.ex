defmodule Bezalel.Settings do
  @moduledoc """
  The user's choices, kept in `Mob.State` (survives restarts): theme mode,
  cover, model (a `Bezalel.Models` id), which conversation is open,
  whether the study-pack download has been offered, and the study
  preferences (`Bezalel.Study.Preferences`: approach, scripture labels,
  sources switched off, results per list, translation), which bezalel_core's
  tools and system prompt read through `study_preferences/1` (`config
  :bezalel_core, :preferences`).
  Sign-ins and API keys aren't here: rho keeps them in the secure store
  (`Rho.Auth`).
  """

  alias Bezalel.Study.Preferences

  @modes [:light, :dark, :night, :system]
  @covers [:leather, :paper]

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

  @spec model() :: String.t()
  def model, do: Mob.State.get(:bezalel_model, Bezalel.Models.default())

  @spec conversation_id() :: integer() | nil
  def conversation_id, do: Mob.State.get(:bezalel_conversation, nil)

  def put_mode(mode) when mode in @modes, do: Mob.State.put(:bezalel_mode, mode)
  def put_cover(cover) when cover in @covers, do: Mob.State.put(:bezalel_cover, cover)
  def put_model(id) when is_binary(id), do: Mob.State.put(:bezalel_model, id)
  def put_conversation_id(id), do: Mob.State.put(:bezalel_conversation, id)

  @doc "Has the first-launch offer of the core study pack been shown?"
  @spec packs_offered?() :: boolean()
  def packs_offered?, do: Mob.State.get(:bezalel_packs_offered, false) == true

  def put_packs_offered, do: Mob.State.put(:bezalel_packs_offered, true)

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

    stored =
      prefs
      |> Map.from_struct()
      |> Map.update!(:excluded_sources, &Enum.sort/1)

    Mob.State.put(:bezalel_study_preferences, stored)
    prefs
  end

  @doc "Applies `fun` to the study preferences and stores the result (`put_study_preferences/1`)."
  @spec update_study_preferences((Preferences.t() -> Preferences.t() | map())) :: Preferences.t()
  def update_study_preferences(fun), do: study_preferences() |> fun.() |> put_study_preferences()

  @doc "The theme module for a mode."
  @spec theme_module(atom()) :: module()
  def theme_module(:system), do: MobBezalel.System
  def theme_module(mode), do: MobBezalel.theme_module(mode)

  defp get(key, default, allowed) do
    value = Mob.State.get(:"bezalel_#{key}", default)
    if value in allowed, do: value, else: default
  end
end
