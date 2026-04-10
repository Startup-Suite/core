defmodule Platform.Org.ContextFile do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @valid_file_keys ~w(
    ORG_IDENTITY.md
    ORG_MEMORY.md
    ORG_AGENTS.md
    ORG_DIRECTORY.md
  )

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
    |> validate_required([:file_key])
    |> validate_format(:file_key, ~r/^[A-Z][A-Z0-9_]*\.md$/,
      message: "must be UPPER_CASE.md format"
    )
    |> unique_constraint(:file_key, name: :org_context_files_workspace_id_file_key_index)
  end

  def valid_file_keys, do: @valid_file_keys
end
