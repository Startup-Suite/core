defmodule Platform.Meetings do
  @moduledoc """
  Context for the Meetings domain.

  Manages meeting rooms and participant presence tracked via LiveKit webhooks.
  Broadcasts presence changes via `Platform.Meetings.PubSub`.
  """

  import Ecto.Query

  alias Platform.Meetings.{Participant, Room}
  alias Platform.Meetings.PubSub, as: MeetingsPubSub
  alias Platform.Repo

  require Logger

  # ── Rooms ────────────────────────────────────────────────────────────────

  @doc "Find or create a room by its LiveKit room name."
  @spec find_or_create_room(String.t()) :: {:ok, Room.t()} | {:error, Ecto.Changeset.t()}
  def find_or_create_room(livekit_room_name) do
    case Repo.get_by(Room, livekit_room_name: livekit_room_name) do
      nil ->
        %Room{}
        |> Room.changeset(%{livekit_room_name: livekit_room_name})
        |> Repo.insert()

      room ->
        {:ok, room}
    end
  end

  @doc "Get a room by ID."
  @spec get_room(binary()) :: Room.t() | nil
  def get_room(id), do: Repo.get(Room, id)

  @doc "Get a room by LiveKit room name."
  @spec get_room_by_name(String.t()) :: Room.t() | nil
  def get_room_by_name(name), do: Repo.get_by(Room, livekit_room_name: name)

  @doc "Get the active (non-idle) room for a space, if any."
  @spec get_active_room(binary()) :: Room.t() | nil
  def get_active_room(space_id) do
    Room
    |> where([r], r.space_id == ^space_id and r.status == "active")
    |> order_by([r], desc: r.inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  @doc "Update room status to active."
  @spec activate_room(Room.t()) :: {:ok, Room.t()} | {:error, Ecto.Changeset.t()}
  def activate_room(%Room{} = room) do
    result =
      room
      |> Room.changeset(%{status: "active"})
      |> Repo.update()

    case result do
      {:ok, updated_room} ->
        MeetingsPubSub.broadcast_room(room.id, {:room_activated, updated_room})
        broadcast_presence_update(room.space_id)
        {:ok, updated_room}

      error ->
        error
    end
  end

  @doc "Set room to idle and mark all active participants as left."
  @spec finish_room(Room.t()) :: {:ok, Room.t()} | {:error, Ecto.Changeset.t()}
  def finish_room(%Room{} = room) do
    now = DateTime.utc_now()

    # Mark all active participants as left
    from(p in Participant,
      where: p.room_id == ^room.id and is_nil(p.left_at)
    )
    |> Repo.update_all(set: [left_at: now, updated_at: now])

    result =
      room
      |> Room.changeset(%{status: "idle"})
      |> Repo.update()

    case result do
      {:ok, updated_room} ->
        MeetingsPubSub.broadcast_room(room.id, {:room_finished, updated_room})
        broadcast_presence_update(room.space_id)
        {:ok, updated_room}

      error ->
        error
    end
  end

  # ── Participants ─────────────────────────────────────────────────────────

  @doc "Record a participant joining a room."
  @spec participant_joined(Room.t(), map()) ::
          {:ok, Participant.t()} | {:error, Ecto.Changeset.t()}
  def participant_joined(%Room{} = room, attrs) do
    result =
      %Participant{}
      |> Participant.changeset(
        Map.merge(attrs, %{
          room_id: room.id,
          joined_at: Map.get(attrs, :joined_at, DateTime.utc_now())
        })
      )
      |> Repo.insert()

    case result do
      {:ok, participant} ->
        MeetingsPubSub.broadcast_room(room.id, {:participant_joined, participant})
        broadcast_presence_update(room.space_id)
        {:ok, participant}

      error ->
        error
    end
  end

  @doc "Record a participant leaving a room."
  @spec participant_left(Room.t(), String.t()) ::
          {:ok, Participant.t()} | {:error, :not_found}
  def participant_left(%Room{} = room, identity) do
    query =
      from(p in Participant,
        where: p.room_id == ^room.id and p.identity == ^identity and is_nil(p.left_at),
        order_by: [desc: p.joined_at],
        limit: 1
      )

    case Repo.one(query) do
      nil ->
        {:error, :not_found}

      participant ->
        {:ok, updated} =
          participant
          |> Participant.changeset(%{left_at: DateTime.utc_now()})
          |> Repo.update()

        MeetingsPubSub.broadcast_room(room.id, {:participant_left, updated})
        broadcast_presence_update(room.space_id)
        {:ok, updated}
    end
  end

  @doc "List active (not yet left) participants in a room."
  @spec list_active_participants(binary()) :: [Participant.t()]
  def list_active_participants(room_id) do
    from(p in Participant,
      where: p.room_id == ^room_id and is_nil(p.left_at),
      order_by: [asc: p.joined_at]
    )
    |> Repo.all()
  end

  # ── Space-level presence queries ─────────────────────────────────────────

  @doc """
  List all active (connected) participants for a space's current meeting.
  Returns an empty list if no active meeting exists.
  """
  @spec list_active_participants_for_space(binary()) :: [Participant.t()]
  def list_active_participants_for_space(space_id) do
    case get_active_room(space_id) do
      nil -> []
      room -> list_active_participants(room.id)
    end
  end

  @doc "Count active participants for a space's current meeting."
  @spec active_participant_count(binary()) :: non_neg_integer()
  def active_participant_count(space_id) do
    case get_active_room(space_id) do
      nil ->
        0

      room ->
        from(p in Participant,
          where: p.room_id == ^room.id and is_nil(p.left_at)
        )
        |> Repo.aggregate(:count)
    end
  end

  @doc """
  For a list of space IDs, return a map of `%{space_id => participant_count}`
  for spaces that have an active meeting with at least one participant.

  Used by the sidebar to show meeting indicators efficiently.
  """
  @spec spaces_with_active_meetings([binary()]) :: %{binary() => non_neg_integer()}
  def spaces_with_active_meetings([]), do: %{}

  def spaces_with_active_meetings(space_ids) when is_list(space_ids) do
    Room
    |> join(:left, [r], p in Participant, on: p.room_id == r.id and is_nil(p.left_at))
    |> where([r, _p], r.space_id in ^space_ids and r.status == "active")
    |> group_by([r, _p], r.space_id)
    |> select([r, p], {r.space_id, count(p.id)})
    |> Repo.all()
    |> Map.new()
  end

  # ── PubSub (legacy compat — prefer Meetings.PubSub directly) ────────────

  @doc "Returns the PubSub topic for a meeting room."
  @spec room_topic(binary()) :: String.t()
  def room_topic(room_id), do: MeetingsPubSub.room_topic(room_id)

  @doc "Subscribe to presence events for a meeting room."
  @spec subscribe_room(binary()) :: :ok | {:error, term()}
  def subscribe_room(room_id), do: MeetingsPubSub.subscribe_room(room_id)

  # ── Private ──────────────────────────────────────────────────────────────

  defp broadcast_presence_update(nil), do: :ok

  defp broadcast_presence_update(space_id) when is_binary(space_id) do
    count = active_participant_count(space_id)
    active = count > 0

    MeetingsPubSub.broadcast_presence(
      space_id,
      {:meeting_presence_update, %{space_id: space_id, active: active, count: count}}
    )
  end

  defp broadcast_presence_update(_), do: :ok
end
