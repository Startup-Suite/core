defmodule Platform.Repo.Migrations.CreateMeetingRoomsAndParticipants do
  use Ecto.Migration

  def change do
    create table(:meeting_rooms, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:livekit_room_name, :string, null: false)
      add(:status, :string, null: false, default: "idle")
      add(:metadata, :map, default: %{})

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:meeting_rooms, [:livekit_room_name]))
    create(index(:meeting_rooms, [:status]))

    create table(:meeting_participants, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:room_id, references(:meeting_rooms, type: :uuid, on_delete: :delete_all), null: false)
      add(:identity, :string, null: false)
      add(:name, :string)
      add(:joined_at, :utc_datetime_usec, null: false)
      add(:left_at, :utc_datetime_usec)
      add(:metadata, :map, default: %{})

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:meeting_participants, [:room_id]))
    create(index(:meeting_participants, [:identity]))
    create(index(:meeting_participants, [:room_id, :identity, :left_at]))
  end
end
