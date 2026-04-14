/**
 * RecordingPlayer hook — inline audio/video player with seekable timeline.
 *
 * Mounted on a container element with `data-src` pointing to the recording
 * stream URL. Creates an HTML5 audio element with play/pause, seek, time
 * display, and playback speed controls.
 */
const RecordingPlayer = {
  mounted() {
    const src = this.el.dataset.src
    if (!src) return

    this._audio = new Audio(src)
    this._audio.preload = "metadata"

    // DOM references
    this._playPauseBtn = this.el.querySelector('[data-role="play-pause"]')
    this._playIcon = this.el.querySelector('[data-icon="play"]')
    this._pauseIcon = this.el.querySelector('[data-icon="pause"]')
    this._seekBar = this.el.querySelector('[data-role="seek"]')
    this._currentTime = this.el.querySelector('[data-role="current-time"]')
    this._totalTime = this.el.querySelector('[data-role="total-time"]')
    this._speedSelect = this.el.querySelector('[data-role="speed"]')
    this._loadingEl = this.el.querySelector('[data-role="loading"]')
    this._errorEl = this.el.querySelector('[data-role="error"]')

    this._setupEventListeners()
  },

  destroyed() {
    if (this._audio) {
      this._audio.pause()
      this._audio.src = ""
      this._audio = null
    }
  },

  _setupEventListeners() {
    const audio = this._audio

    // Audio events
    audio.addEventListener("loadedmetadata", () => {
      if (this._loadingEl) this._loadingEl.classList.add("hidden")
      if (this._totalTime) this._totalTime.textContent = this._formatTime(audio.duration)
      if (this._seekBar) this._seekBar.max = audio.duration
    })

    audio.addEventListener("timeupdate", () => {
      if (this._currentTime) this._currentTime.textContent = this._formatTime(audio.currentTime)
      if (this._seekBar && !this._seeking) {
        this._seekBar.value = audio.currentTime
      }
    })

    audio.addEventListener("ended", () => {
      this._showPlayIcon()
    })

    audio.addEventListener("error", () => {
      if (this._loadingEl) this._loadingEl.classList.add("hidden")
      if (this._errorEl) this._errorEl.classList.remove("hidden")
    })

    audio.addEventListener("canplay", () => {
      if (this._loadingEl) this._loadingEl.classList.add("hidden")
    })

    // Play/pause button
    if (this._playPauseBtn) {
      this._playPauseBtn.addEventListener("click", () => {
        if (audio.paused) {
          audio.play()
          this._showPauseIcon()
        } else {
          audio.pause()
          this._showPlayIcon()
        }
      })
    }

    // Seek bar
    if (this._seekBar) {
      this._seekBar.addEventListener("mousedown", () => { this._seeking = true })
      this._seekBar.addEventListener("mouseup", () => { this._seeking = false })
      this._seekBar.addEventListener("input", (e) => {
        audio.currentTime = parseFloat(e.target.value)
      })
    }

    // Speed control
    if (this._speedSelect) {
      this._speedSelect.addEventListener("change", (e) => {
        audio.playbackRate = parseFloat(e.target.value)
      })
    }
  },

  _showPlayIcon() {
    if (this._playIcon) this._playIcon.classList.remove("hidden")
    if (this._pauseIcon) this._pauseIcon.classList.add("hidden")
  },

  _showPauseIcon() {
    if (this._playIcon) this._playIcon.classList.add("hidden")
    if (this._pauseIcon) this._pauseIcon.classList.remove("hidden")
  },

  _formatTime(seconds) {
    if (!seconds || isNaN(seconds)) return "0:00"
    const mins = Math.floor(seconds / 60)
    const secs = Math.floor(seconds % 60)
    return `${mins}:${secs.toString().padStart(2, "0")}`
  },
}

export default RecordingPlayer
