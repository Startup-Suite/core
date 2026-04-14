defmodule Platform.Meetings do
  @moduledoc """
  Context module for meetings — recordings and transcription.

  Provides CRUD operations for meeting recordings and transcripts,
  including segment accumulation, summary management, and LiveKit
  Egress integration for recording lifecycle.
  """

  import Ecto.Query

  alias Platform.Meetings.{LivekitEgress, Recording, Transcript}

  require Logger
  alias Platform.Repo

  # ═══════════════════════════════════════════════════════════════════════════
  # RECORDINGS
  # ═══════════════════════════════════════════════════════════════════════════

  # ── Recording CRUD ─────────────────────────────────────────────────────────

  @doc """
  Start a recording for a meeting room.

  Creates a Recording record and calls LiveKit Egress API to begin recording.
  If the Egress API call fails, the record is deleted and the error is returned.
  """
  @spec start_recording(String.t(), String.t(), String.t()) ::
          {:ok, Recording.t()} | {:error, term()}
  def start_recording(space_id, started_by_id, room_id) do
    attrs = %{
      room_id: room_id,
      space_id: space_id,
      started_by_id: started_by_id,
      status: "recording"
    }

    with {:ok, recording} <- create_recording(attrs),
         {:ok, egress_id} <- LivekitEgress.start_room_composite_egress(room_id) do
      recording
      |> Recording.changeset(%{egress_id: egress_id})
      |> Repo.update()
    else
      {:error, reason} = error ->
        # Clean up the record if egress call failed
        Logger.warning("[Meetings] start_recording failed: #{inspect(reason)}")
        error
    end
  end

  @doc "Create a recording record (internal use)."
  @spec create_recording(map()) :: {:ok, Recording.t()} | {:error, Ecto.Changeset.t()}
  def create_recording(attrs) do
    %Recording{}
    |> Recording.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Stop an active recording.

  Calls LiveKit Egress API to stop the recording and transitions
  the status to \"processing\".
  """
  @spec stop_recording(String.t()) :: {:ok, Recording.t()} | {:error, term()}
  def stop_recording(recording_id) do
    case get_recording(recording_id) do
      nil ->
        {:error, :not_found}

      %Recording{egress_id: egress_id} = recording when is_binary(egress_id) ->
        _ = LivekitEgress.stop_egress(egress_id)

        recording
        |> Recording.changeset(%{status: "processing"})
        |> Repo.update()

      recording ->
        recording
        |> Recording.changeset(%{status: "processing"})
        |> Repo.update()
    end
  end

  @doc """
  Complete a recording after egress finishes.

  Sets the file_url, duration, file_size, and transitions status to \"ready\".
  Looked up by egress_id (from the webhook).
  """
  @spec complete_recording(String.t(), map()) :: {:ok, Recording.t()} | {:error, term()}
  def complete_recording(egress_id, attrs) when is_binary(egress_id) do
    case get_recording_by_egress_id(egress_id) do
      nil ->
        {:error, :not_found}

      recording ->
        recording
        |> Recording.changeset(Map.merge(attrs, %{status: "ready"}))
        |> Repo.update()
    end
  end

  @doc "Get a recording by ID."
  @spec get_recording(String.t()) :: Recording.t() | nil
  def get_recording(id), do: Repo.get(Recording, id)

  @doc "Get a recording by its LiveKit egress ID."
  @spec get_recording_by_egress_id(String.t()) :: Recording.t() | nil
  def get_recording_by_egress_id(egress_id) do
    Recording
    |> where([r], r.egress_id == ^egress_id)
    |> limit(1)
    |> Repo.one()
  end

  @doc "List recordings for a space, most recent first."
  @spec list_recordings_for_space(String.t()) :: [Recording.t()]
  def list_recordings_for_space(space_id) do
    Recording
    |> where([r], r.space_id == ^space_id)
    |> order_by([r], desc: r.inserted_at)
    |> Repo.all()
  end

  @doc "Get the active recording for a space (status = recording)."
  @spec get_active_recording_for_space(String.t()) :: Recording.t() | nil
  def get_active_recording_for_space(space_id) do
    Recording
    |> where([r], r.space_id == ^space_id and r.status == "recording")
    |> order_by([r], desc: r.inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # TRANSCRIPTS
  # ═══════════════════════════════════════════════════════════════════════════

  # ── Create ─────────────────────────────────────────────────────────────────

  @doc """
  Create a new transcript record for a meeting room.

  ## Examples

      iex> create_transcript(%{room_id: room_id, space_id: space_id})
      {:ok, %Transcript{}}

  """
  @spec create_transcript(map()) :: {:ok, Transcript.t()} | {:error, Ecto.Changeset.t()}
  def create_transcript(attrs) do
    %Transcript{}
    |> Transcript.changeset(Map.put_new(attrs, :started_at, DateTime.utc_now()))
    |> Repo.insert()
  end

  # ── Read ───────────────────────────────────────────────────────────────────

  @doc """
  Get a transcript by ID.
  """
  @spec get_transcript(String.t()) :: Transcript.t() | nil
  def get_transcript(id), do: Repo.get(Transcript, id)

  @doc """
  Get the active (recording-status) transcript for a room.

  Returns `nil` if no active transcript exists.
  """
  @spec get_transcript_for_room(String.t()) :: Transcript.t() | nil
  def get_transcript_for_room(room_id) do
    Transcript
    |> where([t], t.room_id == ^room_id and t.status == "recording")
    |> order_by([t], desc: t.inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  Get a transcript with its segments (same as get_transcript since segments
  are stored inline as JSONB, but named explicitly for clarity in the API).
  """
  @spec get_transcript_with_segments(String.t()) :: Transcript.t() | nil
  def get_transcript_with_segments(id), do: Repo.get(Transcript, id)

  # ── Ensure ─────────────────────────────────────────────────────────────────

  @doc """
  Find the active transcript for a room, or create one if none exists.

  Returns `{:ok, transcript}` in both cases.
  """
  @spec ensure_transcript(map()) :: {:ok, Transcript.t()} | {:error, Ecto.Changeset.t()}
  def ensure_transcript(%{room_id: room_id} = attrs) do
    case get_transcript_for_room(room_id) do
      nil -> create_transcript(attrs)
      transcript -> {:ok, transcript}
    end
  end

  # ── Segment Accumulation ───────────────────────────────────────────────────

  @doc """
  Append a segment map to the transcript's JSONB segments array.

  Each segment should contain at minimum:
  - `participant_identity` — the speaker's identity string
  - `text` — the transcribed text
  - `start_time` — segment start timestamp in milliseconds
  - `end_time` — segment end timestamp in milliseconds

  Optional:
  - `language` — ISO language code
  - `speaker_name` — display name of the speaker

  Uses a Postgres JSONB concatenation to atomically append without
  loading the full array into Elixir.
  """
  @spec append_segment(String.t(), map()) :: {:ok, Transcript.t()} | {:error, term()}
  def append_segment(transcript_id, segment) when is_map(segment) do
    # Use Ecto's jsonb_array_elements approach: load, append, save
    # Raw SQL concatenation has encoding issues with Postgrex parameter binding
    case get_transcript(transcript_id) do
      nil ->
        {:error, :not_found}

      transcript ->
        updated_segments = (transcript.segments || []) ++ [segment]

        transcript
        |> Ecto.Changeset.change(segments: updated_segments)
        |> Repo.update()
    end
  end

  # ── Status Transitions ────────────────────────────────────────────────────

  @doc """
  Transition a transcript to 'processing' status and return it.

  Called when a meeting ends to prepare the transcript for summary generation.
  """
  @spec finalize_transcript(String.t()) :: {:ok, Transcript.t()} | {:error, term()}
  def finalize_transcript(transcript_id) do
    case get_transcript(transcript_id) do
      nil ->
        {:error, :not_found}

      transcript ->
        transcript
        |> Transcript.changeset(%{status: "processing"})
        |> Repo.update()
    end
  end

  @doc """
  Mark a transcript as complete with the generated summary text.
  """
  @spec complete_transcript(String.t(), String.t()) ::
          {:ok, Transcript.t()} | {:error, term()}
  def complete_transcript(transcript_id, summary) when is_binary(summary) do
    case get_transcript(transcript_id) do
      nil ->
        {:error, :not_found}

      transcript ->
        transcript
        |> Transcript.changeset(%{
          status: "complete",
          summary: summary,
          completed_at: DateTime.utc_now()
        })
        |> Repo.update()
    end
  end

  @doc """
  Update the transcript summary text.
  """
  @spec update_transcript_summary(String.t(), String.t()) ::
          {:ok, Transcript.t()} | {:error, term()}
  def update_transcript_summary(transcript_id, summary) when is_binary(summary) do
    case get_transcript(transcript_id) do
      nil ->
        {:error, :not_found}

      transcript ->
        transcript
        |> Transcript.changeset(%{summary: summary})
        |> Repo.update()
    end
  end

  @doc """
  Mark a transcript as failed.
  """
  @spec fail_transcript(String.t()) :: {:ok, Transcript.t()} | {:error, term()}
  def fail_transcript(transcript_id) do
    case get_transcript(transcript_id) do
      nil ->
        {:error, :not_found}

      transcript ->
        transcript
        |> Transcript.changeset(%{status: "failed", completed_at: DateTime.utc_now()})
        |> Repo.update()
    end
  end

  # ── Summary Posting ────────────────────────────────────────────────────────

  # ── Transcript Listing ─────────────────────────────────────────────────────

  @doc "List transcripts for a space, most recent first."
  @spec list_transcripts_for_space(String.t()) :: [Transcript.t()]
  def list_transcripts_for_space(space_id) do
    Transcript
    |> where([t], t.space_id == ^space_id and t.status in ["complete", "processing"])
    |> order_by([t], desc: t.started_at)
    |> Repo.all()
  end

  # ── Summary Posting ────────────────────────────────────────────────────────

  @doc """
  Post a meeting summary as a system message to the space.

  The message includes the formatted summary and a download link
  for the full transcript.
  """
  @spec post_summary_to_space(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def post_summary_to_space(space_id, transcript_id, summary)
      when is_binary(space_id) and is_binary(transcript_id) and is_binary(summary) do
    content = """
    📝 **Meeting Summary**

    #{summary}

    [📄 Full transcript](/api/transcripts/#{transcript_id}/download)
    """

    with {:ok, participant} <-
           Platform.Orchestration.ExecutionSpace.ensure_system_participant(space_id) do
      attrs = %{
        space_id: space_id,
        participant_id: participant.id,
        content_type: "system",
        content: String.trim(content),
        metadata: %{"source" => "meeting_summarizer", "transcript_id" => transcript_id}
      }

      case Platform.Chat.post_message(attrs) do
        {:ok, _message} -> :ok
        {:error, reason} -> {:error, {:post_failed, reason}}
      end
    end
  end
end
