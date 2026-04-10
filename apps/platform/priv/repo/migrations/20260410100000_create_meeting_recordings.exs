defmodule Platform.Repo.Migrations.CreateMeetingRecordings do
  use Ecto.Migration

  def change do
    create table(:meeting_recordings, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:room_id, references(:meeting_rooms, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:egress_id, :string)
      add(:status, :string, null: false, default: "pending")
      add(:file_path, :string)
      add(:file_url, :string)
      add(:duration_seconds, :integer)
      add(:file_size_bytes, :bigint)
      add(:format, :string, default: "mp4")
      add(:started_at, :utc_datetime_usec)
      add(:ended_at, :utc_datetime_usec)
      add(:started_by, :string)
      add(:metadata, :map, default: %{})

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:meeting_recordings, [:room_id]))
    create(index(:meeting_recordings, [:egress_id]))
    create(index(:meeting_recordings, [:status]))

    # For listing recordings by space — join through meeting_rooms
    create(
      index(:meeting_recordings, [:room_id, :started_at],
        name: :meeting_recordings_room_started_idx
      )
    )
  end
end
