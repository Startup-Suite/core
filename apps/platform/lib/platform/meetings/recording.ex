defmodule Platform.Meetings.Recording do
  @moduledoc "Schema for a meeting recording tracked via LiveKit Egress."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  schema "meeting_recordings" do
    field(:egress_id, :string)
    field(:status, :string, default: "pending")
    field(:format, :string, default: "mp4")
    field(:duration_seconds, :integer)
    field(:file_url, :string)
    field(:file_size_bytes, :integer)
    field(:started_by, :string)
    field(:started_at, :utc_datetime_usec)
    field(:ended_at, :utc_datetime_usec)
    field(:metadata, :map, default: %{})

    belongs_to(:room, Platform.Meetings.Room)

    timestamps(type: :utc_datetime_usec)
  end

  @required ~w(room_id status)a
  @optional ~w(egress_id format duration_seconds file_url file_size_bytes started_by started_at ended_at metadata)a

  def changeset(recording, attrs) do
    recording
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:status, ~w(pending recording completed failed))
    |> foreign_key_constraint(:room_id)
  end
end
