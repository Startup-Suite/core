defmodule Platform.Org.MemoryEntry do
  use Ecto.Schema
  import Ecto.Changeset

  schema "org_memory_entries" do
    field(:workspace_id, :binary_id)
    field(:memory_type, :string, default: "daily")
    field(:date, :date)
    field(:content, :string)
    field(:authored_by, :binary_id)
    field(:metadata, :map, default: %{})

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [:workspace_id, :memory_type, :date, :content, :authored_by, :metadata])
    |> validate_required([:memory_type, :date, :content])
    |> validate_inclusion(:memory_type, ~w(daily long_term))
  end
end
