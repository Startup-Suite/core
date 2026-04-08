defmodule Platform.Org.MemoryEntry do
  @moduledoc """
  Schema for the `org_memory_entries` table.

  Uses a bigserial primary key for monotonic ordering.
  Supports daily and long_term memory types.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @foreign_key_type :binary_id
  @valid_memory_types ~w(daily long_term)

  schema "org_memory_entries" do
    field(:workspace_id, :binary_id)
    field(:memory_type, :string)
    field(:date, :date)
    field(:content, :string)
    field(:authored_by, :binary_id)
    field(:metadata, :map, default: %{})
    field(:inserted_at, :utc_datetime_usec, autogenerate: false)
  end

  def changeset(memory_entry, attrs) do
    memory_entry
    |> cast(attrs, [:workspace_id, :memory_type, :date, :content, :authored_by, :metadata])
    |> validate_required([:memory_type, :content])
    |> validate_inclusion(:memory_type, @valid_memory_types)
  end
end
