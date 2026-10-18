defmodule Bezalel.Repo.Migrations.CreateMaterials do
  use Ecto.Migration

  # Materials (bezalel_core's Bezalel.Materials): the files sent to the agent
  # and received from it, and what Bezalel made from them (transcripts,
  # stills, drawings). The bytes are files under the app support directory
  # (Bezalel.MaterialStore); a row is the record, keyed by the bytes' SHA-256.
  def change do
    create table(:materials, primary_key: false) do
      add :id, :text, primary_key: true
      # image | audio | video | document | transcript
      add :kind, :text, null: false
      add :mime, :text, null: false
      add :name, :text, null: false
      add :size, :integer, null: false
      # sent | received | derived
      add :source, :text, null: false
      # nil | transcript | audio_track | still | generated
      add :derivation, :text
      # The ids it was made from (JSON array).
      add :derived_from, {:array, :text}, null: false, default: "[]"
      # duration_ms, width, height, pages, at_ms, prompt, model (JSON object).
      add :meta, :map, null: false, default: "{}"
      add :inserted_at, :utc_datetime, null: false
    end

    create index(:materials, [:kind, :inserted_at])

    # Which conversations a material went with or came from, by their rho
    # session id: the same bytes sent in two conversations are one material
    # in both.
    create table(:material_links, primary_key: false) do
      add :material_id, references(:materials, type: :text, on_delete: :delete_all), null: false

      add :session_id, :text, null: false
      add :inserted_at, :utc_datetime, null: false
    end

    create unique_index(:material_links, [:material_id, :session_id])
    create index(:material_links, [:session_id])
  end
end
