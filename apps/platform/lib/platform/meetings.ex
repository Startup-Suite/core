defmodule Platform.Meetings do
  @moduledoc """
  Context for the Meetings domain.

  Manages meeting rooms, participant presence, recordings, and transcripts
  tracked via LiveKit webhooks. Broadcasts presence and recording changes via
  `Platform.Meetings.PubSub`.
  """

  import Ecto.Query

  alias Platform.Meetings.{Egress, Participant, Recording, Room, Transcript}
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

  # ── Token Generation ─────────────────────────────────────────────────────

  @doc """
  Generate a LiveKit access token (JWT) for a user to join a room.

  The token is an HS256 JWT signed with `LIVEKIT_API_SECRET`, containing:
  - `iss` — the API key
  - `sub` — the user identity
  - `exp` — expiry (default 6 hours)
  - `nbf` — not before (now)
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

  @doc """
  Generate a LiveKit access token for an agent to join a room.

  Similar to `generate_token/2` but uses the agent's slug as identity
  and includes agent metadata in the token. The agent gets the same
  permissions as a human participant (publish, subscribe, data).

  ## Parameters

    - `room` — a `%Room{}` struct with `livekit_room_name`
    - `agent` — a map or struct with `:id`, `:slug`, and `:name`

  Returns `{:ok, token_string}` or `{:error, reason}`.
  """
  @spec generate_agent_token(Room.t(), map()) :: {:ok, String.t()} | {:error, atom()}
  def generate_agent_token(%Room{} = room, %{id: agent_id, slug: slug, name: name}) do
    api_key = System.get_env("LIVEKIT_API_KEY")
    api_secret = System.get_env("LIVEKIT_API_SECRET")

    if is_nil(api_key) or is_nil(api_secret) do
      {:error, :livekit_not_configured}
    else
      now = System.system_time(:second)
      ttl = 6 * 60 * 60
      identity = "agent:#{slug}"

      metadata =
        Jason.encode!(%{
          "kind" => "agent",
          "agent_id" => agent_id,
          "agent_slug" => slug
        })

      claims = %{
        "iss" => api_key,
        "sub" => identity,
        "nbf" => now,
        "exp" => now + ttl,
        "jti" => Ecto.UUID.generate(),
        "name" => name,
        "metadata" => metadata,
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

  @doc """
  Dispatch a meeting_join signal to an agent's runtime.

  Generates an agent token for the given room, then broadcasts a
  `meeting_join` event to the agent's runtime channel topic. The
  runtime worker is expected to connect to LiveKit using the provided
  token and begin the STT/LLM/TTS loop.

  ## Parameters

    - `room` — a `%Room{}` struct (must have `livekit_room_name` and `space_id`)
    - `agent` — a `%Agent{}` struct (must have `id`, `slug`, `name`, `runtime_id`)
    - `opts` — optional keyword list:
      - `:space_id` — the space context (defaults to `room.space_id`)

  Returns `{:ok, :dispatched}` or `{:error, reason}`.
  """
  def dispatch_meeting_join(%Room{} = room, %{runtime_id: runtime_id} = agent, opts \\ []) do
    alias Platform.Federation
    alias Platform.Federation.RuntimePresence

    space_id = Keyword.get(opts, :space_id, room.space_id)

    with runtime when not is_nil(runtime) <- Federation.get_runtime(runtime_id),
         true <- RuntimePresence.online?(runtime.runtime_id),
         {:ok, token} <- generate_agent_token(room, agent) do
      payload = %{
        event: "meeting_join",
        room_name: room.livekit_room_name,
        room_id: room.id,
        token: token,
        agent_identity: "agent:#{agent.slug}",
        agent_name: agent.name,
        agent_id: agent.id,
        space_id: space_id
      }

      PlatformWeb.Endpoint.broadcast(
        "runtime:#{runtime.runtime_id}",
        "meeting_join",
        payload
      )

      Logger.info(
        "[Meetings] dispatched meeting_join to agent=#{agent.slug} " <>
          "room=#{room.livekit_room_name} runtime=#{runtime.runtime_id}"
      )

      {:ok, :dispatched}
    else
      nil -> {:error, :runtime_not_found}
      false -> {:error, :runtime_offline}
      {:error, reason} -> {:error, reason}
    end
  end

  def dispatch_meeting_join(_room, _agent, _opts) do
    {:error, :invalid_agent}
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

  # ── Recordings ───────────────────────────────────────────────────────────

  @doc """
  Start recording a meeting room via LiveKit Egress.

  Creates a `meeting_recordings` record in `starting` status, then calls the
  LiveKit Egress API to start a room composite recording. On success, updates
  the record with the egress ID.

  Returns `{:ok, recording}` or `{:error, reason}`.
  """
  @spec start_recording(Room.t(), map()) :: {:ok, Recording.t()} | {:error, term()}
  def start_recording(%Room{} = room, %{user_id: user_id} = _opts) do
    recording_attrs = %{
      room_id: room.id,
      space_id: room.space_id,
      status: "starting",
      started_by: user_id,
      started_at: DateTime.utc_now()
    }

    with {:ok, recording} <- create_recording(recording_attrs),
         {:ok, egress_info} <-
           Egress.start_room_composite_egress(room.livekit_room_name) do
      egress_id = Map.get(egress_info, "egressId") || Map.get(egress_info, "egress_id")

      update_recording(recording, %{
        egress_id: egress_id,
        metadata: %{"egress_info" => egress_info}
      })
      |> tap(fn
        {:ok, rec} ->
          MeetingsPubSub.broadcast_room(room.id, {:recording_started, rec})
          broadcast_presence_update(room.space_id)

        _ ->
          :ok
      end)
    else
      {:error, reason} ->
        Logger.error("[Meetings] Failed to start recording: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Stop an active recording.

  Calls the LiveKit Egress API to stop the egress. Updates the recording
  status to `processing`. The final status update happens when the
  `egress_ended` webhook fires.
  """
  @spec stop_recording(Recording.t()) :: {:ok, Recording.t()} | {:error, term()}
  def stop_recording(%Recording{egress_id: nil}), do: {:error, :no_egress_id}

  def stop_recording(%Recording{egress_id: egress_id} = recording) do
    case Egress.stop_egress(egress_id) do
      {:ok, _egress_info} ->
        update_recording(recording, %{status: "processing"})
        |> tap(fn
          {:ok, rec} ->
            MeetingsPubSub.broadcast_room(recording.room_id, {:recording_stopping, rec})

          _ ->
            :ok
        end)

      {:error, _reason} = error ->
        error
    end
  end

  @doc "Create a recording record."
  @spec create_recording(map()) :: {:ok, Recording.t()} | {:error, Ecto.Changeset.t()}
  def create_recording(attrs) do
    %Recording{}
    |> Recording.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Update a recording record."
  @spec update_recording(Recording.t(), map()) ::
          {:ok, Recording.t()} | {:error, Ecto.Changeset.t()}
  def update_recording(%Recording{} = recording, attrs) do
    recording
    |> Recording.changeset(attrs)
    |> Repo.update()
  end

  @doc "Get a recording by ID."
  @spec get_recording(binary()) :: Recording.t() | nil
  def get_recording(id), do: Repo.get(Recording, id)

  @doc "Get a recording by its LiveKit egress ID."
  @spec get_recording_by_egress_id(String.t()) :: Recording.t() | nil
  def get_recording_by_egress_id(egress_id) do
    Repo.get_by(Recording, egress_id: egress_id)
  end

  @doc "List all recordings for a room, newest first."
  @spec list_recordings_for_room(binary()) :: [Recording.t()]
  def list_recordings_for_room(room_id) do
    from(r in Recording,
      where: r.room_id == ^room_id,
      order_by: [desc: r.started_at]
    )
    |> Repo.all()
  end

  @doc """
  List all recordings for a space (via its rooms), newest first.
  """
  @spec list_recordings_for_space(binary()) :: [Recording.t()]
  def list_recordings_for_space(space_id) do
    from(r in Recording,
      join: room in Room,
      on: r.room_id == room.id,
      where: room.space_id == ^space_id,
      order_by: [desc: r.started_at],
      preload: [:room]
    )
    |> Repo.all()
  end

  @doc "Get the active recording for a room (status in starting/active), if any."
  @spec get_active_recording(binary()) :: Recording.t() | nil
  def get_active_recording(room_id) do
    from(r in Recording,
      where: r.room_id == ^room_id and r.status in ["starting", "active"],
      order_by: [desc: r.started_at],
      limit: 1
    )
    |> Repo.one()
  end

  @doc "Check if a room is currently being recorded."
  @spec recording?(binary()) :: boolean()
  def recording?(room_id) do
    from(r in Recording,
      where: r.room_id == ^room_id and r.status in ["starting", "active"]
    )
    |> Repo.exists?()
  end

  # ── Transcripts ──────────────────────────────────────────────────────────

  @doc "Create a new transcript record for a meeting room."
  @spec create_transcript(map()) :: {:ok, Transcript.t()} | {:error, Ecto.Changeset.t()}
  def create_transcript(attrs) do
    %Transcript{}
    |> Transcript.changeset(Map.put_new(attrs, :started_at, DateTime.utc_now()))
    |> Repo.insert()
  end

  @doc "Get a transcript by ID."
  @spec get_transcript(String.t()) :: Transcript.t() | nil
  def get_transcript(id), do: Repo.get(Transcript, id)

  @doc "Get the active (recording-status) transcript for a room."
  @spec get_transcript_for_room(String.t()) :: Transcript.t() | nil
  def get_transcript_for_room(room_id) do
    Transcript
    |> where([t], t.room_id == ^room_id and t.status == "recording")
    |> order_by([t], desc: t.inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  @doc "Get a transcript with its segments."
  @spec get_transcript_with_segments(String.t()) :: Transcript.t() | nil
  def get_transcript_with_segments(id), do: Repo.get(Transcript, id)

  @doc "Find the active transcript for a room, or create one if none exists."
  @spec ensure_transcript(map()) :: {:ok, Transcript.t()} | {:error, Ecto.Changeset.t()}
  def ensure_transcript(%{room_id: room_id} = attrs) do
    case get_transcript_for_room(room_id) do
      nil -> create_transcript(attrs)
      transcript -> {:ok, transcript}
    end
  end

  @doc "List completed or processing transcripts for a space."
  @spec list_transcripts_for_space(String.t()) :: [Transcript.t()]
  def list_transcripts_for_space(space_id) do
    from(t in Transcript,
      where: t.space_id == ^space_id and t.status in ["complete", "processing"],
      order_by: [desc: t.started_at]
    )
    |> Repo.all()
  end

  @doc "Append a segment to the transcript's segments array."
  @spec append_segment(String.t(), map()) :: {:ok, Transcript.t()} | {:error, term()}
  def append_segment(transcript_id, segment) when is_map(segment) do
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

  @doc "Transition a transcript to 'processing' status."
  @spec finalize_transcript(String.t()) :: {:ok, Transcript.t()} | {:error, term()}
  def finalize_transcript(transcript_id) do
    case get_transcript(transcript_id) do
      nil -> {:error, :not_found}
      transcript -> transcript |> Transcript.changeset(%{status: "processing"}) |> Repo.update()
    end
  end

  @doc "Mark a transcript as complete with the generated summary."
  @spec complete_transcript(String.t(), String.t()) :: {:ok, Transcript.t()} | {:error, term()}
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

  @doc "Mark a transcript as failed."
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

  @doc "Update the transcript summary text."
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

  @doc "Post a meeting summary as a system message to the space."
  @spec post_summary_to_space(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def post_summary_to_space(space_id, transcript_id, summary)
      when is_binary(space_id) and is_binary(transcript_id) and is_binary(summary) do
    content = """
    \U0001f4dd **Meeting Summary**

    #{summary}

    [\U0001f4c4 Full transcript](/api/transcripts/#{transcript_id}/download)
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
