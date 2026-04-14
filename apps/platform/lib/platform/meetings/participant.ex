defmodule Platform.Meetings.Participant do
  @moduledoc "Schema for a meeting participant tracked via LiveKit webhooks."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  schema "meeting_participants" do
    field(:identity, :string)
    field(:name, :string)
    field(:joined_at, :utc_datetime_usec)
    field(:left_at, :utc_datetime_usec)
    field(:metadata, :map, default: %{})

    belongs_to(:room, Platform.Meetings.Room)

    timestamps(type: :utc_datetime_usec)
  end

  @required ~w(room_id identity joined_at)a
  @optional ~w(name left_at metadata)a

  def changeset(participant, attrs) do
    participant
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> foreign_key_constraint(:room_id)
  end
end
