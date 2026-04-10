defmodule Platform.Meetings do
  @moduledoc """
  Context for the Meetings domain.

  Manages meeting rooms, participant presence, and recordings tracked via
  LiveKit webhooks. Broadcasts presence and recording changes via
  `Platform.Meetings.PubSub`.
  """

  import Ecto.Query

  alias Platform.Meetings.{Participant, Room}
  alias Platform.Meetings.PubSub, as: MeetingsPubSub
  alias Platform.Repo

  require Logger

  # ── Configuration ─────────────────────────────────────────────────────────

  @doc """
  Returns true when all required LiveKit env vars are set:
  LIVEKIT_URL, LIVEKIT_API_KEY, LIVEKIT_API_SECRET.

  Used to gate the "Join Meeting" button in the UI.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    url = System.get_env("LIVEKIT_URL")
    key = System.get_env("LIVEKIT_API_KEY")
    secret = System.get_env("LIVEKIT_API_SECRET")

    is_binary(url) and url != "" and
      is_binary(key) and key != "" and
      is_binary(secret) and secret != ""
  end

  @doc "Returns the configured LiveKit server URL."
  @spec livekit_url() :: String.t() | nil
  def livekit_url, do: System.get_env("LIVEKIT_URL")

  # ── PubSub Topic Helpers ─────────────────────────────────────────────────

  @doc "Returns the PubSub topic for a meeting room: `\"meetings:room:{room_id}\"`."
  @spec meeting_presence_topic(binary()) :: String.t()
  defdelegate meeting_presence_topic(room_id), to: MeetingsPubSub, as: :room_topic

  @doc "Returns the global presence summary topic: `\"meetings:presence_summary\"`."
  @spec meeting_presence_summary_topic() :: String.t()
  defdelegate meeting_presence_summary_topic(), to: MeetingsPubSub, as: :presence_summary_topic

  @doc "Subscribe to presence events for a specific meeting room."
  @spec subscribe_to_room_presence(binary()) :: :ok | {:error, term()}
  defdelegate subscribe_to_room_presence(room_id), to: MeetingsPubSub, as: :subscribe_room

  @doc "Subscribe to the global presence summary topic for sidebar indicators."
  @spec subscribe_to_presence_summary() :: :ok | {:error, term()}
  defdelegate subscribe_to_presence_summary(), to: MeetingsPubSub, as: :subscribe_presence_summary

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

  @doc """
  Ensure a meeting room exists for a space.

  Uses `"space:{space_id}"` as the LiveKit room name. If a room already
  exists for this space, returns it; otherwise creates one.
  """
  @spec ensure_room(binary()) :: {:ok, Room.t()} | {:error, Ecto.Changeset.t()}
  def ensure_room(space_id) do
    room_name = "space:#{space_id}"

    case Repo.get_by(Room, space_id: space_id) do
      nil ->
        %Room{}
        |> Room.changeset(%{livekit_room_name: room_name, space_id: space_id})
        |> Repo.insert()

      room ->
        {:ok, room}
    end
  end

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
        broadcast_presence_change(room.id, room.space_id)
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
        broadcast_presence_change(room.id, room.space_id)
        {:ok, updated_room}

      error ->
        error
    end
  end

  # ── Participants ─────────────────────────────────────────────────────────

  @doc """
  Record a participant joining a room.

  Broadcasts `{:participant_joined, participant}` on the room topic and
  updates the presence summary for the sidebar.
  """
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
        broadcast_presence_change(room.id, room.space_id)
        {:ok, participant}

      error ->
        error
    end
  end

  @doc """
  Record a participant leaving a room.

  Finds the most recent active participant record matching the identity,
  sets `left_at`, and broadcasts the change.
  """
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
        broadcast_presence_change(room.id, room.space_id)
        {:ok, updated}
    end
  end

  @doc """
  List active (not yet left) participants in a room, preloading user and
  agent associations for display name and avatar resolution.
  """
  @spec active_participants(binary()) :: [Participant.t()]
  def active_participants(room_id) do
    from(p in Participant,
      where: p.room_id == ^room_id and is_nil(p.left_at),
      order_by: [asc: p.joined_at],
      preload: [:user, :agent]
    )
    |> Repo.all()
  end

  # ── Space-level presence queries ─────────────────────────────────────────

  @doc """
  List all active (connected) participants for a space's current meeting.
  Returns an empty list if no active meeting exists. Preloads user/agent.
  """
  @spec active_participants_for_space(binary()) :: [Participant.t()]
  def active_participants_for_space(space_id) do
    case get_active_room(space_id) do
      nil -> []
      room -> active_participants(room.id)
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

  Used by the sidebar to show meeting indicators efficiently in a single query.
  """
  @spec active_meeting_counts([binary()]) :: %{binary() => non_neg_integer()}
  def active_meeting_counts([]), do: %{}

  def active_meeting_counts(space_ids) when is_list(space_ids) do
    Room
    |> join(:inner, [r], p in Participant, on: p.room_id == r.id and is_nil(p.left_at))
    |> where([r, _p], r.space_id in ^space_ids and r.status == "active")
    |> group_by([r, _p], r.space_id)
    |> select([r, p], {r.space_id, count(p.id)})
    |> Repo.all()
    |> Map.new()
  end

  # ── Token Generation ─────────────────────────────────────────────────────

  @doc """
  Generate a LiveKit access token (JWT) for a user to join a room.

  The token is an HS256 JWT signed with `LIVEKIT_API_SECRET`, containing:
  - `iss` — the API key
  - `sub` — the user identity
  - `exp` — expiry (default 6 hours)
  - `video` — grant with room name and permissions

  Returns `{:ok, token_string}` or `{:error, reason}`.
  """
  @spec generate_token(Room.t(), map()) :: {:ok, String.t()} | {:error, atom()}
  def generate_token(%Room{} = room, %{identity: identity, name: name}) do
    api_key = System.get_env("LIVEKIT_API_KEY")
    api_secret = System.get_env("LIVEKIT_API_SECRET")

    if is_nil(api_key) or is_nil(api_secret) do
      {:error, :livekit_not_configured}
    else
      now = System.system_time(:second)
      ttl = 6 * 60 * 60

      claims = %{
        "iss" => api_key,
        "sub" => identity,
        "nbf" => now,
        "exp" => now + ttl,
        "jti" => Ecto.UUID.generate(),
        "name" => name,
        "video" => %{
          "room" => room.livekit_room_name,
          "roomJoin" => true,
          "canPublish" => true,
          "canSubscribe" => true,
          "canPublishData" => true
        }
      }

      {:ok, encode_jwt(claims, api_secret)}
    end
  end

  defp encode_jwt(claims, secret) do
    header = %{"alg" => "HS256", "typ" => "JWT"}

    header_b64 = header |> Jason.encode!() |> Base.url_encode64(padding: false)
    payload_b64 = claims |> Jason.encode!() |> Base.url_encode64(padding: false)

    signing_input = "#{header_b64}.#{payload_b64}"
    signature = :crypto.mac(:hmac, :sha256, secret, signing_input)
    sig_b64 = Base.url_encode64(signature, padding: false)

    "#{signing_input}.#{sig_b64}"
  end

  # ── Presence Broadcasting (private) ──────────────────────────────────────

  @doc """
  Broadcast a presence change for a room.

  Sends `{:meeting_presence, %{room_id, event}}` on the room topic AND
  `{:meeting_presence_summary, %{space_id}}` on the summary topic.
  Also sends a `{:meeting_presence_update, %{space_id, active, count}}`
  on the per-space presence topic.
  """
  @spec broadcast_presence_change(binary(), binary() | nil) :: :ok
  def broadcast_presence_change(_room_id, nil), do: :ok

  def broadcast_presence_change(room_id, space_id) when is_binary(space_id) do
    count = active_participant_count_for_room(room_id)
    active = count > 0

    # Per-space presence topic (ChatLive header)
    MeetingsPubSub.broadcast_presence(
      space_id,
      {:meeting_presence_update, %{space_id: space_id, active: active, count: count}}
    )

    # Global summary topic (sidebar)
    MeetingsPubSub.broadcast_presence_summary(space_id)

    :ok
  end

  def broadcast_presence_change(_room_id, _space_id), do: :ok

  # ── Private ──────────────────────────────────────────────────────────────

  defp active_participant_count_for_room(room_id) do
    from(p in Participant,
      where: p.room_id == ^room_id and is_nil(p.left_at)
    )
    |> Repo.aggregate(:count)
  end
end
