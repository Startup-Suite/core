defmodule PlatformWeb.LivekitWebhookController do
  @moduledoc """
  Receives LiveKit server-side webhook events for room lifecycle and
  participant presence tracking.

  Handles:
  - `participant_joined` — insert meeting_participants record, broadcast presence
  - `participant_left` — set `left_at`, broadcast presence
  - `room_started` — update room status to `active`
  - `room_finished` — update room status to `idle`, clean up participants
  - `egress_ended` — update recording status, store file URL

  Webhook payloads are verified using `LIVEKIT_WEBHOOK_SECRET` env var.
  Unverified payloads are rejected with 401.
  """

  use PlatformWeb, :controller

  alias Platform.Meetings

  require Logger

  # ── Plugs ────────────────────────────────────────────────────────────────

  plug :verify_livekit_signature when action in [:handle]

  # ── Handlers ─────────────────────────────────────────────────────────────

  @doc "Main webhook entry point — dispatches by event type."
  def handle(conn, %{"event" => event} = params) do
    Logger.info("[LiveKit Webhook] Received event: #{event}")

    case event do
      "participant_joined" -> handle_participant_joined(conn, params)
      "participant_left" -> handle_participant_left(conn, params)
      "room_started" -> handle_room_started(conn, params)
      "room_finished" -> handle_room_finished(conn, params)
      "egress_ended" -> handle_egress_ended(conn, params)
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

  defp handle_egress_ended(conn, params) do
    room_name = get_in(params, ["room", "name"])
    egress_id = get_in(params, ["egressInfo", "egressId"])
    file_url = extract_file_url(params)
    status = get_in(params, ["egressInfo", "status"])

    case Meetings.get_room_by_name(room_name) do
      nil ->
        Logger.warning("[LiveKit Webhook] egress_ended for unknown room: #{room_name}")
        conn |> put_status(:ok) |> json(%{status: "ignored", reason: "unknown room"})

      room ->
        # Store egress info in room metadata
        egress_info = %{
          "egress_id" => egress_id,
          "file_url" => file_url,
          "status" => status,
          "ended_at" => DateTime.utc_now() |> DateTime.to_iso8601()
        }

        existing_egresses = Map.get(room.metadata || %{}, "egresses", [])

        updated_metadata =
          Map.put(room.metadata || %{}, "egresses", existing_egresses ++ [egress_info])

        case room
             |> Platform.Meetings.Room.changeset(%{metadata: updated_metadata})
             |> Platform.Repo.update() do
          {:ok, _room} ->
            Logger.info(
              "[LiveKit Webhook] Egress ended: #{egress_id} for room #{room_name} (#{status})"
            )

            conn
            |> put_status(:ok)
            |> json(%{
              status: "recorded",
              event: "egress_ended",
              egress_id: egress_id,
              file_url: file_url
            })

          {:error, changeset} ->
            Logger.warning(
              "[LiveKit Webhook] Failed to record egress for #{room_name}: #{inspect(changeset)}"
            )

            conn
            |> put_status(:unprocessable_entity)
            |> json(%{status: "error", reason: "failed to record egress"})
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

  defp read_raw_body(conn) do
    case Plug.Conn.read_body(conn) do
      {:ok, body, _conn} -> body
      _ -> ""
    end
  end

  defp extract_file_url(params) do
    # LiveKit egress can have file or segments output
    get_in(params, ["egressInfo", "file", "filename"]) ||
      get_in(params, ["egressInfo", "fileResults", Access.at(0), "filename"]) ||
      get_in(params, ["egressInfo", "segmentResults", Access.at(0), "playlistName"])
  end

  # ── Signature verification ──────────────────────────────────────────────

  defp verify_livekit_signature(conn, _opts) do
    secret = System.get_env("LIVEKIT_WEBHOOK_SECRET")

    if is_nil(secret) or secret == "" do
      # No secret configured — reject all requests for safety
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
        raw_body = conn.assigns[:raw_body] || read_raw_body(conn)
        body_len = byte_size(raw_body || "")
        has_raw = Map.has_key?(conn.assigns, :raw_body)

        Logger.debug("[LiveKit Webhook] raw_body in assigns=#{has_raw}, length=#{body_len}")

        if verify_livekit_token(auth_header, raw_body, secret) do
          conn
        else
          Logger.warning("[LiveKit Webhook] Invalid webhook signature, body_len=#{body_len}")

          conn
          |> put_status(:unauthorized)
          |> json(%{status: "error", reason: "invalid signature"})
          |> halt()
        end
      end
    end
  end

  @doc """
  Verify a LiveKit webhook token.

  LiveKit signs webhooks using a JWT (HS256) with the API secret.
  The JWT body hash claim must match the SHA256 of the raw request body.
  """
  def verify_livekit_token(token, body, secret) do
    try do
      # LiveKit uses a simple JWT with HS256
      # The token contains a `sha256` claim that must match the body hash
      case decode_jwt(token, secret) do
        {:ok, claims} ->
          expected_hash = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
          token_hash = Map.get(claims, "sha256", "")
          Plug.Crypto.secure_compare(expected_hash, String.downcase(token_hash))

        {:error, _reason} ->
          false
      end
    rescue
      _ -> false
    end
  end

  defp decode_jwt(token, secret) do
    # Simple HS256 JWT decode — LiveKit webhook tokens are compact JWTs
    case String.split(token, ".") do
      [header_b64, payload_b64, signature_b64] ->
        signing_input = "#{header_b64}.#{payload_b64}"

        with {:ok, sig} <- Base.url_decode64(signature_b64, padding: false),
             computed_sig <- :crypto.mac(:hmac, :sha256, secret, signing_input),
             true <- Plug.Crypto.secure_compare(computed_sig, sig),
             {:ok, payload_json} <- Base.url_decode64(payload_b64, padding: false),
             {:ok, claims} <- Jason.decode(payload_json) do
          {:ok, claims}
        else
          _ -> {:error, :invalid_token}
        end

      _ ->
        {:error, :malformed_token}
    end
  end
end
