defmodule Platform.Meetings.Transcript do
  @moduledoc """
  Schema for a meeting transcript.

  Stores per-meeting transcription data as a JSONB array of segments.
  Each segment contains speaker identity, speaker name, text, and a
  timestamp in milliseconds relative to the meeting start.

  ## Status lifecycle

      recording → processing → complete
                            ↘ failed

  - `recording` — actively receiving segments from LiveKit
  - `processing` — meeting ended, generating LLM summary
  - `complete` — summary generated and posted to space
  - `failed` — summary generation failed (transcript still available)
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(recording processing complete failed)

  schema "meeting_transcripts" do
    field(:space_id, :binary_id)
    field(:segments, {:array, :map}, default: [])
    field(:summary, :string)
    field(:status, :string, default: "recording")
    field(:language, :string, default: "en")
    field(:started_at, :utc_datetime_usec)
    field(:completed_at, :utc_datetime_usec)

    belongs_to(:room, Platform.Meetings.Room)

    timestamps(type: :utc_datetime_usec)
  end

  @required ~w(room_id)a
  @optional ~w(space_id segments summary status language started_at completed_at)a

  def changeset(transcript, attrs) do
    transcript
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:room_id)
  end
end
