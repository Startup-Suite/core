defmodule Platform.Repo.Migrations.CreateOrgContextFiles do
  use Ecto.Migration

  def change do
    create table(:org_context_files, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:workspace_id, :binary_id)
      add(:file_key, :text, null: false)
      add(:content, :text, null: false, default: "")
      add(:version, :integer, null: false, default: 1)
      add(:updated_by, :binary_id)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:org_context_files, [:workspace_id, :file_key]))
    create(index(:org_context_files, [:workspace_id]))
  end
end
