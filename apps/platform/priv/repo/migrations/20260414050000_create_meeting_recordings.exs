defmodule Platform.Repo.Migrations.CreateMeetingRecordings do
  use Ecto.Migration

  def change do
    create table(:meeting_recordings, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:room_id, :uuid, null: false)
      add(:space_id, :uuid)
      add(:started_by_id, references(:users, type: :uuid, on_delete: :nothing))
      add(:status, :string, null: false, default: "recording")
      add(:duration, :integer)
      add(:file_url, :text)
      add(:file_size, :integer)
      add(:egress_id, :string)

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:meeting_recordings, [:room_id]))
    create(index(:meeting_recordings, [:space_id]))
    create(index(:meeting_recordings, [:status]))
    create(index(:meeting_recordings, [:egress_id]))
  end
end
