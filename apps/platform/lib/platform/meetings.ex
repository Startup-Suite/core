defmodule Platform.Meetings do
  @moduledoc """
  Context for the Meetings domain.

  Manages meeting rooms and participant presence tracked via LiveKit webhooks.
  Broadcasts presence changes on `meetings:room:<room_id>` PubSub topics.
  """

  import Ecto.Query

  alias Platform.Meetings.{Participant, Room}
  alias Platform.Repo

  require Logger

  @pubsub Platform.PubSub

  # ── PubSub ───────────────────────────────────────────────────────────────

  @doc "Returns the PubSub topic for a meeting room."
  @spec room_topic(binary()) :: String.t()
  def room_topic(room_id), do: "meetings:room:#{room_id}"

  @doc "Subscribe to presence events for a meeting room."
  @spec subscribe_room(binary()) :: :ok | {:error, term()}
  def subscribe_room(room_id) do
    Phoenix.PubSub.subscribe(@pubsub, room_topic(room_id))
  end

  defp broadcast_room(room_id, event) do
    Phoenix.PubSub.broadcast(@pubsub, room_topic(room_id), event)
  end

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

  @doc "Update room status to active."
  @spec activate_room(Room.t()) :: {:ok, Room.t()} | {:error, Ecto.Changeset.t()}
  def activate_room(%Room{} = room) do
    room
    |> Room.changeset(%{status: "active"})
    |> Repo.update()
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
        broadcast_room(room.id, {:room_finished, updated_room})
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
        broadcast_room(room.id, {:participant_joined, participant})
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

        broadcast_room(room.id, {:participant_left, updated})
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
end
