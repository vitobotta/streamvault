import { Controller } from "@hotwired/stimulus"
import { WebVttParser } from "player/web_vtt_parser"
import { PlaybackCoordinator } from "player/playback_coordinator"

const MIN_VALID_DURATION_SECONDS = 60
const SUBTITLE_STARTUP_WINDOW_SECONDS = 5
const SUBTITLE_STARTUP_LOOK_BEHIND_SECONDS = 2
const STREAM_STALL_TIMEOUT_MS = 60000
const BUFFER_AHEAD_SECONDS = 30
const BUFFER_AHEAD_MAX_WAIT_MS = 15000
// After a stall, rebuild a meaningful buffer before resuming so ffmpeg
// can catch up and transient upstream dips don't cause immediate
// re-stall. 10s absorbs variable-rate sources (RealDebrid links from
// torrent swarms, HEVC transcode below 1×) without making the user wait
// 30s. The original 30s was raised to fix a userPaused auto-resume bug
// that has since been fixed — 10s is sufficient to absorb transcode dips
// while keeping the wait tolerable.
const REBUFFER_AHEAD_SECONDS = 10
// Stall watchdog timeout for rebuffer stalls (playback already started).
// Must be longer than REBUFFER_MAX_WAIT_MS so the deadline (which resumes
// with partial buffer) fires before the watchdog (which reconnects).
// 20s gives ffmpeg time to accumulate buffer; if no data arrives for 20s
// the fetch is truly dead.
const REBUFFER_STALL_TIMEOUT_MS = 20000
// Maximum time to wait for the rebuffer gate (REBUFFER_AHEAD_SECONDS)
// before resuming with whatever buffer has accumulated.  On a slow
// or trickling source, data arrives in small bursts that never reach
// the gate threshold — without a deadline, the video would sit on
// "Buffering" forever.  12s gives ffmpeg time to build buffer even on
// a slow source; the stall watchdog handles a genuinely dead source.
const REBUFFER_MAX_WAIT_MS = 12000
const MSE_FORWARD_BUFFER_HIGH_SECONDS = 45
const MSE_FORWARD_BUFFER_LOW_SECONDS = 30
const MSE_PENDING_BUFFER_HIGH_BYTES = 16 * 1024 * 1024
const MSE_PENDING_BUFFER_LOW_BYTES = 8 * 1024 * 1024
const MSE_CAPACITY_POLL_MS = 250
const MSE_MIME_TYPE = 'video/mp4; codecs="avc1.640028,mp4a.40.2"'
const REMUX_PRESENTATION_PROBE_SECONDS = 0.001
const REMUX_PRESENTATION_PROBE_TIMEOUT_MS = 500
const MAX_REMUX_PRESENTATION_OFFSET_SECONDS = 1
const REMUX_SEEK_TOLERANCE_SECONDS = 0.25
const REMUX_SEEK_TIMEOUT_MS = 500
const INTERACTIVE_SELECTOR = "button, a, input, textarea, select, [contenteditable='true']"
const SAFARI_AUTOPLAY_GUIDANCE_KEY = "streamvault:safari-autoplay-guidance-seen"

export default class extends Controller {
  static get targets() {
    return [
      "video", "controls", "seekBar", "seekFilled", "seekBuffered", "seekHandle",
      "playButton", "playIcon", "pauseIcon", "currentTime", "durationDisplay",
      "volumeIcon", "muteIcon", "startupOverlay", "startupStatus", "autoplayGuidance", "autoplayPlayButton",
      "seekingOverlay", "seekingOverlayMessage", "sourceInfo", "sourceToggle", "sourceDetails", "sourceUrl",
      "sourceFilename", "backButton", "audioControls", "audioMenu", "audioOptions", "audioButtonLabel",
      "subtitleControls", "subtitleMenu", "subtitleOptions", "subtitleButtonLabel", "subtitleOverlay"
    ]
  }
  static get values() {
    return {
      streamingUrl: String, source: String, directStreamUrl: String, filename: String, imdbId: String, type: String,
      directPlayHint: Boolean,
      season: String, episode: String, resumeAt: String, startSeconds: Number,
      title: String, duration: Number, posterUrl: String,
      defaultLanguage: String, preferredLanguages: String,
      tracksUrl: String, seekUrl: String, subtitlesUrl: String, resumeUrl: String
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
    this.videoWaitingHandler = () => this.onVideoWaiting()
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
    this.tracksData = null
    this.mediaTracksLoaded = false
    this.directPlayActive = false
    this.primedDirectPlayUrl = null
    this.startupOverlayHideTimer = null
    this.playPromptCleanup = null
    this.dragMoveHandler = null
    this.suppressNextSeekClick = false
    this.suppressSeekClickTimer = null
    this.mediaSource = null
    this.sourceBuffer = null
    this.fetchController = null
    this.mseFetchEnded = false
    this.pendingSeekSeconds = null
    this.remuxLoadToken = 0
    this.remuxSeekController = null
    this.remuxLoadCleanup = null
    this.stallWatchdogTimer = null
    this.bufferingOverlayTimer = null
    this.pendingAppendBuffer = null
    this.quotaRetryTimer = null
    this.quotaBlockedAtTime = null
    this.mseReadPaused = false
    this.mseQuotaErrorCount = 0
    this.systemRebufferPaused = false
    this.rebufferDeadlineTimer = null
    this.bufferAheadDeadlineTimer = null
    this.prematureEndRecoveryTimer = null
    this.lastProgressTime = 0
    this.lastProgressPosition = 0
    this.lastBufferEnd = 0
    this.lastBufferDataTime = 0
    this.lastProgressEventTime = 0
    this.progressWatchdogArmed = false
    this.streamRecoveryActive = false
    this.playbackStarted = false
    this.isStalled = false
    // True when the user deliberately paused (button/spacebar). The
    // rebuffer gate in maybeStartPlayback must never auto-resume a
    // user pause — only a rebuffer pause (buffer ran dry).
    this.userPaused = false
    // True once navigateBack has saved progress and aborted the fetch;
    // suppresses the duplicate save in the beforeunload handler.
    this.navigatingAway = false
    this.bufferAheadDeadline = null
    this.rebufferDeadline = null
    this.mseSupported = window.MediaSource && MediaSource.isTypeSupported(MSE_MIME_TYPE)
    this.hlsSessionId = null
    this.playbackId = globalThis.crypto?.randomUUID?.() ||
      `${Date.now()}-${Math.random().toString(16).slice(2)}`


    // Show source info
    this.sourceInfoTarget.classList.remove("hidden")
    this.sourceUrlTarget.textContent = "Protected RealDebrid source"
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
    // canplay is intentionally NOT listened to — it fires when the browser
    // has just one frame, which hides the buffering overlay prematurely
    // during a stall.  Only "playing" (actual playback resuming) hides it.
    this.videoEndedHandler = () => this.onVideoEnded()
    this.videoTarget.addEventListener("ended", this.videoEndedHandler)
    this.videoErrorHandler = (e) => this.onVideoError(e)
    this.videoTarget.addEventListener("error", this.videoErrorHandler)

    // Resume: transcode streams already start at the resume position
    // via ffmpeg -ss, so no client-side seek needed.  Direct play uses
    // the native <video> element which seeks via Range requests.

    // Duration: probe in the background via AJAX — never block video
    // playback. The video starts immediately; the seek bar populates
    // when the probe completes (usually a few seconds).
    this.currentTimeTarget.textContent = this.formatTime(this.startSecondsValue)
    this.updateDurationDisplay()
    this.onTimeUpdate()
    this.syncStartupOverlay()
    this.playbackCoordinator().connect()
    this.probeDuration()

    // Save progress on page unload — but skip if navigateBack already
    // saved (navigatingAway flag prevents a duplicate save).
    this.beforeUnloadHandler = () => { if (!this.navigatingAway) this.saveProgressSync() }
    window.addEventListener("beforeunload", this.beforeUnloadHandler)

  }

  disconnect() {
    this.playbackCoordinator().disconnect()
    // Save progress only if navigateBack hasn't already done it.
    if (!this.navigatingAway) this.saveProgressSync()
    this.clearUiHideTimer()
    this.clearStartupOverlayTimer()
    this.clearPlayPrompt()
    this.clearSuppressSeekClickTimer()
    this.clearStallWatchdog()
    clearTimeout(this.bufferingOverlayTimer)
    clearTimeout(this.quotaRetryTimer)
    clearTimeout(this.rebufferDeadlineTimer)
    clearTimeout(this.bufferAheadDeadlineTimer)
    clearTimeout(this.prematureEndRecoveryTimer)
    this.playbackStarted = false
    this.bufferAheadDeadline = null
    this.rebufferDeadline = null
    this.cancelRemuxLoad()
    this.remuxLoadToken += 1
    this.pendingAppendBuffer = null
    this.systemRebufferPaused = false
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
    this.videoTarget.removeEventListener("ended", this.videoEndedHandler)
    this.videoTarget.removeEventListener("error", this.videoErrorHandler)
    window.removeEventListener("beforeunload", this.beforeUnloadHandler)
    this.removeTextSubtitleTrack()
    if (this.fetchController) { this.fetchController.abort(); this.fetchController = null }
    this.bufferQueue = []
    this.fmp4Buffer = null
    this.fmp4BufferSize = 0
    this.pendingSeekSeconds = null
    // Skip video element teardown when navigating away — the page is
    // being destroyed and pauseAndDetachVideo's videoTarget.load()
    // forces a synchronous decode-pipeline flush that blocks the
    // main thread, delaying the new page from rendering.  The browser
    // tears down the video element during unload.
    if (!this.navigatingAway) this.pauseAndDetachVideo()
  }

  async probeDuration() {
    // The streaming page normally already carries Cinemeta/watch-history
    // duration. Avoid opening the remote media with a redundant FFprobe while
    // the compatibility probe is trying to produce the first playable frame.
    if (this.validDuration(this.knownDuration)) return

    try {
      const source = this.sourceToken()
      if (!source) return

      const response = await fetch(`/transcode/duration?source=${encodeURIComponent(source)}`)
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

  sourceToken() {
    if (this.hasSourceValue && this.sourceValue) return this.sourceValue

    try {
      const url = new URL(this.streamingUrlValue, window.location.origin)
      return url.searchParams.get("source")
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

  urlWithPlaybackId(value) {
    const url = new URL(value, window.location.origin)
    url.searchParams.set("playback_id", this.playbackId)
    return url.pathname + url.search
  }
  playbackCoordinator() {
    this._playbackCoordinator ||= new PlaybackCoordinator(this, {
      fetcher: (...args) => fetch(...args),
      documentRoot: document,
      origin: window.location.origin,
      userAgent: () => globalThis.navigator?.userAgent || "",
      createMediaSource: () => new MediaSource(),
      createObjectUrl: (value) => URL.createObjectURL(value),
      revokeObjectUrl: (value) => URL.revokeObjectURL(value)
    })
    return this._playbackCoordinator
  }

  playbackEngine() {
    return this.playbackCoordinator().engine
  }


  primeDirectPlay() {
    return this.playbackEngine().primeDirectPlay()
  }

  setupMseSource(streamUrl) {
    return this.playbackEngine().setupMseSource(streamUrl)
  }

  // iPhone and iPod Touch don't support MediaSource Extensions.
  // iPad (iPadOS 17.1+) supports ManagedMediaSource, so the MSE
  // path works there — exclude it explicitly.
  isIOS() {
    return this.playbackEngine().isIOS()
  }

  isSafari() {
    return this.playbackEngine().isSafari()
  }

  isChromium() {
    return this.playbackEngine().isChromium()
  }

  isHls() {
    return this.playbackEngine().isHls()
  }

  isDirectPlay() {
    return this.playbackEngine().isDirectPlay()
  }

  isNativeDirectPlay() {
    return this.playbackEngine().isNativeDirectPlay()
  }

  playbackTimelineOffset() {
    return this.playbackEngine().timelineOffset()
  }

  isRemuxDirectPlay() {
    return this.playbackEngine().isRemuxDirectPlay()
  }

  directPlayEligible() {
    return this.playbackEngine().directPlayEligible()
  }

  defaultAudioStreamIndex() {
    return this.playbackEngine().defaultAudioStreamIndex()
  }

  remuxDirectEligible() {
    return this.playbackEngine().remuxDirectEligible()
  }

  browserCanPlayCodec(codec) {
    return this.playbackEngine().browserCanPlayCodec(codec)
  }

  platformSupportsHevc() {
    return this.playbackEngine().platformSupportsHevc()
  }

  // Start direct play: set <video> src to the proxied RD URL so the
  // browser downloads at network speed.  No ffmpeg, no MSE, no box
  // parser — the browser handles everything natively.
  startDirectPlay() {
    this.directPlayActive = true
    this.remuxDirectPlay = false
    this.isSeeking = false
    this.subtitlePlaybackHoldToken = null
    this.streamRecoveryAttempts = 0
    this.streamRecoveryActive = false

    if (this.mediaSource) {
      if (this.mediaSource.readyState === "open") { try { this.mediaSource.endOfStream() } catch {} }
      this.mediaSource = null
      this.sourceBuffer = null
    }
    if (this.fetchController) { this.fetchController.abort(); this.fetchController = null }

    const directUrl = this.urlWithPlaybackId(this.directStreamUrlValue)
    const play = () => {
      const promise = this.videoTarget.play()
      if (promise?.catch) promise.catch((error) => this.handleAutoplayFailure(error))
    }
    const seekAndPlay = () => {
      if (this.startSecondsValue <= 0) {
        play()
        return
      }

      const targetSeconds = this.startSecondsValue
      const onSeeked = () => play()
      this.videoTarget.addEventListener("seeked", onSeeked, { once: true })
      try {
        this.videoTarget.currentTime = targetSeconds
      } catch {
        this.videoTarget.removeEventListener("seeked", onSeeked)
        play()
      }
    }

    // Keep an already-primed source alive. Reassigning it would discard the
    // MP4 index Chromium downloaded in parallel with the track probe.
    this.videoTarget.autoplay = false
    if (this.primedDirectPlayUrl === directUrl && this.videoTarget.readyState >= 1) {
      seekAndPlay()
    } else {
      if (this.startSecondsValue > 0) {
        this.videoTarget.addEventListener("loadedmetadata", seekAndPlay, { once: true })
      }
      if (this.primedDirectPlayUrl !== directUrl) this.videoTarget.src = directUrl
      if (this.startSecondsValue <= 0) play()
    }
    this.primedDirectPlayUrl = null
    // Don't set playbackStarted=true or start progress watchdog here —
    // onVideoReady() sets them when "playing" fires.
  }

  // Start remux direct play. Non-zero positions resolve to the preceding
  // source keyframe, but ffmpeg receives the exact target so Matroska seeking
  // does not jump back by a second cue. The native element skips the copied
  // pre-roll when its fMP4 timeline is seekable; otherwise the verified seek
  // falls back to the exact MSE/transcode path rather than playing misaligned
  // video and audio.
  async startRemuxDirectPlay() {
    this.directPlayActive = true
    this.remuxDirectPlay = true
    this.isSeeking = false
    this.subtitlePlaybackHoldToken = null
    this.streamRecoveryAttempts = 0
    this.streamRecoveryActive = false

    if (this.mediaSource) {
      if (this.mediaSource.readyState === "open") { try { this.mediaSource.endOfStream() } catch {} }
      this.mediaSource = null
      this.sourceBuffer = null
    }
    if (this.fetchController) { this.fetchController.abort(); this.fetchController = null }

    await this.loadRemuxAt(this.startSecondsValue)
  }

  async loadRemuxAt(targetSeconds) {
    this.cancelRemuxLoad()
    const token = ++this.remuxLoadToken
    const seekController = new AbortController()
    this.remuxSeekController = seekController
    const plan = await this.loadRemuxSeekPlan(targetSeconds, seekController.signal)
    if (this.remuxSeekController === seekController) this.remuxSeekController = null
    if (token !== this.remuxLoadToken) return
    if (!plan) {
      this.fallbackRemuxToMse(targetSeconds)
      return
    }

    const anchorSeconds = Number(plan.anchor_seconds)
    const inputSeekSeconds = Number(plan.input_seek_seconds ?? targetSeconds)
    const skipSeconds = Number(plan.skip_seconds)
    if (!Number.isFinite(anchorSeconds) || !Number.isFinite(inputSeekSeconds) || !Number.isFinite(skipSeconds)) {
      this.fallbackRemuxToMse(targetSeconds)
      return
    }

    this.startSecondsValue = anchorSeconds
    this.element.dataset.videoPlayerStartSecondsValue = anchorSeconds.toString()
    this.loadRemuxSource(
      this.buildRemuxDirectUrl(inputSeekSeconds, token),
      skipSeconds,
      targetSeconds,
      token
    )
  }

  async loadRemuxSeekPlan(targetSeconds, signal = null) {
    const source = this.sourceToken()
    if (!source) return null

    try {
      const endpoint = this.hasSeekUrlValue ? this.seekUrlValue : "/transcode/seek"
      const url = new URL(endpoint, window.location.origin)
      url.searchParams.set("source", source)
      url.searchParams.set("start_seconds", targetSeconds)
      const response = await fetch(url.pathname + url.search, {
        headers: { "Accept": "application/json" },
        signal
      })
      if (!response.ok) return null
      const plan = await response.json()
      return plan.copy_safe === true ? plan : null
    } catch (error) {
      if (error.name !== "AbortError") console.warn("Remux seek planning failed:", error)
      return null
    }
  }

  cancelRemuxLoad() {
    if (this.remuxSeekController) {
      this.remuxSeekController.abort()
      this.remuxSeekController = null
    }
    if (this.remuxLoadCleanup) {
      const cleanup = this.remuxLoadCleanup
      this.remuxLoadCleanup = null
      cleanup()
    }
  }

  loadRemuxSource(remuxUrl, skipSeconds, targetSeconds, token) {
    const video = this.videoTarget
    let completed = false
    let timeoutId = null
    const shouldMeasurePresentationOffset = skipSeconds > 0 && this.isChromium()
    let presentationOffsetSeconds = shouldMeasurePresentationOffset ? null : 0
    let presentationFrameCallbackId = null
    let presentationProbeTimeoutId = null
    let measuringPresentationOffset = false
    let seekTimeoutId = null
    let seekedHandler = null
    let seekPending = false

    const clearPresentationFrameCallback = () => {
      if (presentationFrameCallbackId === null) return
      if (typeof video.cancelVideoFrameCallback === "function") {
        video.cancelVideoFrameCallback(presentationFrameCallbackId)
      }
      presentationFrameCallbackId = null
    }
    const cleanup = () => {
      video.removeEventListener("loadeddata", maybeStart)
      video.removeEventListener("canplay", maybeStart)
      video.removeEventListener("progress", maybeStart)
      if (seekedHandler) video.removeEventListener("seeked", seekedHandler)
      seekedHandler = null
      seekPending = false
      clearPresentationFrameCallback()
      clearTimeout(presentationProbeTimeoutId)
      presentationProbeTimeoutId = null
      clearTimeout(timeoutId)
      clearTimeout(seekTimeoutId)
      seekTimeoutId = null
      if (this.remuxLoadCleanup === cleanup) this.remuxLoadCleanup = null
    }
    const play = () => {
      if (token !== this.remuxLoadToken) return
      const playPromise = video.play()
      if (playPromise?.catch) playPromise.catch(() => {})
    }
    const playAfterSeek = (expectedTime) => {
      if (token !== this.remuxLoadToken) return
      if (Math.abs(video.currentTime - expectedTime) > REMUX_SEEK_TOLERANCE_SECONDS) {
        this.fallbackRemuxToMse(targetSeconds)
        return
      }
      play()
    }
    const maybeStart = () => {
      if (completed) return
      if (token !== this.remuxLoadToken) {
        cleanup()
        return
      }

      // Chromium exposes copied B-frame composition delay through the first
      // presented frame. Safari may never fire this callback while paused, so
      // it proceeds with the source pre-roll instead of blocking startup.
      if (presentationOffsetSeconds === null) {
        if (measuringPresentationOffset || video.readyState < 2) return
        if (typeof video.requestVideoFrameCallback !== "function") {
          presentationOffsetSeconds = 0
        } else {
          measuringPresentationOffset = true
          try {
            presentationFrameCallbackId = video.requestVideoFrameCallback((_now, metadata) => {
              presentationFrameCallbackId = null
              clearTimeout(presentationProbeTimeoutId)
              presentationProbeTimeoutId = null
              measuringPresentationOffset = false
              if (completed || token !== this.remuxLoadToken) return

              const mediaTime = Number(metadata.mediaTime)
              presentationOffsetSeconds =
                Number.isFinite(mediaTime) && mediaTime >= 0 && mediaTime <= MAX_REMUX_PRESENTATION_OFFSET_SECONDS
                  ? mediaTime
                  : 0
              if (presentationOffsetSeconds > 0) {
                this.startSecondsValue = Math.max(0, this.startSecondsValue - presentationOffsetSeconds)
                this.element.dataset.videoPlayerStartSecondsValue = this.startSecondsValue.toString()
              }
              maybeStart()
            })
            presentationProbeTimeoutId = setTimeout(() => {
              presentationProbeTimeoutId = null
              if (completed || token !== this.remuxLoadToken) return
              clearPresentationFrameCallback()
              measuringPresentationOffset = false
              presentationOffsetSeconds = 0
              maybeStart()
            }, REMUX_PRESENTATION_PROBE_TIMEOUT_MS)
            video.currentTime = REMUX_PRESENTATION_PROBE_SECONDS
            return
          } catch {
            clearPresentationFrameCallback()
            clearTimeout(presentationProbeTimeoutId)
            presentationProbeTimeoutId = null
            measuringPresentationOffset = false
            presentationOffsetSeconds = 0
          }
        }
      }

      const playbackStartSeconds = skipSeconds + presentationOffsetSeconds
      if (!this.mediaRangeContains(playbackStartSeconds, 0.5)) return

      completed = true
      clearTimeout(timeoutId)
      timeoutId = null
      if (playbackStartSeconds > 0) {
        seekPending = true
        seekedHandler = () => {
          if (!seekPending) return
          seekPending = false
          clearTimeout(seekTimeoutId)
          seekTimeoutId = null
          cleanup()
          playAfterSeek(playbackStartSeconds)
        }
        video.addEventListener("seeked", seekedHandler, { once: true })
        seekTimeoutId = setTimeout(() => {
          if (!seekPending || token !== this.remuxLoadToken) return
          seekPending = false
          cleanup()
          this.fallbackRemuxToMse(targetSeconds)
        }, REMUX_SEEK_TIMEOUT_MS)
        try {
          video.currentTime = playbackStartSeconds
        } catch {
          seekPending = false
          cleanup()
          this.fallbackRemuxToMse(targetSeconds)
        }
      } else {
        cleanup()
        play()
      }
    }

    this.remuxLoadCleanup = cleanup
    video.addEventListener("loadeddata", maybeStart)
    video.addEventListener("canplay", maybeStart)
    video.addEventListener("progress", maybeStart)
    timeoutId = setTimeout(() => {
      if (completed || token !== this.remuxLoadToken) return
      completed = true
      cleanup()
      this.fallbackRemuxToMse(targetSeconds)
    }, STREAM_STALL_TIMEOUT_MS)

    video.autoplay = false
    video.src = remuxUrl
    // Assigning src starts resource selection; calling load() as well can
    // cancel and duplicate the same long-lived FFmpeg request.
  }

  mediaRangeContains(position, minAheadSeconds) {
    const ranges = this.videoTarget.buffered
    for (let i = 0; i < ranges.length; i++) {
      if (ranges.start(i) <= position + 0.25 && ranges.end(i) >= position + minAheadSeconds) return true
    }
    return false
  }

  fallbackRemuxToMse(targetSeconds) {
    this.cancelRemuxLoad()
    this.remuxLoadToken += 1
    this.directPlayActive = false
    this.remuxDirectPlay = false
    this.startSecondsValue = targetSeconds
    this.element.dataset.videoPlayerStartSecondsValue = targetSeconds.toString()

    const url = new URL(this.streamingUrlValue, window.location.origin)
    url.searchParams.set("start_seconds", targetSeconds)
    if (this.selectedAudioStream) url.searchParams.set("audio_stream", this.selectedAudioStream)
    if (this.burnedSubtitleSelected()) url.searchParams.set("subtitle_stream", this.selectedSubtitleStream)
    const nextSrc = url.pathname + url.search
    this.streamingUrlValue = nextSrc
    this.element.dataset.videoPlayerStreamingUrlValue = nextSrc
    this.setupMseSource(nextSrc)
  }

  // Build the remux URL from the exact input seek target. A unique load ID
  // distinguishes controller reloads from duplicate browser requests.
  buildRemuxDirectUrl(startSeconds = this.startSecondsValue, loadToken = null) {
    const base = this.tracksData?.remux_direct_url
    if (!base) return this.streamingUrlValue
    const url = new URL(base, window.location.origin)
    if (startSeconds > 0) {
      url.searchParams.set("start_seconds", startSeconds)
    } else {
      url.searchParams.delete("start_seconds")
    }
    if (this.selectedAudioStream) url.searchParams.set("audio_stream", this.selectedAudioStream)
    if (this.burnedSubtitleSelected()) url.searchParams.set("subtitle_stream", this.selectedSubtitleStream)
    if (loadToken !== null) url.searchParams.set("load_id", loadToken)
    url.searchParams.set("playback_id", this.playbackId)
    return url.pathname + url.search
  }

  appendSelectedHlsTracks(params) {
    if (this.selectedAudioStream) params.set('audio_stream', this.selectedAudioStream)
    if (this.burnedSubtitleSelected()) params.set('subtitle_stream', this.selectedSubtitleStream)
  }

  hlsSessionClient() {
    return this.playbackCoordinator().hls
  }

  async startHlsPlayback() {
    return this.hlsSessionClient().start()
  }

  handleAutoplayFailure(error) {
    const policyBlocked = error?.name === "NotAllowedError"
    if (policyBlocked) {
      console.info("Playback: Safari requires a tap to start audible playback")
    } else {
      console.warn("Playback: autoplay failed, showing play prompt", error)
    }

    this.showPlayPrompt({
      explainAutoplay: policyBlocked && this.shouldShowSafariAutoplayGuidance()
    })
  }

  shouldShowSafariAutoplayGuidance() {
    if (!this.isSafari() || this.isIOS() || this.safariAutoplayGuidanceShown) return false

    try {
      return window.localStorage?.getItem(SAFARI_AUTOPLAY_GUIDANCE_KEY) !== "1"
    } catch {
      return true
    }
  }

  markSafariAutoplayGuidanceSeen() {
    this.safariAutoplayGuidanceShown = true
    try {
      window.localStorage?.setItem(SAFARI_AUTOPLAY_GUIDANCE_KEY, "1")
    } catch {
      // Storage may be unavailable in private browsing. The current controller
      // still remembers that the explanation has already been shown.
    }
  }

  showPlayPrompt({ explainAutoplay = false } = {}) {
    if (!this.hasStartupOverlayTarget) return

    this.clearPlayPrompt()
    const overlay = this.startupOverlayTarget
    const status = this.hasStartupStatusTarget ? this.startupStatusTarget : null
    const guidance = this.hasAutoplayGuidanceTarget ? this.autoplayGuidanceTarget : null
    const playButton = this.hasAutoplayPlayButtonTarget ? this.autoplayPlayButtonTarget : null
    const spinner = overlay.querySelector(".animate-spin")
    const label = overlay.querySelector("span.text-white")
    const sub = overlay.querySelector("span.text-sv-text-muted")
    const showGuidance = explainAutoplay && guidance && playButton
    const interactiveTarget = showGuidance ? playButton : overlay

    overlay.classList.remove("hidden", "opacity-0", "pointer-events-none")
    overlay.setAttribute("aria-hidden", "false")
    if (spinner) spinner.style.display = "none"

    if (showGuidance) {
      this.markSafariAutoplayGuidanceSeen()
      if (status) status.classList.add("hidden")
      guidance.classList.remove("hidden")
      overlay.classList.remove("cursor-pointer")
      overlay.setAttribute("role", "dialog")
      overlay.setAttribute("aria-modal", "true")
      overlay.setAttribute("aria-labelledby", "safari-autoplay-title")
      overlay.removeAttribute("tabindex")
      overlay.removeAttribute("aria-label")
      playButton.focus?.({ preventScroll: true })
    } else {
      if (status) status.classList.remove("hidden")
      if (guidance) guidance.classList.add("hidden")
      overlay.classList.add("cursor-pointer")
      overlay.setAttribute("role", "button")
      overlay.setAttribute("tabindex", "0")
      overlay.setAttribute("aria-label", "Play video")
      overlay.removeAttribute("aria-modal")
      overlay.removeAttribute("aria-labelledby")
      if (label) label.textContent = "Play"
      if (sub) sub.textContent = "Tap or press Enter to start"
    }

    const attemptPlay = (event) => {
      if (event.type === "keydown" && event.key !== "Enter" && event.key !== " ") return
      event.preventDefault()
      event.stopPropagation()
      if (guidance) guidance.classList.add("hidden")
      if (status) status.classList.remove("hidden")
      overlay.setAttribute("role", "status")
      overlay.removeAttribute("aria-modal")
      overlay.removeAttribute("aria-labelledby")
      if (spinner) spinner.style.display = ""
      if (label) label.textContent = "Starting playback"
      if (sub) sub.textContent = "Loading stream..."

      Promise.resolve(this.videoTarget.play()).then(() => {
        // A resolved play() means the browser accepted and started playback.
        // Safari can omit or delay the matching "playing" event, so do not
        // leave the blocking startup overlay waiting on that event forever.
        this.clearPlayPrompt()
        this.hideStartupOverlay()
      }).catch((playError) => {
        console.warn("Playback: failed after user gesture", playError)
        if (spinner) spinner.style.display = "none"
        if (label) label.textContent = "Try again"
        if (sub) sub.textContent = "Tap or press Enter to retry"
      })
    }

    interactiveTarget.addEventListener("click", attemptPlay)
    if (!showGuidance) interactiveTarget.addEventListener("keydown", attemptPlay)
    this.playPromptCleanup = () => {
      interactiveTarget.removeEventListener("click", attemptPlay)
      if (!showGuidance) interactiveTarget.removeEventListener("keydown", attemptPlay)
      overlay.classList.remove("cursor-pointer")
      overlay.setAttribute("role", "status")
      overlay.removeAttribute("tabindex")
      overlay.removeAttribute("aria-label")
      overlay.removeAttribute("aria-modal")
      overlay.removeAttribute("aria-labelledby")
      if (guidance) guidance.classList.add("hidden")
      if (status) status.classList.remove("hidden")
    }
  }

  clearPlayPrompt() {
    if (!this.playPromptCleanup) return

    const cleanup = this.playPromptCleanup
    this.playPromptCleanup = null
    cleanup()
  }

  // Poll the HLS playlist URL until enough segments are ready, ffmpeg
  // fails (424), or a timeout is reached.  Waiting for at least 2
  // segments (instead of 1) gives iOS Safari a buffer head start: by
  // the time it fetches and decodes the first segment, ffmpeg has
  // already produced the second and is working on the third.  This
  // reduces the periodic black-screen underruns that happen when
  // playback starts with a single segment buffer and the transcode
  // throughput dips.  Falls back to 1 segment if the timeout is nearly
  // reached, so a slow source doesn't fail entirely.
  async waitForPlaylist(playlistUrl) {
    return this.hlsSessionClient().waitForPlaylist(playlistUrl)
  }

  // Restart the HLS transcode from a new position (seek).
  // Stops the current session, starts a new one with the updated
  // start_seconds, and swaps the video source to the new playlist.
  async restartHlsSession(startSeconds) {
    return this.hlsSessionClient().restart(startSeconds)
  }

  // Best-effort: tell the backend to kill the ffmpeg HLS process for
  // the current session.  Fire-and-forget — disconnect must not block,
  // and the session TTL cleans up if the request never lands.
  async stopHlsSession() {
    return this.hlsSessionClient().stop()
  }

  async startStreamingFetch(url) {
    const fetchController = new AbortController()
    this.fetchController = fetchController
    // Arm the stall watchdog before awaiting the fetch.  If the source
    // is dead (e.g. an expired RealDebrid link) the server returns a
    // 502 after its first-data timeout, and the only thing that will
    // trigger recovery is this watchdog — neither onBufferUpdateEnd nor
    // a fresh "waiting" event will fire when no data ever arrives.
    this.startStallWatchdog()
    try {
      const response = await fetch(this.urlWithPlaybackId(url), { signal: fetchController.signal })
      if (!response.ok) {
        console.warn("Stream fetch failed:", response.status)
        // A 502 means ffmpeg couldn't open the source (expired link,
        // auth failure).  Trigger recovery instead of leaving the
        // video frozen on "Buffering…".
        this.handleStreamStall()
        return
      }
      const reader = response.body.getReader()
      let firstChunk = true
      while (true) {
        // No per-chunk timeout: ffmpeg transcodes in bursts, and
        // pausing between bursts is normal. The stall watchdog on the
        // video element detects true playback stalls (buffer ran dry
        // with no new data arriving).
        const capacityAvailable = await this.waitForMseReadCapacity(fetchController.signal)
        if (!capacityAvailable) return
        const { done, value } = await reader.read()
        if (done) {
          // The server closed the response early (e.g. Cloudflare 100s
          // origin timeout, or ffmpeg exited mid-stream). If the video
          // is not actually near the end, recover by reconnecting.
          this.handlePrematureStreamEnd()
          break
        }
        if (firstChunk) {
          firstChunk = false
          this.streamRecoveryAttempts = 0
          this.streamRecoveryActive = false
          // Set a deadline: if the buffer-ahead threshold isn't reached
          // within BUFFER_AHEAD_MAX_WAIT_MS, start playback with whatever
          // we have — better to play with a small buffer than stall on
          // a slow source forever.
          this.bufferAheadDeadline = Date.now() + BUFFER_AHEAD_MAX_WAIT_MS
          clearTimeout(this.bufferAheadDeadlineTimer)
          this.bufferAheadDeadlineTimer = setTimeout(() => {
            this.bufferAheadDeadlineTimer = null
            this.maybeStartPlayback(true)
          }, BUFFER_AHEAD_MAX_WAIT_MS)
        }
        this.queueBufferChunk(value)
      }
    } catch (e) {
      if (e.name === "AbortError") return
      console.warn("Stream fetch failed:", e)
      this.handlePrematureStreamEnd()
    }
    finally {
      if (this.fetchController === fetchController) this.fetchController = null
    }
  }

  async waitForMseReadCapacity(signal) {
    while (!signal.aborted) {
      const bufferedAhead = this.playbackStarted
        ? this.bufferedAheadOfCurrent()
        : Math.max(0, this.currentBufferEnd() - this.videoTarget.currentTime)
      const pendingBytes = this.fmp4BufferSize || 0
      const overHighWater =
        this.pendingAppendBuffer !== null ||
        bufferedAhead >= MSE_FORWARD_BUFFER_HIGH_SECONDS ||
        pendingBytes >= MSE_PENDING_BUFFER_HIGH_BYTES

      if (!this.mseReadPaused && !overHighWater) return true
      this.mseReadPaused = true

      const belowLowWater =
        this.pendingAppendBuffer === null &&
        bufferedAhead <= MSE_FORWARD_BUFFER_LOW_SECONDS &&
        pendingBytes <= MSE_PENDING_BUFFER_LOW_BYTES
      if (belowLowWater) {
        this.mseReadPaused = false
        return true
      }

      await this.#sleep(MSE_CAPACITY_POLL_MS)
    }

    return false
  }

  // ── Stall watchdog ────────────────────────────────────────────────
  //
  // The watchdog monitors the VIDEO ELEMENT, not the network fetch.
  // When the video fires "waiting" (buffer ran dry), we start a timer.
  // If the video doesn't fire "playing"/"canplay" within
  // STREAM_STALL_TIMEOUT_MS, the stream is truly stalled — the fetch
  // is not delivering data fast enough to sustain playback. We then
  // reconnect from the current position. If the video resumes before
  // the timer fires, the timer is cancelled and no recovery occurs.
  //
  // This avoids false recoveries during normal transcoding pauses:
  // ffmpeg may pause between bursts, but as long as the MSE buffer
  // has enough data to keep the video playing, no "waiting" event
  // fires and the watchdog never triggers.

  onVideoWaiting() {
    // In HLS mode (iOS), the MSE stall watchdog can't reconnect (no
    // MediaSource on iPhone).  Show the buffering overlay for user
    // feedback and arm the progress watchdog so a dead ffmpeg is
    // detected instead of hanging forever.
    if (this.isHls()) {
      clearTimeout(this.bufferingOverlayTimer)
      const waitPos = this.videoTarget.currentTime
      this.bufferingOverlayTimer = setTimeout(() => {
        this.bufferingOverlayTimer = null
        // Re-check: if currentTime advanced, the stall resolved.
        if (this.videoTarget.currentTime > waitPos + 0.1) return
        this.showBufferingOverlay()
        this.startProgressWatchdog()
      }, 200)
      return
    }

    // Native media playback, including remux, is browser-buffered. Chrome
    // deliberately maintains only a small buffer for chunked remux responses,
    // so forcing a deep application-level gate here creates the stalls it is
    // meant to prevent. Debounce transient waits and let the browser resume.
    if (this.isDirectPlay()) {
      clearTimeout(this.bufferingOverlayTimer)
      const waitPos = this.videoTarget.currentTime
      this.bufferingOverlayTimer = setTimeout(() => {
        this.bufferingOverlayTimer = null
        if (this.videoTarget.currentTime > waitPos + 0.1) return
        if (this.hasBufferedAhead(2)) return
        this.isStalled = true
        this.showBufferingOverlay()
        this.startProgressWatchdog()
      }, 1500)
      return
    }

    // MSE path: Chrome does NOT set paused=true when the MSE buffer runs
    // dry — the video stays "playing" but currentTime stops advancing.
    // Debounce 200ms to filter genuinely transient waits (ffmpeg burst
    // arrived, MSE appended).  Re-check by testing whether currentTime
    // actually advanced during the 200ms, NOT whether paused===false —
    // paused stays false during an MSE underrun.
    clearTimeout(this.bufferingOverlayTimer)
    const waitPos = this.videoTarget.currentTime
    const hadBufferedAheadAtWait = this.hasBufferedAhead(2)
    this.bufferingOverlayTimer = setTimeout(() => {
        this.bufferingOverlayTimer = null
        const playbackAdvanced = this.videoTarget.currentTime > waitPos + 0.1
        // A wait that began with data is a decoder re-init and can resolve
        // through either playback progress or the existing buffer. A wait
        // that began dry must not be dismissed by a tiny append that moves
        // the playhead briefly; require the full rebuffer high-water mark.
        if (hadBufferedAheadAtWait) {
          if (playbackAdvanced || this.hasBufferedAhead(2)) return
        } else if (playbackAdvanced && this.bufferedAheadOfCurrent() >= REBUFFER_AHEAD_SECONDS) {
          return
        }
        this.beginSystemRebuffer()
        // After a stall with playback already started, use a shorter
        // watchdog. The explicit system pause prevents trickle-resume churn.
        this.startStallWatchdog(this.playbackStarted ? REBUFFER_STALL_TIMEOUT_MS : STREAM_STALL_TIMEOUT_MS)
    }, 200)
  }

  beginSystemRebuffer() {
    if (this.userPaused) return

    this.stopProgressWatchdog()
    this.isStalled = true
    this.systemRebufferPaused = true
    this.showBufferingOverlay()
    this.videoTarget.pause()
    this.rebufferDeadline = Date.now() + REBUFFER_MAX_WAIT_MS
    clearTimeout(this.rebufferDeadlineTimer)
    this.rebufferDeadlineTimer = setTimeout(() => {
      this.rebufferDeadlineTimer = null
      this.maybeStartPlayback(true)
    }, REBUFFER_MAX_WAIT_MS)
  }

  clearSystemRebufferGate() {
    clearTimeout(this.rebufferDeadlineTimer)
    this.rebufferDeadlineTimer = null
    this.rebufferDeadline = null
    this.systemRebufferPaused = false
  }

  // Returns true if there's at least `minSeconds` (default 0.5s) of
  // buffered data ahead of the current position.
  hasBufferedAhead(minSeconds = 0.5) {
    const video = this.videoTarget
    if (!video) return false
    const ranges = video.buffered
    if (!ranges || ranges.length === 0) return false
    const pos = video.currentTime
    for (let i = 0; i < ranges.length; i++) {
      if (ranges.start(i) <= pos && ranges.end(i) > pos + minSeconds) {
        return true
      }
    }
    return false
  }

  recoveryMonitor() {
    return this.playbackCoordinator().recovery
  }

  startStallWatchdog(timeoutMs = STREAM_STALL_TIMEOUT_MS) {
    return this.recoveryMonitor().startStallWatchdog(timeoutMs)
  }

  clearStallWatchdog() {
    return this.recoveryMonitor().clearStallWatchdog()
  }

  startProgressWatchdog() {
    return this.recoveryMonitor().startProgressWatchdog()
  }

  tickProgressWatchdog() {
    return this.recoveryMonitor().tickProgressWatchdog()
  }

  checkProgressStall() {
    return this.recoveryMonitor().checkProgressStall()
  }

  currentBufferEnd() {
    return this.recoveryMonitor().currentBufferEnd()
  }

  resetProgressBaseline() {
    return this.recoveryMonitor().resetProgressBaseline()
  }

  stopProgressWatchdog() {
    return this.recoveryMonitor().stopProgressWatchdog()
  }

  handleStreamStall(eventType = "stall") {
    return this.recoveryMonitor().handleStreamStall(eventType)
  }

  // Restart direct/remux playback from the current position.  Unlike
  // reconnectFromCurrentPosition (which switches to MSE), this keeps
  // the same direct/remux path — just reloads the URL with the current
  // start_seconds so ffmpeg re-seeks and produces data from there.
  reconnectDirectPlay() {
    const targetSeconds = Math.floor(this.currentPlaybackPosition())
    this.startSecondsValue = targetSeconds
    this.element.dataset.videoPlayerStartSecondsValue = targetSeconds.toString()
    this.streamRecoveryActive = false
    this.isStalled = false

    // Hide the "Buffering..." overlay — we're reconnecting.  The
    // startup overlay is already hidden (playback started earlier).
    // Show a brief "Buffering..." to give user feedback during the
    // reconnect, but with pointer-events-none so they can still seek.
    this.showBufferingOverlay()

    this.clearStallWatchdog()
    this.stopProgressWatchdog()
    this.startStallWatchdog(STREAM_STALL_TIMEOUT_MS)

    if (this.isRemuxDirectPlay()) {
      console.log(`[Player] Reconnecting remux direct play at ${targetSeconds}s`)
      this.loadRemuxAt(targetSeconds)
      return
    }

    // Native direct play reloads the Range-capable source, then seeks back
    // to the absolute playhead after metadata is available.
    console.log(`[Player] Reconnecting direct play at ${targetSeconds}s`)
    const play = () => this.videoTarget.play().catch(() => {})
    this.videoTarget.addEventListener("loadedmetadata", () => {
      if (targetSeconds > 0) {
        this.videoTarget.addEventListener("seeked", play, { once: true })
        this.videoTarget.currentTime = targetSeconds
      } else {
        play()
      }
    }, { once: true })
    this.videoTarget.src = this.urlWithPlaybackId(this.directStreamUrlValue)
    this.videoTarget.load()
  }

  // HLS stall recovery (iOS).  When the progress watchdog detects
  // that currentTime has frozen for PROGRESS_STALL_TIMEOUT_MS while
  // the video is supposedly playing, the ffmpeg HLS process has
  // likely died or the upstream source stalled.  Restart the HLS
  // transcode from the current playback position — the same path a
  // user seek takes — so playback resumes instead of hanging on a
  // frozen frame or "Buffering" forever.
  handleHlsStall(eventType = "hls_stall") {
    return this.recoveryMonitor().handleHlsStall(eventType)
  }

  handlePrematureStreamEnd() {
    return this.recoveryMonitor().handlePrematureEnd()
  }

  finishOrRecoverMseEnd() {
    return this.recoveryMonitor().finishOrRecoverMseEnd()
  }

  schedulePrematureEndRecovery() {
    return this.recoveryMonitor().schedulePrematureEndRecovery()
  }

  bufferedAheadOfCurrent() {
    return this.recoveryMonitor().bufferedAhead()
  }

  reportStall(eventType, details = {}) {
    return this.recoveryMonitor().report(eventType, details)
  }

  playbackPath() {
    return this.recoveryMonitor().path()
  }

  // Abort the current fetch, tear down the MSE pipeline, and restart
  // from the current playback position. This is the same machinery
  // a manual seek uses, but triggered automatically by the watchdog.
  //
  // The recovery *attempt counter* is preserved across the restart so
  // repeated stalls eventually give up (STREAM_MAX_RECOVERY_ATTEMPTS)
  // instead of looping forever.  The *active* flag is NOT preserved:
  // restartPlaybackAt and setupMseSource already clear it, and
  // restoring it to true afterwards would permanently block all
  // further recovery if the reconnect fetch produces no data (the
  async reconnectFromCurrentPosition() {
    const targetSeconds = Math.floor(this.currentPlaybackPosition())
    const savedAttempts = this.streamRecoveryAttempts

    // Backoff before the 2nd and 3rd reconnect attempts so a transient
    // upstream throttle has time to clear before we hammer the same RD
    // link again.  handleStreamStall pre-increments streamRecoveryAttempts
    // before calling us, so savedAttempts is 1 on the first stall, 2 on
    // the second, 3 on the third.  Skip the backoff on the first attempt
    // (no delay on a fresh stall).  During the sleep, streamRecoveryActive
    // is still true (set by handleStreamStall) so the guard at
    // handleStreamStall:1087 blocks concurrent re-entry.  The "Buffering…"
    // overlay is already shown by handleStreamStall and stays visible.
    if (savedAttempts >= 2) {
      await this.#sleep(2000)
    }

    // Don't show the "Seeking..." overlay for automatic recovery —
    // it sets isSeeking=true which blocks the seek bar and shows a
    // jarring "Seeking" message for what is actually a rebuffer.
    // Instead, keep the existing "Buffering..." overlay (already
    // shown by showBufferingOverlay, which has pointer-events-none).
    // We only set isSeeking + show "Seeking..." for explicit user
    // seeks (performSeek → restartPlaybackAt).
    this.streamRecoveryAttempts = 0
    this.streamRecoveryActive = false
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
    this.reloadTextSubtitlesAt(targetSeconds)
    this.streamRecoveryAttempts = savedAttempts
  }

  // Private: promise-based sleep. Used by reconnectFromCurrentPosition
  // to back off between reconnect attempts. No existing equivalent.
  #sleep(ms) {
    return new Promise(resolve => setTimeout(resolve, ms))
  }

  // fMP4 box parser: the HTTP response delivers arbitrary byte chunks
  // that don't align with fMP4 box boundaries.  Appending a partial
  // moof or mdat box to SourceBuffer triggers
  // CHUNK_DEMUXER_ERROR_APPEND_FAILED.  This parser accumulates bytes
  // and only feeds complete top-level boxes (or moof+mdat pairs) to
  // appendBuffer, holding back partial boxes until more data arrives.
  mseBufferManager() {
    return this.playbackCoordinator().buffer
  }

  queueBufferChunk(chunk) {
    return this.mseBufferManager().queueChunk(chunk)
  }

  extractCompleteBoxes() {
    return this.mseBufferManager().extractCompleteBoxes()
  }

  flushBufferQueue() {
    return this.mseBufferManager().flush()
  }

  evictForQuota() {
    return this.mseBufferManager().evictForQuota()
  }

  scheduleQuotaRetry() {
    return this.mseBufferManager().scheduleQuotaRetry()
  }

  onBufferUpdateEnd() {
    return this.mseBufferManager().onUpdateEnd()
  }

  // Start (or resume) playback once the buffer holds at least
  // BUFFER_AHEAD_SECONDS ahead of the current position.  This runs on
  // every appendBuffer completion — not just the initial start — so it
  // also gates rebuffering: when the video stalls (buffer ran dry),
  // it stays paused until enough data accumulates to sustain playback
  // for a while, rather than resuming on a trickle and immediately
  // re-stalling.
  //
  // For the initial start, a max-wait deadline (BUFFER_AHEAD_MAX_WAIT_MS
  // from the first chunk) ensures we don't stall forever on a very slow
  // source: if the threshold isn't reached in time, we start with
  // whatever we have.
  maybeStartPlayback(deadlineTriggered = false) {

    if (!this.sourceBuffer || this.sourceBuffer.buffered.length === 0) return

    const bufferedAhead = this.bufferedAheadOfCurrent()

    if (!this.playbackStarted) {
      const deadlineReached = deadlineTriggered ||
        (this.bufferAheadDeadline && Date.now() >= this.bufferAheadDeadline)
      if (bufferedAhead >= BUFFER_AHEAD_SECONDS || (deadlineReached && bufferedAhead >= 0.5)) {
        this.playbackStarted = true
        this.bufferAheadDeadline = null
        clearTimeout(this.bufferAheadDeadlineTimer)
        this.bufferAheadDeadlineTimer = null
        const playPromise = this.videoTarget.play()
        if (playPromise?.catch) playPromise.catch(() => {})
      }
      return
    }

    // A confirmed MSE underrun explicitly pauses the element. Resume only
    // after rebuilding the high-water buffer, or after the real deadline
    // timer fires with at least a playable amount of data.
    if (this.systemRebufferPaused && !this.videoTarget.ended && !this.userPaused && !this.isSeeking) {
      const deadlineReached = deadlineTriggered ||
        (this.rebufferDeadline && Date.now() >= this.rebufferDeadline)
      if (bufferedAhead >= REBUFFER_AHEAD_SECONDS || (deadlineReached && bufferedAhead >= 0.5)) {
        this.clearSystemRebufferGate()
        this.isStalled = false
        const playPromise = this.videoTarget.play()
        if (playPromise?.catch) playPromise.catch(() => {})
      }
    }
  }

  // Safety net for the hasBufferedAhead(2) gate in onVideoReady.
  // When a rebuffer resume lands with < 2s of buffer, onVideoReady
  // returns without hiding the buffering overlay — by design, to avoid
  // a freeze-resume-freeze flicker.  But if the video then plays fine
  // (data arrives fast enough to sustain playback without another
  // stall), "playing" never fires again and the stall watchdog keeps
  // getting reset by each onBufferUpdateEnd, so nothing re-checks
  // whether the buffer has recovered — the "Buffering…" overlay stays
  // forever.  This runs on every appendBuffer completion and hides the
  // overlay once the video is actually playing with >= 2s of buffer.
  maybeHideBufferingOverlay() {
    if (this.isSeeking) return
    if (this.subtitlePlaybackHoldToken !== null) return
    if (!this.playbackStarted || this.isStalled || this.userPaused) return
    if (this.videoTarget.paused || this.videoTarget.ended) return
    if (!this.hasBufferedAhead(2)) return
    if (this.seekingOverlayTarget.classList.contains("hidden")) return
    clearTimeout(this.bufferingOverlayTimer)
    this.bufferingOverlayTimer = null
    this.clearStallWatchdog()
    this.streamRecoveryAttempts = 0
    this.streamRecoveryActive = false
    this.startProgressWatchdog()
    this.hideSeekingOverlay()
  }

  evictOldBuffer() {
    return this.mseBufferManager().evictOldBuffer()
  }

  // ── Play / pause ──────────────────────────────────────────────────

  togglePlay() {
    if (this.videoTarget.paused) {
      this.userPaused = false
      if (this.systemRebufferPaused) {
        this.maybeStartPlayback(true)
        return
      }
      const playPromise = this.videoTarget.play()
      if (playPromise?.catch) playPromise.catch(() => {})
    } else {
      this.userPaused = true
      this.videoTarget.pause()
      this.clearStallWatchdog()
      this.stopProgressWatchdog()
      this.clearSystemRebufferGate()
      this.isStalled = false
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

  // Tear down playback before navigating away.  The ONLY thing that
  // must happen synchronously is aborting the fetch so the backend
  // kills ffmpeg (Media::Transcoder ensure block on ClientDisconnected).
  // The video element teardown (revokeObjectURL, src="", load) is
  // skipped: load() forces a synchronous media-engine pipeline flush
  // that blocks the main thread for a noticeable moment — especially
  // with a deep MSE buffer and hardware decoding — and the page is
  // being destroyed anyway.  pause() alone is cheap (no flush) and is
  // called first so the user sees the stream stop the instant they
  // click back, instead of the video playing on while the new page
  // loads.  The beforeunload handler is skipped to avoid a duplicate
  // save (navigateBack already saved).
  stopPlaybackForNavigation() {
    if (this.hasVideoTarget) { try { this.videoTarget.pause() } catch {} }
    this.playbackCoordinator().disconnect()
    this.saveProgressSync()
    this.navigatingAway = true
    if (this.fetchController) { this.fetchController.abort(); this.fetchController = null }
    this.bufferQueue = []
    this.fmp4Buffer = null; this.fmp4BufferSize = 0
  }

  // Auto-advance to the next episode when the current one finishes.
  // Only applies to shows — movies just stop (progress already saved).
  async onVideoEnded() {
    if (this.typeValue !== "show") return

    // Persist the known duration as the final position so an actual media
    // end always crosses the 98% episode-completion threshold.
    await this.saveProgress(true)

    if (this.resumeUrlValue) {
      const url = new URL(this.resumeUrlValue, window.location.origin)
      url.searchParams.set("type", "show")
      url.searchParams.set("imdb_id", this.imdbIdValue)
      url.searchParams.set("autoplay", "1")
      window.location.href = url.toString()
    }
  }

  onVideoError(e) {
    const video = this.videoTarget
    const err = video.error
    if (!err) return

    console.error("Video error:", {
      code: err.code,
      message: err.message,
      src: video.src,
      currentSrc: video.currentSrc,
      readyState: video.readyState,
      networkState: video.networkState,
      isHls: this.isHls()
    })

    if (this.isHls()) {
      this.showSeekingOverlay("Stream error — tap to retry")
      const overlay = this.seekingOverlayTarget
      const onRetry = () => {
        overlay.removeEventListener("click", onRetry)
        this.hideSeekingOverlay()
        if (this.hlsSessionId) {
          video.load()
          video.play().catch(() => {})
        } else {
          this.startHlsPlayback()
        }
      }
      overlay.addEventListener("click", onRetry)
      return
    }

    if (this.isDirectPlay() && this.isSafari()) {
      console.warn("Safari native playback failed — falling back to HLS.")
      const targetSeconds = Math.floor(this.currentPlaybackPosition())
      this.startSecondsValue = targetSeconds
      this.element.dataset.videoPlayerStartSecondsValue = targetSeconds.toString()
      this.showBufferingOverlay()
      this.startHlsPlayback()
      return
    }

    // Remux can repair a failed network/container delivery, but it copies
    // the video codec unchanged. Decode/unsupported-source errors must go
    // directly to video transcoding instead of retrying the same codec.
    if (err.code === 2 && this.isNativeDirectPlay() && this.remuxDirectEligible()) {
      console.warn("Native direct network failed — falling back to remux.")
      const targetSeconds = Math.floor(this.currentPlaybackPosition())
      this.directPlayActive = false
      this.startSecondsValue = targetSeconds
      this.element.dataset.videoPlayerStartSecondsValue = targetSeconds.toString()
      this.showBufferingOverlay()
      this.startRemuxDirectPlay()
      return
    }

    if (this.isDirectPlay()) {
      console.warn("Direct play failed — falling back to MSE/transcode.")
      const targetSeconds = Math.floor(this.currentPlaybackPosition())
      this.directPlayActive = false
      this.remuxDirectPlay = false
      this.streamingUrlValue = this.element.dataset.videoPlayerStreamingUrlValue
      this.restartPlaybackAt(targetSeconds)
    }
  }

  pauseAndDetachVideo() {
    if (!this.hasVideoTarget) return
    try {
      if (this.fetchController) { this.fetchController.abort(); this.fetchController = null }
      this.bufferQueue = []
      this.fmp4Buffer = null; this.fmp4BufferSize = 0
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
      // Disarm the progress watchdog on a deliberate pause —
      // currentTime won't advance, but this is not a stall.
      this.stopProgressWatchdog()
    } else {
      this.playIconTarget.classList.add("hidden")
      this.pauseIconTarget.classList.remove("hidden")
      // Re-arm on resume (also covers recovery from a rebuffer pause
      // gated by maybeStartPlayback).
      this.startProgressWatchdog()
    }
  }

  onVideoReady() {
    // Only act when the video is actually playing.  If the video is
    // paused (deliberate rebuffer gate in maybeStartPlayback), don't
    // interfere — the "Buffering..." overlay should stay visible.
    if (this.videoTarget.paused) return

    // Always hide the startup overlay on first play — it's only shown
    // before playback begins, and "playing" means playback has begun.
    this.hideStartupOverlay()

    // After a user seek, hide the seeking overlay as soon as playback
    // resumes — the seeking overlay is not a buffering indicator, and
    // the rebuffer gate handles buffer depth from here.  Only gate
    // the buffering/stall-recovery overlay hide on buffer depth.
    if (this.isSeeking) {
      clearTimeout(this.bufferingOverlayTimer)
      this.bufferingOverlayTimer = null
      this.isStalled = false
      this.clearStallWatchdog()
      this.streamRecoveryAttempts = 0
      this.streamRecoveryActive = false
      this.startProgressWatchdog()
      this.hideSeekingOverlay()
      return
    }

    // For direct play (including remux), the browser manages its own
    // buffering.  If "playing" fires, the video is actually playing —
    // always hide the overlay.  The 2s buffer gate below is for MSE,
    // where Chrome can fire "playing" on a trickle then immediately
    // re-stall.  Direct play doesn't have this problem, and the gate
    // causes the overlay to get stuck if the browser resumes with <2s
    // of buffer (no onBufferUpdateEnd safety net exists for direct play).
    if (this.isDirectPlay()) {
      this.playbackStarted = true
      clearTimeout(this.bufferingOverlayTimer)
      this.bufferingOverlayTimer = null
      this.isStalled = false
      this.clearStallWatchdog()
      this.streamRecoveryAttempts = 0
      this.streamRecoveryActive = false
      this.startProgressWatchdog()
      this.hideSeekingOverlay()
      return
    }

    // Don't hide the buffering overlay if the buffer is critically low.
    // Chrome fires "playing" on a tiny trickle of data, then immediately
    // stalls again — if we hide the overlay here, the user sees a rapid
    // freeze-resume-freeze cycle with no spinner.  Keep the buffering
    // overlay visible until there's at least 2s of buffer ahead.
    if (!this.hasBufferedAhead(2)) return

    clearTimeout(this.bufferingOverlayTimer)
    this.bufferingOverlayTimer = null
    this.isStalled = false
    this.clearStallWatchdog()
    this.streamRecoveryAttempts = 0
    this.streamRecoveryActive = false
    this.startProgressWatchdog()
    this.hideSeekingOverlay()
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
    if (this.mediaTracksLoaded) return
    if (!this.hasTracksUrlValue) return

    const source = this.sourceToken()
    if (!source) return

    try {
      const url = new URL(this.tracksUrlValue, window.location.origin)
      url.searchParams.set("source", source)
      this.addContentMetadataParams(url)
      const response = await fetch(url.pathname + url.search, { headers: { "Accept": "application/json" } })
      if (!response.ok) return

      const data = await response.json()
      this.tracksData = data
      this.mediaTracksLoaded = true
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

    const targetSeconds = Math.floor(this.currentPlaybackPosition())
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
    return this.videoTarget.currentTime + this.playbackTimelineOffset()
  }

  reloadTextSubtitlesAt(position, holdPlayback = false) {
    if (!this.textSubtitleSelected()) return

    this.loadSubtitleTrack(position, {
      durationSeconds: SUBTITLE_STARTUP_WINDOW_SECONDS,
      lookBehindSeconds: SUBTITLE_STARTUP_LOOK_BEHIND_SECONDS,
      holdPlayback: holdPlayback
    })
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

  subtitlePipeline() {
    return this.playbackCoordinator().subtitles
  }

  prefetchSubtitleStream(subtitleStream) {
    return this.subtitlePipeline().prefetch(subtitleStream)
  }

  addContentMetadataParams(url) {
    return this.subtitlePipeline().addContentMetadata(url)
  }

  async loadSubtitleTrack(currentPosition = this.currentPlaybackPosition(), options = {}) {
    return this.subtitlePipeline().load(currentPosition, options)
  }

  subtitleRequestUrl(source, subtitleStream, windowStart, durationSeconds) {
    return this.subtitlePipeline().requestUrl(source, subtitleStream, windowStart, durationSeconds)
  }

  subtitleRequestKey(subtitleStream, windowStart, durationSeconds) {
    return this.subtitlePipeline().requestKey(subtitleStream, windowStart, durationSeconds)
  }

  async fetchSubtitleResponse(url, signal) {
    return this.subtitlePipeline().fetchResponse(url, signal)
  }

  rememberPrefetchedSubtitleResponse(requestKey, response) {
    return this.subtitlePipeline().rememberPrefetchedResponse(requestKey, response)
  }

  applySubtitleResponse(response, windowStart) {
    return this.subtitlePipeline().applyResponse(response, windowStart)
  }

  beginSubtitlePlaybackHold(holdPlayback, loadToken) {
    return this.subtitlePipeline().beginPlaybackHold(holdPlayback, loadToken)
  }

  finishSubtitlePlaybackHold(loadToken) {
    return this.subtitlePipeline().finishPlaybackHold(loadToken)
  }

  removeTextSubtitleTrack() {
    return this.subtitlePipeline().removeTextTrack()
  }

  resetSubtitleWindow() {
    return this.subtitlePipeline().resetWindow()
  }

  subtitleWindowDuration(value) {
    return this.subtitlePipeline().windowDuration(value)
  }

  subtitleLookBehind(value, durationSeconds) {
    return this.subtitlePipeline().lookBehind(value, durationSeconds)
  }

  scheduleSubtitleRetry(delayMs = 5000) {
    return this.subtitlePipeline().scheduleRetry(delayMs)
  }

  primeSubtitleContinuation(requestedSubtitleStream) {
    return this.subtitlePipeline().primeContinuation(requestedSubtitleStream)
  }

  abortSubtitleLoad() {
    return this.subtitlePipeline().abortLoad()
  }

  clearSubtitleCues() {
    return this.subtitlePipeline().clearCues()
  }

  mergeSubtitleCues(existingCues, incomingCues, currentPosition) {
    return this.subtitlePipeline().mergeCues(existingCues, incomingCues, currentPosition)
  }

  pruneSubtitleCues(cues, currentPosition) {
    return this.subtitlePipeline().pruneCues(cues, currentPosition)
  }

  webVttParser() {
    this._webVttParser ||= new WebVttParser()
    return this._webVttParser
  }

  parseWebVtt(text, offsetSeconds = 0) {
    return this.webVttParser().parse(text, offsetSeconds)
  }

  parseWebVttCue(block) {
    return this.webVttParser().parseCue(block)
  }

  parseCueTimestamp(value) {
    return this.webVttParser().parseTimestamp(value)
  }

  cleanCueText(text) {
    return this.webVttParser().cleanText(text)
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
    return this.subtitlePipeline().ensureWindow(currentPos)
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
    // Standard Fullscreen API — works on desktop and Android.
    if (document.fullscreenElement) {
      document.exitFullscreen()
    } else if (this.element.requestFullscreen) {
      this.element.requestFullscreen()
    } else {
      // iOS Safari (including PWA standalone mode) doesn't support
      // the Fullscreen API on arbitrary elements.  Use the video
      // element's native webkitEnterFullscreen instead — it enters
      // iOS's built-in fullscreen video player.
      const video = this.videoTarget
      if (video.webkitEnterFullscreen) {
        video.webkitEnterFullscreen()
      }
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
    if (targetSeconds === Math.floor(this.currentPlaybackPosition())) return

    if (this.isSeeking) {
      if (this.isRemuxDirectPlay()) {
        this.pendingSeekSeconds = null
        this.restartPlaybackAt(targetSeconds)
        this.currentTimeTarget.textContent = this.formatTime(targetSeconds)
        this.updateSeekVisuals(targetSeconds / this.knownDuration)
        return
      }
      this.pendingSeekSeconds = targetSeconds
      return
    }
    this.restartPlaybackAt(targetSeconds)
    this.currentTimeTarget.textContent = this.formatTime(targetSeconds)
    this.updateSeekVisuals(targetSeconds / this.knownDuration)
  }

  restartPlaybackAt(targetSeconds) {
    if (this.isHls()) {
      this.isSeeking = true
      this.showSeekingOverlay("Seeking...")
      this.startSecondsValue = targetSeconds
      this.element.dataset.videoPlayerStartSecondsValue = targetSeconds.toString()
      this.restartHlsSession(targetSeconds)
      return
    }

    // Remux seeks resolve the preceding source keyframe and skip its
    // pre-roll in the native element, preserving -c:v copy.
    if (this.isRemuxDirectPlay()) {
      this.isSeeking = true
      this.showSeekingOverlay("Seeking...")
      this.videoTarget.pause()
      this.stopProgressWatchdog()
      this.clearSubtitleCues()
      this.reloadTextSubtitlesAt(targetSeconds)
      this.resetProgressBaseline()
      this.loadRemuxAt(targetSeconds)
      return
    }

    // Native direct play cannot burn bitmap subtitles. Switch to the
    // transcode path below so ffmpeg receives and overlays the selection.
    if (this.isNativeDirectPlay() && this.burnedSubtitleSelected()) {
      this.directPlayActive = false
      this.remuxDirectPlay = false
    }

    // Direct play: browser handles seeking via Range requests.
    // Reset the progress watchdog so the freeze detector doesn't
    // fire during the seek (currentTime briefly stalls).
    if (this.isNativeDirectPlay()) {
      this.startSecondsValue = targetSeconds
      this.element.dataset.videoPlayerStartSecondsValue = targetSeconds.toString()
      this.videoTarget.currentTime = targetSeconds
      this.clearSubtitleCues()
      this.reloadTextSubtitlesAt(targetSeconds)
      this.resetProgressBaseline()
      return
    }

    this.isSeeking = true
    this.showSeekingOverlay()
    this.streamRecoveryAttempts = 0
    this.streamRecoveryActive = false
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
    this.reloadTextSubtitlesAt(targetSeconds, true)
  }

  // ── Time / progress updates ───────────────────────────────────────

  onTimeUpdate() {
    const currentPos = this.currentPlaybackPosition()
    const duration = this.effectiveDuration()

    this.currentTimeTarget.textContent = this.formatTime(currentPos)
    this.updateSubtitleOverlay(currentPos)
    if (duration > 0) {
      this.updateSeekVisuals(currentPos / duration)
    }

    // Update the buffer bar every time the playhead moves — not just
    // when new data arrives (onProgress).  Without this, the grey buffer
    // bar stays at its old position while the playhead advances through
    // the buffer, making it look like there's lots of buffer ahead when
    // there isn't.  This is the #1 cause of "buffering happens when the
    // timeline shows lots of buffer ahead" — the timeline was lying.
    this.updateBufferBar()

    // Safety net: if the "Buffering..." overlay is stuck (isStalled=true)
    // but currentTime is actively advancing (video is playing), the stall
    // has resolved.  "playing" may not have fired (browsers don't always
    // emit it when resuming from buffered ranges), and "progress" may not
    // fire (browser playing from buffer, not downloading).  "timeupdate"
    // fires whenever currentTime changes, making it the most reliable
    // signal that playback is alive.  Clear the overlay if there's buffer
    // ahead — no point showing "Buffering..." when the video is moving.
    if (this.isStalled && !this.systemRebufferPaused && !this.videoTarget.paused && !this.userPaused && !this.isSeeking && this.hasBufferedAhead(2)) {
      clearTimeout(this.bufferingOverlayTimer)
      this.bufferingOverlayTimer = null
      this.isStalled = false
      this.clearStallWatchdog()
      this.streamRecoveryAttempts = 0
      this.streamRecoveryActive = false
      this.startProgressWatchdog()
      this.hideSeekingOverlay()
    }
  }

  // Update the grey buffer bar to show from the playhead to the end of
  // the buffered range containing currentTime.  Called from both
  // onTimeUpdate (every ~250ms) and onProgress (when new data arrives).
  updateBufferBar() {
    const video = this.videoTarget
    if (!video.buffered.length || this.knownDuration <= 0) return

    const timelineOffset = this.playbackTimelineOffset()
    const ct = video.currentTime + timelineOffset
    let bufferEndAbsolute = ct
    for (let i = 0; i < video.buffered.length; i++) {
      const rangeStart = video.buffered.start(i) + timelineOffset
      const rangeEnd = video.buffered.end(i) + timelineOffset
      if (ct >= rangeStart && ct <= rangeEnd) {
        bufferEndAbsolute = rangeEnd
        break
      }
    }

    const playheadPercent = Math.min(100, (ct / this.knownDuration) * 100)
    const bufferEndPercent = Math.min(100, (bufferEndAbsolute / this.knownDuration) * 100)
    this.seekBufferedTarget.style.left = `${playheadPercent}%`
    this.seekBufferedTarget.style.width = `${Math.max(0, bufferEndPercent - playheadPercent)}%`
  }

  onProgress() {
    // Track when the browser last received data — used by the progress
    // watchdog to detect download stalls for direct/remux play.
    this.lastProgressEventTime = Date.now()

    // Safety net for direct play: if the "Buffering..." overlay is stuck
    // (isStalled=true from a previous "waiting" event) but the browser
    // has since buffered ahead and is actively playing, clear the overlay.
    // For direct play there's no onBufferUpdateEnd → maybeHideBufferingOverlay
    // safety net (no SourceBuffer), so without this the overlay can stay
    // stuck forever if onVideoReady's 2s gate returned early.
    if (this.isDirectPlay() && this.isStalled && !this.videoTarget.paused && !this.userPaused && this.hasBufferedAhead(2)) {
      clearTimeout(this.bufferingOverlayTimer)
      this.bufferingOverlayTimer = null
      this.isStalled = false
      this.clearStallWatchdog()
      this.streamRecoveryAttempts = 0
      this.streamRecoveryActive = false
      this.startProgressWatchdog()
      this.hideSeekingOverlay()
    }

    this.updateBufferBar()
  }

  updateSeekVisuals(fraction) {
    const percent = Math.max(0, Math.min(1, fraction)) * 100
    this.seekFilledTarget.style.width = `${percent}%`
    this.seekHandleTarget.style.left = `${percent}%`
  }

  effectiveDuration() {
    if (this.knownDuration > 0) return this.knownDuration
    const d = this.videoTarget.duration
    return this.validDuration(d) ? d + this.playbackTimelineOffset() : 0
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
      // Seeking/error overlays ARE interactive (e.g. onVideoError
      // adds a click-to-retry handler). Remove pointer-events-none
      // that showBufferingOverlay may have set.
      this.seekingOverlayTarget.classList.remove("pointer-events-none")
      this.seekingOverlayTarget.classList.remove("hidden")
    }
  }

  bufferedRangesDebug() {
    const r = this.videoTarget.buffered
    if (!r || r.length === 0) return "empty"
    return Array.from({ length: r.length }, (_, i) =>
      `[${r.start(i).toFixed(1)}-${r.end(i).toFixed(1)}]`
    ).join(" ")
  }

  // Show the overlay with a "Buffering..." message — used when the
  // video element runs out of data mid-playback (not a user seek).
  showBufferingOverlay() {
    if (this.hasSeekingOverlayMessageTarget) this.seekingOverlayMessageTarget.textContent = "Buffering..."
    // pointer-events-none so the user can still seek/click while the
    // buffering spinner is visible — the overlay is visual feedback,
    // not a modal.
    this.seekingOverlayTarget.classList.add("pointer-events-none")
    this.seekingOverlayTarget.classList.remove("hidden")
  }

  hideSeekingOverlay() {
    if (this.subtitlePlaybackHoldToken !== null) return
    this.isSeeking = false
    this.seekingOverlayTarget.classList.add("hidden")
    this.seekingOverlayTarget.classList.remove("pointer-events-none")

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
      this.backButtonTarget.style.opacity = "0"
      this.backButtonTarget.style.pointerEvents = "none"
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

  progressReporter() {
    return this.playbackCoordinator().progress
  }



  async saveProgress(completed = false) {
    return this.progressReporter().save(completed)
  }

  saveProgressSync() {
    return this.progressReporter().saveSync()
  }

  progressPayload() {
    return this.progressReporter().payload()
  }

  saveableDurationSeconds() {
    return this.progressReporter().saveableDurationSeconds()
  }
}
