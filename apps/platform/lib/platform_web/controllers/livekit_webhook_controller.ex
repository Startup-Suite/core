defmodule PlatformWeb.LivekitWebhookController do
  @moduledoc """
  Receives LiveKit server-side webhook events for room lifecycle and
  participant presence tracking.

  Handles:
  - `participant_joined` — insert meeting_participants record, broadcast presence
  - `participant_left` — set `left_at`, broadcast presence
  - `room_started` — update room status to `active`
  - `room_finished` — update room status to `idle`, clean up participants
  - `egress_started` — update recording status to `active`
  - `egress_ended` — update recording with file path, duration, final status

  Webhook payloads are verified using `LIVEKIT_WEBHOOK_SECRET` env var.
  The Authorization header must contain a valid HS256 JWT signed with the secret.
  Unverified payloads are rejected with 401.
  """

  use PlatformWeb, :controller

  alias Platform.Meetings
  alias Platform.Meetings.PubSub, as: MeetingsPubSub

  require Logger

  # ── Plugs ────────────────────────────────────────────────────────────────

  plug(:verify_livekit_signature when action in [:handle])

  # ── Handlers ─────────────────────────────────────────────────────────────

  @doc "Main webhook entry point — dispatches by event type."
  def handle(conn, %{"event" => event} = params) do
    Logger.info("[LiveKit Webhook] Received event: #{event}")

    case event do
      "participant_joined" -> handle_participant_joined(conn, params)
      "participant_left" -> handle_participant_left(conn, params)
      "room_started" -> handle_room_started(conn, params)
      "room_finished" -> handle_room_finished(conn, params)
      "egress_started" -> handle_egress_started(conn, params)
      "egress_ended" -> handle_egress_ended(conn, params)
      "transcription" -> handle_transcription(conn, params)
      _ -> conn |> put_status(:ok) |> json(%{status: "ignored", reason: "unhandled event"})
    end
  end

  def handle(conn, _params) do
    conn |> put_status(:ok) |> json(%{status: "ignored", reason: "no event field"})
  end

  # ── Event handlers ───────────────────────────────────────────────────────

  defp handle_participant_joined(conn, params) do
    room_name = get_in(params, ["room", "name"])
    identity = get_in(params, ["participant", "identity"])
    name = get_in(params, ["participant", "name"])
    metadata = get_in(params, ["participant", "metadata"])

    with {:ok, room} <- Meetings.find_or_create_room(room_name),
         {:ok, participant} <-
           Meetings.participant_joined(room, %{
             identity: identity,
             name: name,
             metadata: parse_metadata(metadata)
           }) do
      Logger.info("[LiveKit Webhook] Participant joined: #{identity} in room #{room_name}")

      conn
      |> put_status(:created)
      |> json(%{status: "recorded", event: "participant_joined", participant_id: participant.id})
    else
      {:error, changeset} ->
        Logger.warning(
          "[LiveKit Webhook] Failed to record participant_joined: #{inspect(changeset)}"
        )

        conn
        |> put_status(:unprocessable_entity)
        |> json(%{status: "error", reason: "failed to record participant"})
    end
  end

  defp handle_participant_left(conn, params) do
    room_name = get_in(params, ["room", "name"])
    identity = get_in(params, ["participant", "identity"])

    case Meetings.get_room_by_name(room_name) do
      nil ->
        Logger.warning("[LiveKit Webhook] participant_left for unknown room: #{room_name}")
        conn |> put_status(:ok) |> json(%{status: "ignored", reason: "unknown room"})

      room ->
        case Meetings.participant_left(room, identity) do
          {:ok, participant} ->
            Logger.info("[LiveKit Webhook] Participant left: #{identity} from room #{room_name}")

            conn
            |> put_status(:ok)
            |> json(%{
              status: "recorded",
              event: "participant_left",
              participant_id: participant.id
            })

          {:error, :not_found} ->
            Logger.warning(
              "[LiveKit Webhook] participant_left for unknown participant: #{identity} in #{room_name}"
            )

            conn
            |> put_status(:ok)
            |> json(%{status: "ignored", reason: "participant not found"})
        end
    end
  end

  defp handle_room_started(conn, params) do
    room_name = get_in(params, ["room", "name"])

    with {:ok, room} <- Meetings.find_or_create_room(room_name),
         {:ok, room} <- Meetings.activate_room(room) do
      Logger.info("[LiveKit Webhook] Room started: #{room_name}")

      # Auto-create transcript for the new room
      case Meetings.ensure_transcript(%{room_id: room.id, space_id: room.space_id}) do
        {:ok, transcript} ->
          Logger.info(
            "[LiveKit Webhook] Created transcript #{transcript.id} for room #{room_name}"
          )

        {:error, reason} ->
          Logger.warning(
            "[LiveKit Webhook] Failed to create transcript for room #{room_name}: #{inspect(reason)}"
          )
      end

      conn
      |> put_status(:ok)
      |> json(%{status: "recorded", event: "room_started", room_id: room.id})
    else
      {:error, changeset} ->
        Logger.warning(
          "[LiveKit Webhook] Failed to activate room #{room_name}: #{inspect(changeset)}"
        )

        conn
        |> put_status(:unprocessable_entity)
        |> json(%{status: "error", reason: "failed to activate room"})
    end
  end

  defp handle_room_finished(conn, params) do
    room_name = get_in(params, ["room", "name"])

    case Meetings.get_room_by_name(room_name) do
      nil ->
        Logger.warning("[LiveKit Webhook] room_finished for unknown room: #{room_name}")
        conn |> put_status(:ok) |> json(%{status: "ignored", reason: "unknown room"})

      room ->
        case Meetings.finish_room(room) do
          {:ok, room} ->
            Logger.info("[LiveKit Webhook] Room finished: #{room_name}")

            # Finalize any active transcript and trigger summary
            case Meetings.get_transcript_for_room(room.id) do
              nil ->
                :ok

              transcript ->
                case Meetings.finalize_transcript(transcript.id) do
                  {:ok, finalized} ->
                    Logger.info("[LiveKit Webhook] Finalized transcript #{finalized.id}")
                    maybe_trigger_summary(finalized)

                  {:error, reason} ->
                    Logger.warning(
                      "[LiveKit Webhook] Failed to finalize transcript: #{inspect(reason)}"
                    )
                end
            end

            conn
            |> put_status(:ok)
            |> json(%{status: "recorded", event: "room_finished", room_id: room.id})

          {:error, changeset} ->
            Logger.warning(
              "[LiveKit Webhook] Failed to finish room #{room_name}: #{inspect(changeset)}"
            )

            conn
            |> put_status(:unprocessable_entity)
            |> json(%{status: "error", reason: "failed to finish room"})
        end
    end
  end

  defp handle_egress_started(conn, params) do
    egress_id = get_in(params, ["egressInfo", "egressId"])
    room_name = get_in(params, ["egressInfo", "roomName"]) || get_in(params, ["room", "name"])

    case Meetings.get_recording_by_egress_id(egress_id) do
      nil ->
        Logger.warning(
          "[LiveKit Webhook] egress_started for unknown recording: egress_id=#{egress_id}"
        )

        conn |> put_status(:ok) |> json(%{status: "ignored", reason: "unknown recording"})

      recording ->
        case Meetings.update_recording(recording, %{
               status: "active",
               metadata: Map.merge(recording.metadata || %{}, %{"room_name" => room_name})
             }) do
          {:ok, updated} ->
            MeetingsPubSub.broadcast_recording_update(
              recording.room_id,
              {:recording_active, updated}
            )

            Logger.info("[LiveKit Webhook] Egress started: #{egress_id} for room #{room_name}")

            conn
            |> put_status(:ok)
            |> json(%{status: "recorded", event: "egress_started", egress_id: egress_id})

          {:error, changeset} ->
            Logger.warning(
              "[LiveKit Webhook] Failed to update recording for egress_started: #{inspect(changeset)}"
            )

            conn
            |> put_status(:unprocessable_entity)
            |> json(%{status: "error", reason: "failed to update recording"})
        end
    end
  end

  defp handle_egress_ended(conn, params) do
    egress_id = get_in(params, ["egressInfo", "egressId"])
    egress_status = get_in(params, ["egressInfo", "status"])
    file_path = extract_file_path(params)
    duration = extract_duration(params)
    file_size = extract_file_size(params)

    case Meetings.get_recording_by_egress_id(egress_id) do
      nil ->
        Logger.warning(
          "[LiveKit Webhook] egress_ended for unknown recording: egress_id=#{egress_id}"
        )

        conn |> put_status(:ok) |> json(%{status: "ignored", reason: "unknown recording"})

      recording ->
        # Determine final status based on egress status
        final_status =
          if egress_status in ["EGRESS_COMPLETE", "EGRESS_ENDING"],
            do: "completed",
            else: "failed"

        update_attrs =
          %{
            status: final_status,
            ended_at: DateTime.utc_now(),
            metadata:
              Map.merge(recording.metadata || %{}, %{
                "egress_status" => egress_status,
                "egress_info" => get_in(params, ["egressInfo"]) || %{}
              })
          }
          |> maybe_put(:file_path, file_path)
          |> maybe_put(:duration_seconds, duration)
          |> maybe_put(:file_size, file_size)

        case Meetings.update_recording(recording, update_attrs) do
          {:ok, updated} ->
            event =
              if final_status == "completed",
                do: {:recording_completed, updated},
                else: {:recording_failed, updated}

            MeetingsPubSub.broadcast_recording_update(recording.room_id, event)

            Logger.info(
              "[LiveKit Webhook] Egress ended: #{egress_id} status=#{final_status} file=#{file_path}"
            )

            conn
            |> put_status(:ok)
            |> json(%{
              status: "recorded",
              event: "egress_ended",
              egress_id: egress_id,
              recording_status: final_status
            })

          {:error, changeset} ->
            Logger.warning(
              "[LiveKit Webhook] Failed to update recording for egress_ended: #{inspect(changeset)}"
            )

            conn
            |> put_status(:unprocessable_entity)
            |> json(%{status: "error", reason: "failed to update recording"})
        end
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp parse_metadata(nil), do: %{}

  defp parse_metadata(metadata) when is_binary(metadata) do
    case Jason.decode(metadata) do
      {:ok, decoded} -> decoded
      _ -> %{"raw" => metadata}
    end
  end

  defp parse_metadata(metadata) when is_map(metadata), do: metadata

  defp extract_file_path(params) do
    get_in(params, ["egressInfo", "file", "filename"]) ||
      get_in(params, ["egressInfo", "fileResults", Access.at(0), "filename"])
  end

  defp extract_duration(params) do
    case get_in(params, ["egressInfo", "file", "duration"]) ||
           get_in(params, ["egressInfo", "fileResults", Access.at(0), "duration"]) do
      nil -> nil
      # LiveKit returns duration in nanoseconds
      ns when is_integer(ns) -> div(ns, 1_000_000_000)
      ns when is_binary(ns) -> ns |> String.to_integer() |> div(1_000_000_000)
    end
  end

  defp extract_file_size(params) do
    get_in(params, ["egressInfo", "file", "size"]) ||
      get_in(params, ["egressInfo", "fileResults", Access.at(0), "size"])
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # ── Signature verification ──────────────────────────────────────────────

  defp verify_livekit_signature(conn, _opts) do
    secret = System.get_env("LIVEKIT_WEBHOOK_SECRET")

    if is_nil(secret) or secret == "" do
      Logger.warning("[LiveKit Webhook] LIVEKIT_WEBHOOK_SECRET not configured, rejecting request")

      conn
      |> put_status(:unauthorized)
      |> json(%{status: "error", reason: "webhook secret not configured"})
      |> halt()
    else
      auth_header = get_req_header(conn, "authorization") |> List.first()

      if is_nil(auth_header) do
        Logger.warning("[LiveKit Webhook] Missing Authorization header")

        conn
        |> put_status(:unauthorized)
        |> json(%{status: "error", reason: "missing authorization header"})
        |> halt()
      else
        if verify_jwt_signature(auth_header, secret) do
          conn
        else
          Logger.warning("[LiveKit Webhook] Invalid webhook signature")

          conn
          |> put_status(:unauthorized)
          |> json(%{status: "error", reason: "invalid signature"})
          |> halt()
        end
      end
    end
  end

  @doc """
  Verify a LiveKit webhook JWT signature (HS256).

  Checks that the JWT was signed with the given secret. This proves the
  webhook came from a source that knows the API secret.
  """
  def verify_jwt_signature(token, secret) do
    case String.split(token, ".") do
      [header_b64, payload_b64, signature_b64] ->
        signing_input = header_b64 <> "." <> payload_b64

        with {:ok, sig} <- Base.url_decode64(signature_b64, padding: false) do
          computed_sig = :crypto.mac(:hmac, :sha256, secret, signing_input)
          Plug.Crypto.secure_compare(computed_sig, sig)
        else
          _ -> false
        end

      _ ->
        false
    end
  rescue
    _ -> false
  end

  # ── Transcription handler ────────────────────────────────────────────────────

  defp handle_transcription(conn, params) do
    room_name = get_in(params, ["room", "name"])
    room_id = get_in(params, ["room", "sid"]) || room_name
    raw_segments = params["segments"] || []

    if room_id && raw_segments != [] do
      case Meetings.get_transcript_for_room(room_id) do
        nil ->
          case Meetings.ensure_transcript(%{room_id: room_id}) do
            {:ok, transcript} ->
              append_segments(conn, transcript.id, raw_segments, room_id)

            {:error, reason} ->
              Logger.warning(
                "[LiveKit Webhook] Failed to ensure transcript for room #{room_id}: #{inspect(reason)}"
              )

              conn
              |> put_status(:unprocessable_entity)
              |> json(%{status: "error", reason: inspect(reason)})
          end

        transcript ->
          append_segments(conn, transcript.id, raw_segments, room_id)
      end
    else
      conn |> put_status(:ok) |> json(%{status: "ignored", reason: "no room or empty segments"})
    end
  end

  defp append_segments(conn, transcript_id, raw_segments, room_id) do
    results =
      Enum.map(raw_segments, fn seg ->
        segment = %{
          "participant_identity" => seg["participant_identity"] || seg["identity"],
          "speaker_name" => seg["speaker_name"] || seg["name"],
          "text" => seg["text"] || "",
          "start_time" => seg["start_time"] || 0,
          "end_time" => seg["end_time"] || 0,
          "language" => seg["language"],
          "final" => seg["final"] != false
        }

        Meetings.append_segment(transcript_id, segment)
      end)

    errors = Enum.filter(results, &match?({:error, _}, &1))

    if errors == [] do
      Logger.debug(
        "[LiveKit Webhook] Appended #{length(raw_segments)} segments for room #{room_id}"
      )

      conn
      |> put_status(:ok)
      |> json(%{
        status: "appended",
        transcript_id: transcript_id,
        segments_appended: length(raw_segments)
      })
    else
      Logger.warning("[LiveKit Webhook] #{length(errors)} segment(s) failed for room #{room_id}")

      conn
      |> put_status(:ok)
      |> json(%{
        status: "partial",
        transcript_id: transcript_id,
        segments_appended: length(raw_segments) - length(errors),
        segments_failed: length(errors)
      })
    end
  end

  defp maybe_trigger_summary(transcript) do
    if Code.ensure_loaded?(Platform.Meetings.Summarizer) do
      Platform.Meetings.Summarizer.summarize_async(transcript)
    else
      Logger.debug(
        "[LiveKit Webhook] Summarizer not available, skipping summary for transcript #{transcript.id}"
      )
    end
  end
end
