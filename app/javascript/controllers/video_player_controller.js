import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["video", "sourceInfo", "sourceToggle", "sourceDetails", "sourceUrl", "sourceFilename", "backButton"]
  static values = { streamingUrl: String, filename: String, imdbId: String, type: String, season: String, episode: String }

  connect() {
    this.player = null
    this.progressInterval = null
    this.uiHideTimer = null
    this.mouseMoveHandler = this.onMouseMove.bind(this)

    this.sourceInfoTarget.classList.remove("hidden")
    this.sourceUrlTarget.textContent = this.streamingUrlValue
    this.sourceFilenameTarget.textContent = this.filenameValue || "Unknown"
    this.showOverlayUi()
    this.element.addEventListener("mousemove", this.mouseMoveHandler)

    this.player = new Plyr(this.videoTarget, {
      controls: ['play-large', 'play', 'progress', 'current-time', 'duration', 'mute', 'volume', 'captions', 'settings', 'pip', 'airplay', 'fullscreen'],
      settings: ['captions', 'quality', 'speed'],
      keyboard: { focused: true, global: true }
    })

    this.player.on("ready", () => this.player.play())
    this.player.on("ended", () => this.onVideoEnded())
    this.startProgressTracking()
  }

  disconnect() {
    this.stopProgressTracking()
    this.clearUiHideTimer()
    if (this.player) this.player.destroy()
    this.element.removeEventListener("mousemove", this.mouseMoveHandler)
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
