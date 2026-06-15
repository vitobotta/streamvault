import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["loading", "error", "errorMessage", "status", "playerWrapper", "video",
                     "sourceInfo", "sourceToggle", "sourceDetails", "sourceUrl", "sourceFilename",
                     "backButton"]
  static values = { url: String, imdbId: String, type: String, season: String, episode: String }

  connect() {
    this.player = null
    this.progressInterval = null
    this.uiHideTimer = null
    this.pollAttempts = 0
    this.maxPollAttempts = 60
    this.mouseMoveHandler = this.onMouseMove.bind(this)
    this.resolveStream()
  }

  disconnect() {
    this.stopPolling()
    this.stopProgressTracking()
    this.clearUiHideTimer()
    if (this.player) this.player.destroy()
    this.element.removeEventListener("mousemove", this.mouseMoveHandler)
  }

  async resolveStream() {
    this.statusTarget.textContent = "Resolving stream..."
    this.pollForUrl()
    this.pollInterval = setInterval(() => this.pollForUrl(), 2000)
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
      this.showError("Stream preparation timed out. Try a different quality.")
      return
    }

    try {
      const response = await fetch(this.urlValue, {
        headers: { "Accept": "application/json" }
      })

      if (!response.ok) {
        this.stopPolling()
        const errData = await response.json().catch(() => ({}))
        this.showError(errData.error || "Failed to resolve stream.")
        return
      }

      const data = await response.json()

      if (data.status === "ready" && data.streaming_url) {
        this.stopPolling()
        this.showPlayer(data.streaming_url, data.filename)
      } else if (data.status === "downloading") {
        this.statusTarget.textContent = "Downloading... Please wait."
      } else if (data.status === "waiting") {
        this.statusTarget.textContent = "Preparing stream..."
      } else if (data.error) {
        this.stopPolling()
        this.showError(data.error)
      }
    } catch (e) {
      console.warn("Poll error:", e)
    }
  }

  showPlayer(url, filename) {
    this.loadingTarget.classList.add("hidden")
    this.playerWrapperTarget.classList.remove("hidden")

    this.sourceInfoTarget.classList.remove("hidden")
    this.sourceUrlTarget.textContent = url
    this.sourceFilenameTarget.textContent = filename || url.split("/").pop() || "Unknown"
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

  // Overlay UI auto-hide after 4s idle
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

      await fetch(`/streaming/play/progress`, {
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
}
