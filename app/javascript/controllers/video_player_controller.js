import { Controller } from "@hotwired/stimulus"

const MIN_VALID_DURATION_SECONDS = 60
const SUBTITLE_STARTUP_WINDOW_SECONDS = 5
const SUBTITLE_STARTUP_LOOK_BEHIND_SECONDS = 2
const SUBTITLE_WINDOW_SECONDS = 15
const SUBTITLE_LOOK_BEHIND_SECONDS = 5
const EXTERNAL_SUBTITLE_WINDOW_SECONDS = 60
const SUBTITLE_PREFETCH_SECONDS = 10
const INTERACTIVE_SELECTOR = "button, a, input, textarea, select, [contenteditable='true']"

export default class extends Controller {
  static get targets() {
    return [
      "video", "controls", "seekBar", "seekFilled", "seekBuffered", "seekHandle",
      "playButton", "playIcon", "pauseIcon", "currentTime", "durationDisplay",
      "volumeIcon", "muteIcon", "startupOverlay", "seekingOverlay",
      "seekingOverlayMessage", "sourceInfo", "sourceToggle", "sourceDetails", "sourceUrl", "sourceFilename", "backButton",
      "audioControls", "audioMenu", "audioOptions", "audioButtonLabel",
      "subtitleControls", "subtitleMenu", "subtitleOptions", "subtitleButtonLabel", "subtitleOverlay"
    ]
  }
  static get values() {
    return {
      streamingUrl: String, filename: String, imdbId: String, type: String,
      season: String, episode: String, resumeAt: String, startSeconds: Number,
      title: String, duration: Number, posterUrl: String,
      defaultLanguage: String, preferredLanguages: String,
      tracksUrl: String, subtitlesUrl: String, resumeUrl: String
    }
  }

  connect() {
    this.progressInterval = null
    this.uiHideTimer = null
    this.knownDuration = this.validDuration(this.durationValue) ? this.durationValue : 0
    this.isSeeking = false
    this.isDragging = false
    this.mouseMoveHandler = this.onMouseMove.bind(this)
    this.keydownHandler = this.onKeyDown.bind(this)
    this.videoClickHandler = this.onVideoClick.bind(this)
    this.documentClickHandler = this.onDocumentClick.bind(this)
    this.updatePlayIconHandler = this.updatePlayIcon.bind(this)
    this.timeUpdateHandler = this.onTimeUpdate.bind(this)
    this.progressHandler = this.onProgress.bind(this)
    this.volumeChangeHandler = this.updateVolumeIcon.bind(this)
    this.videoWaitingHandler = () => this.showSeekingOverlay()
    this.videoReadyHandler = () => this.onVideoReady()
    this.audioTracks = []
    this.subtitleTracks = []
    this.selectedAudioStream = this.currentUrlParam("audio_stream")
    this.selectedSubtitleStream = this.currentUrlParam("subtitle_stream")
    this.subtitleCues = []
    this.subtitleWindowStart = null
    this.subtitleWindowEnd = null
    this.subtitleLoading = false
    this.subtitleLoadToken = 0
    this.subtitleAbortController = null
    this.subtitleRetryAfter = 0
    this.subtitlePrefetches = new Map()
    this.subtitlePrefetchResults = new Map()
    this.subtitlePlaybackHoldToken = null
    this.startupOverlayHideTimer = null
    this.dragMoveHandler = null
    this.suppressNextSeekClick = false
    this.suppressSeekClickTimer = null
    this.mediaSource = null
    this.sourceBuffer = null
    this.fetchController = null
    this.bufferQueue = []
    this.bufferAppending = false
    this.pendingSeekSeconds = null
    this.mseSupported = window.MediaSource && MediaSource.isTypeSupported('video/mp4; codecs="avc1.42E01E,mp4a.40.2"')

    this.ensureVideoSource()

    // Show source info
    this.sourceInfoTarget.classList.remove("hidden")
    this.sourceUrlTarget.textContent = this.streamingUrlValue
    this.sourceFilenameTarget.textContent = this.filenameValue || "Unknown"
    this.showOverlayUi()
    this.element.addEventListener("mousemove", this.mouseMoveHandler)
    document.addEventListener("keydown", this.keydownHandler)
    document.addEventListener("click", this.documentClickHandler)
    // Video event listeners
    this.videoTarget.addEventListener("click", this.videoClickHandler)
    this.videoTarget.addEventListener("play", this.updatePlayIconHandler)
    this.videoTarget.addEventListener("pause", this.updatePlayIconHandler)
    this.videoTarget.addEventListener("timeupdate", this.timeUpdateHandler)
    this.videoTarget.addEventListener("progress", this.progressHandler)
    this.videoTarget.addEventListener("volumechange", this.volumeChangeHandler)
    this.videoTarget.addEventListener("waiting", this.videoWaitingHandler)
    this.videoTarget.addEventListener("playing", this.videoReadyHandler)
    this.videoTarget.addEventListener("canplay", this.videoReadyHandler)
    this.videoEndedHandler = () => this.onVideoEnded()
    this.videoTarget.addEventListener("ended", this.videoEndedHandler)

    // Resume: transcode streams already start at the resume position
    // via ffmpeg -ss, so no client-side seek needed.

    // Duration: probe in the background via AJAX — never block video
    // playback. The video starts immediately; the seek bar populates
    // when the probe completes (usually a few seconds).
    this.currentTimeTarget.textContent = this.formatTime(this.startSecondsValue)
    this.updateDurationDisplay()
    this.onTimeUpdate()
    this.syncStartupOverlay()
    this.probeDuration()
    this.loadMediaTracks()

    // Save progress on page unload
    this.beforeUnloadHandler = () => this.saveProgressSync()
    window.addEventListener("beforeunload", this.beforeUnloadHandler)

    // Track progress every 5s
    this.startProgressTracking()
  }

  disconnect() {
    this.stopProgressTracking()
    this.saveProgressSync()
    this.clearUiHideTimer()
    this.clearStartupOverlayTimer()
    this.clearSuppressSeekClickTimer()
    this.cancelSeekDrag()
    this.element.removeEventListener("mousemove", this.mouseMoveHandler)
    document.removeEventListener("keydown", this.keydownHandler)
    document.removeEventListener("click", this.documentClickHandler)
    this.videoTarget.removeEventListener("click", this.videoClickHandler)
    this.videoTarget.removeEventListener("play", this.updatePlayIconHandler)
    this.videoTarget.removeEventListener("pause", this.updatePlayIconHandler)
    this.videoTarget.removeEventListener("timeupdate", this.timeUpdateHandler)
    this.videoTarget.removeEventListener("progress", this.progressHandler)
    this.videoTarget.removeEventListener("volumechange", this.volumeChangeHandler)
    this.videoTarget.removeEventListener("waiting", this.videoWaitingHandler)
    this.videoTarget.removeEventListener("playing", this.videoReadyHandler)
    this.videoTarget.removeEventListener("canplay", this.videoReadyHandler)
    this.videoTarget.removeEventListener("ended", this.videoEndedHandler)
    window.removeEventListener("beforeunload", this.beforeUnloadHandler)
    this.removeTextSubtitleTrack()
    if (this.fetchController) { this.fetchController.abort(); this.fetchController = null }
    this.bufferQueue = []
    this.pendingSeekSeconds = null
    this.pauseAndDetachVideo()
  }

  async probeDuration() {
    try {
      const rawUrl = this.extractRawUrl()
      if (!rawUrl) return

      const response = await fetch(`/transcode/duration?url=${encodeURIComponent(rawUrl)}`)
      const data = await response.json()
      const probedDuration = Number(data.duration)
      if (this.validDuration(probedDuration)) {
        this.knownDuration = probedDuration
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

  currentUrlParam(name) {
    try {
      const url = new URL(this.streamingUrlValue || this.videoTarget.currentSrc || this.videoTarget.src, window.location.origin)
      return url.searchParams.get(name)
    } catch {
      return null
    }
  }
  ensureVideoSource() {
    if (!this.streamingUrlValue) return
    if (this.mseSupported) {
      this.setupMseSource(this.streamingUrlValue)
    } else if (!this.videoTarget.getAttribute("src")) {
      this.videoTarget.src = this.streamingUrlValue
    }
  }
  setupMseSource(streamUrl) {
    // Abort current fetch and clear queue
    if (this.fetchController) { this.fetchController.abort(); this.fetchController = null }
    this.bufferQueue = []

    // Tear down old MediaSource
    if (this.mediaSource) {
      if (this.mediaSource.readyState === "open") { try { this.mediaSource.endOfStream() } catch {} }
      this.mediaSource = null
      this.sourceBuffer = null
    }
    if (this.videoTarget.src.startsWith("blob:")) URL.revokeObjectURL(this.videoTarget.src)

    const mimeType = 'video/mp4; codecs="avc1.42E01E,mp4a.40.2"'
    if (!this.mseSupported) {
      this.videoTarget.src = streamUrl
      this.videoTarget.load()
      const p = this.videoTarget.play(); if (p?.catch) p.catch(() => {})
      return
    }

    this.mediaSource = new MediaSource()
    this.videoTarget.src = URL.createObjectURL(this.mediaSource)
    this.mediaSource.addEventListener("sourceopen", () => {
      this.sourceBuffer = this.mediaSource.addSourceBuffer(mimeType)
      this.sourceBuffer.mode = "segments"
      this.sourceBuffer.addEventListener("updateend", () => this.onBufferUpdateEnd())
      this.startStreamingFetch(streamUrl)
    }, { once: true })
  }

  async startStreamingFetch(url) {
    this.fetchController = new AbortController()
    try {
      const response = await fetch(url, { signal: this.fetchController.signal })
      if (!response.ok) { console.warn("Stream fetch failed:", response.status); return }
      const reader = response.body.getReader()
      let firstChunk = true
      while (true) {
        const { done, value } = await reader.read()
        if (done) break
        if (firstChunk) {
          firstChunk = false
          const p = this.videoTarget.play(); if (p?.catch) p.catch(() => {})
        }
        this.queueBufferChunk(value)
      }
    } catch (e) {
      if (e.name === "AbortError") return
      console.warn("Stream fetch failed:", e)
    }
  }

  queueBufferChunk(chunk) {
    this.bufferQueue.push(chunk)
    this.flushBufferQueue()
  }

  flushBufferQueue() {
    if (this.bufferAppending || !this.sourceBuffer || this.sourceBuffer.updating) return
    if (this.bufferQueue.length === 0) return
    this.bufferAppending = true
    const chunk = this.bufferQueue.shift()
    try {
      this.sourceBuffer.appendBuffer(chunk)
    } catch (e) {
      this.bufferAppending = false
      if (e.name === "QuotaExceededError") this.evictOldBuffer()
    }
  }

  onBufferUpdateEnd() {
    this.bufferAppending = false
    this.evictOldBuffer()
    this.flushBufferQueue()
  }

  evictOldBuffer() {
    if (!this.sourceBuffer || this.sourceBuffer.updating) return
    const evictBefore = this.videoTarget.currentTime - 30
    if (evictBefore <= 0) return
    for (let i = 0; i < this.sourceBuffer.buffered.length; i++) {
      const start = this.sourceBuffer.buffered.start(i)
      const end = this.sourceBuffer.buffered.end(i)
      if (start < evictBefore) {
        try { this.sourceBuffer.remove(start, Math.min(end, evictBefore)) } catch {}
        return
      }
    }
  }

  // ── Play / pause ──────────────────────────────────────────────────

  togglePlay() {
    if (this.videoTarget.paused) {
      const playPromise = this.videoTarget.play()
      if (playPromise?.catch) playPromise.catch(() => {})
    } else {
      this.videoTarget.pause()
    }
  }

  onVideoClick(event) {
    event.preventDefault()
    this.togglePlay()
    this.showOverlayUi()
  }

  onKeyDown(event) {
    if (event.key !== " " && event.key !== "Spacebar") return
    if (event.repeat || this.isInteractiveElement(event.target)) return

    event.preventDefault()
    this.togglePlay()
    this.showOverlayUi()
  }

  isInteractiveElement(element) {
    return element instanceof Element && element.closest(INTERACTIVE_SELECTOR)
  }

  navigateBack(event) {
    event.preventDefault()
    event.stopImmediatePropagation()
    const href = event.currentTarget.href
    this.stopPlaybackForNavigation()
    window.location.href = href
  }

  stopPlaybackForNavigation() {
    this.stopProgressTracking()
    this.saveProgressSync()
    this.pauseAndDetachVideo()
  }

  // Auto-advance to the next episode when the current one finishes.
  // Only applies to shows — movies just stop (progress already saved).
  async onVideoEnded() {
    if (this.typeValue !== "show") return

    // Flush final progress so the finished episode crosses 95%.
    await this.saveProgress()

    if (this.resumeUrlValue) {
      const url = `${this.resumeUrlValue}?type=show&show_imdb_id=${encodeURIComponent(this.imdbIdValue)}`
      window.location.href = url
    }
  }

  pauseAndDetachVideo() {
    if (!this.hasVideoTarget) return
    try {
      if (this.fetchController) { this.fetchController.abort(); this.fetchController = null }
      this.bufferQueue = []
      if (this.mediaSource) {
        if (this.mediaSource.readyState === "open") { try { this.mediaSource.endOfStream() } catch {} }
        this.mediaSource = null
        this.sourceBuffer = null
      }
      this.videoTarget.pause()
      if (this.videoTarget.src.startsWith("blob:")) URL.revokeObjectURL(this.videoTarget.src)
      this.videoTarget.src = ""
      this.videoTarget.removeAttribute("src")
      this.videoTarget.load()
    } catch {}
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

  onVideoReady() {
    this.hideSeekingOverlay()
    this.hideStartupOverlay()
  }

  syncStartupOverlay() {
    if (!this.hasStartupOverlayTarget) return

    if (!this.videoTarget.paused && this.videoTarget.currentTime > 0) {
      this.hideStartupOverlay()
      return
    }

    this.clearStartupOverlayTimer()
    this.startupOverlayHideTimer = setTimeout(() => {
      if (!this.hasVideoTarget) return
      if (!this.videoTarget.paused && this.videoTarget.readyState >= HTMLMediaElement.HAVE_CURRENT_DATA) {
        this.hideStartupOverlay()
      }
    }, 0)
  }

  hideStartupOverlay() {
    if (!this.hasStartupOverlayTarget) return

    this.startupOverlayTarget.classList.add("opacity-0", "pointer-events-none")
    this.startupOverlayTarget.setAttribute("aria-hidden", "true")
    this.clearStartupOverlayTimer()
    this.startupOverlayHideTimer = setTimeout(() => {
      if (this.hasStartupOverlayTarget) this.startupOverlayTarget.classList.add("hidden")
    }, 220)
  }

  clearStartupOverlayTimer() {
    if (!this.startupOverlayHideTimer) return

    clearTimeout(this.startupOverlayHideTimer)
    this.startupOverlayHideTimer = null
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

  // ── Audio / subtitles ─────────────────────────────────────────────

  async loadMediaTracks() {
    if (!this.hasTracksUrlValue) return

    const rawUrl = this.extractRawUrl()
    if (!rawUrl) return

    try {
      const url = new URL(this.tracksUrlValue, window.location.origin)
      url.searchParams.set("url", rawUrl)
      this.addContentMetadataParams(url)
      const response = await fetch(url.pathname + url.search, { headers: { "Accept": "application/json" } })
      if (!response.ok) return

      const data = await response.json()
      this.audioTracks = Array.isArray(data.audio) ? data.audio : []
      this.subtitleTracks = Array.isArray(data.subtitles) ? data.subtitles : []
      this.selectedAudioStream ||= this.preferredAudioTrack()?.index?.toString() || null
      if (this.selectedSubtitleStream && !this.subtitleTrackForStream(this.selectedSubtitleStream)) {
        this.selectedSubtitleStream = null
      }
      this.renderTrackControls()
      if (this.textSubtitleSelected()) this.loadSubtitleTrack(this.currentPlaybackPosition(), {
        durationSeconds: SUBTITLE_STARTUP_WINDOW_SECONDS,
        lookBehindSeconds: SUBTITLE_STARTUP_LOOK_BEHIND_SECONDS,
        holdPlayback: true
      })
    } catch (e) {
      console.warn("Track probe failed:", e)
    }
  }

  preferredAudioTrack() {
    const languagePriority = this.languagePriority()
    const preferredTracks = this.audioTracks
      .filter((track) => languagePriority.includes(track.language))
      .sort((a, b) => {
        const languageDelta = languagePriority.indexOf(a.language) - languagePriority.indexOf(b.language)
        if (languageDelta !== 0) return languageDelta
        return Number(a.position || 0) - Number(b.position || 0)
      })

    return preferredTracks[0] || this.audioTracks.find((track) => track.default) || this.audioTracks[0]
  }

  languagePriority() {
    const languages = [this.defaultLanguageValue, ...this.preferredLanguages()]
    return [...new Set(languages.map((language) => language?.toString().toUpperCase()).filter(Boolean))]
  }

  preferredLanguages() {
    try {
      const parsed = JSON.parse(this.preferredLanguagesValue || "[]")
      return Array.isArray(parsed) ? parsed : []
    } catch {
      return []
    }
  }

  renderTrackControls() {
    this.renderAudioControls()
    this.renderSubtitleControls()
  }

  renderAudioControls() {
    if (!this.hasAudioControlsTarget || !this.hasAudioOptionsTarget) return
    if (this.audioTracks.length <= 1) {
      this.audioControlsTarget.classList.add("hidden")
      return
    }

    this.audioControlsTarget.classList.remove("hidden")
    this.audioOptionsTarget.replaceChildren()
    this.audioTracks.forEach((track) => {
      this.audioOptionsTarget.appendChild(this.trackOptionButton({
        label: track.label || "Audio",
        selected: track.index?.toString() === this.selectedAudioStream,
        datasetName: "audioStream",
        datasetValue: track.index,
        action: "click->video-player#selectAudioTrack"
      }))
    })
    this.updateAudioButtonLabel()
  }

  renderSubtitleControls() {
    if (!this.hasSubtitleControlsTarget || !this.hasSubtitleOptionsTarget) return
    if (this.subtitleTracks.length === 0) {
      this.subtitleControlsTarget.classList.add("hidden")
      return
    }

    this.subtitleControlsTarget.classList.remove("hidden")
    this.subtitleOptionsTarget.replaceChildren()
    this.subtitleOptionsTarget.appendChild(this.trackOptionButton({
      label: "Off",
      selected: !this.selectedSubtitleStream,
      datasetName: "subtitleStream",
      datasetValue: "",
      action: "click->video-player#selectSubtitleTrack"
    }))

    this.subtitleTracks.forEach((track) => {
      this.subtitleOptionsTarget.appendChild(this.trackOptionButton({
        label: track.label || "Subtitle",
        selected: track.index?.toString() === this.selectedSubtitleStream,
        datasetName: "subtitleStream",
        datasetValue: track.index,
        action: track.external === true
          ? "click->video-player#selectSubtitleTrack pointerenter->video-player#prefetchSubtitleTrack focus->video-player#prefetchSubtitleTrack"
          : "click->video-player#selectSubtitleTrack"
      }))
    })
    this.updateSubtitleButtonLabel()
  }

  trackOptionButton({ label, selected, datasetName, datasetValue, action }) {
    const button = document.createElement("button")
    button.type = "button"
    button.className = `block w-full text-left px-2 py-1.5 rounded transition-colors ${selected ? "bg-sv-accent text-white" : "hover:bg-sv-surface-hover text-sv-text-muted hover:text-white"}`
    button.dataset[datasetName] = datasetValue?.toString() || ""
    button.dataset.action = action
    button.textContent = label
    return button
  }

  selectAudioTrack(event) {
    const selectedStream = event.currentTarget.dataset.audioStream
    if (!selectedStream || selectedStream === this.selectedAudioStream) {
      this.closeTrackMenus()
      return
    }

    this.selectedAudioStream = selectedStream
    this.renderAudioControls()
    this.closeTrackMenus()

    const targetSeconds = Math.floor(this.videoTarget.currentTime + this.startSecondsValue)
    this.restartPlaybackAt(targetSeconds)
  }

  selectSubtitleTrack(event) {
    const previousBurnedSubtitle = this.burnedSubtitleSelected()
    const selectedStream = event.currentTarget.dataset.subtitleStream || null
    if (selectedStream === this.selectedSubtitleStream) {
      this.closeTrackMenus()
      return
    }

    this.selectedSubtitleStream = selectedStream
    this.subtitleRetryAfter = 0
    this.clearSubtitleCues()
    this.renderSubtitleControls()
    this.closeTrackMenus()

    const targetSeconds = Math.floor(this.currentPlaybackPosition())
    if (previousBurnedSubtitle || this.burnedSubtitleSelected()) {
      this.restartPlaybackAt(targetSeconds)
    } else if (this.textSubtitleSelected()) {
      this.loadSubtitleTrack(targetSeconds, {
        durationSeconds: SUBTITLE_STARTUP_WINDOW_SECONDS,
        lookBehindSeconds: SUBTITLE_STARTUP_LOOK_BEHIND_SECONDS,
        holdPlayback: true
      })
    }
  }

  currentPlaybackPosition() {
    return this.videoTarget.currentTime + this.startSecondsValue
  }

  selectedSubtitleTrack() {
    if (!this.selectedSubtitleStream) return null

    return this.subtitleTrackForStream(this.selectedSubtitleStream)
  }

  subtitleTrackForStream(subtitleStream) {
    if (!subtitleStream) return null

    return this.subtitleTracks.find((track) => track.index?.toString() === subtitleStream) || null
  }

  textSubtitleSelected() {
    return this.selectedSubtitleTrack()?.text_supported === true
  }

  burnedSubtitleSelected() {
    if (!this.selectedSubtitleStream) return false

    const track = this.selectedSubtitleTrack()
    return !track || track.text_supported !== true
  }

  externalSubtitleSelected() {
    return this.selectedSubtitleTrack()?.external === true
  }

  prefetchSubtitleTrack(event) {
    this.prefetchSubtitleStream(event.currentTarget.dataset.subtitleStream)
  }

  prefetchLikelyExternalSubtitle() {
    const selectedTrack = this.subtitleTrackForStream(this.selectedSubtitleStream)
    const track = selectedTrack?.external === true ? selectedTrack : this.subtitleTracks.find((candidate) => candidate.external === true)
    this.prefetchSubtitleStream(track?.index?.toString())
  }

  prefetchSubtitleStream(subtitleStream) {
    const track = this.subtitleTrackForStream(subtitleStream)
    if (track?.external !== true) return

    const rawUrl = this.extractRawUrl()
    if (!rawUrl) return

    const durationSeconds = EXTERNAL_SUBTITLE_WINDOW_SECONDS
    const windowStart = Math.max(
      0,
      Math.floor(this.currentPlaybackPosition()) - this.subtitleLookBehind(SUBTITLE_STARTUP_LOOK_BEHIND_SECONDS, durationSeconds)
    )
    const requestKey = this.subtitleRequestKey(subtitleStream, windowStart, durationSeconds)
    if (this.subtitlePrefetchResults.has(requestKey) || this.subtitlePrefetches.has(requestKey)) return

    const url = this.subtitleRequestUrl(rawUrl, subtitleStream, windowStart, durationSeconds)
    const prefetch = this.fetchSubtitleResponse(url)
      .then((response) => {
        this.rememberPrefetchedSubtitleResponse(requestKey, response)
        return response
      })
      .catch(() => null)
      .finally(() => this.subtitlePrefetches.delete(requestKey))

    this.subtitlePrefetches.set(requestKey, prefetch)
  }

  addContentMetadataParams(url) {
    const params = {
      imdb_id: this.imdbIdValue,
      type: this.typeValue,
      season: this.seasonValue,
      episode: this.episodeValue,
      title: this.titleValue,
      filename: this.filenameValue
    }

    Object.entries(params).forEach(([key, value]) => {
      if (value === undefined || value === null || value.toString() === "") return

      url.searchParams.set(key, value.toString())
    })
  }

  async loadSubtitleTrack(
    currentPosition = this.currentPlaybackPosition(),
    {
      durationSeconds = SUBTITLE_WINDOW_SECONDS,
      lookBehindSeconds = SUBTITLE_LOOK_BEHIND_SECONDS,
      holdPlayback = false
    } = {}
  ) {
    if (!this.hasSubtitlesUrlValue || !this.textSubtitleSelected()) return

    const rawUrl = this.extractRawUrl()
    if (!rawUrl) return

    const requestedSubtitleStream = this.selectedSubtitleStream
    const externalSubtitle = this.externalSubtitleSelected()
    const requestedDurationSeconds = externalSubtitle ? EXTERNAL_SUBTITLE_WINDOW_SECONDS : this.subtitleWindowDuration(durationSeconds)
    const shouldPrimeContinuation = !externalSubtitle && requestedDurationSeconds < SUBTITLE_WINDOW_SECONDS
    const windowStart = Math.max(0, Math.floor(currentPosition) - this.subtitleLookBehind(lookBehindSeconds, requestedDurationSeconds))
    if (this.subtitleLoading && this.subtitleWindowStart === windowStart) return

    const loadToken = this.subtitleLoadToken + 1
    this.subtitleLoadToken = loadToken
    this.subtitleLoading = true
    this.subtitleWindowStart = windowStart
    this.subtitleWindowEnd = windowStart + requestedDurationSeconds
    this.abortSubtitleLoad()
    const abortController = new AbortController()
    this.subtitleAbortController = abortController
    this.beginSubtitlePlaybackHold(holdPlayback, loadToken)

    const requestKey = this.subtitleRequestKey(requestedSubtitleStream, windowStart, requestedDurationSeconds)
    const cachedPrefetch = this.subtitlePrefetchResults.get(requestKey)
    const pendingPrefetch = this.subtitlePrefetches.get(requestKey)
    const url = this.subtitleRequestUrl(rawUrl, requestedSubtitleStream, windowStart, requestedDurationSeconds)

    try {
      const prefetchedResponse = cachedPrefetch || (pendingPrefetch ? await pendingPrefetch : null)
      const response = prefetchedResponse || await this.fetchSubtitleResponse(url, abortController.signal)
      if (this.selectedSubtitleStream !== requestedSubtitleStream || this.subtitleLoadToken !== loadToken) return
      this.applySubtitleResponse(response, windowStart)
    } catch (e) {
      if (e.name === "AbortError") return

      console.warn("Subtitle load failed:", e)
      this.resetSubtitleWindow()
      this.scheduleSubtitleRetry()
    } finally {
      const requestStillCurrent = this.subtitleLoadToken === loadToken
      if (requestStillCurrent) this.subtitleLoading = false
      if (this.subtitleAbortController === abortController) this.subtitleAbortController = null
      this.finishSubtitlePlaybackHold(loadToken)
      if (requestStillCurrent && shouldPrimeContinuation) this.primeSubtitleContinuation(requestedSubtitleStream)
    }
  }

  subtitleRequestUrl(rawUrl, subtitleStream, windowStart, durationSeconds) {
    const url = new URL(this.subtitlesUrlValue, window.location.origin)
    url.searchParams.set("url", rawUrl)
    url.searchParams.set("subtitle_stream", subtitleStream)
    url.searchParams.set("start_seconds", windowStart.toString())
    url.searchParams.set("duration_seconds", durationSeconds.toString())
    return url
  }

  subtitleRequestKey(subtitleStream, windowStart, durationSeconds) {
    return `${subtitleStream}:${windowStart}:${durationSeconds}`
  }

  async fetchSubtitleResponse(url, signal) {
    const response = await fetch(url.pathname + url.search, {
      headers: { "Accept": "text/vtt" },
      signal
    })
    const text = response.status === 204 ? "" : await response.text()
    return { ok: response.ok, status: response.status, text }
  }

  rememberPrefetchedSubtitleResponse(requestKey, response) {
    if (!response) return

    this.subtitlePrefetchResults.set(requestKey, response)
    while (this.subtitlePrefetchResults.size > 8) {
      this.subtitlePrefetchResults.delete(this.subtitlePrefetchResults.keys().next().value)
    }
  }

  applySubtitleResponse(response, windowStart) {
    if (response.status === 204) {
      this.subtitleRetryAfter = 0
      this.subtitleCues = this.pruneSubtitleCues(this.subtitleCues, this.currentPlaybackPosition())
      this.updateSubtitleOverlay(this.currentPlaybackPosition())
      return
    }

    if (!response.ok) {
      this.resetSubtitleWindow()
      this.scheduleSubtitleRetry()
      return
    }

    const incomingCues = this.parseWebVtt(response.text, windowStart)
    this.subtitleCues = this.mergeSubtitleCues(this.subtitleCues, incomingCues, this.currentPlaybackPosition())
    this.subtitleRetryAfter = 0
    this.updateSubtitleOverlay(this.currentPlaybackPosition())
  }

  beginSubtitlePlaybackHold(holdPlayback, loadToken) {
    if (!holdPlayback || this.videoTarget.paused || this.videoTarget.ended) return

    this.subtitlePlaybackHoldToken = loadToken
    this.isSeeking = true
    this.videoTarget.pause()
    this.showSeekingOverlay("Loading subtitles...")
  }

  finishSubtitlePlaybackHold(loadToken) {
    if (this.subtitlePlaybackHoldToken !== loadToken) return

    this.subtitlePlaybackHoldToken = null
    this.hideSeekingOverlay()
    const playPromise = this.videoTarget.play()
    if (playPromise?.catch) playPromise.catch(() => {})
  }

  removeTextSubtitleTrack() {
    this.subtitleLoadToken += 1
    this.abortSubtitleLoad()
    this.clearSubtitleCues()
    this.subtitleWindowStart = null
    this.subtitleWindowEnd = null
    this.subtitleLoading = false
    this.subtitleRetryAfter = 0
  }

  resetSubtitleWindow() {
    this.subtitleWindowStart = null
    this.subtitleWindowEnd = null
  }

  subtitleWindowDuration(value) {
    const seconds = Number(value)
    if (!Number.isFinite(seconds) || seconds <= 0) return SUBTITLE_WINDOW_SECONDS

    return Math.max(SUBTITLE_STARTUP_WINDOW_SECONDS, Math.min(60, Math.floor(seconds)))
  }

  subtitleLookBehind(value, durationSeconds) {
    const seconds = Number(value)
    const lookBehindSeconds = Number.isFinite(seconds) && seconds >= 0 ? Math.floor(seconds) : SUBTITLE_LOOK_BEHIND_SECONDS

    return Math.min(lookBehindSeconds, Math.max(0, durationSeconds - 1))
  }

  scheduleSubtitleRetry(delayMs = 5000) {
    this.subtitleRetryAfter = Date.now() + delayMs
  }

  primeSubtitleContinuation(requestedSubtitleStream) {
    if (this.subtitleRetryAfter) return
    if (this.subtitleWindowEnd === null) return
    if (this.selectedSubtitleStream !== requestedSubtitleStream) return
    if (!this.textSubtitleSelected()) return

    this.loadSubtitleTrack(this.subtitleWindowEnd, { durationSeconds: SUBTITLE_WINDOW_SECONDS })
  }

  abortSubtitleLoad() {
    if (!this.subtitleAbortController) return

    this.subtitleAbortController.abort()
    this.subtitleAbortController = null
  }

  clearSubtitleCues() {
    this.subtitleCues = []
    if (this.hasSubtitleOverlayTarget) {
      this.subtitleOverlayTarget.textContent = ""
      this.subtitleOverlayTarget.classList.add("hidden")
    }
  }

  mergeSubtitleCues(existingCues, incomingCues, currentPosition) {
    const cuesByKey = new Map()
    const keepAfter = currentPosition - 5
    const combinedCues = [...existingCues, ...incomingCues]
    combinedCues.forEach((cue) => {
      if (cue.end < keepAfter) return

      cuesByKey.set(`${cue.start}|${cue.end}|${cue.text}`, cue)
    })

    return [...cuesByKey.values()].sort((a, b) => a.start - b.start || a.end - b.end)
  }

  pruneSubtitleCues(cues, currentPosition) {
    const keepAfter = currentPosition - 5
    return cues.filter((cue) => cue.end >= keepAfter)
  }

  parseWebVtt(text, offsetSeconds = 0) {
    const cues = text
      .replace(/^\uFEFF/, "")
      .split(/\r?\n\s*\r?\n/)
      .filter((block) => block.includes("-->"))
      .map((block) => this.parseWebVttCue(block))
      .filter(Boolean)

    if (offsetSeconds <= 0 || cues.some((cue) => cue.start >= offsetSeconds - 30)) {
      return cues
    }

    return cues.map((cue) => ({
      ...cue,
      start: cue.start + offsetSeconds,
      end: cue.end + offsetSeconds
    }))
  }

  parseWebVttCue(block) {
    const lines = block.split(/\r?\n/).map((line) => line.trim()).filter(Boolean)
    const timingIndex = lines.findIndex((line) => line.includes("-->"))
    if (timingIndex < 0) return null

    const [startText, endAndSettings] = lines[timingIndex].split("-->").map((part) => part.trim())
    const endText = endAndSettings?.split(/\s+/)[0]
    const start = this.parseCueTimestamp(startText)
    const end = this.parseCueTimestamp(endText)
    if (!Number.isFinite(start) || !Number.isFinite(end) || end <= start) return null

    const cueText = lines
      .slice(timingIndex + 1)
      .map((line) => this.cleanCueText(line))
      .join("\n")
      .trim()

    if (!cueText) return null
    return { start, end, text: cueText }
  }

  parseCueTimestamp(value) {
    const parts = value?.split(":") || []
    if (parts.length < 2 || parts.length > 3) return NaN

    const seconds = Number(parts.pop().replace(",", "."))
    const minutes = Number(parts.pop())
    const hours = parts.length === 1 ? Number(parts.pop()) : 0
    if (![hours, minutes, seconds].every(Number.isFinite)) return NaN

    return (hours * 3600) + (minutes * 60) + seconds
  }

  cleanCueText(text) {
    return text
      .replace(/<[^>]+>/g, "")
      .replace(/&amp;/g, "&")
      .replace(/&lt;/g, "<")
      .replace(/&gt;/g, ">")
      .replace(/&quot;/g, "\"")
      .replace(/&#39;/g, "'")
  }

  updateSubtitleOverlay(currentPos) {
    if (!this.hasSubtitleOverlayTarget) return
    this.ensureSubtitleWindow(currentPos)
    if (this.subtitleCues.length === 0) return

    const activeCues = this.subtitleCues
      .filter((cue) => currentPos >= cue.start && currentPos <= cue.end)
      .map((cue) => cue.text)

    if (activeCues.length === 0) {
      this.subtitleOverlayTarget.textContent = ""
      this.subtitleOverlayTarget.classList.add("hidden")
      return
    }

    this.subtitleOverlayTarget.textContent = activeCues.join("\n")
    this.subtitleOverlayTarget.classList.remove("hidden")
  }

  ensureSubtitleWindow(currentPos) {
    if (!this.textSubtitleSelected() || this.subtitleLoading) return
    if (this.subtitleRetryAfter && Date.now() < this.subtitleRetryAfter) return

    // Skip if we already have a window covering the current position
    if (this.subtitleWindowStart !== null && this.subtitleWindowEnd !== null &&
        currentPos >= this.subtitleWindowStart - 2 && currentPos < this.subtitleWindowEnd) return

    const missingWindow = this.subtitleWindowStart === null || this.subtitleWindowEnd === null
    const beforeWindow = !missingWindow && currentPos < this.subtitleWindowStart
    const windowLength = missingWindow ? SUBTITLE_WINDOW_SECONDS : this.subtitleWindowEnd - this.subtitleWindowStart
    const prefetchSeconds = Math.min(SUBTITLE_PREFETCH_SECONDS, Math.max(1, windowLength / 2))
    const nearWindowEnd = !missingWindow && currentPos >= this.subtitleWindowEnd - prefetchSeconds

    if (missingWindow || beforeWindow) {
      this.loadSubtitleTrack(currentPos, {
        durationSeconds: SUBTITLE_STARTUP_WINDOW_SECONDS,
        lookBehindSeconds: SUBTITLE_STARTUP_LOOK_BEHIND_SECONDS
      })
    } else if (nearWindowEnd) {
      this.loadSubtitleTrack(this.subtitleWindowEnd, { durationSeconds: SUBTITLE_WINDOW_SECONDS })
    }
  }

  updateAudioButtonLabel() {
    if (!this.hasAudioButtonLabelTarget) return

    const selectedTrack = this.audioTracks.find((track) => track.index?.toString() === this.selectedAudioStream)
    this.audioButtonLabelTarget.textContent = selectedTrack?.language_label || "Audio"
  }

  updateSubtitleButtonLabel() {
    if (!this.hasSubtitleButtonLabelTarget) return

    const selectedTrack = this.subtitleTracks.find((track) => track.index?.toString() === this.selectedSubtitleStream)
    this.subtitleButtonLabelTarget.textContent = selectedTrack?.language_label || "CC"
  }

  toggleAudioMenu(event) {
    event.stopPropagation()
    this.toggleTrackMenu(this.audioMenuTarget, this.hasSubtitleMenuTarget ? this.subtitleMenuTarget : null)
  }

  toggleSubtitleMenu(event) {
    event.stopPropagation()
    this.toggleTrackMenu(this.subtitleMenuTarget, this.hasAudioMenuTarget ? this.audioMenuTarget : null)
    if (!this.subtitleMenuTarget.classList.contains("hidden")) this.prefetchLikelyExternalSubtitle()
  }

  toggleTrackMenu(menu, otherMenu) {
    otherMenu?.classList.add("hidden")
    menu.classList.toggle("hidden")
    this.showOverlayUi()
    if (!menu.classList.contains("hidden")) this.clearUiHideTimer()
  }

  closeTrackMenus() {
    if (this.hasAudioMenuTarget) this.audioMenuTarget.classList.add("hidden")
    if (this.hasSubtitleMenuTarget) this.subtitleMenuTarget.classList.add("hidden")
    this.scheduleUiHide()
  }

  trackMenuOpen() {
    return (this.hasAudioMenuTarget && !this.audioMenuTarget.classList.contains("hidden")) ||
      (this.hasSubtitleMenuTarget && !this.subtitleMenuTarget.classList.contains("hidden"))
  }

  onDocumentClick(event) {
    if (!this.trackMenuOpen()) return
    if (this.hasAudioControlsTarget && this.audioControlsTarget.contains(event.target)) return
    if (this.hasSubtitleControlsTarget && this.subtitleControlsTarget.contains(event.target)) return

    this.closeTrackMenus()
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
    if (this.suppressNextSeekClick) {
      this.suppressNextSeekClick = false
      return
    }
    if (this.isDragging) return // drag handler manages this
    const percent = this.seekPercentFromEvent(event)
    this.performSeek(percent)
  }

  startSeekDrag(event) {
    this.cancelSeekDrag()
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
    const percent = this.seekPercentFromEvent(event)
    this.cancelSeekDrag()
    this.suppressNextSeekClick = true
    this.clearSuppressSeekClickTimer()
    this.suppressSeekClickTimer = setTimeout(() => {
      this.suppressNextSeekClick = false
      this.suppressSeekClickTimer = null
    }, 250)
    this.performSeek(percent)
  }

  cancelSeekDrag() {
    this.isDragging = false
    if (!this.dragMoveHandler) return

    document.removeEventListener("mousemove", this.dragMoveHandler)
    document.removeEventListener("touchmove", this.dragMoveHandler)
    this.dragMoveHandler = null
  }

  clearSuppressSeekClickTimer() {
    if (!this.suppressSeekClickTimer) return

    clearTimeout(this.suppressSeekClickTimer)
    this.suppressSeekClickTimer = null
  }

  seekPercentFromEvent(event) {
    const rect = this.seekBarTarget.getBoundingClientRect()
    const point = event.changedTouches?.[0] || event.touches?.[0] || event
    const clientX = point.clientX ?? rect.left
    const percent = (clientX - rect.left) / rect.width
    return Math.max(0, Math.min(1, percent))
  }

  performSeek(percent) {
    if (this.knownDuration <= 0) return
    const targetSeconds = Math.floor(percent * this.knownDuration)
    if (targetSeconds === this.startSecondsValue) return

    if (this.isSeeking) {
      this.pendingSeekSeconds = targetSeconds
      return
    }
    this.restartPlaybackAt(targetSeconds)
    this.currentTimeTarget.textContent = this.formatTime(targetSeconds)
    this.updateSeekVisuals(targetSeconds / this.knownDuration)
  }

  restartPlaybackAt(targetSeconds) {
    this.isSeeking = true
    this.showSeekingOverlay()
    this.startSecondsValue = targetSeconds
    this.element.dataset.videoPlayerStartSecondsValue = targetSeconds.toString()

    const url = new URL(this.streamingUrlValue, window.location.origin)
    if (targetSeconds > 0) {
      url.searchParams.set("start_seconds", targetSeconds)
    } else {
      url.searchParams.delete("start_seconds")
    }

    if (this.selectedAudioStream) {
      url.searchParams.set("audio_stream", this.selectedAudioStream)
    } else {
      url.searchParams.delete("audio_stream")
    }

    if (this.burnedSubtitleSelected()) {
      url.searchParams.set("subtitle_stream", this.selectedSubtitleStream)
    } else {
      url.searchParams.delete("subtitle_stream")
    }

    const nextSrc = url.pathname + url.search
    this.streamingUrlValue = nextSrc
    this.element.dataset.videoPlayerStreamingUrlValue = nextSrc

    this.setupMseSource(nextSrc)

    this.clearSubtitleCues()
    if (this.textSubtitleSelected()) {
      this.loadSubtitleTrack(targetSeconds, {
        durationSeconds: SUBTITLE_STARTUP_WINDOW_SECONDS,
        lookBehindSeconds: SUBTITLE_STARTUP_LOOK_BEHIND_SECONDS,
        holdPlayback: true
      })
    }
  }

  // ── Time / progress updates ───────────────────────────────────────

  onTimeUpdate() {
    const currentPos = this.videoTarget.currentTime + this.startSecondsValue
    const duration = this.effectiveDuration()

    this.currentTimeTarget.textContent = this.formatTime(currentPos)
    this.updateSubtitleOverlay(currentPos)
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
    return this.validDuration(d) ? d + this.startSecondsValue : 0
  }

  updateDurationDisplay() {
    const duration = this.effectiveDuration()
    this.durationDisplayTarget.textContent = duration > 0 ? this.formatTime(duration) : "--:--"
  }

  validDuration(seconds) {
    return Number.isFinite(seconds) && seconds >= MIN_VALID_DURATION_SECONDS
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

  showSeekingOverlay(message = "Seeking...") {
    if (this.hasSeekingOverlayMessageTarget) this.seekingOverlayMessageTarget.textContent = message
    if (this.isSeeking) {
      this.seekingOverlayTarget.classList.remove("hidden")
    }
  }

  hideSeekingOverlay() {
    if (this.subtitlePlaybackHoldToken !== null) return
    this.isSeeking = false
    this.seekingOverlayTarget.classList.add("hidden")

    if (this.pendingSeekSeconds !== null) {
      const target = this.pendingSeekSeconds
      this.pendingSeekSeconds = null
      this.restartPlaybackAt(target)
    }
  }

  // ── Overlay UI (auto-hide) ────────────────────────────────────────

  showOverlayUi() {
    this.backButtonTarget.style.opacity = "1"
    this.backButtonTarget.style.pointerEvents = "auto"
    this.sourceInfoTarget.style.opacity = "1"
    this.sourceInfoTarget.style.pointerEvents = "auto"
    this.controlsTarget.style.opacity = "1"
    this.controlsTarget.style.pointerEvents = "auto"
    this.scheduleUiHide()
  }

  hideOverlayUi() {
    if (!this.videoTarget.paused && !this.trackMenuOpen()) {
      this.sourceInfoTarget.style.opacity = "0"
      this.sourceInfoTarget.style.pointerEvents = "none"
      this.controlsTarget.style.opacity = "0"
      this.controlsTarget.style.pointerEvents = "none"
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
    const durationSeconds = this.saveableDurationSeconds()
    if (progressSeconds <= 0) return

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
    const durationSeconds = this.saveableDurationSeconds()
    if (progressSeconds <= 0) return

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

  saveableDurationSeconds() {
    const duration = Math.floor(this.effectiveDuration())
    return duration > 0 ? duration : 0
  }
}
