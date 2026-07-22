export class HlsSessionClient {
  constructor(player, { fetcher = globalThis.fetch, documentRoot = globalThis.document } = {}) {
    this.player = player
    this.fetcher = fetcher
    this.documentRoot = documentRoot
  }

  async start() {
    this.player.cancelRemuxLoad()
    this.player.clearHlsPlayPrompt()
    this.player.directPlayActive = false
    this.player.remuxDirectPlay = false
    this.player.primedDirectPlayUrl = null

    const directUrl = this.player.directUrlValue || this.player.extractRawUrl()
    if (!directUrl) {
      console.warn("HLS: no direct URL available")
      return
    }

    try {
      const data = await this.startSession(directUrl, this.player.startSecondsValue)
      if (!data) return

      this.player.hlsSessionId = data.session_id
      if (!await this.player.waitForPlaylist(data.playlist_url)) {
        console.warn("HLS: playlist not ready or ffmpeg failed")
        this.showStartupFailure()
        return
      }

      this.player.videoTarget.autoplay = true
      this.player.videoTarget.src = data.playlist_url
      this.player.videoTarget.load()
      const playPromise = this.player.videoTarget.play()
      if (playPromise?.catch) playPromise.catch((error) => this.player.handleHlsAutoplayFailure(error))
    } catch (error) {
      console.warn("HLS: start error", error)
    }
  }

  async waitForPlaylist(playlistUrl) {
    const maxAttempts = 150
    const pollInterval = 200
    const minSegments = 2
    const fallbackAttempts = 100

    for (let attempt = 0; attempt < maxAttempts; attempt++) {
      try {
        const response = await this.fetcher(playlistUrl)
        if (response.status === 424) {
          try {
            const body = await response.json()
            console.warn("HLS: ffmpeg failed:", body.error)
          } catch {}
          return false
        }
        if (response.status === 200) {
          const text = await response.text()
          const segmentCount = (text.match(/#EXTINF/g) || []).length
          const minimumNeeded = attempt >= fallbackAttempts ? 1 : minSegments
          if (segmentCount >= minimumNeeded) return true
        }
      } catch {
        // Transient network errors remain pollable.
      }
      await new Promise((resolve) => setTimeout(resolve, pollInterval))
    }

    console.warn("HLS: playlist poll timed out after", maxAttempts * pollInterval / 1000, "s")
    return false
  }

  async restart(startSeconds) {
    this.player.videoTarget.pause()
    this.player.clearSubtitleCues()
    this.player.reloadTextSubtitlesAt(startSeconds)
    this.player.stopHlsSession()

    const directUrl = this.player.directUrlValue || this.player.extractRawUrl()
    if (!directUrl) {
      console.warn("HLS seek: no direct URL available")
      this.finishSeek()
      return
    }

    try {
      const data = await this.startSession(directUrl, startSeconds)
      if (!data) {
        this.finishSeek()
        return
      }

      this.player.hlsSessionId = data.session_id
      if (!await this.player.waitForPlaylist(data.playlist_url)) {
        console.warn("HLS seek: playlist not ready or ffmpeg failed")
        this.finishSeek()
        return
      }

      this.player.videoTarget.src = data.playlist_url
      this.player.videoTarget.load()
      const playPromise = this.player.videoTarget.play()
      if (playPromise?.catch) playPromise.catch(() => {})

      const onPlaying = () => {
        this.finishSeek()
        this.player.videoTarget.removeEventListener("playing", onPlaying)
      }
      this.player.videoTarget.addEventListener("playing", onPlaying, { once: true })
      setTimeout(() => {
        if (this.player.isSeeking) this.finishSeek()
      }, 30000)
    } catch (error) {
      console.warn("HLS seek: error", error)
      this.finishSeek()
    }
  }

  async stop() {
    if (!this.player.hlsSessionId) return

    const sessionId = this.player.hlsSessionId
    this.player.hlsSessionId = null
    try {
      await this.fetcher(`/hls/${sessionId}/stop`, {
        method: "POST",
        headers: { "X-CSRF-Token": this.csrfToken() },
        keepalive: true
      })
    } catch {
      // Best-effort teardown; the server-side TTL is the fallback.
    }
  }

  async startSession(directUrl, startSeconds) {
    const params = new URLSearchParams({ url: directUrl })
    params.set("playback_id", this.player.playbackId)
    if (startSeconds && startSeconds > 0) params.set("start_seconds", startSeconds)
    this.player.appendSelectedHlsTracks(params)

    const response = await this.fetcher("/hls/start", {
      method: "POST",
      headers: {
        "Content-Type": "application/x-www-form-urlencoded",
        "X-CSRF-Token": this.csrfToken()
      },
      body: params.toString()
    })

    if (!response.ok) {
      console.warn("HLS: start failed", response.status)
      return null
    }
    return response.json()
  }

  csrfToken() {
    return this.documentRoot?.querySelector("meta[name='csrf-token']")?.content
  }

  finishSeek() {
    this.player.isSeeking = false
    this.player.hideSeekingOverlay()
  }

  showStartupFailure() {
    if (!this.player.hasStartupOverlayTarget) return

    const label = this.player.startupOverlayTarget.querySelector("span.text-white")
    const detail = this.player.startupOverlayTarget.querySelector("span.text-sv-text-muted")
    if (label) label.textContent = "Stream failed to start"
    if (detail) detail.textContent = "Try going back and selecting another stream"
  }
}
