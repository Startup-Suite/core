/**
 * MeetingRoom hook — root-level LiveKit Room manager.
 *
 * Mounted on a persistent DOM element in the shell layout (outside per-page
 * LiveViews) so the connection survives LiveView navigation.
 *
 * Lifecycle:
 *   1. Server pushes "join-meeting" with {token, url, room_name, space_slug}
 *   2. Hook dynamically imports livekit-client, creates Room, connects
 *   3. Audio/video elements attached to a root-level container (#meeting-media)
 *   4. State changes pushed back to server via pushEvent
 *   5. Server pushes "leave-meeting" or user clicks leave → disconnect + cleanup
 *
 * The hook also drives the duration timer displayed in the meeting bar.
 */
const MeetingRoom = {
  mounted() {
    // State
    this.room = null
    this.joinedAt = null
    this.timerInterval = null
    this.micEnabled = true
    this.cameraEnabled = false

    // Listen for server push events
    this.handleEvent("join-meeting", (payload) => this.joinMeeting(payload))
    this.handleEvent("leave-meeting", () => this.leaveMeeting())
    this.handleEvent("toggle-mic", () => this.toggleMic())
    this.handleEvent("toggle-camera", () => this.toggleCamera())
  },

  destroyed() {
    this.leaveMeeting()
  },

  async joinMeeting({ token, url, room_name, space_slug }) {
    // Avoid double-join
    if (this.room) {
      console.warn("[MeetingRoom] Already in a meeting, leaving first")
      await this.leaveMeeting()
    }

    try {
      // Dynamic import — livekit-client is only loaded when needed
      const { Room, RoomEvent, Track } = await import("livekit-client")

      this.room = new Room({
        adaptiveStream: true,
        dynacast: true,
      })

      // Wire up event handlers
      this.room.on(RoomEvent.TrackSubscribed, (track, publication, participant) => {
        this.handleTrackSubscribed(track, participant)
      })

      this.room.on(RoomEvent.TrackUnsubscribed, (track, publication, participant) => {
        this.handleTrackUnsubscribed(track, participant)
      })

      this.room.on(RoomEvent.Disconnected, () => {
        this.handleDisconnected()
      })

      this.room.on(RoomEvent.ParticipantConnected, (participant) => {
        this.pushEvent("meeting-participant-connected", {
          identity: participant.identity,
          name: participant.name || participant.identity,
        })
      })

      this.room.on(RoomEvent.ParticipantDisconnected, (participant) => {
        this.pushEvent("meeting-participant-disconnected", {
          identity: participant.identity,
        })
      })

      // Active speaker detection — fires when speaking participants change
      this.room.on(RoomEvent.ActiveSpeakersChanged, (speakers) => {
        const identities = speakers.map((p) => p.identity)
        this.pushEvent("meeting-active-speakers-changed", {
          identities: identities,
        })
      })

      // Transcription — forward captions to MeetingCaptions hook via DOM event
      this.room.on(RoomEvent.TranscriptionReceived, (segments, participant) => {
        if (!segments || segments.length === 0) return
        const speakerName = participant?.name || participant?.identity || "Unknown"
        for (const seg of segments) {
          document.dispatchEvent(new CustomEvent("meeting:caption", {
            detail: {
              id: seg.id || crypto.randomUUID(),
              speaker: speakerName,
              text: seg.text || "",
              final: seg.final !== false,
              timestamp: seg.startTime || Date.now(),
            },
          }))
        }
      })

      // Connect
      await this.room.connect(url, token)

      // Expose room reference for MeetingCaptions hook
      window.__livekitRoom = this.room
      window.dispatchEvent(new Event("livekit:room-connected"))

      // Enable mic by default
      await this.room.localParticipant.setMicrophoneEnabled(true)
      this.micEnabled = true
      this.cameraEnabled = false

      // Start duration timer
      this.joinedAt = Date.now()
      this.startTimer()

      // Notify server we're connected
      this.pushEvent("meeting-joined", {
        room_name: room_name,
        space_slug: space_slug,
      })
    } catch (error) {
      console.error("[MeetingRoom] Failed to join meeting:", error)
      this.pushEvent("meeting-error", { message: error.message })
    }
  },

  async leaveMeeting() {
    this.stopTimer()

    if (this.room) {
      try {
        this.room.disconnect(true)
      } catch (e) {
        console.warn("[MeetingRoom] Error during disconnect:", e)
      }
      this.room = null
    }

    // Clean up global reference
    if (window.__livekitRoom === this.room) {
      window.__livekitRoom = null
    }

    this.joinedAt = null
    this.micEnabled = true
    this.cameraEnabled = false

    // Remove any media elements we created
    const mediaContainer = document.getElementById("meeting-media")
    if (mediaContainer) {
      mediaContainer.innerHTML = ""
    }

    this.pushEvent("meeting-left", {})
  },

  async toggleMic() {
    if (!this.room) return

    try {
      this.micEnabled = !this.micEnabled
      await this.room.localParticipant.setMicrophoneEnabled(this.micEnabled)
      this.pushEvent("meeting-mic-toggled", { enabled: this.micEnabled })
    } catch (error) {
      console.error("[MeetingRoom] Failed to toggle mic:", error)
      // Revert state
      this.micEnabled = !this.micEnabled
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
      this.cameraEnabled = !this.cameraEnabled
    }
  },

  handleTrackSubscribed(track, participant) {
    const mediaContainer = document.getElementById("meeting-media")
    if (!mediaContainer) return

    const el = track.attach()
    el.id = `track-${participant.identity}-${track.sid}`
    el.dataset.participantIdentity = participant.identity

    // Audio tracks are hidden but still attached for playback
    if (track.kind === "audio") {
      el.style.display = "none"
    }

    mediaContainer.appendChild(el)
  },

  handleTrackUnsubscribed(track, participant) {
    const elements = track.detach()
    elements.forEach((el) => el.remove())
  },

  handleDisconnected() {
    this.stopTimer()
    this.room = null
    this.joinedAt = null

    const mediaContainer = document.getElementById("meeting-media")
    if (mediaContainer) {
      mediaContainer.innerHTML = ""
    }

    this.pushEvent("meeting-disconnected", {})
  },

  startTimer() {
    this.stopTimer()
    this.updateTimerDisplay()
    this.timerInterval = setInterval(() => this.updateTimerDisplay(), 1000)
  },

  stopTimer() {
    if (this.timerInterval) {
      clearInterval(this.timerInterval)
      this.timerInterval = null
    }
  },

  updateTimerDisplay() {
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
