defmodule Bezalel.Library.Conversation do
  @moduledoc """
  One study conversation on the shelf: a passage study, a word study, ...
  Its transcript is its rho session (`session_id`, in the file
  `session_file` under `Rho.Session.dir/0`; both nil until it's first
  written); `message_count` is what the shelf shows. `deleted_at` is set
  while a delete can still be undone (`Bezalel.Library.delete_conversation/1`):
  the conversation is off the shelf until it's purged or put back.
  `pushback` is its Pushback switch (`Bezalel.Library.put_pushback/2`).
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "conversations" do
    field :name, :string
    field :kicker, :string
    field :kind, :string
    field :session_id, :string
    field :session_file, :string
    field :message_count, :integer, default: 0
    field :deleted_at, :utc_datetime_usec
    field :pushback, :boolean, default: false
    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(conversation, attrs) do
    conversation
    |> cast(attrs, [:name, :kicker, :kind])
    |> validate_required([:name, :kicker, :kind])
  end
end
