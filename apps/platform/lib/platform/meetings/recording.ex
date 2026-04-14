defmodule Platform.Meetings.Recording do
  @moduledoc """
  Schema for a meeting recording created via LiveKit Egress.

  Lifecycle:
    starting → active → processing → completed | failed

  - `starting`    — egress requested, waiting for LiveKit confirmation
  - `active`      — egress is actively recording
  - `processing`  — egress ended, file being finalized
  - `completed`   — file available for playback
  - `failed`      — egress failed or was cancelled
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(starting active processing completed failed)

  schema "meeting_recordings" do
    field(:egress_id, :string)
    field(:status, :string, default: "starting")
    field(:file_path, :string)
    field(:file_size, :integer)
    field(:duration_seconds, :integer)
    field(:content_type, :string, default: "video/webm")
    field(:started_at, :utc_datetime_usec)
    field(:ended_at, :utc_datetime_usec)
    field(:metadata, :map, default: %{})

    belongs_to(:room, Platform.Meetings.Room)
    belongs_to(:space, Platform.Chat.Space, foreign_key: :space_id)
    belongs_to(:started_by_user, Platform.Accounts.User, foreign_key: :started_by)

    timestamps(type: :utc_datetime_usec)
  end

  @required ~w(room_id)a
  @optional ~w(space_id egress_id status file_path file_size duration_seconds content_type started_at ended_at started_by metadata)a

  def changeset(recording, attrs) do
    recording
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:room_id)
    |> foreign_key_constraint(:space_id)
    |> foreign_key_constraint(:started_by)
    |> unique_constraint(:egress_id)
  end
end
