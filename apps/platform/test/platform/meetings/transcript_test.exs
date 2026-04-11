defmodule Platform.Meetings.TranscriptTest do
  @moduledoc false
  use Platform.DataCase, async: true

  alias Platform.Meetings
  alias Platform.Meetings.Transcript

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp create_room(attrs \\ %{}) do
    room_name = "room-#{System.unique_integer([:positive])}"
    space_id = Map.get(attrs, :space_id, Ecto.UUID.generate())

    {:ok, room} =
      Meetings.find_or_create_room(room_name)

    # Set space_id on the room
    room
    |> Ecto.Changeset.change(%{space_id: space_id})
    |> Repo.update!()
  end

  defp sample_segment(overrides \\ %{}) do
    Map.merge(
      %{
        "speaker_identity" => "user-alice",
        "speaker_name" => "Alice",
        "text" => "Hello, this is a test.",
        "timestamp_ms" => 5000,
        "language" => "en",
        "is_final" => true
      },
      overrides
    )
  end

  # ── create_transcript/1 ─────────────────────────────────────────────────

  describe "create_transcript/1" do
    test "creates a transcript with valid attrs" do
      room = create_room()

      assert {:ok, %Transcript{} = transcript} =
               Meetings.create_transcript(%{
                 room_id: room.id,
                 space_id: room.space_id,
                 status: "recording",
                 started_at: DateTime.utc_now()
               })

      assert transcript.room_id == room.id
      assert transcript.space_id == room.space_id
      assert transcript.status == "recording"
      assert transcript.segments == []
    end

    test "requires room_id" do
      assert {:error, changeset} = Meetings.create_transcript(%{status: "recording"})
      assert %{room_id: ["can't be blank"]} = errors_on(changeset)
    end

    test "validates status inclusion" do
      room = create_room()

      assert {:error, changeset} =
               Meetings.create_transcript(%{room_id: room.id, status: "invalid"})

      assert %{status: ["is invalid"]} = errors_on(changeset)
    end
  end

  # ── ensure_transcript/1 ─────────────────────────────────────────────────

  describe "ensure_transcript/1" do
    test "creates a new transcript when none exists" do
      room = create_room()

      assert {:ok, %Transcript{} = transcript} = Meetings.ensure_transcript(room)
      assert transcript.room_id == room.id
      assert transcript.status == "recording"
    end

    test "returns existing active transcript" do
      room = create_room()

      {:ok, original} = Meetings.ensure_transcript(room)
      {:ok, found} = Meetings.ensure_transcript(room)

      assert original.id == found.id
    end

    test "creates new transcript if existing one is not recording" do
      room = create_room()

      {:ok, original} = Meetings.ensure_transcript(room)
      {:ok, _} = Meetings.finalize_transcript(original)

      {:ok, new_transcript} = Meetings.ensure_transcript(room)
      assert new_transcript.id != original.id
      assert new_transcript.status == "recording"
    end
  end

  # ── get_transcript/1 ────────────────────────────────────────────────────

  describe "get_transcript/1" do
    test "returns transcript by ID" do
      room = create_room()
      {:ok, transcript} = Meetings.ensure_transcript(room)

      assert found = Meetings.get_transcript(transcript.id)
      assert found.id == transcript.id
    end

    test "returns nil for unknown ID" do
      assert Meetings.get_transcript(Ecto.UUID.generate()) == nil
    end
  end

  # ── get_transcript_for_room/1 ───────────────────────────────────────────

  describe "get_transcript_for_room/1" do
    test "returns the most recent transcript for a room" do
      room = create_room()
      {:ok, transcript} = Meetings.ensure_transcript(room)

      assert found = Meetings.get_transcript_for_room(room.id)
      assert found.id == transcript.id
    end

    test "returns nil when no transcripts exist" do
      room = create_room()
      assert Meetings.get_transcript_for_room(room.id) == nil
    end
  end

  # ── append_segment/2 ────────────────────────────────────────────────────

  describe "append_segment/2" do
    test "appends a segment to the transcript" do
      room = create_room()
      {:ok, transcript} = Meetings.ensure_transcript(room)

      segment = sample_segment()
      assert {:ok, updated} = Meetings.append_segment(transcript, segment)

      assert length(updated.segments) == 1
      assert hd(updated.segments)["text"] == "Hello, this is a test."
    end

    test "appends multiple segments in order" do
      room = create_room()
      {:ok, transcript} = Meetings.ensure_transcript(room)

      {:ok, _} = Meetings.append_segment(transcript, sample_segment(%{"text" => "First"}))
      {:ok, updated} = Meetings.append_segment(transcript, sample_segment(%{"text" => "Second"}))

      assert length(updated.segments) == 2
      texts = Enum.map(updated.segments, & &1["text"])
      assert texts == ["First", "Second"]
    end
  end

  # ── finalize_transcript/1 ───────────────────────────────────────────────

  describe "finalize_transcript/1" do
    test "transitions status from recording to processing" do
      room = create_room()
      {:ok, transcript} = Meetings.ensure_transcript(room)

      assert {:ok, finalized} = Meetings.finalize_transcript(transcript)
      assert finalized.status == "processing"
    end
  end

  # ── complete_transcript/2 ───────────────────────────────────────────────

  describe "complete_transcript/2" do
    test "sets status to complete with summary" do
      room = create_room()
      {:ok, transcript} = Meetings.ensure_transcript(room)
      {:ok, finalized} = Meetings.finalize_transcript(transcript)

      summary = "## Meeting Summary\n- Discussed testing\n- Decided to ship"

      assert {:ok, completed} = Meetings.complete_transcript(finalized, summary)
      assert completed.status == "complete"
      assert completed.summary == summary
      assert completed.completed_at != nil
    end
  end

  # ── fail_transcript/2 ──────────────────────────────────────────────────

  describe "fail_transcript/2" do
    test "sets status to failed" do
      room = create_room()
      {:ok, transcript} = Meetings.ensure_transcript(room)
      {:ok, finalized} = Meetings.finalize_transcript(transcript)

      assert {:ok, failed} = Meetings.fail_transcript(finalized, "LLM timeout")
      assert failed.status == "failed"
      assert failed.completed_at != nil
    end
  end

  # ── format_transcript_text/1 ───────────────────────────────────────────

  describe "format_transcript_text/1" do
    test "formats segments as readable text" do
      transcript = %Transcript{
        segments: [
          %{
            "speaker_name" => "Alice",
            "text" => "Hello everyone",
            "timestamp_ms" => 0,
            "is_final" => true
          },
          %{
            "speaker_name" => "Bob",
            "text" => "Hi Alice",
            "timestamp_ms" => 5000,
            "is_final" => true
          }
        ]
      }

      text = Meetings.format_transcript_text(transcript)
      assert text =~ "[00:00:00] Alice: Hello everyone"
      assert text =~ "[00:00:05] Bob: Hi Alice"
    end

    test "filters out non-final segments" do
      transcript = %Transcript{
        segments: [
          %{"speaker_name" => "Alice", "text" => "Hel", "timestamp_ms" => 0, "is_final" => false},
          %{
            "speaker_name" => "Alice",
            "text" => "Hello",
            "timestamp_ms" => 0,
            "is_final" => true
          }
        ]
      }

      text = Meetings.format_transcript_text(transcript)
      refute text =~ "Hel\n"
      assert text =~ "Hello"
    end

    test "handles empty segments" do
      transcript = %Transcript{segments: []}
      assert Meetings.format_transcript_text(transcript) == ""
    end

    test "formats hours correctly" do
      transcript = %Transcript{
        segments: [
          %{
            "speaker_name" => "Alice",
            "text" => "Still going",
            "timestamp_ms" => 3_661_000,
            "is_final" => true
          }
        ]
      }

      text = Meetings.format_transcript_text(transcript)
      assert text =~ "[01:01:01]"
    end

    test "uses speaker_identity as fallback" do
      transcript = %Transcript{
        segments: [
          %{
            "speaker_identity" => "user-123",
            "text" => "Hello",
            "timestamp_ms" => 0,
            "is_final" => true
          }
        ]
      }

      text = Meetings.format_transcript_text(transcript)
      assert text =~ "user-123: Hello"
    end
  end

  # ── list_transcripts_for_space/1 ───────────────────────────────────────

  describe "list_transcripts_for_space/1" do
    test "returns transcripts for a space" do
      room = create_room()
      {:ok, _transcript} = Meetings.ensure_transcript(room)

      transcripts = Meetings.list_transcripts_for_space(room.space_id)
      assert length(transcripts) == 1
    end

    test "returns empty list for space with no transcripts" do
      assert Meetings.list_transcripts_for_space(Ecto.UUID.generate()) == []
    end
  end
end
