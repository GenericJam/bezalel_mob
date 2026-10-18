defmodule Bezalel.Repo.Migrations.ConversationPushback do
  use Ecto.Migration

  # The conversation's Pushback switch (its menu): when on, the model
  # chosen under Settings → Models → Pushback from reviews each finished
  # reply and the answering model responds (Bezalel.Agent.Pushback.auto/4).
  # Off for every conversation until the user turns it on.
  def change do
    alter table(:conversations) do
      add :pushback, :boolean, default: false, null: false
    end
  end
end
