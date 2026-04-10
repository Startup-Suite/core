defmodule PlatformWeb.LivekitWebhookControllerTest do
  use PlatformWeb.ConnCase, async: true

  alias Platform.Meetings

  @livekit_webhook_path "/api/webhooks/livekit"

  # ── Test helpers ─────────────────────────────────────────────────────────

  defp webhook_secret, do: "test-livekit-secret"

  defp sign_request(secret) do
    # Create a minimal valid HS256 JWT signed with the secret
    header = %{"alg" => "HS256", "typ" => "JWT"}
    payload = %{"iss" => "livekit", "nbf" => System.system_time(:second)}

    header_b64 = header |> Jason.encode!() |> Base.url_encode64(padding: false)
    payload_b64 = payload |> Jason.encode!() |> Base.url_encode64(padding: false)

    signing_input = header_b64 <> "." <> payload_b64
    signature = :crypto.mac(:hmac, :sha256, secret, signing_input)
    sig_b64 = Base.url_encode64(signature, padding: false)

    header_b64 <> "." <> payload_b64 <> "." <> sig_b64
  end

  defp post_webhook(conn, payload, opts \\ []) do
    secret = Keyword.get(opts, :secret, webhook_secret())
    token = sign_request(secret)

    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", token)
    |> post(@livekit_webhook_path, payload)
  end

  defp participant_joined_payload(room_name, identity, name \\ nil) do
    %{
      "event" => "participant_joined",
      "room" => %{"name" => room_name, "sid" => "RM_test123"},
      "participant" => %{
        "identity" => identity,
        "name" => name || identity,
        "sid" => "PA_#{identity}",
        "metadata" => ""
      }
    }
  end

  defp participant_left_payload(room_name, identity) do
    %{
      "event" => "participant_left",
      "room" => %{"name" => room_name, "sid" => "RM_test123"},
      "participant" => %{
        "identity" => identity,
        "sid" => "PA_#{identity}"
      }
    }
  end

  defp room_started_payload(room_name) do
    %{
      "event" => "room_started",
      "room" => %{"name" => room_name, "sid" => "RM_test123"}
    }
  end

  defp room_finished_payload(room_name) do
    %{
      "event" => "room_finished",
      "room" => %{"name" => room_name, "sid" => "RM_test123"}
    }
  end

  defp egress_ended_payload(room_name, egress_id, file_url) do
    %{
      "event" => "egress_ended",
      "room" => %{"name" => room_name, "sid" => "RM_test123"},
      "egressInfo" => %{
        "egressId" => egress_id,
        "status" => "EGRESS_COMPLETE",
        "file" => %{"filename" => file_url}
      }
    }
  end

  # ── Setup ────────────────────────────────────────────────────────────────

  setup do
    System.put_env("LIVEKIT_WEBHOOK_SECRET", webhook_secret())
    on_exit(fn -> System.delete_env("LIVEKIT_WEBHOOK_SECRET") end)
    :ok
  end

  # ── Participant joined tests ─────────────────────────────────────────────

  describe "POST #{@livekit_webhook_path} — participant_joined" do
    test "records a new participant and creates room if needed", %{conn: conn} do
      room_name = "room-#{System.unique_integer([:positive])}"
      payload = participant_joined_payload(room_name, "user-alice", "Alice")

      conn = post_webhook(conn, payload)

      assert %{
               "status" => "recorded",
               "event" => "participant_joined",
               "participant_id" => id
             } = json_response(conn, 201)

      assert is_binary(id)

      room = Meetings.get_room_by_name(room_name)
      assert room != nil

      participants = Meetings.list_active_participants(room.id)
      assert length(participants) == 1
      assert hd(participants).identity == "user-alice"
      assert hd(participants).name == "Alice"
    end

    test "records multiple participants in the same room", %{conn: conn} do
      room_name = "room-#{System.unique_integer([:positive])}"

      conn1 = post_webhook(conn, participant_joined_payload(room_name, "user-alice"))
      assert %{"status" => "recorded"} = json_response(conn1, 201)

      conn2 = post_webhook(conn, participant_joined_payload(room_name, "user-bob"))
      assert %{"status" => "recorded"} = json_response(conn2, 201)

      room = Meetings.get_room_by_name(room_name)
      participants = Meetings.list_active_participants(room.id)
      assert length(participants) == 2
    end
  end

  # ── Participant left tests ──────────────────────────────────────────────

  describe "POST #{@livekit_webhook_path} — participant_left" do
    test "marks participant as left", %{conn: conn} do
      room_name = "room-#{System.unique_integer([:positive])}"

      conn1 = post_webhook(conn, participant_joined_payload(room_name, "user-alice"))
      assert %{"status" => "recorded"} = json_response(conn1, 201)

      conn2 = post_webhook(conn, participant_left_payload(room_name, "user-alice"))

      assert %{
               "status" => "recorded",
               "event" => "participant_left"
             } = json_response(conn2, 200)

      room = Meetings.get_room_by_name(room_name)
      active = Meetings.list_active_participants(room.id)
      assert active == []
    end

    test "ignores leave for unknown room", %{conn: conn} do
      payload = participant_left_payload("nonexistent-room", "user-alice")
      conn = post_webhook(conn, payload)

      assert %{"status" => "ignored", "reason" => "unknown room"} = json_response(conn, 200)
    end

    test "ignores leave for unknown participant", %{conn: conn} do
      room_name = "room-#{System.unique_integer([:positive])}"

      conn1 = post_webhook(conn, participant_joined_payload(room_name, "user-alice"))
      assert %{"status" => "recorded"} = json_response(conn1, 201)

      conn2 = post_webhook(conn, participant_left_payload(room_name, "user-unknown"))

      assert %{"status" => "ignored", "reason" => "participant not found"} =
               json_response(conn2, 200)
    end
  end

  # ── Room started tests ─────────────────────────────────────────────────

  describe "POST #{@livekit_webhook_path} — room_started" do
    test "creates room and sets status to active", %{conn: conn} do
      room_name = "room-#{System.unique_integer([:positive])}"
      payload = room_started_payload(room_name)

      conn = post_webhook(conn, payload)

      assert %{
               "status" => "recorded",
               "event" => "room_started",
               "room_id" => _id
             } = json_response(conn, 200)

      room = Meetings.get_room_by_name(room_name)
      assert room.status == "active"
    end

    test "activates existing idle room", %{conn: conn} do
      room_name = "room-#{System.unique_integer([:positive])}"
      {:ok, _room} = Meetings.find_or_create_room(room_name)

      conn = post_webhook(conn, room_started_payload(room_name))

      assert %{"status" => "recorded"} = json_response(conn, 200)

      room = Meetings.get_room_by_name(room_name)
      assert room.status == "active"
    end
  end

  # ── Room finished tests ────────────────────────────────────────────────

  describe "POST #{@livekit_webhook_path} — room_finished" do
    test "sets room to idle and cleans up participants", %{conn: conn} do
      room_name = "room-#{System.unique_integer([:positive])}"

      post_webhook(conn, room_started_payload(room_name))
      post_webhook(conn, participant_joined_payload(room_name, "user-alice"))
      post_webhook(conn, participant_joined_payload(room_name, "user-bob"))

      room = Meetings.get_room_by_name(room_name)
      assert length(Meetings.list_active_participants(room.id)) == 2

      conn = post_webhook(conn, room_finished_payload(room_name))

      assert %{
               "status" => "recorded",
               "event" => "room_finished"
             } = json_response(conn, 200)

      room = Meetings.get_room_by_name(room_name)
      assert room.status == "idle"
      assert Meetings.list_active_participants(room.id) == []
    end

    test "ignores finish for unknown room", %{conn: conn} do
      conn = post_webhook(conn, room_finished_payload("nonexistent-room"))

      assert %{"status" => "ignored", "reason" => "unknown room"} = json_response(conn, 200)
    end
  end

  # ── Egress ended tests ─────────────────────────────────────────────────

  describe "POST #{@livekit_webhook_path} — egress_ended" do
    test "records egress info in room metadata", %{conn: conn} do
      room_name = "room-#{System.unique_integer([:positive])}"

      post_webhook(conn, room_started_payload(room_name))

      payload = egress_ended_payload(room_name, "EG_abc123", "recordings/meeting.mp4")
      conn = post_webhook(conn, payload)

      assert %{
               "status" => "recorded",
               "event" => "egress_ended",
               "egress_id" => "EG_abc123",
               "file_url" => "recordings/meeting.mp4"
             } = json_response(conn, 200)

      room = Meetings.get_room_by_name(room_name)
      assert [egress] = room.metadata["egresses"]
      assert egress["egress_id"] == "EG_abc123"
      assert egress["file_url"] == "recordings/meeting.mp4"
      assert egress["status"] == "EGRESS_COMPLETE"
    end

    test "ignores egress for unknown room", %{conn: conn} do
      payload = egress_ended_payload("nonexistent-room", "EG_abc", "file.mp4")
      conn = post_webhook(conn, payload)

      assert %{"status" => "ignored", "reason" => "unknown room"} = json_response(conn, 200)
    end
  end

  # ── Unhandled events ───────────────────────────────────────────────────

  describe "POST #{@livekit_webhook_path} — unhandled events" do
    test "ignores unknown event types", %{conn: conn} do
      payload = %{"event" => "track_published", "room" => %{"name" => "test"}}
      conn = post_webhook(conn, payload)

      assert %{"status" => "ignored", "reason" => "unhandled event"} = json_response(conn, 200)
    end

    test "ignores payloads without event field", %{conn: conn} do
      conn = post_webhook(conn, %{"something" => "else"})

      assert %{"status" => "ignored", "reason" => "no event field"} = json_response(conn, 200)
    end
  end

  # ── Signature verification tests ───────────────────────────────────────

  describe "signature verification" do
    test "rejects requests without authorization header", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(@livekit_webhook_path, %{"event" => "room_started"})

      assert %{"status" => "error", "reason" => "missing authorization header"} =
               json_response(conn, 401)
    end

    test "rejects requests with invalid signature", %{conn: conn} do
      bad_token = sign_request("wrong-secret")

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", bad_token)
        |> post(@livekit_webhook_path, %{"event" => "room_started"})

      assert %{"status" => "error", "reason" => "invalid signature"} =
               json_response(conn, 401)
    end

    test "rejects when LIVEKIT_WEBHOOK_SECRET is not set", %{conn: conn} do
      System.delete_env("LIVEKIT_WEBHOOK_SECRET")

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "some-token")
        |> post(@livekit_webhook_path, %{"event" => "room_started"})

      assert %{"status" => "error", "reason" => "webhook secret not configured"} =
               json_response(conn, 401)
    end

    test "verify_jwt_signature/2 returns true for valid token" do
      secret = "test-secret"
      token = sign_request(secret)
      assert PlatformWeb.LivekitWebhookController.verify_jwt_signature(token, secret)
    end

    test "verify_jwt_signature/2 returns false for wrong secret" do
      token = sign_request("correct-secret")
      refute PlatformWeb.LivekitWebhookController.verify_jwt_signature(token, "wrong-secret")
    end

    test "verify_jwt_signature/2 returns false for malformed token" do
      refute PlatformWeb.LivekitWebhookController.verify_jwt_signature("not-a-jwt", "secret")
    end
  end

  # ── PubSub broadcast tests ────────────────────────────────────────────

  describe "PubSub broadcasts" do
    test "participant_joined broadcasts on room topic", %{conn: conn} do
      room_name = "room-#{System.unique_integer([:positive])}"

      {:ok, room} = Meetings.find_or_create_room(room_name)
      Meetings.subscribe_room(room.id)

      post_webhook(conn, participant_joined_payload(room_name, "user-alice", "Alice"))

      assert_receive {:participant_joined, participant}
      assert participant.identity == "user-alice"
      assert participant.name == "Alice"
    end

    test "participant_left broadcasts on room topic", %{conn: conn} do
      room_name = "room-#{System.unique_integer([:positive])}"

      post_webhook(conn, participant_joined_payload(room_name, "user-alice"))

      room = Meetings.get_room_by_name(room_name)
      Meetings.subscribe_room(room.id)

      post_webhook(conn, participant_left_payload(room_name, "user-alice"))

      assert_receive {:participant_left, participant}
      assert participant.identity == "user-alice"
      assert participant.left_at != nil
    end

    test "room_finished broadcasts on room topic", %{conn: conn} do
      room_name = "room-#{System.unique_integer([:positive])}"

      post_webhook(conn, room_started_payload(room_name))

      room = Meetings.get_room_by_name(room_name)
      Meetings.subscribe_room(room.id)

      post_webhook(conn, room_finished_payload(room_name))

      assert_receive {:room_finished, finished_room}
      assert finished_room.status == "idle"
    end
  end
end
