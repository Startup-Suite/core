defmodule Platform.Repo.Migrations.CreateOrgContextTables do
  use Ecto.Migration

  def change do
    create table(:org_context_files, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :workspace_id, :binary_id
      add :file_key, :text, null: false
      add :content, :text, null: false, default: ""
      add :version, :integer, null: false, default: 1
      add :updated_by, :binary_id
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(
             :org_context_files,
             ["coalesce(workspace_id, '00000000-0000-0000-0000-000000000000'::uuid)", :file_key],
             name: :org_context_files_unique_key
           )

    create table(:org_memory_entries, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :workspace_id, :binary_id
      add :memory_type, :string, null: false
      add :date, :date
      add :content, :text, null: false
      add :authored_by, :binary_id
      add :metadata, :map, default: %{}
      add :inserted_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create index(:org_memory_entries, [:workspace_id, :date],
             name: :org_memory_entries_workspace_date
           )

    create index(:org_memory_entries, [:workspace_id, :memory_type])
  end
end
