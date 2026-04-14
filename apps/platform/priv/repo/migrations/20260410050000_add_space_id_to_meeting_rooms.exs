defmodule Platform.Repo.Migrations.AddSpaceIdToMeetingRooms do
  use Ecto.Migration

  def change do
    alter table(:meeting_rooms) do
      add(:space_id, references(:chat_spaces, type: :binary_id, on_delete: :delete_all))
    end

    create(index(:meeting_rooms, [:space_id]))
  end
end
