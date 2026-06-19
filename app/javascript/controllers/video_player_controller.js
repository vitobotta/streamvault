import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static get targets() {
    return [
      "video", "controls", "seekBar", "seekFilled", "seekBuffered", "seekHandle",
      "playButton", "playIcon", "pauseIcon", "currentTime", "durationDisplay",
      "volumeIcon", "muteIcon", "seekingOverlay",
      "sourceInfo", "sourceToggle", "sourceDetails", "sourceUrl", "sourceFilename", "backButton"
    ]
  }
  static get values() {
    return {
      streamingUrl: String, filename: String, imdbId: String, type: String,
      season: String, episode: String, resumeAt: String, startSeconds: Number,
      title: String, duration: Number, posterUrl: String
    }
  }

  connect() {
    this.progressInterval = null
    this.uiHideTimer = null
    this.knownDuration = 0
    this.isSeeking = false
    this.isDragging = false
    this.mouseMoveHandler = this.onMouseMove.bind(this)

    // Show source info
    this.sourceInfoTarget.classList.remove("hidden")
    this.sourceUrlTarget.textContent = this.streamingUrlValue
    this.sourceFilenameTarget.textContent = this.filenameValue || "Unknown"
    this.showOverlayUi()
    this.element.addEventListener("mousemove", this.mouseMoveHandler)
    // Video event listeners
    this.videoTarget.addEventListener("play", () => this.updatePlayIcon())
    this.videoTarget.addEventListener("pause", () => this.updatePlayIcon())
    this.videoTarget.addEventListener("timeupdate", () => this.onTimeUpdate())
    this.videoTarget.addEventListener("progress", () => this.onProgress())
    this.videoTarget.addEventListener("volumechange", () => this.updateVolumeIcon())
    this.videoTarget.addEventListener("waiting", () => this.showSeekingOverlay())
    this.videoTarget.addEventListener("playing", () => this.hideSeekingOverlay())
    this.videoTarget.addEventListener("canplay", () => this.hideSeekingOverlay())

    // Resume: transcode streams already start at the resume position
    // via ffmpeg -ss, so no client-side seek needed.

    // Duration: probe in the background via AJAX — never block video
    // playback. The video starts immediately; the seek bar populates
    // when the probe completes (usually a few seconds).
    this.currentTimeTarget.textContent = this.formatTime(this.startSecondsValue)
    this.probeDuration()

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

  async probeDuration() {
    try {
      const rawUrl = this.extractRawUrl()
      if (!rawUrl) return

      const response = await fetch(`/transcode/duration?url=${encodeURIComponent(rawUrl)}`)
      const data = await response.json()
      if (data.duration > 0) {
        this.knownDuration = data.duration
        this.updateDurationDisplay()
        // Now that we know the duration, position the seek bar at the
        // current playback point (which starts at startSecondsValue).
        this.onTimeUpdate()
      }
    } catch (e) {
      console.warn("Duration probe failed:", e)
    }
  }

  extractRawUrl() {
    try {
      const url = new URL(this.streamingUrlValue, window.location.origin)
      return url.searchParams.get("url")
    } catch {
      return null
    }
  }

  // ── Play / pause ──────────────────────────────────────────────────

  togglePlay() {
    if (this.videoTarget.paused) {
      this.videoTarget.play()
    } else {
      this.videoTarget.pause()
    }
  }

  updatePlayIcon() {
    if (this.videoTarget.paused) {
      this.playIconTarget.classList.remove("hidden")
      this.pauseIconTarget.classList.add("hidden")
    } else {
      this.playIconTarget.classList.add("hidden")
      this.pauseIconTarget.classList.remove("hidden")
    }
  }

  // ── Volume / mute ─────────────────────────────────────────────────

  toggleMute() {
    this.videoTarget.muted = !this.videoTarget.muted
  }

  updateVolumeIcon() {
    if (this.videoTarget.muted || this.videoTarget.volume === 0) {
      this.volumeIconTarget.classList.add("hidden")
      this.muteIconTarget.classList.remove("hidden")
    } else {
      this.volumeIconTarget.classList.remove("hidden")
      this.muteIconTarget.classList.add("hidden")
    }
  }

  // ── Fullscreen ────────────────────────────────────────────────────

  toggleFullscreen() {
    if (document.fullscreenElement) {
      document.exitFullscreen()
    } else {
      this.element.requestFullscreen()
    }
  }

  // ── Seek bar ──────────────────────────────────────────────────────

  // The seek bar shows the position within the full movie (not within
  // the current transcode fragment).  For transcode streams, seeking
  // restarts ffmpeg with -ss at the new position.
  seek(event) {
    if (this.isDragging) return // drag handler manages this
    const percent = this.seekPercentFromEvent(event)
    this.performSeek(percent)
  }

  startSeekDrag(event) {
    this.isDragging = true
    event.preventDefault()
    this.dragMoveHandler = (e) => this.onSeekDragMove(e)
    document.addEventListener("mousemove", this.dragMoveHandler)
    document.addEventListener("touchmove", this.dragMoveHandler)
  }

  onSeekDragMove(event) {
    if (!this.isDragging) return
    const percent = this.seekPercentFromEvent(event)
    this.updateSeekVisuals(percent)
  }

  stopSeekDrag(event) {
    if (!this.isDragging) return
    this.isDragging = false
    document.removeEventListener("mousemove", this.dragMoveHandler)
    document.removeEventListener("touchmove", this.dragMoveHandler)
    const percent = this.seekPercentFromEvent(event)
    this.performSeek(percent)
  }

  seekPercentFromEvent(event) {
    const rect = this.seekBarTarget.getBoundingClientRect()
    const clientX = event.touches ? event.touches[0].clientX : event.clientX
    const percent = (clientX - rect.left) / rect.width
    return Math.max(0, Math.min(1, percent))
  }

  performSeek(percent) {
    if (this.knownDuration <= 0) return

    const targetSeconds = Math.floor(percent * this.knownDuration)

    // Restart ffmpeg at the new position
    if (targetSeconds === this.startSecondsValue) return

    this.isSeeking = true
    this.showSeekingOverlay()
    this.startSecondsValue = targetSeconds

    const url = new URL(this.streamingUrlValue, window.location.origin)
    if (targetSeconds > 0) {
      url.searchParams.set("start_seconds", targetSeconds)
    } else {
      url.searchParams.delete("start_seconds")
    }

    this.videoTarget.src = url.pathname + url.search
    this.videoTarget.load()
    this.videoTarget.play()
  }

  // ── Time / progress updates ───────────────────────────────────────

  onTimeUpdate() {
    const currentPos = this.videoTarget.currentTime + this.startSecondsValue
    const duration = this.effectiveDuration()

    this.currentTimeTarget.textContent = this.formatTime(currentPos)
    if (duration > 0) {
      this.updateSeekVisuals(currentPos / duration)
    }
  }

  onProgress() {
    const video = this.videoTarget
    if (!video.buffered.length || this.knownDuration <= 0) return

    const bufferedEnd = video.buffered.end(video.buffered.length - 1)
    const totalWithOffset = bufferedEnd + this.startSecondsValue
    const percent = (totalWithOffset / this.knownDuration) * 100
    this.seekBufferedTarget.style.width = `${Math.min(100, percent)}%`
  }

  updateSeekVisuals(fraction) {
    const percent = Math.max(0, Math.min(1, fraction)) * 100
    this.seekFilledTarget.style.width = `${percent}%`
    this.seekHandleTarget.style.left = `${percent}%`
  }

  effectiveDuration() {
    if (this.knownDuration > 0) return this.knownDuration
    const d = this.videoTarget.duration
    return (d && isFinite(d)) ? d + this.startSecondsValue : 0
  }

  updateDurationDisplay() {
    const duration = this.effectiveDuration()
    this.durationDisplayTarget.textContent = duration > 0 ? this.formatTime(duration) : "--:--"
  }

  formatTime(seconds) {
    if (!seconds || !isFinite(seconds) || seconds < 0) return "0:00"
    const h = Math.floor(seconds / 3600)
    const m = Math.floor((seconds % 3600) / 60)
    const s = Math.floor(seconds % 60)
    if (h > 0) return `${h}:${m.toString().padStart(2, "0")}:${s.toString().padStart(2, "0")}`
    return `${m}:${s.toString().padStart(2, "0")}`
  }

  // ── Seeking overlay ───────────────────────────────────────────────

  showSeekingOverlay() {
    if (this.isSeeking) {
      this.seekingOverlayTarget.classList.remove("hidden")
    }
  }

  hideSeekingOverlay() {
    this.isSeeking = false
    this.seekingOverlayTarget.classList.add("hidden")
  }

  // ── Overlay UI (auto-hide) ────────────────────────────────────────

  showOverlayUi() {
    this.backButtonTarget.style.opacity = "1"
    this.sourceInfoTarget.style.opacity = "1"
    this.controlsTarget.style.opacity = "1"
    this.scheduleUiHide()
  }

  hideOverlayUi() {
    if (!this.videoTarget.paused) {
      this.backButtonTarget.style.opacity = "0"
      this.sourceInfoTarget.style.opacity = "0"
      this.controlsTarget.style.opacity = "0"
    }
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
    this.showOverlayUi()
  }

  toggleSourceInfo() {
    this.sourceDetailsTarget.classList.toggle("hidden")
    this.clearUiHideTimer()
    if (!this.sourceDetailsTarget.classList.contains("hidden")) {
      this.backButtonTarget.style.opacity = "1"
      this.sourceInfoTarget.style.opacity = "1"
      this.controlsTarget.style.opacity = "1"
    } else {
      this.scheduleUiHide()
    }
  }

  // ── Progress tracking ─────────────────────────────────────────────

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

  async saveProgress() {
    const video = this.videoTarget
    if (!video) return
    const progressSeconds = Math.floor(video.currentTime + this.startSecondsValue)
    const durationSeconds = Math.floor(this.effectiveDuration())
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
          title: this.titleValue || null,
          poster_url: this.posterUrlValue || null
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
    const durationSeconds = Math.floor(this.effectiveDuration())
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
        title: this.titleValue || null,
        poster_url: this.posterUrlValue || null
      }),
      keepalive: true
    })
  }
}
