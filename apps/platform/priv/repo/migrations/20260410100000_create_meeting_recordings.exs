defmodule Platform.Repo.Migrations.CreateMeetingRecordings do
  use Ecto.Migration

  def change do
    create table(:meeting_recordings, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:room_id, references(:meeting_rooms, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:space_id, references(:chat_spaces, type: :binary_id, on_delete: :delete_all))

      add(:egress_id, :string)
      add(:status, :string, null: false, default: "starting")
      add(:file_path, :string)
      add(:file_size, :bigint)
      add(:duration_seconds, :integer)
      add(:content_type, :string, default: "video/webm")
      add(:started_by, references(:users, type: :uuid, on_delete: :nilify_all))
      add(:started_at, :utc_datetime_usec)
      add(:ended_at, :utc_datetime_usec)
      add(:metadata, :map, default: %{})

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:meeting_recordings, [:room_id]))
    create(index(:meeting_recordings, [:space_id]))
    create(unique_index(:meeting_recordings, [:egress_id]))
    create(index(:meeting_recordings, [:status]))
  end
end
