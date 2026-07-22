export class ProgressReporter {
  constructor(player, { fetcher = globalThis.fetch, documentRoot = globalThis.document } = {}) {
    this.player = player
    this.fetcher = fetcher
    this.documentRoot = documentRoot
  }

  start() {
    this.player.progressAbortController = null
    this.player.progressInterval = setInterval(() => {
      if (this.player.videoTarget && !this.player.videoTarget.paused) this.save()
    }, 5000)
  }

  stop() {
    if (this.player.progressInterval) {
      clearInterval(this.player.progressInterval)
      this.player.progressInterval = null
    }
    if (this.player.progressAbortController) {
      this.player.progressAbortController.abort()
      this.player.progressAbortController = null
    }
  }

  async save(completed = false) {
    const payload = this.payload(completed)
    if (!payload) return

    if (this.player.progressAbortController) this.player.progressAbortController.abort()
    this.player.progressAbortController = new AbortController()

    try {
      await this.fetcher("/streaming/play/progress", {
        method: "PATCH",
        headers: this.headers(),
        body: JSON.stringify(payload),
        signal: this.player.progressAbortController.signal
      })
    } catch (error) {
      if (error.name !== "AbortError") console.warn("Progress save failed:", error)
    } finally {
      if (this.player.progressAbortController?.signal.aborted) {
        this.player.progressAbortController = null
      }
    }
  }

  saveSync() {
    const payload = this.payload()
    if (!payload) return

    this.fetcher("/streaming/play/progress", {
      method: "PATCH",
      headers: this.headers(),
      body: JSON.stringify(payload),
      keepalive: true
    })
  }

  payload(completed = false) {
    if (!this.player.videoTarget) return null

    const durationSeconds = this.saveableDurationSeconds()
    const progressSeconds = completed && durationSeconds > 0
      ? durationSeconds
      : Math.floor(this.player.currentPlaybackPosition())
    if (progressSeconds <= 0) return null

    return {
      imdb_id: this.player.imdbIdValue,
      progress_seconds: progressSeconds,
      duration_seconds: durationSeconds,
      type: this.player.typeValue,
      season: this.player.seasonValue,
      episode: this.player.episodeValue,
      title: this.player.titleValue || null,
      poster_url: this.player.posterUrlValue || null
    }
  }

  saveableDurationSeconds() {
    const duration = Math.floor(this.player.effectiveDuration())
    return duration > 0 ? duration : 0
  }

  headers() {
    const csrfToken = this.documentRoot?.querySelector("meta[name='csrf-token']")?.content
    return { "Content-Type": "application/json", "X-CSRF-Token": csrfToken }
  }
}
