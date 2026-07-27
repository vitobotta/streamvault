const STARTUP_WINDOW_SECONDS = 5
const STARTUP_LOOK_BEHIND_SECONDS = 2
const WINDOW_SECONDS = 15
const LOOK_BEHIND_SECONDS = 5
const EXTERNAL_WINDOW_SECONDS = 60
const PREFETCH_SECONDS = 10

export class SubtitlePipeline {
  constructor(player, { fetcher = globalThis.fetch, origin = globalThis.location?.origin } = {}) {
    this.player = player
    this.fetcher = fetcher
    this.origin = origin
  }

  prefetch(subtitleStream) {
    const track = this.player.subtitleTrackForStream(subtitleStream)
    if (track?.external !== true) return

    const source = this.player.sourceToken()
    if (!source) return

    const durationSeconds = EXTERNAL_WINDOW_SECONDS
    const windowStart = Math.max(
      0,
      Math.floor(this.player.currentPlaybackPosition()) - this.player.subtitleLookBehind(STARTUP_LOOK_BEHIND_SECONDS, durationSeconds)
    )
    const requestKey = this.player.subtitleRequestKey(subtitleStream, windowStart, durationSeconds)
    if (this.player.subtitlePrefetchResults.has(requestKey) || this.player.subtitlePrefetches.has(requestKey)) return

    const url = this.player.subtitleRequestUrl(source, subtitleStream, windowStart, durationSeconds)
    const prefetch = this.player.fetchSubtitleResponse(url)
      .then((response) => {
        this.player.rememberPrefetchedSubtitleResponse(requestKey, response)
        return response
      })
      .catch(() => null)
      .finally(() => this.player.subtitlePrefetches.delete(requestKey))

    this.player.subtitlePrefetches.set(requestKey, prefetch)
  }

  addContentMetadata(url) {
    const params = {
      imdb_id: this.player.imdbIdValue,
      type: this.player.typeValue,
      season: this.player.seasonValue,
      episode: this.player.episodeValue,
      title: this.player.titleValue,
      filename: this.player.filenameValue
    }

    Object.entries(params).forEach(([key, value]) => {
      if (value === undefined || value === null || value.toString() === "") return
      url.searchParams.set(key, value.toString())
    })
  }

  async load(
    currentPosition = this.player.currentPlaybackPosition(),
    {
      durationSeconds = WINDOW_SECONDS,
      lookBehindSeconds = LOOK_BEHIND_SECONDS,
      holdPlayback = false
    } = {}
  ) {
    if (!this.player.hasSubtitlesUrlValue || !this.player.textSubtitleSelected()) return

    const source = this.player.sourceToken()
    if (!source) return

    const requestedSubtitleStream = this.player.selectedSubtitleStream
    const externalSubtitle = this.player.externalSubtitleSelected()
    const requestedDurationSeconds = externalSubtitle ? EXTERNAL_WINDOW_SECONDS : this.player.subtitleWindowDuration(durationSeconds)
    const shouldPrimeContinuation = !externalSubtitle && requestedDurationSeconds < WINDOW_SECONDS
    const windowStart = Math.max(0, Math.floor(currentPosition) - this.player.subtitleLookBehind(lookBehindSeconds, requestedDurationSeconds))
    if (this.player.subtitleLoading && this.player.subtitleWindowStart === windowStart) return

    const loadToken = this.player.subtitleLoadToken + 1
    this.player.subtitleLoadToken = loadToken
    this.player.subtitleLoading = true
    this.player.subtitleWindowStart = windowStart
    this.player.subtitleWindowEnd = windowStart + requestedDurationSeconds
    this.player.abortSubtitleLoad()
    const abortController = new AbortController()
    this.player.subtitleAbortController = abortController
    this.player.beginSubtitlePlaybackHold(holdPlayback, loadToken)

    const requestKey = this.player.subtitleRequestKey(requestedSubtitleStream, windowStart, requestedDurationSeconds)
    const cachedPrefetch = this.player.subtitlePrefetchResults.get(requestKey)
    const pendingPrefetch = this.player.subtitlePrefetches.get(requestKey)
    const url = this.player.subtitleRequestUrl(source, requestedSubtitleStream, windowStart, requestedDurationSeconds)

    try {
      const prefetchedResponse = cachedPrefetch || (pendingPrefetch ? await pendingPrefetch : null)
      const response = prefetchedResponse || await this.player.fetchSubtitleResponse(url, abortController.signal)
      if (this.player.selectedSubtitleStream !== requestedSubtitleStream || this.player.subtitleLoadToken !== loadToken) return
      this.player.applySubtitleResponse(response, windowStart)
    } catch (error) {
      if (error.name === "AbortError") return

      console.warn("Subtitle load failed:", error)
      this.player.resetSubtitleWindow()
      this.player.scheduleSubtitleRetry()
    } finally {
      const requestStillCurrent = this.player.subtitleLoadToken === loadToken
      if (requestStillCurrent) this.player.subtitleLoading = false
      if (this.player.subtitleAbortController === abortController) this.player.subtitleAbortController = null
      this.player.finishSubtitlePlaybackHold(loadToken)
      if (requestStillCurrent && shouldPrimeContinuation) this.player.primeSubtitleContinuation(requestedSubtitleStream)
    }
  }

  requestUrl(source, subtitleStream, windowStart, durationSeconds) {
    const url = new URL(this.player.subtitlesUrlValue, this.origin)
    url.searchParams.set("source", source)
    url.searchParams.set("subtitle_stream", subtitleStream)
    url.searchParams.set("start_seconds", windowStart.toString())
    url.searchParams.set("duration_seconds", durationSeconds.toString())
    return url
  }

  requestKey(subtitleStream, windowStart, durationSeconds) {
    return `${subtitleStream}:${windowStart}:${durationSeconds}`
  }

  async fetchResponse(url, signal) {
    const response = await this.fetcher(url.pathname + url.search, {
      headers: { "Accept": "text/vtt" },
      signal
    })
    const text = response.status === 204 ? "" : await response.text()
    return { ok: response.ok, status: response.status, text }
  }

  rememberPrefetchedResponse(requestKey, response) {
    if (!response) return

    this.player.subtitlePrefetchResults.set(requestKey, response)
    while (this.player.subtitlePrefetchResults.size > 8) {
      this.player.subtitlePrefetchResults.delete(this.player.subtitlePrefetchResults.keys().next().value)
    }
  }

  applyResponse(response, windowStart) {
    if (response.status === 204) {
      this.player.subtitleRetryAfter = 0
      this.player.subtitleCues = this.player.pruneSubtitleCues(this.player.subtitleCues, this.player.currentPlaybackPosition())
      this.player.updateSubtitleOverlay(this.player.currentPlaybackPosition())
      return
    }

    if (!response.ok) {
      this.player.resetSubtitleWindow()
      this.player.scheduleSubtitleRetry()
      return
    }

    const incomingCues = this.player.parseWebVtt(response.text, windowStart)
    this.player.subtitleCues = this.player.mergeSubtitleCues(this.player.subtitleCues, incomingCues, this.player.currentPlaybackPosition())
    this.player.subtitleRetryAfter = 0
    this.player.updateSubtitleOverlay(this.player.currentPlaybackPosition())
  }

  beginPlaybackHold(holdPlayback, loadToken) {
    if (!holdPlayback || this.player.videoTarget.paused || this.player.videoTarget.ended) return

    this.player.subtitlePlaybackHoldToken = loadToken
    this.player.isSeeking = true
    this.player.videoTarget.pause()
    this.player.showSeekingOverlay("Loading subtitles...")
  }

  finishPlaybackHold(loadToken) {
    if (this.player.subtitlePlaybackHoldToken !== loadToken) return

    this.player.subtitlePlaybackHoldToken = null
    this.player.hideSeekingOverlay()
    if (this.player.userPaused) return
    const playPromise = this.player.videoTarget.play()
    if (playPromise?.catch) playPromise.catch(() => {})
  }

  removeTextTrack() {
    this.player.clearSubtitleCues()
    this.player.subtitleRetryAfter = 0
  }

  resetWindow() {
    this.player.subtitleWindowStart = null
    this.player.subtitleWindowEnd = null
  }

  windowDuration(value) {
    const seconds = Number(value)
    if (!Number.isFinite(seconds) || seconds <= 0) return WINDOW_SECONDS
    return Math.max(STARTUP_WINDOW_SECONDS, Math.min(60, Math.floor(seconds)))
  }

  lookBehind(value, durationSeconds) {
    const seconds = Number(value)
    const lookBehindSeconds = Number.isFinite(seconds) && seconds >= 0 ? Math.floor(seconds) : LOOK_BEHIND_SECONDS
    return Math.min(lookBehindSeconds, Math.max(0, durationSeconds - 1))
  }

  scheduleRetry(delayMs = 5000) {
    this.player.subtitleRetryAfter = Date.now() + delayMs
  }

  primeContinuation(requestedSubtitleStream) {
    if (this.player.subtitleRetryAfter) return
    if (this.player.subtitleWindowEnd === null) return
    if (this.player.selectedSubtitleStream !== requestedSubtitleStream) return
    if (!this.player.textSubtitleSelected()) return

    this.player.loadSubtitleTrack(this.player.subtitleWindowEnd, { durationSeconds: WINDOW_SECONDS })
  }

  abortLoad() {
    if (!this.player.subtitleAbortController) return
    this.player.subtitleAbortController.abort()
    this.player.subtitleAbortController = null
  }

  clearCues() {
    this.player.subtitleLoadToken += 1
    this.player.abortSubtitleLoad()
    this.player.subtitleLoading = false
    this.player.resetSubtitleWindow()
    this.player.subtitleCues = []
    if (this.player.hasSubtitleOverlayTarget) {
      this.player.subtitleOverlayTarget.textContent = ""
      this.player.subtitleOverlayTarget.classList.add("hidden")
    }
  }

  mergeCues(existingCues, incomingCues, currentPosition) {
    const cuesByKey = new Map()
    const keepAfter = currentPosition - 5
    for (const cue of [...existingCues, ...incomingCues]) {
      if (cue.end < keepAfter) continue
      cuesByKey.set(`${cue.start}|${cue.end}|${cue.text}`, cue)
    }
    return [...cuesByKey.values()].sort((a, b) => a.start - b.start || a.end - b.end)
  }

  pruneCues(cues, currentPosition) {
    const keepAfter = currentPosition - 5
    return cues.filter((cue) => cue.end >= keepAfter)
  }

  ensureWindow(currentPosition) {
    if (!this.player.textSubtitleSelected() || this.player.subtitleLoading) return
    if (this.player.subtitleRetryAfter && Date.now() < this.player.subtitleRetryAfter) return

    if (this.player.subtitleWindowStart !== null && this.player.subtitleWindowEnd !== null &&
        currentPosition >= this.player.subtitleWindowStart - 2 && currentPosition < this.player.subtitleWindowEnd) return

    const missingWindow = this.player.subtitleWindowStart === null || this.player.subtitleWindowEnd === null
    const beforeWindow = !missingWindow && currentPosition < this.player.subtitleWindowStart
    const windowLength = missingWindow ? WINDOW_SECONDS : this.player.subtitleWindowEnd - this.player.subtitleWindowStart
    const prefetchSeconds = Math.min(PREFETCH_SECONDS, Math.max(1, windowLength / 2))
    const nearWindowEnd = !missingWindow && currentPosition >= this.player.subtitleWindowEnd - prefetchSeconds

    if (missingWindow || beforeWindow) {
      this.player.loadSubtitleTrack(currentPosition, {
        durationSeconds: STARTUP_WINDOW_SECONDS,
        lookBehindSeconds: STARTUP_LOOK_BEHIND_SECONDS
      })
    } else if (nearWindowEnd) {
      this.player.loadSubtitleTrack(this.player.subtitleWindowEnd, { durationSeconds: WINDOW_SECONDS })
    }
  }
}
