/**
 * RecordingPlayer — JS hook for inline recording playback.
 *
 * Initializes an HTML5 <audio>/<video> element with seeking,
 * play/pause, time display, and playback speed controls.
 *
 * Data attributes:
 *   data-src — URL to the recording stream endpoint
 *   data-type — MIME type (default "video/webm")
 */
const RecordingPlayer = {
  mounted() {
    this.mediaEl = this.el.querySelector("[data-media]")
    this.seekBar = this.el.querySelector("[data-seek]")
    this.currentTimeEl = this.el.querySelector("[data-current-time]")
    this.durationEl = this.el.querySelector("[data-duration]")
    this.playBtn = this.el.querySelector("[data-play-btn]")
    this.speedBtn = this.el.querySelector("[data-speed-btn]")

    if (!this.mediaEl) return

    this.speeds = [0.5, 1, 1.5, 2]
    this.speedIndex = 1

    // Play/Pause toggle
    if (this.playBtn) {
      this.playBtn.addEventListener("click", () => {
        if (this.mediaEl.paused) {
          this.mediaEl.play()
        } else {
          this.mediaEl.pause()
        }
      })
    }

    // Speed toggle
    if (this.speedBtn) {
      this.speedBtn.addEventListener("click", () => {
        this.speedIndex = (this.speedIndex + 1) % this.speeds.length
        this.mediaEl.playbackRate = this.speeds[this.speedIndex]
        this.speedBtn.textContent = this.speeds[this.speedIndex] + "x"
      })
    }

    // Seek bar
    if (this.seekBar) {
      this.seekBar.addEventListener("input", () => {
        if (this.mediaEl.duration) {
          this.mediaEl.currentTime =
            (this.seekBar.value / 100) * this.mediaEl.duration
        }
      })
    }

    // Update UI on play/pause
    this.mediaEl.addEventListener("play", () => {
      if (this.playBtn) {
        this.playBtn.setAttribute("data-playing", "true")
      }
    })

    this.mediaEl.addEventListener("pause", () => {
      if (this.playBtn) {
        this.playBtn.removeAttribute("data-playing")
      }
    })

    // Update time display and seek bar
    this.mediaEl.addEventListener("timeupdate", () => {
      if (this.currentTimeEl) {
        this.currentTimeEl.textContent = this.formatTime(
          this.mediaEl.currentTime,
        )
      }
      if (this.seekBar && this.mediaEl.duration) {
        this.seekBar.value =
          (this.mediaEl.currentTime / this.mediaEl.duration) * 100
      }
    })

    // Set duration once loaded
    this.mediaEl.addEventListener("loadedmetadata", () => {
      if (this.durationEl) {
        this.durationEl.textContent = this.formatTime(this.mediaEl.duration)
      }
    })

    // Handle end of playback
    this.mediaEl.addEventListener("ended", () => {
      if (this.playBtn) {
        this.playBtn.removeAttribute("data-playing")
      }
      if (this.seekBar) {
        this.seekBar.value = 0
      }
    })

    // Handle errors
    this.mediaEl.addEventListener("error", () => {
      const errorEl = this.el.querySelector("[data-error]")
      if (errorEl) {
        errorEl.classList.remove("hidden")
      }
    })
  },

  destroyed() {
    if (this.mediaEl) {
      this.mediaEl.pause()
      this.mediaEl.src = ""
    }
  },

  formatTime(seconds) {
    if (!seconds || isNaN(seconds)) return "0:00"
    const m = Math.floor(seconds / 60)
    const s = Math.floor(seconds % 60)
    return m + ":" + String(s).padStart(2, "0")
  },
}

export default RecordingPlayer
