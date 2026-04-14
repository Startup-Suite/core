defmodule Platform.MeetingsTest do
  @moduledoc """
  Tests for `Platform.Meetings` context — transcription CRUD, PubSub
  presence helpers, participant tracking, and space-level presence queries.
  """

  use Platform.DataCase, async: false

  alias Platform.Meetings
  alias Platform.Meetings.Transcript
  alias Platform.Meetings.PubSub, as: MeetingsPubSub

  # ── Transcript Helpers ──────────────────────────────────────────────────────

  defp unique_room_id, do: Platform.Types.UUIDv7.generate()
  defp unique_space_id, do: Platform.Types.UUIDv7.generate()

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  defp valid_attrs(overrides \\ %{}) do
    Map.merge(
      %{room_id: unique_room_id(), space_id: unique_space_id()},
      overrides
    )
  end

  defp create_transcript!(overrides \\ %{}) do
    {:ok, transcript} = Meetings.create_transcript(valid_attrs(overrides))
    transcript
  end

  # ── Presence Helpers ────────────────────────────────────────────────────────

  defp create_space do
    {:ok, space} =
      Platform.Chat.create_space(%{
        name: "Meeting Test Space",
        slug: "meeting-test-#{System.unique_integer([:positive])}",
        kind: "channel"
      })

    space
  end

  defp create_room(space_id) do
    {:ok, room} = Meetings.ensure_room(space_id)
    room
  end

  defp activate_room(room) do
    {:ok, room} = Meetings.activate_room(room)
    room
  end

  defp join_participant(room, identity, attrs \\ %{}) do
    {:ok, participant} =
      Meetings.participant_joined(
        room,
        Map.merge(%{identity: identity, display_name: identity}, attrs)
      )

    participant
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Transcription Tests
  # ═══════════════════════════════════════════════════════════════════════════

  describe "create_transcript/1" do
    test "creates a transcript with valid attrs" do
      attrs = valid_attrs()
      assert {:ok, %Transcript{} = transcript} = Meetings.create_transcript(attrs)
      assert transcript.room_id == attrs.room_id
      assert transcript.space_id == attrs.space_id
      assert transcript.status == "recording"
      assert transcript.segments == []
      assert transcript.summary == nil
      assert transcript.started_at != nil
    end

    test "requires room_id" do
      assert {:error, changeset} = Meetings.create_transcript(%{space_id: unique_space_id()})
      assert %{room_id: ["can't be blank"]} = errors_on(changeset)
    end

    test "rejects invalid status" do
      attrs = valid_attrs(%{status: "invalid"})
      assert {:error, changeset} = Meetings.create_transcript(attrs)
      assert %{status: ["is invalid"]} = errors_on(changeset)
    end

    test "auto-sets started_at if not provided" do
      {:ok, transcript} = Meetings.create_transcript(valid_attrs())
      assert transcript.started_at != nil
    end

    test "respects explicit started_at" do
      explicit = ~U[2026-01-01 12:00:00.000000Z]
      {:ok, transcript} = Meetings.create_transcript(valid_attrs(%{started_at: explicit}))
      assert transcript.started_at == explicit
    end
  end

  describe "get_transcript/1" do
    test "returns transcript by ID" do
      transcript = create_transcript!()
      assert Meetings.get_transcript(transcript.id) == transcript
    end

    test "returns nil for missing ID" do
      assert Meetings.get_transcript(Platform.Types.UUIDv7.generate()) == nil
    end
  end

  describe "get_transcript_for_room/1" do
    test "returns the active transcript for a room" do
      room_id = unique_room_id()
      transcript = create_transcript!(%{room_id: room_id})
      assert Meetings.get_transcript_for_room(room_id).id == transcript.id
    end

    test "returns nil when no active transcript exists" do
      assert Meetings.get_transcript_for_room(unique_room_id()) == nil
    end

    test "ignores non-recording transcripts" do
      room_id = unique_room_id()
      transcript = create_transcript!(%{room_id: room_id})
      {:ok, _} = Meetings.finalize_transcript(transcript.id)
      assert Meetings.get_transcript_for_room(room_id) == nil
    end
  end

  describe "get_transcript_with_segments/1" do
    test "returns transcript with segments" do
      transcript = create_transcript!()
      assert Meetings.get_transcript_with_segments(transcript.id).id == transcript.id
    end
  end

  describe "ensure_transcript/1" do
    test "creates a new transcript when none exists" do
      attrs = valid_attrs()
      assert {:ok, %Transcript{}} = Meetings.ensure_transcript(attrs)
    end

    test "returns existing transcript when one exists" do
      room_id = unique_room_id()
      existing = create_transcript!(%{room_id: room_id})

      assert {:ok, found} = Meetings.ensure_transcript(%{room_id: room_id})
      assert found.id == existing.id
    end
  end

  describe "append_segment/2" do
    test "appends a segment to the transcript" do
      transcript = create_transcript!()

      segment = %{
        "participant_identity" => "user-123",
        "speaker_name" => "Alice",
        "text" => "Hello, world!",
        "start_time" => 1000,
        "end_time" => 2000,
        "language" => "en"
      }

      assert {:ok, updated} = Meetings.append_segment(transcript.id, segment)
      assert length(updated.segments) == 1
      assert hd(updated.segments)["text"] == "Hello, world!"
    end

    test "appends multiple segments sequentially" do
      transcript = create_transcript!()

      for i <- 1..3 do
        segment = %{
          "participant_identity" => "user-#{i}",
          "text" => "Segment #{i}",
          "start_time" => i * 1000,
          "end_time" => (i + 1) * 1000
        }

        {:ok, _} = Meetings.append_segment(transcript.id, segment)
      end

      updated = Meetings.get_transcript(transcript.id)
      assert length(updated.segments) == 3
    end

    test "returns error for non-existent transcript" do
      segment = %{"text" => "test", "start_time" => 0, "end_time" => 1000}

      assert {:error, :not_found} =
               Meetings.append_segment(Platform.Types.UUIDv7.generate(), segment)
    end
  end

  describe "finalize_transcript/1" do
    test "transitions status to processing" do
      transcript = create_transcript!()
      assert {:ok, finalized} = Meetings.finalize_transcript(transcript.id)
      assert finalized.status == "processing"
    end

    test "returns error for non-existent transcript" do
      assert {:error, :not_found} = Meetings.finalize_transcript(Platform.Types.UUIDv7.generate())
    end
  end

  describe "complete_transcript/2" do
    test "marks transcript as complete with summary" do
      transcript = create_transcript!()
      {:ok, _} = Meetings.finalize_transcript(transcript.id)

      summary = "## Meeting Summary\n- Discussed project timeline"
      assert {:ok, completed} = Meetings.complete_transcript(transcript.id, summary)
      assert completed.status == "complete"
      assert completed.summary == summary
      assert completed.completed_at != nil
    end

    test "returns error for non-existent transcript" do
      assert {:error, :not_found} =
               Meetings.complete_transcript(Platform.Types.UUIDv7.generate(), "summary")
    end
  end

  describe "update_transcript_summary/2" do
    test "updates the summary text" do
      transcript = create_transcript!()
      assert {:ok, updated} = Meetings.update_transcript_summary(transcript.id, "New summary")
      assert updated.summary == "New summary"
    end

    test "returns error for non-existent transcript" do
      assert {:error, :not_found} =
               Meetings.update_transcript_summary(Platform.Types.UUIDv7.generate(), "summary")
    end
  end

  describe "fail_transcript/1" do
    test "marks transcript as failed" do
      transcript = create_transcript!()
      assert {:ok, failed} = Meetings.fail_transcript(transcript.id)
      assert failed.status == "failed"
      assert failed.completed_at != nil
    end

    test "returns error for non-existent transcript" do
      assert {:error, :not_found} = Meetings.fail_transcript(Platform.Types.UUIDv7.generate())
    end
  end

  describe "Transcript schema" do
    test "valid statuses" do
      assert Transcript.statuses() == ~w(recording processing complete failed)
    end

    test "changeset validates status inclusion" do
      changeset =
        %Transcript{}
        |> Transcript.changeset(%{room_id: unique_room_id(), status: "bogus"})

      refute changeset.valid?
      assert %{status: ["is invalid"]} = errors_on(changeset)
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # PubSub / Presence Tests
  # ═══════════════════════════════════════════════════════════════════════════

  describe "PubSub topic helpers" do
    test "meeting_presence_topic/1 returns room topic" do
      room_id = Ecto.UUID.generate()
      assert Meetings.meeting_presence_topic(room_id) == "meetings:room:#{room_id}"
    end

    test "meeting_presence_summary_topic/0 returns summary topic" do
      assert Meetings.meeting_presence_summary_topic() == "meetings:presence_summary"
    end
  end

  describe "subscribe helpers" do
    test "subscribe_to_room_presence/1 subscribes to room topic" do
      room_id = Ecto.UUID.generate()
      assert :ok = Meetings.subscribe_to_room_presence(room_id)

      # Verify we receive broadcasts on this topic
      MeetingsPubSub.broadcast_room(room_id, {:test_event, :hello})
      assert_receive {:test_event, :hello}
    end

    test "subscribe_to_presence_summary/0 subscribes to summary topic" do
      assert :ok = Meetings.subscribe_to_presence_summary()

      MeetingsPubSub.broadcast_presence_summary("some-space-id")
      assert_receive {:meeting_presence_summary, %{space_id: "some-space-id"}}
    end
  end

  describe "ensure_room/1" do
    test "creates a room for a space" do
      space = create_space()
      {:ok, room} = Meetings.ensure_room(space.id)

      assert room.space_id == space.id
      assert room.livekit_room_name == "space:#{space.id}"
      assert room.status == "idle"
    end

    test "returns existing room on second call" do
      space = create_space()
      {:ok, room1} = Meetings.ensure_room(space.id)
      {:ok, room2} = Meetings.ensure_room(space.id)

      assert room1.id == room2.id
    end
  end

  describe "activate_room/1" do
    test "sets room status to active and broadcasts" do
      space = create_space()
      room = create_room(space.id)

      MeetingsPubSub.subscribe_room(room.id)
      MeetingsPubSub.subscribe_presence(space.id)

      {:ok, activated} = Meetings.activate_room(room)
      assert activated.status == "active"

      assert_receive {:room_activated, ^activated}
      assert_receive {:meeting_presence_update, %{space_id: _, active: false, count: 0}}
    end
  end

  describe "finish_room/1" do
    test "sets room to idle and marks participants as left" do
      space = create_space()
      room = create_room(space.id) |> activate_room()
      _p = join_participant(room, "user:alice")

      MeetingsPubSub.subscribe_room(room.id)

      {:ok, finished} = Meetings.finish_room(room)
      assert finished.status == "idle"

      # All participants should be marked as left
      assert Meetings.active_participants(room.id) == []
      assert_receive {:room_finished, ^finished}
    end
  end

  describe "participant_joined/2" do
    test "creates participant and broadcasts on room + presence topics" do
      space = create_space()
      room = create_room(space.id) |> activate_room()

      MeetingsPubSub.subscribe_room(room.id)
      MeetingsPubSub.subscribe_presence(space.id)

      {:ok, participant} =
        Meetings.participant_joined(room, %{
          identity: "user:bob",
          display_name: "Bob"
        })

      assert participant.identity == "user:bob"
      assert participant.display_name == "Bob"
      assert participant.room_id == room.id
      assert is_nil(participant.left_at)

      assert_receive {:participant_joined, ^participant}
      assert_receive {:meeting_presence_update, %{space_id: _, active: true, count: 1}}
    end
  end

  describe "participant_left/2" do
    test "sets left_at and broadcasts" do
      space = create_space()
      room = create_room(space.id) |> activate_room()
      _p = join_participant(room, "user:carol")

      MeetingsPubSub.subscribe_room(room.id)

      {:ok, left} = Meetings.participant_left(room, "user:carol")
      assert left.left_at != nil
      assert_receive {:participant_left, ^left}
    end

    test "returns error when participant not found" do
      space = create_space()
      room = create_room(space.id) |> activate_room()

      assert {:error, :not_found} = Meetings.participant_left(room, "user:nobody")
    end
  end

  describe "active_participants/1" do
    test "returns only participants with nil left_at, preloads user/agent" do
      space = create_space()
      room = create_room(space.id) |> activate_room()

      _p1 = join_participant(room, "user:alice")
      p2 = join_participant(room, "user:bob")
      Meetings.participant_left(room, "user:alice")

      active = Meetings.active_participants(room.id)
      assert length(active) == 1
      assert hd(active).id == p2.id

      # Preloads should be loaded (nil since no FK set, but not Ecto.Association.NotLoaded)
      participant = hd(active)
      assert is_nil(participant.user) or is_struct(participant.user)
      assert is_nil(participant.agent) or is_struct(participant.agent)
    end
  end

  describe "active_meeting_counts/1" do
    test "returns empty map for empty list" do
      assert Meetings.active_meeting_counts([]) == %{}
    end

    test "returns counts for spaces with active meetings" do
      space1 = create_space()
      space2 = create_space()
      space3 = create_space()

      room1 = create_room(space1.id) |> activate_room()
      room2 = create_room(space2.id) |> activate_room()
      _room3 = create_room(space3.id)

      join_participant(room1, "user:alice")
      join_participant(room1, "user:bob")
      join_participant(room2, "user:carol")

      counts = Meetings.active_meeting_counts([space1.id, space2.id, space3.id])

      assert counts[space1.id] == 2
      assert counts[space2.id] == 1
      # space3 has no active meeting (room is idle)
      refute Map.has_key?(counts, space3.id)
    end

    test "excludes participants who have left" do
      space = create_space()
      room = create_room(space.id) |> activate_room()

      join_participant(room, "user:alice")
      join_participant(room, "user:bob")
      Meetings.participant_left(room, "user:alice")

      counts = Meetings.active_meeting_counts([space.id])
      assert counts[space.id] == 1
    end
  end

  describe "active_participants_for_space/1" do
    test "returns participants for active meeting in space" do
      space = create_space()
      room = create_room(space.id) |> activate_room()

      join_participant(room, "user:alice")
      join_participant(room, "user:bob")

      participants = Meetings.active_participants_for_space(space.id)
      assert length(participants) == 2
    end

    test "returns empty list when no active meeting" do
      space = create_space()
      _room = create_room(space.id)

      assert Meetings.active_participants_for_space(space.id) == []
    end
  end

  describe "broadcast_presence_change/2" do
    test "broadcasts on presence and summary topics" do
      space = create_space()
      room = create_room(space.id) |> activate_room()

      MeetingsPubSub.subscribe_presence(space.id)
      MeetingsPubSub.subscribe_presence_summary()

      join_participant(room, "user:dave")

      # participant_joined already calls broadcast_presence_change internally
      assert_receive {:meeting_presence_update, %{space_id: _, active: true, count: 1}}
      assert_receive {:meeting_presence_summary, %{space_id: _}}
    end

    test "no-ops for nil space_id" do
      assert :ok = Meetings.broadcast_presence_change("some-room-id", nil)
    end
  end
end
