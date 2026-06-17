import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  staticTargets = ["video", "sourceInfo", "sourceToggle", "sourceDetails", "sourceUrl", "sourceFilename", "backButton"]
  staticValues = { streamingUrl: String, filename: String, imdbId: String, type: String, season: String, episode: String, resumeAt: String, startSeconds: Number, title: String }

  connect() {
    this.progressInterval = null
    this.uiHideTimer = null
    this.mouseMoveHandler = this.onMouseMove.bind(this)

    // Show source info
    this.sourceInfoTarget.classList.remove("hidden")
    this.sourceUrlTarget.textContent = this.streamingUrlValue
    this.sourceFilenameTarget.textContent = this.filenameValue || "Unknown"
    this.showOverlayUi()
    this.element.addEventListener("mousemove", this.mouseMoveHandler)

    // Resume from last position.
    // When transcoding, the stream already starts at the resume position
    // (ffmpeg -ss), so we must NOT set currentTime — that would trigger
    // a seek, which cancels and re-requests the stream (causing stutter).
    // For direct streams (no transcode), seek client-side as before.
    const resumeAt = parseInt(this.resumeAtValue) || 0
    if (resumeAt > 0 && this.startSecondsValue === 0) {
      this.videoTarget.addEventListener("loadeddata", () => {
        this.videoTarget.currentTime = resumeAt
      }, { once: true })
    }

    // Save progress on page unload
    this.beforeUnloadHandler = () => this.saveProgressSync()
    window.addEventListener("beforeunload", this.beforeUnloadHandler)

    // Track progress every 5s
    this.startProgressTracking()
  }

  disconnect() {
    this.stopProgressTracking()
    this.clearUiHideTimer()
    this.element.removeEventListener("mousemove", this.mouseMoveHandler)
    window.removeEventListener("beforeunload", this.beforeUnloadHandler)
  }

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
      if (this.videoTarget && !this.videoTarget.paused) this.saveProgress()
    }, 5000)
  }

  stopProgressTracking() {
    if (this.progressInterval) {
      clearInterval(this.progressInterval)
      this.progressInterval = null
    }
  }

  // Progress is reported as currentTime + startSeconds so that when
  // transcoding with -ss (stream starts at e.g. 77s), the saved
  // progress reflects the actual position in the movie, not the
  // position within the transcoded fragment.
  async saveProgress() {
    const video = this.videoTarget
    if (!video) return
    const progressSeconds = Math.floor(video.currentTime + this.startSecondsValue)
    const durationSeconds = Math.floor(video.duration + this.startSecondsValue)
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
          episode: this.episodeValue,
          title: this.titleValue || null
        })
      })
    } catch (e) {
      console.warn("Progress save failed:", e)
    }
  }

  saveProgressSync() {
    const video = this.videoTarget
    if (!video) return
    const progressSeconds = Math.floor(video.currentTime + this.startSecondsValue)
    const durationSeconds = Math.floor(video.duration + this.startSecondsValue)
    if (durationSeconds <= 0) return

    const csrfToken = document.querySelector("meta[name='csrf-token']")?.content
    fetch(`/streaming/play/progress`, {
      method: "PATCH",
      headers: { "Content-Type": "application/json", "X-CSRF-Token": csrfToken },
      body: JSON.stringify({
        imdb_id: this.imdbIdValue,
        progress_seconds: progressSeconds,
        duration_seconds: durationSeconds,
        type: this.typeValue,
        season: this.seasonValue,
        episode: this.episodeValue,
        title: this.titleValue || null
      }),
      keepalive: true
    })
  }
}
