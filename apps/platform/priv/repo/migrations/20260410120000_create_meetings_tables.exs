defmodule Platform.Repo.Migrations.CreateMeetingsTables do
  use Ecto.Migration

  def change do
    create table(:meeting_rooms, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:space_id, references(:chat_spaces, type: :binary_id, on_delete: :delete_all))
      add(:livekit_room_name, :string, null: false)
      add(:status, :string, null: false, default: "idle")
      add(:config, :map, default: %{})

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:meeting_rooms, [:livekit_room_name]))
    create(unique_index(:meeting_rooms, [:space_id]))
    create(index(:meeting_rooms, [:status]))

    create table(:meeting_participants, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:room_id, references(:meeting_rooms, type: :uuid, on_delete: :delete_all), null: false)
      add(:user_id, references(:users, type: :binary_id, on_delete: :nilify_all))
      add(:agent_id, references(:agents, type: :binary_id, on_delete: :nilify_all))
      add(:identity, :string, null: false)
      add(:display_name, :string)
      add(:joined_at, :utc_datetime_usec, null: false)
      add(:left_at, :utc_datetime_usec)
      add(:metadata, :map, default: %{})

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:meeting_participants, [:room_id]))
    create(index(:meeting_participants, [:user_id]))
    create(index(:meeting_participants, [:agent_id]))
    create(index(:meeting_participants, [:room_id, :identity, :left_at]))

    create table(:meeting_recordings, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:room_id, references(:meeting_rooms, type: :uuid, on_delete: :delete_all), null: false)
      add(:egress_id, :string)
      add(:status, :string, null: false, default: "pending")
      add(:format, :string, default: "mp4")
      add(:duration_seconds, :integer)
      add(:file_url, :string)
      add(:file_size_bytes, :bigint)
      add(:started_by, :string)
      add(:started_at, :utc_datetime_usec)
      add(:ended_at, :utc_datetime_usec)
      add(:metadata, :map, default: %{})

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:meeting_recordings, [:room_id]))
    create(index(:meeting_recordings, [:egress_id]))
    create(index(:meeting_recordings, [:status]))
  end
end
