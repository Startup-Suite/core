defmodule Platform.Meetings.Recording do
  @moduledoc """
  Schema for meeting recordings.

  Each recording belongs to a meeting room (via LiveKit) and stores the
  egress output file metadata once the recording completes.

  Status lifecycle: recording → processing → ready → failed
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(recording processing ready failed)

  schema "meeting_recordings" do
    field(:room_id, :binary_id)
    field(:space_id, :binary_id)
    field(:started_by_id, :binary_id)
    field(:status, :string, default: "recording")
    field(:duration, :integer)
    field(:file_url, :string)
    field(:file_size, :integer)
    field(:egress_id, :string)

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields ~w(room_id)a
  @optional_fields ~w(space_id started_by_id status duration file_url file_size egress_id)a

  @doc "Changeset for creating or updating a recording."
  def changeset(recording, attrs) do
    recording
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:status, @statuses)
  end

  @doc "Returns the list of valid status values."
  def statuses, do: @statuses
end
