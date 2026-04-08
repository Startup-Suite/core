defmodule Platform.Org.ContextFile do
  @moduledoc """
  Schema for the `org_context_files` table.

  Stores org-level context files (ORG_IDENTITY.md, ORG_MEMORY.md, etc.)
  scoped to a workspace. Each file is versioned and identified by a key.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  schema "org_context_files" do
    field(:workspace_id, :binary_id)
    field(:file_key, :string)
    field(:content, :string, default: "")
    field(:version, :integer, default: 1)
    field(:updated_by, :binary_id)
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(context_file, attrs) do
    context_file
    |> cast(attrs, [:workspace_id, :file_key, :content, :version, :updated_by])
    |> validate_required([:file_key, :content])
    |> unique_constraint(:file_key,
      name: :org_context_files_unique_key,
      message: "file key already exists for this workspace"
    )
  end
end
