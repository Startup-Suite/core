defmodule Platform.Meetings.Room do
  @moduledoc "Schema for a LiveKit meeting room tied to a chat space."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  schema "meeting_rooms" do
    field(:space_id, :binary_id)
    field(:livekit_room_name, :string)
    field(:status, :string, default: "idle")
    field(:config, :map, default: %{})

    has_many(:participants, Platform.Meetings.Participant, foreign_key: :room_id)
    has_many(:recordings, Platform.Meetings.Recording, foreign_key: :room_id)

    timestamps(type: :utc_datetime_usec)
  end

  @required ~w(livekit_room_name)a
  @optional ~w(space_id status config)a

  def changeset(room, attrs) do
    room
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:status, ~w(idle active))
    |> unique_constraint(:livekit_room_name)
    |> unique_constraint(:space_id)
    |> foreign_key_constraint(:space_id)
  end
end
