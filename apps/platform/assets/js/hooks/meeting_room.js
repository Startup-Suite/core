/**
 * MeetingRoom hook — full meeting lifecycle bridge between LiveView and LiveKit.
 *
 * Handles: join/leave, mic/camera/screen-share toggles, call duration timer,
 * track subscription/unsubscription, participant connect/disconnect events,
 * active speaker detection, and graceful cleanup on disconnect.
 *
 * Server push events consumed:
 *   - "join-meeting"   {token, url, room_name, space_slug}
 *   - "leave-meeting"  (no payload)
 *   - "toggle-mic"     (no payload)
 *   - "toggle-camera"  (no payload)
 *   - "toggle-screen-share" (no payload)
 *
 * Client pushEvents emitted:
 *   - "meeting-joined"                 {room_name, space_slug}
 *   - "meeting-left"                   {}
 *   - "meeting-disconnected"           {}
 *   - "meeting-error"                  {message}
 *   - "meeting-mic-toggled"            {enabled}
 *   - "meeting-camera-toggled"         {enabled}
 *   - "meeting-screen-share-toggled"   {enabled}
 *   - "meeting-participant-connected"  {identity, name}
 *   - "meeting-participant-disconnected" {identity}
 *   - "meeting-active-speakers-changed"  {identities}
 *
 * Also dispatches `meeting:caption` DOM events for MeetingCaptions hook
 * when transcription segments arrive.
 */
import { createParticipantTile, removeParticipantTile, attachTrackToTile,
         detachTrackFromTile, setActiveSpeakers, clearAllTiles } from "./meeting_panel"

const MeetingRoom = {
  mounted() {
    this.room = null
    this.joinedAt = null
    this.timerInterval = null
    this.micEnabled = true
    this.cameraEnabled = false
    this.screenShareEnabled = false

    // Server → client event bindings
    this.handleEvent("join-meeting", (payload) => this.joinMeeting(payload))
    this.handleEvent("leave-meeting", () => this.leaveMeeting())
    this.handleEvent("toggle-mic", () => this.toggleMic())
    this.handleEvent("toggle-camera", () => this.toggleCamera())
    this.handleEvent("toggle-screen-share", () => this.toggleScreenShare())
  },

  destroyed() {
    this.leaveMeeting()
  },

  // ── Join / Leave ─────────────────────────────────────────────────────

  async joinMeeting({ token, url, room_name, space_slug }) {
    if (this.room) {
      console.warn("[MeetingRoom] Already in a meeting, leaving first")
      await this.leaveMeeting()
    }

    try {
      const { Room, RoomEvent } = await import("livekit-client")

      this.room = new Room({
        adaptiveStream: true,
        dynacast: true,
      })

      // ── Track events ──
      this.room.on(RoomEvent.TrackSubscribed, (track, _publication, participant) => {
        this._handleTrackSubscribed(track, participant)
      })

      this.room.on(RoomEvent.TrackUnsubscribed, (track, _publication, participant) => {
        this._handleTrackUnsubscribed(track, participant)
      })

      // ── Participant events ──
      this.room.on(RoomEvent.ParticipantConnected, (participant) => {
        createParticipantTile(participant)
        this.pushEvent("meeting-participant-connected", {
          identity: participant.identity,
          name: participant.name || participant.identity,
        })
      })

      this.room.on(RoomEvent.ParticipantDisconnected, (participant) => {
        removeParticipantTile(participant.identity)
        this.pushEvent("meeting-participant-disconnected", {
          identity: participant.identity,
        })
      })

      // ── Active speakers ──
      this.room.on(RoomEvent.ActiveSpeakersChanged, (speakers) => {
        const identities = speakers.map((p) => p.identity)
        setActiveSpeakers(identities)
        this.pushEvent("meeting-active-speakers-changed", { identities })
      })

      // ── Disconnect ──
      this.room.on(RoomEvent.Disconnected, () => {
        this._handleDisconnected()
      })

      // ── Transcription (for MeetingCaptions hook) ──
      this.room.on(RoomEvent.TranscriptionReceived, (segments, participant) => {
        this._onTranscription(segments, participant)
      })

      // Connect and enable mic by default
      await this.room.connect(url, token)

      // Expose room globally for other hooks/debug
      window.__livekitRoom = this.room
      window.dispatchEvent(new CustomEvent("livekit:room-connected"))

      await this.room.localParticipant.setMicrophoneEnabled(true)
      this.micEnabled = true
      this.cameraEnabled = false
      this.screenShareEnabled = false

      // Create tiles for participants already in the room
      this.room.remoteParticipants.forEach((participant) => {
        createParticipantTile(participant)
      })
      // Local participant tile
      createParticipantTile(this.room.localParticipant, true)

      // Start call timer
      this.joinedAt = Date.now()
      this._startTimer()

      this.pushEvent("meeting-joined", { room_name, space_slug })
    } catch (error) {
      console.error("[MeetingRoom] Failed to join meeting:", error)
      this.pushEvent("meeting-error", { message: error.message })
    }
  },

  async leaveMeeting() {
    this._stopTimer()

    if (this.room) {
      try {
        this.room.disconnect(true)
      } catch (e) {
        console.warn("[MeetingRoom] Error during disconnect:", e)
      }
      this.room = null
      window.__livekitRoom = null
    }

    this.joinedAt = null
    this.micEnabled = true
    this.cameraEnabled = false
    this.screenShareEnabled = false

    clearAllTiles()
    this.pushEvent("meeting-left", {})
  },

  // ── Toggles ──────────────────────────────────────────────────────────

  async toggleMic() {
    if (!this.room) return
    try {
      this.micEnabled = !this.micEnabled
      await this.room.localParticipant.setMicrophoneEnabled(this.micEnabled)
      this.pushEvent("meeting-mic-toggled", { enabled: this.micEnabled })
    } catch (error) {
      console.error("[MeetingRoom] Failed to toggle mic:", error)
      this.micEnabled = !this.micEnabled // revert
    }
  },

  async toggleCamera() {
    if (!this.room) return
    try {
      this.cameraEnabled = !this.cameraEnabled
      await this.room.localParticipant.setCameraEnabled(this.cameraEnabled)
      this.pushEvent("meeting-camera-toggled", { enabled: this.cameraEnabled })
    } catch (error) {
      console.error("[MeetingRoom] Failed to toggle camera:", error)
      this.cameraEnabled = !this.cameraEnabled // revert
    }
  },

  async toggleScreenShare() {
    if (!this.room) return
    try {
      this.screenShareEnabled = !this.screenShareEnabled
      await this.room.localParticipant.setScreenShareEnabled(this.screenShareEnabled)
      this.pushEvent("meeting-screen-share-toggled", { enabled: this.screenShareEnabled })
    } catch (error) {
      console.error("[MeetingRoom] Failed to toggle screen share:", error)
      this.screenShareEnabled = !this.screenShareEnabled // revert
    }
  },

  // ── Track handlers ───────────────────────────────────────────────────

  _handleTrackSubscribed(track, participant) {
    attachTrackToTile(track, participant)
  },

  _handleTrackUnsubscribed(track, participant) {
    detachTrackFromTile(track, participant)
  },

  // ── Disconnect handler ───────────────────────────────────────────────

  _handleDisconnected() {
    this._stopTimer()
    this.room = null
    this.joinedAt = null
    window.__livekitRoom = null
    clearAllTiles()
    this.pushEvent("meeting-disconnected", {})
  },

  // ── Transcription passthrough (for MeetingCaptions) ──────────────────

  _onTranscription(segments, participant) {
    if (!segments || segments.length === 0) return
    const speakerName = participant?.name || participant?.identity || "Unknown"

    for (const seg of segments) {
      const detail = {
        id: seg.id || crypto.randomUUID(),
        speaker: speakerName,
        text: seg.text || "",
        final: seg.final !== false,
        timestamp: seg.startTime || Date.now(),
      }
      document.dispatchEvent(new CustomEvent("meeting:caption", { detail }))
    }
  },

  // ── Call duration timer ──────────────────────────────────────────────

  _startTimer() {
    this._stopTimer()
    this._updateTimerDisplay()
    this.timerInterval = setInterval(() => this._updateTimerDisplay(), 1000)
  },

  _stopTimer() {
    if (this.timerInterval) {
      clearInterval(this.timerInterval)
      this.timerInterval = null
    }
  },

  _updateTimerDisplay() {
    if (!this.joinedAt) return
    const elapsed = Math.floor((Date.now() - this.joinedAt) / 1000)
    const hours = Math.floor(elapsed / 3600)
    const minutes = Math.floor((elapsed % 3600) / 60)
    const seconds = elapsed % 60

    const display = hours > 0
      ? `${hours}:${String(minutes).padStart(2, "0")}:${String(seconds).padStart(2, "0")}`
      : `${minutes}:${String(seconds).padStart(2, "0")}`

    const timerEl = document.getElementById("meeting-duration")
    if (timerEl) {
      timerEl.textContent = display
    }
  },
}

export default MeetingRoom
