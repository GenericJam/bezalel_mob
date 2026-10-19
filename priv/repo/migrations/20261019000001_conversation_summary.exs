defmodule Bezalel.Repo.Migrations.ConversationSummary do
  use Ecto.Migration

  # The conversation's one-line summary, written with its title (the name)
  # by the lead's provider's small model after each finished reply
  # (Bezalel.Titles, bezalel_core's Bezalel.Agent.Title); nil until then.
  def change do
    alter table(:conversations) do
      add :summary, :text
    end
  end
end
