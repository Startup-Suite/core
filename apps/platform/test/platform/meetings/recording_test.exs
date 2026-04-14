defmodule Platform.Meetings.RecordingTest do
  @moduledoc false
  use Platform.DataCase, async: true

  alias Platform.Meetings
  alias Platform.Meetings.Recording

  defp unique_id, do: Platform.Types.UUIDv7.generate()

  defp valid_attrs(overrides \\ %{}) do
    Map.merge(
      %{room_id: unique_id(), space_id: unique_id()},
      overrides
    )
  end

  defp create_recording!(overrides \\ %{}) do
    {:ok, recording} = Meetings.create_recording(valid_attrs(overrides))
    recording
  end

  describe "create_recording/1" do
    test "creates a recording with valid attrs" do
      attrs = valid_attrs()
      assert {:ok, %Recording{} = recording} = Meetings.create_recording(attrs)
      assert recording.room_id == attrs.room_id
      assert recording.space_id == attrs.space_id
      assert recording.status == "recording"
    end

    test "requires room_id" do
      assert {:error, changeset} = Meetings.create_recording(%{space_id: unique_id()})
      assert %{room_id: ["can't be blank"]} = errors_on(changeset)
    end

    test "rejects invalid status" do
      attrs = valid_attrs(%{status: "bogus"})
      assert {:error, changeset} = Meetings.create_recording(attrs)
      assert %{status: ["is invalid"]} = errors_on(changeset)
    end
  end

  describe "get_recording/1" do
    test "returns recording by ID" do
      recording = create_recording!()
      assert Meetings.get_recording(recording.id).id == recording.id
    end

    test "returns nil for missing ID" do
      assert Meetings.get_recording(unique_id()) == nil
    end
  end

  describe "get_recording_by_egress_id/1" do
    test "returns recording by egress_id" do
      egress_id = "EG_test_#{unique_id()}"
      recording = create_recording!(%{egress_id: egress_id})
      assert Meetings.get_recording_by_egress_id(egress_id).id == recording.id
    end

    test "returns nil when no match" do
      assert Meetings.get_recording_by_egress_id("EG_nonexistent") == nil
    end
  end

  describe "list_recordings_for_space/1" do
    test "returns recordings for a space" do
      space_id = unique_id()
      r1 = create_recording!(%{space_id: space_id})
      r2 = create_recording!(%{space_id: space_id})
      _other = create_recording!(%{space_id: unique_id()})

      results = Meetings.list_recordings_for_space(space_id)
      ids = Enum.map(results, & &1.id)
      assert length(ids) == 2
      assert r1.id in ids
      assert r2.id in ids
    end

    test "returns empty list for space with no recordings" do
      assert Meetings.list_recordings_for_space(unique_id()) == []
    end
  end

  describe "get_active_recording_for_space/1" do
    test "returns active recording" do
      space_id = unique_id()
      recording = create_recording!(%{space_id: space_id})
      assert Meetings.get_active_recording_for_space(space_id).id == recording.id
    end

    test "returns nil when no active recording" do
      space_id = unique_id()
      recording = create_recording!(%{space_id: space_id})

      {:ok, _} =
        recording
        |> Recording.changeset(%{status: "ready"})
        |> Repo.update()

      assert Meetings.get_active_recording_for_space(space_id) == nil
    end
  end

  describe "complete_recording/2" do
    test "marks recording as ready with file metadata" do
      egress_id = "EG_#{unique_id()}"
      _recording = create_recording!(%{egress_id: egress_id})

      attrs = %{
        file_url: "https://storage.example.com/recording.mp4",
        file_size: 1_234_567,
        duration: 300
      }

      assert {:ok, completed} = Meetings.complete_recording(egress_id, attrs)
      assert completed.status == "ready"
      assert completed.file_url == attrs.file_url
      assert completed.file_size == attrs.file_size
      assert completed.duration == attrs.duration
    end

    test "returns error for non-existent egress_id" do
      assert {:error, :not_found} = Meetings.complete_recording("EG_missing", %{})
    end
  end

  describe "stop_recording/1" do
    test "transitions status to processing" do
      recording = create_recording!()

      assert {:ok, stopped} = Meetings.stop_recording(recording.id)
      assert stopped.status == "processing"
    end

    test "returns error for non-existent recording" do
      assert {:error, :not_found} = Meetings.stop_recording(unique_id())
    end
  end

  describe "Recording schema" do
    test "valid statuses" do
      assert Recording.statuses() == ~w(recording processing ready failed)
    end

    test "changeset validates status inclusion" do
      changeset =
        %Recording{}
        |> Recording.changeset(%{room_id: unique_id(), status: "invalid"})

      refute changeset.valid?
      assert %{status: ["is invalid"]} = errors_on(changeset)
    end
  end
end
