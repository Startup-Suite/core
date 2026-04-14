defmodule Platform.Repo.Migrations.CreateOrgMemoryEntries do
  use Ecto.Migration

  def change do
    create table(:org_memory_entries) do
      add(:workspace_id, :binary_id)
      add(:memory_type, :text, null: false, default: "daily")
      add(:date, :date, null: false)
      add(:content, :text, null: false)
      add(:authored_by, :binary_id)
      add(:metadata, :map, default: %{})

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(index(:org_memory_entries, [:workspace_id]))
    create(index(:org_memory_entries, [:date]))
    create(index(:org_memory_entries, [:memory_type]))
    create(index(:org_memory_entries, [:workspace_id, :date]))
  end
end
