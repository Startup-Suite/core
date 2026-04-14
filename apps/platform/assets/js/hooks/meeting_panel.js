/**
 * meeting_panel.js — Participant tile DOM manager for the meeting panel.
 *
 * Manages creation, update, and removal of participant tile elements based
 * on LiveKit participant state. Handles:
 *   - Creating tiles with avatar + name fallback when no video
 *   - Attaching video tracks to tile containers
 *   - Removing tracks and tiles on participant departure
 *   - Active speaker highlighting via CSS class
 *
 * All DOM operations target `#meeting-participants` as the tile container
 * and `#meeting-media` as the hidden audio/media attachment point.
 *
 * Tile structure:
 *   <div class="meeting-tile" data-identity="...">
 *     <div class="meeting-tile-video">  <!-- video elements go here -->
 *     </div>
 *     <div class="meeting-tile-avatar"> <!-- shown when no video -->
 *       <div class="meeting-tile-avatar-circle">
 *         <span>JC</span>              <!-- initials -->
 *       </div>
 *     </div>
 *     <div class="meeting-tile-name">
 *       <span>Jordan Coombs</span>
 *       <span class="meeting-tile-you">(You)</span>  <!-- if local -->
 *     </div>
 *   </div>
 */

const CONTAINER_ID = "meeting-participants"
const MEDIA_CONTAINER_ID = "meeting-media"

/**
 * Extract initials from a display name.
 * "Jordan Coombs" → "JC", "sage" → "S", "" → "?"
 */
function getInitials(name) {
  if (!name || !name.trim()) return "?"
  const parts = name.trim().split(/\s+/)
  if (parts.length === 1) return parts[0].charAt(0).toUpperCase()
  return (parts[0].charAt(0) + parts[parts.length - 1].charAt(0)).toUpperCase()
}

/**
 * Escape HTML entities in a string.
 */
function escapeHtml(str) {
  const div = document.createElement("div")
  div.textContent = str
  return div.innerHTML
}

/**
 * Get or create the tile container element.
 */
function getContainer() {
  return document.getElementById(CONTAINER_ID)
}

/**
 * Get the hidden media container for audio elements.
 */
function getMediaContainer() {
  return document.getElementById(MEDIA_CONTAINER_ID)
}

/**
 * Get an existing tile element by participant identity.
 */
function getTile(identity) {
  const container = getContainer()
  if (!container) return null
  return container.querySelector(`[data-identity="${CSS.escape(identity)}"]`)
}

/**
 * Create a participant tile and append it to the container.
 *
 * @param {object} participant - LiveKit Participant object
 * @param {boolean} isLocal - Whether this is the local participant
 * @returns {HTMLElement|null} The created tile element, or null if container missing
 */
export function createParticipantTile(participant, isLocal = false) {
  const container = getContainer()
  if (!container) return null

  const identity = participant.identity
  const name = participant.name || participant.identity || "Unknown"

  // Don't create duplicate tiles
  if (getTile(identity)) return getTile(identity)

  const tile = document.createElement("div")
  tile.className = "meeting-tile"
  tile.dataset.identity = identity
  if (isLocal) tile.dataset.local = "true"

  // Video container (empty until a video track is attached)
  const videoWrap = document.createElement("div")
  videoWrap.className = "meeting-tile-video"
  tile.appendChild(videoWrap)

  // Avatar fallback (visible when no video tracks)
  const avatarWrap = document.createElement("div")
  avatarWrap.className = "meeting-tile-avatar"

  const avatarCircle = document.createElement("div")
  avatarCircle.className = "meeting-tile-avatar-circle"

  const initialsSpan = document.createElement("span")
  initialsSpan.textContent = getInitials(name)
  avatarCircle.appendChild(initialsSpan)
  avatarWrap.appendChild(avatarCircle)
  tile.appendChild(avatarWrap)

  // Name label
  const nameWrap = document.createElement("div")
  nameWrap.className = "meeting-tile-name"

  const nameSpan = document.createElement("span")
  nameSpan.textContent = name
  nameWrap.appendChild(nameSpan)

  if (isLocal) {
    const youSpan = document.createElement("span")
    youSpan.className = "meeting-tile-you"
    youSpan.textContent = "(You)"
    nameWrap.appendChild(youSpan)
  }

  tile.appendChild(nameWrap)
  container.appendChild(tile)

  _updateTileVideoVisibility(tile)
  return tile
}

/**
 * Remove a participant tile from the DOM.
 *
 * @param {string} identity - Participant identity
 */
export function removeParticipantTile(identity) {
  const tile = getTile(identity)
  if (tile) {
    // Detach any media elements first
    const videoWrap = tile.querySelector(".meeting-tile-video")
    if (videoWrap) {
      videoWrap.querySelectorAll("video, audio").forEach((el) => {
        el.srcObject = null
        el.remove()
      })
    }
    tile.remove()
  }
}

/**
 * Attach a subscribed track to the appropriate participant tile.
 * Video tracks go into the tile's video container.
 * Audio tracks go into the hidden media container.
 *
 * @param {object} track - LiveKit Track
 * @param {object} participant - LiveKit Participant
 */
export function attachTrackToTile(track, participant) {
  const el = track.attach()
  el.id = `track-${participant.identity}-${track.sid}`
  el.dataset.participantIdentity = participant.identity
  el.dataset.trackSid = track.sid

  if (track.kind === "video") {
    const tile = getTile(participant.identity)
    if (!tile) {
      // Tile doesn't exist yet — create it on the fly
      const newTile = createParticipantTile(participant)
      if (newTile) {
        const videoWrap = newTile.querySelector(".meeting-tile-video")
        if (videoWrap) videoWrap.appendChild(el)
        _updateTileVideoVisibility(newTile)
      }
    } else {
      const videoWrap = tile.querySelector(".meeting-tile-video")
      if (videoWrap) videoWrap.appendChild(el)
      _updateTileVideoVisibility(tile)
    }
  } else {
    // Audio tracks go in hidden media container
    el.style.display = "none"
    const mediaContainer = getMediaContainer()
    if (mediaContainer) {
      mediaContainer.appendChild(el)
    }
  }
}

/**
 * Detach a track from its tile or the media container.
 *
 * @param {object} track - LiveKit Track
 * @param {object} participant - LiveKit Participant
 */
export function detachTrackFromTile(track, participant) {
  const elements = track.detach()
  elements.forEach((el) => el.remove())

  // Update tile visibility after video removal
  if (track.kind === "video") {
    const tile = getTile(participant.identity)
    if (tile) _updateTileVideoVisibility(tile)
  }
}

/**
 * Apply active-speaker highlighting to tiles.
 * Adds `meeting-tile-speaking` class to active speakers,
 * removes it from everyone else.
 *
 * @param {string[]} activeIdentities - Array of speaking participant identities
 */
export function setActiveSpeakers(activeIdentities) {
  const container = getContainer()
  if (!container) return

  const activeSet = new Set(activeIdentities)
  container.querySelectorAll(".meeting-tile").forEach((tile) => {
    const identity = tile.dataset.identity
    if (activeSet.has(identity)) {
      tile.classList.add("meeting-tile-speaking")
    } else {
      tile.classList.remove("meeting-tile-speaking")
    }
  })
}

/**
 * Remove all participant tiles and clear media container.
 * Called on leave/disconnect.
 */
export function clearAllTiles() {
  const container = getContainer()
  if (container) container.innerHTML = ""

  const mediaContainer = getMediaContainer()
  if (mediaContainer) mediaContainer.innerHTML = ""
}

// ── Internal helpers ─────────────────────────────────────────────────

/**
 * Toggle avatar visibility based on whether the tile has video tracks.
 * Shows avatar when no video elements present, hides when video exists.
 */
function _updateTileVideoVisibility(tile) {
  const videoWrap = tile.querySelector(".meeting-tile-video")
  const avatarWrap = tile.querySelector(".meeting-tile-avatar")
  if (!videoWrap || !avatarWrap) return

  const hasVideo = videoWrap.querySelectorAll("video").length > 0
  avatarWrap.style.display = hasVideo ? "none" : "flex"
  videoWrap.style.display = hasVideo ? "block" : "none"
}
