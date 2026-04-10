defmodule Platform.Meetings.Recording do
  @moduledoc """
  Schema for a meeting recording created via LiveKit Egress.

  Lifecycle:
    pending → recording → completed | failed

  - `pending`   — egress requested but not yet confirmed started
  - `recording` — egress is actively recording
  - `completed` — egress finished, file available
  - `failed`    — egress failed or was cancelled
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(pending recording completed failed)

  schema "meeting_recordings" do
    field(:egress_id, :string)
    field(:status, :string, default: "pending")
    field(:file_path, :string)
    field(:file_url, :string)
    field(:duration_seconds, :integer)
    field(:file_size_bytes, :integer)
    field(:format, :string, default: "mp4")
    field(:started_at, :utc_datetime_usec)
    field(:ended_at, :utc_datetime_usec)
    field(:started_by, :string)
    field(:metadata, :map, default: %{})

    belongs_to(:room, Platform.Meetings.Room)

    timestamps(type: :utc_datetime_usec)
  end

  @required ~w(room_id)a
  @optional ~w(egress_id status file_path file_url duration_seconds file_size_bytes format started_at ended_at started_by metadata)a

  def changeset(recording, attrs) do
    recording
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:room_id)
  end
end
