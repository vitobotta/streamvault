import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["loading", "error", "errorMessage", "status", "playerWrapper", "video",
                     "sourceInfo", "sourceToggle", "sourceDetails", "sourceUrl", "sourceFilename",
                     "backButton"]
  static values = { url: String, imdbId: String, type: String, season: String, episode: String }

  connect() {
    this.player = null
    this.progressInterval = null
    this.pollAttempts = 0
    this.maxPollAttempts = 120
    this.uiHideTimer = null
    this.mouseMoveHandler = this.onMouseMove.bind(this)
    this.startPolling()
  }

  disconnect() {
    this.stopPolling()
    this.stopProgressTracking()
    this.clearUiHideTimer()
    if (this.player) this.player.destroy()
    this.element.removeEventListener("mousemove", this.mouseMoveHandler)
  }

  startPolling() {
    this.pollForUrl()
    this.pollInterval = setInterval(() => this.pollForUrl(), 1000)
  }

  stopPolling() {
    if (this.pollInterval) {
      clearInterval(this.pollInterval)
      this.pollInterval = null
    }
  }

  async pollForUrl() {
    this.pollAttempts++

    if (this.pollAttempts > this.maxPollAttempts) {
      this.stopPolling()
      this.showError("Stream preparation timed out. Please try again.")
      return
    }

    try {
      const response = await fetch(this.urlValue, { headers: { "Accept": "application/json" } })

      if (!response.ok) {
        const errData = await response.json().catch(() => ({}))
        if (errData.error) {
          this.stopPolling()
          this.showError(errData.error)
        }
        return
      }

      const data = await response.json()

      if (data.status === "ready" && data.streaming_url) {
        this.stopPolling()
        this.showPlayer(data.streaming_url, data.filename)
      } else if (data.error) {
        this.stopPolling()
        this.showError(data.error)
      } else {
        this.updateStatus(data)
      }
    } catch (e) {
      console.warn("Poll error:", e)
    }
  }

  updateStatus(data) {
    const statusEl = this.statusTarget
    const status = data.status || "preparing"
    const progress = data.progress || 0
    const speed = data.speed ? this.formatSpeed(data.speed) : ""

    const errorStates = ["infringing_file", "magnet_error", "error", "virus"]
    if (errorStates.includes(status)) {
      const messages = {
        infringing_file: "This content is blocked due to copyright restrictions. Try a different stream.",
        magnet_error: "Could not process this torrent. Try a different stream.",
        virus: "File flagged as potentially harmful. Try a different stream.",
        error: "An error occurred with this torrent. Try a different stream."
      }
      this.stopPolling()
      this.showError(messages[status] || "Stream unavailable. Try a different stream.")
      return
    }

    const messages = {
      magnet_conversion: "Connecting to peers...",
      waiting_files_selection: "Preparing files...",
      downloading: progress > 0 ? `Downloading: ${progress}% ${speed}` : "Starting download...",
      queued: "Queued...",
      uploading: "Processing...",
      compressing: "Processing...",
      downloaded: "Almost ready..."
    }

    statusEl.textContent = messages[status] || `Preparing... (${status})`
  }

  showPlayer(url, filename) {
    this.loadingTarget.classList.add("hidden")
    this.playerWrapperTarget.classList.remove("hidden")

    // Show overlay UI (back button + source info)
    this.sourceInfoTarget.classList.remove("hidden")
    this.sourceUrlTarget.textContent = url
    this.sourceFilenameTarget.textContent = filename || "Unknown"
    this.showOverlayUi()
    this.element.addEventListener("mousemove", this.mouseMoveHandler)

    const video = this.videoTarget
    video.src = url

    this.player = new Plyr(video, {
      controls: ['play-large', 'play', 'progress', 'current-time', 'duration', 'mute', 'volume', 'captions', 'settings', 'pip', 'airplay', 'fullscreen'],
      settings: ['captions', 'quality', 'speed'],
      keyboard: { focused: true, global: true }
    })

    this.player.on("ready", () => this.player.play())
    this.player.on("ended", () => this.onVideoEnded())

    this.startProgressTracking()
  }

  // Overlay UI (back button + source info) auto-hide after 4s idle
  showOverlayUi() {
    this.backButtonTarget.style.opacity = "1"
    this.sourceInfoTarget.style.opacity = "1"
    this.scheduleUiHide()
  }

  hideOverlayUi() {
    this.backButtonTarget.style.opacity = "0"
    this.sourceInfoTarget.style.opacity = "0"
  }

  scheduleUiHide() {
    this.clearUiHideTimer()
    this.uiHideTimer = setTimeout(() => this.hideOverlayUi(), 4000)
  }

  clearUiHideTimer() {
    if (this.uiHideTimer) {
      clearTimeout(this.uiHideTimer)
      this.uiHideTimer = null
    }
  }

  onMouseMove() {
    this.backButtonTarget.style.opacity = "1"
    this.sourceInfoTarget.style.opacity = "1"
    this.scheduleUiHide()
  }

  toggleSourceInfo() {
    this.sourceDetailsTarget.classList.toggle("hidden")
    this.clearUiHideTimer()
    if (!this.sourceDetailsTarget.classList.contains("hidden")) {
      // Details open — keep everything visible
      this.backButtonTarget.style.opacity = "1"
      this.sourceInfoTarget.style.opacity = "1"
    } else {
      this.scheduleUiHide()
    }
  }

  showError(message) {
    this.loadingTarget.classList.add("hidden")
    this.errorTarget.classList.remove("hidden")
    this.errorMessageTarget.textContent = message
  }

  startProgressTracking() {
    this.progressInterval = setInterval(() => {
      if (this.player && !this.player.paused) this.saveProgress()
    }, 10000)
  }

  stopProgressTracking() {
    if (this.progressInterval) {
      clearInterval(this.progressInterval)
      this.progressInterval = null
    }
  }

  async saveProgress() {
    if (!this.player) return

    const progressSeconds = Math.floor(this.player.currentTime)
    const durationSeconds = Math.floor(this.player.duration)

    if (durationSeconds <= 0) return

    try {
      const csrfToken = document.querySelector("meta[name='csrf-token']")?.content
      const torrentId = this.urlValue.split("/").filter(s => s).at(-2)

      await fetch(`/streaming/${torrentId}/progress`, {
        method: "PATCH",
        headers: { "Content-Type": "application/json", "X-CSRF-Token": csrfToken },
        body: JSON.stringify({
          imdb_id: this.imdbIdValue,
          progress_seconds: progressSeconds,
          duration_seconds: durationSeconds,
          type: this.typeValue,
          season: this.seasonValue,
          episode: this.episodeValue
        })
      })
    } catch (e) {
      console.warn("Progress save failed:", e)
    }
  }

  onVideoEnded() {
    this.saveProgress()
  }

  formatSpeed(bytes) {
    if (bytes >= 1_000_000) return `${(bytes / 1_000_000).toFixed(1)} MB/s`
    if (bytes >= 1_000) return `${(bytes / 1_000).toFixed(0)} KB/s`
    return `${bytes} B/s`
  }
}
