import { Controller } from "@hotwired/stimulus"

const MIN_VALID_DURATION_SECONDS = 60
const SUBTITLE_STARTUP_WINDOW_SECONDS = 5
const SUBTITLE_STARTUP_LOOK_BEHIND_SECONDS = 2
const SUBTITLE_WINDOW_SECONDS = 15
const SUBTITLE_LOOK_BEHIND_SECONDS = 5
const EXTERNAL_SUBTITLE_WINDOW_SECONDS = 60
const SUBTITLE_PREFETCH_SECONDS = 10
const STREAM_STALL_TIMEOUT_MS = 60000
const PROGRESS_STALL_TIMEOUT_MS = 20000
const PROGRESS_WATCHDOG_INTERVAL_MS = 3000
const STREAM_MAX_RECOVERY_ATTEMPTS = 3
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
const MSE_QUOTA_RETRY_MS = 250
const MSE_BACK_BUFFER_SECONDS = 30
const MSE_BACK_BUFFER_EVICT_BATCH_SECONDS = 30
const MSE_QUOTA_BACK_BUFFER_SECONDS = 2
const PREMATURE_END_RECOVERY_BUFFER_SECONDS = 5
const COMPLETION_RATIO = 0.98
const MSE_MIME_TYPE = 'video/mp4; codecs="avc1.640028,mp4a.40.2"'
const REMUX_PRESENTATION_PROBE_SECONDS = 0.001
const REMUX_PRESENTATION_PROBE_TIMEOUT_MS = 500
const MAX_REMUX_PRESENTATION_OFFSET_SECONDS = 1
const REMUX_SEEK_TOLERANCE_SECONDS = 0.25
const REMUX_SEEK_TIMEOUT_MS = 500
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
      streamingUrl: String, directUrl: String, directStreamUrl: String, filename: String, imdbId: String, type: String,
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
    this.hlsPlayPromptCleanup = null
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
    this.probeDuration()

    // Save progress on page unload — but skip if navigateBack already
    // saved (navigatingAway flag prevents a duplicate save).
    this.beforeUnloadHandler = () => { if (!this.navigatingAway) this.saveProgressSync() }
    window.addEventListener("beforeunload", this.beforeUnloadHandler)

    // Track progress every 5s
    this.startProgressTracking()
  }

  disconnect() {
    this.stopHlsSession()
    this.stopProgressTracking()
    // Save progress only if navigateBack hasn't already done it.
    if (!this.navigatingAway) this.saveProgressSync()
    this.clearUiHideTimer()
    this.clearStartupOverlayTimer()
    this.clearHlsPlayPrompt()
    this.clearSuppressSeekClickTimer()
    this.clearStallWatchdog()
    clearTimeout(this.bufferingOverlayTimer)
    clearTimeout(this.quotaRetryTimer)
    clearTimeout(this.rebufferDeadlineTimer)
    clearTimeout(this.bufferAheadDeadlineTimer)
    clearTimeout(this.prematureEndRecoveryTimer)
    this.stopProgressWatchdog()
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

  urlWithPlaybackId(value) {
    const url = new URL(value, window.location.origin)
    url.searchParams.set("playback_id", this.playbackId)
    return url.pathname + url.search
  }
  async ensureVideoSource() {
    if (!this.streamingUrlValue) return
    if (this.isIOS()) {
      // HLS handles media playback on iPhone, but the player still needs
      // track metadata for its audio/subtitle controls and burn-in choices.
      await this.loadMediaTracks()
      this.startHlsPlayback()
      return
    }

    const safari = this.isSafari()
    if (!this.mseSupported && !safari) {
      this.videoTarget.src = this.streamingUrlValue
      return
    }

    // A provider-ranked H.264/AAC MP4 can begin loading its header and MP4
    // index while FFprobe validates the exact streams. This keeps the probe as
    // the authority for codec and preferred-audio decisions without putting
    // its network latency in front of the browser's own metadata fetch.
    const tracksPromise = this.loadMediaTracks()
    if (this.directPlayHintValue) this.primeDirectPlay()
    await tracksPromise
    if (this.directPlayEligible()) {
      console.log("[Player] Path: direct play (native <video>, no ffmpeg)")
      this.startDirectPlay()
    } else if (safari) {
      // Safari expects seekable native MP4 resources; the remux endpoint is a
      // non-seekable chunked response and can fail before metadata with
      // MEDIA_ERR_SRC_NOT_SUPPORTED. Native HLS is Safari's reliable streaming
      // transport and avoids poisoning the element before a fallback starts.
      this.primedDirectPlayUrl = null
      console.log("[Player] Path: native HLS (Safari)")
      this.startHlsPlayback()
    } else if (this.remuxDirectEligible()) {
      this.primedDirectPlayUrl = null
      console.log("[Player] Path: remux direct play (-c:v copy, no re-encode)")
      this.startRemuxDirectPlay()
    } else {
      this.primedDirectPlayUrl = null
      console.log("[Player] Path: MSE/transcode (hardware decode + encode)")
      this.setupMseSource(this.streamingUrlValue)
    }
  }

  primeDirectPlay() {
    if (!this.directStreamUrlValue) return
    // An explicit track selection needs FFprobe before we know whether native
    // playback can honor it, so only prime the ordinary default-track case.
    if (this.selectedAudioStream || this.selectedSubtitleStream) return

    const directUrl = this.urlWithPlaybackId(this.directStreamUrlValue)
    this.primedDirectPlayUrl = directUrl
    this.videoTarget.autoplay = false
    this.videoTarget.preload = "auto"
    this.videoTarget.src = directUrl
    // Assigning src starts resource selection. Calling load() as well can
    // cancel and duplicate the same Range request in Chromium.
  }
  setupMseSource(streamUrl) {
    // Abort current fetch and clear queue
    if (this.fetchController) { this.fetchController.abort(); this.fetchController = null }
    this.bufferQueue = []
    this.fmp4Buffer = null
    this.fmp4BufferSize = 0
    this.pendingAppendBuffer = null
    this.mseFetchEnded = false
    this.quotaBlockedAtTime = null
    this.mseReadPaused = false
    clearTimeout(this.quotaRetryTimer)
    this.quotaRetryTimer = null
    this.clearSystemRebufferGate()
    clearTimeout(this.bufferAheadDeadlineTimer)
    this.bufferAheadDeadlineTimer = null
    clearTimeout(this.prematureEndRecoveryTimer)
    this.prematureEndRecoveryTimer = null
    this.playbackStarted = false
    this.isStalled = false
    this.userPaused = false
    this.directPlayActive = false
    this.remuxDirectPlay = false
    this.bufferAheadDeadline = null
    this.rebufferDeadline = null
    // Clear any stall watchdog from the previous connection so a
    // pending timer can't fire into the new MSE pipeline.
    this.clearStallWatchdog()

    // Tear down old MediaSource
    if (this.mediaSource) {
      if (this.mediaSource.readyState === "open") { try { this.mediaSource.endOfStream() } catch {} }
      this.mediaSource = null
      this.sourceBuffer = null
    }
    if (this.videoTarget.src.startsWith("blob:")) URL.revokeObjectURL(this.videoTarget.src)

    const mimeType = MSE_MIME_TYPE
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

  // iPhone and iPod Touch don't support MediaSource Extensions.
  // iPad (iPadOS 17.1+) supports ManagedMediaSource, so the MSE
  // path works there — exclude it explicitly.
  isIOS() {
    const ua = navigator.userAgent
    return /iPhone|iPod/.test(ua) && !/iPad/.test(ua)
  }

  isSafari() {
    const ua = globalThis.navigator?.userAgent || ""
    return /Safari/.test(ua) && !/(Chrome|Chromium|CriOS|FxiOS|Edg|OPR|Android)/.test(ua)
  }

  isChromium() {
    const ua = globalThis.navigator?.userAgent || ""
    return /(Chrome|Chromium|CriOS|Edg|OPR)/.test(ua)
  }

  // True when using native HLS playback (iOS).  All MSE-specific
  // machinery (stall watchdog, progress watchdog, reconnect, buffer
  // management) must be skipped on this path — MediaSource doesn't
  // exist on iPhone Safari, and the native HLS player handles its
  // own buffering and recovery.
  isHls() {
    return !!this.hlsSessionId
  }

  // True when using direct play (native <video> src, no MSE, no ffmpeg).
  // The browser downloads the proxied RD URL at network speed, seeks via
  // Range requests, and handles its own buffering.
  isDirectPlay() {
    return !!this.directPlayActive
  }

  // Native direct play seeks inside the original file, so currentTime is
  // already absolute. Remux, HLS, and MSE streams restart at zero and need
  // startSecondsValue added back to recover the source timeline.
  isNativeDirectPlay() {
    return this.isDirectPlay() && !this.isRemuxDirectPlay()
  }

  playbackTimelineOffset() {
    return this.isNativeDirectPlay() ? 0 : this.startSecondsValue
  }

  // True when using remux direct play: native <video src> pointing at
  // the transcode endpoint with remux=1 (-c:v copy, no video re-encode).
  // The browser handles buffering natively — no MSE, no SourceBuffer.
  // Seeking requires changing the src (non-seekable streaming response).
  isRemuxDirectPlay() {
    return !!this.remuxDirectPlay
  }

  // Can the current stream be played without ffmpeg? The server confirms
  // an MP4-family container plus default AAC audio; the browser makes the
  // final codec decision because HEVC support is platform-specific.
  directPlayEligible() {
    if (!this.directStreamUrlValue) return false
    if (this.streamRecoveryAttempts > 0) return false
    if (this.burnedSubtitleSelected()) return false
    if (this.selectedAudioStream && this.selectedAudioStream !== this.defaultAudioStreamIndex()) return false
    if (this.tracksData?.direct_playable !== true) return false

    const codec = this.tracksData?.video_codec
    if (!codec) return false
    const isHevc = codec === "hevc" || codec === "h265"
    if (isHevc && this.isSafari() && this.tracksData?.video_codec_tag !== "hvc1") return false
    return codec === "h264" || this.browserCanPlayCodec(codec)
  }

  // Return the index (as string) of the default audio track, or null if
  // there's no default track.  Used by directPlayEligible to allow direct
  // play when the user's preferred language matches the default track —
  // the browser plays the default track anyway, so no ffmpeg is needed.
  defaultAudioStreamIndex() {
    const defaultTrack = this.audioTracks.find((track) => track.default) || this.audioTracks[0]
    return defaultTrack?.index?.toString() || null
  }

  // Can the current stream be remuxed (video copy, no re-encode)?
  // Requires H.264 or HEVC video codec — the browser plays both
  // natively (HEVC via VideoToolbox on macOS).  Works for any container
  // (MKV, m2ts, MP4) and any B-frame status — the native <video>
  // element handles B-frames correctly, unlike MSE's SourceBuffer.
  // Unlike direct play, audio stream selection IS supported: ffmpeg
  // selects and transcodes the specified audio track to AAC while
  // copying the video stream verbatim.  Burned subtitles require
  // video re-encode, so remux is skipped when a burn subtitle is active.
  remuxDirectEligible() {
    if (this.isSafari()) return false
    if (this.streamRecoveryAttempts > 0) return false
    if (this.burnedSubtitleSelected()) return false
    if (!this.tracksData?.remux_direct_playable) return false
    // Check browser can play the codec natively. HEVC requires
    // VideoToolbox (macOS Chrome/Edge/Safari). Firefox and Linux
    // Chrome don't support HEVC — skip remux for HEVC there.
    const codec = this.tracksData?.video_codec
    const isHevc = codec === "hevc" || codec === "h265"
    const width = Number(this.tracksData?.video_width) || 0
    const height = Number(this.tracksData?.video_height) || 0
    // A generic hvc1 result does not prove that the native element accepts an
    // UHD Main10/HDR configuration. When it rejects the remux, Chromium wastes
    // a complete seek/probe cycle and starts the H.264 fallback from scratch.
    // Fail closed for UHD HEVC and start the sustainable MSE path immediately.
    if (isHevc && (width > 1920 || height > 1080)) return false
    if (codec && codec !== "h264" && !this.browserCanPlayCodec(codec)) return false
    return true
  }

  // Check if the browser can natively play a video codec via <video>.
  // canPlayType is conservative — it returns "" (treated as "no") for
  // HEVC even on macOS Chrome 107+ where the <video> element CAN play
  // HEVC via VideoToolbox.  So for HEVC we also check the platform:
  // macOS (Chrome/Edge/Safari) and iOS/iPadOS have native HEVC support.
  // Windows requires the HEVC Video Extension from the Store, which
  // most users have, so we allow "maybe" there too.
  browserCanPlayCodec(codec) {
    const isHevc = codec === "hevc" || codec === "h265"
    const mime = isHevc
      ? 'video/mp4; codecs="hvc1"'
      : `video/mp4; codecs="${codec}"`
    const result = this.videoTarget.canPlayType(mime)
    if (result === "probably" || result === "maybe") return true

    // canPlayType returned "" but the browser may still play HEVC.
    // Chrome 107+ on macOS supports HEVC via VideoToolbox but
    // canPlayType can return "" depending on the build/flags.
    // Safari always reports "probably" for HEVC on macOS/iOS.
    // Allow HEVC on macOS and iOS regardless of canPlayType — the
    // worst case is the <video> fires an "error" event, which the
    // player already handles by falling back to MSE/transcode.
    if (isHevc && this.platformSupportsHevc()) return true

    return false
  }

  // Returns true on platforms with native HEVC support:
  //   - macOS (Chrome 107+, Edge, Safari) via VideoToolbox
  //   - iOS/iPadOS (Safari) via hardware decoder
  //   - Android (Chrome) via hardware decoder (most devices)
  // Windows is NOT included here because HEVC requires a Store
  // extension that not all users have installed — let canPlayType
  // handle it (returns "probably" when the extension is present).
  platformSupportsHevc() {
    const ua = navigator.userAgent
    // macOS: Safari, Chrome, Edge all support HEVC via VideoToolbox.
    // Chrome 107+ enabled HEVC by default on macOS.
    if (/Mac OS X/.test(ua) && !/Windows/.test(ua)) return true
    // iPhone/iPad: native HEVC support (hardware decoder).
    if (/iPhone|iPad|iPod/.test(ua)) return true
    // Android: most modern devices have HEVC hardware decode.
    // Chrome on Android supports HEVC since Chrome 107.
    if (/Android/.test(ua)) return true
    return false
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
      if (promise?.catch) promise.catch(() => {})
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
    const rawUrl = this.extractRawUrl()
    if (!rawUrl) return null

    try {
      const endpoint = this.hasSeekUrlValue ? this.seekUrlValue : "/transcode/seek"
      const url = new URL(endpoint, window.location.origin)
      url.searchParams.set("url", rawUrl)
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

  async startHlsPlayback() {
    this.cancelRemuxLoad()
    this.clearHlsPlayPrompt()
    this.directPlayActive = false
    this.remuxDirectPlay = false
    this.primedDirectPlayUrl = null

    const directUrl = this.directUrlValue || this.extractRawUrl()
    if (!directUrl) {
      console.warn('HLS: no direct URL available')
      return
    }

    try {
      const params = new URLSearchParams({ url: directUrl })
      params.set("playback_id", this.playbackId)
      if (this.startSecondsValue && this.startSecondsValue > 0) {
        params.set('start_seconds', this.startSecondsValue)
      }
      this.appendSelectedHlsTracks(params)

      const csrfToken = document.querySelector("meta[name='csrf-token']")?.content
      const response = await fetch('/hls/start', {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded', 'X-CSRF-Token': csrfToken },
        body: params.toString()
      })

      if (!response.ok) {
        console.warn('HLS: start failed', response.status)
        return
      }

      const data = await response.json()
      this.hlsSessionId = data.session_id

      // Poll the playlist URL until ffmpeg has produced the first
      // segment (200) or failed (424).  The server returns 202
      // (Accepted) while the playlist isn't ready yet.  This avoids
      // setting a video src that points to a non-existent playlist,
      // which would cause iOS Safari to fail silently.
      const playlistReady = await this.waitForPlaylist(data.playlist_url)
      if (!playlistReady) {
        console.warn('HLS: playlist not ready or ffmpeg failed')
        if (this.hasStartupOverlayTarget) {
          const label = this.startupOverlayTarget.querySelector("span.text-white")
          const sub = this.startupOverlayTarget.querySelector("span.text-sv-text-muted")
          if (label) label.textContent = "Stream failed to start"
          if (sub) sub.textContent = "Try going back and selecting another stream"
        }
        return
      }

      // Native HLS playback — iOS Safari handles the playlist natively.
      this.videoTarget.autoplay = true
      this.videoTarget.src = data.playlist_url
      this.videoTarget.load()
      const p = this.videoTarget.play()
      if (p?.catch) p.catch((error) => {
        // Starting the HLS session and waiting for its playlist crosses an
        // asynchronous boundary, so Safari may no longer associate play()
        // with the navigation click. Its audible-autoplay policy then requires
        // one fresh user gesture. Present that as an explicit play control
        // instead of treating the policy rejection as a stream failure.
        if (error?.name === "NotAllowedError") {
          console.info("HLS: Safari requires a tap to start audible playback")
        } else {
          console.warn("HLS: autoplay failed, showing play prompt", error)
        }
        this.showHlsPlayPrompt()
      })
    } catch (e) {
      console.warn('HLS: start error', e)
    }
  }

  showHlsPlayPrompt() {
    if (!this.hasStartupOverlayTarget) return

    this.clearHlsPlayPrompt()
    const overlay = this.startupOverlayTarget
    const spinner = overlay.querySelector(".animate-spin")
    const label = overlay.querySelector("span.text-white")
    const sub = overlay.querySelector("span.text-sv-text-muted")

    overlay.classList.remove("hidden", "opacity-0", "pointer-events-none")
    overlay.classList.add("cursor-pointer")
    overlay.setAttribute("aria-hidden", "false")
    overlay.setAttribute("role", "button")
    overlay.setAttribute("tabindex", "0")
    overlay.setAttribute("aria-label", "Play video")
    if (spinner) spinner.style.display = "none"
    if (label) label.textContent = "Play"
    if (sub) sub.textContent = "Tap or press Enter to start"

    const attemptPlay = (event) => {
      if (event.type === "keydown" && event.key !== "Enter" && event.key !== " ") return
      event.preventDefault()
      event.stopPropagation()
      if (spinner) spinner.style.display = ""
      if (label) label.textContent = "Starting playback"
      if (sub) sub.textContent = "Loading stream..."

      Promise.resolve(this.videoTarget.play()).then(() => {
        // The "playing" event owns hiding the overlay after the first frame.
        this.clearHlsPlayPrompt()
      }).catch((playError) => {
        console.warn("HLS: playback failed after user gesture", playError)
        if (spinner) spinner.style.display = "none"
        if (label) label.textContent = "Try again"
        if (sub) sub.textContent = "Tap or press Enter to retry"
      })
    }

    overlay.addEventListener("click", attemptPlay)
    overlay.addEventListener("keydown", attemptPlay)
    this.hlsPlayPromptCleanup = () => {
      overlay.removeEventListener("click", attemptPlay)
      overlay.removeEventListener("keydown", attemptPlay)
      overlay.classList.remove("cursor-pointer")
      overlay.setAttribute("role", "status")
      overlay.removeAttribute("tabindex")
      overlay.removeAttribute("aria-label")
    }
  }

  clearHlsPlayPrompt() {
    if (!this.hlsPlayPromptCleanup) return

    const cleanup = this.hlsPlayPromptCleanup
    this.hlsPlayPromptCleanup = null
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
    const maxAttempts = 150  // 150 × 200ms = 30s max wait
    const pollInterval = 200
    const minSegments = 2
    // After this many attempts, accept 1 segment rather than timing out.
    const fallbackAttempts = 100  // 20s
    for (let i = 0; i < maxAttempts; i++) {
      try {
        // GET (not HEAD) so we can count segments in the playlist body.
        // The playlist is small (a few KB), so fetching it is cheap.
        const res = await fetch(playlistUrl)
        if (res.status === 424) {
          try {
            const body = await res.json()
            console.warn('HLS: ffmpeg failed:', body.error)
          } catch {}
          return false
        }
        if (res.status === 200) {
          const text = await res.text()
          const segmentCount = (text.match(/#EXTINF/g) || []).length
          const minNeeded = i >= fallbackAttempts ? 1 : minSegments
          if (segmentCount >= minNeeded) return true
        }
        // 202 (Accepted) — playlist not ready yet, keep polling
      } catch {
        // network error — keep polling
      }
      await new Promise(resolve => setTimeout(resolve, pollInterval))
    }
    console.warn('HLS: playlist poll timed out after', maxAttempts * pollInterval / 1000, 's')
    return false
  }

  // Restart the HLS transcode from a new position (seek).
  // Stops the current session, starts a new one with the updated
  // start_seconds, and swaps the video source to the new playlist.
  async restartHlsSession(startSeconds) {
    // Pause the video immediately so it doesn't keep playing the
    // old stream behind the seeking overlay.
    this.videoTarget.pause()
    this.clearSubtitleCues()
    this.reloadTextSubtitlesAt(startSeconds)

    // Fire the stop request without awaiting — it runs in parallel
    // with the new session start.  The old ffmpeg process is killed
    // server-side; we don't need to wait for that before starting
    // the new transcode.
    this.stopHlsSession()

    const directUrl = this.directUrlValue || this.extractRawUrl()
    if (!directUrl) {
      console.warn('HLS seek: no direct URL available')
      this.isSeeking = false
      this.hideSeekingOverlay()
      return
    }

    try {
      const params = new URLSearchParams({ url: directUrl })
      params.set("playback_id", this.playbackId)
      if (startSeconds > 0) {
        params.set('start_seconds', startSeconds)
      }
      this.appendSelectedHlsTracks(params)

      const csrfToken = document.querySelector("meta[name='csrf-token']")?.content
      const response = await fetch('/hls/start', {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded', 'X-CSRF-Token': csrfToken },
        body: params.toString()
      })

      if (!response.ok) {
        console.warn('HLS seek: start failed', response.status)
        this.isSeeking = false
        this.hideSeekingOverlay()
        return
      }

      const data = await response.json()
      this.hlsSessionId = data.session_id

      // Wait for the playlist to be ready before swapping the video
      // source — same as initial playback.
      const playlistReady = await this.waitForPlaylist(data.playlist_url)
      if (!playlistReady) {
        console.warn('HLS seek: playlist not ready or ffmpeg failed')
        this.isSeeking = false
        this.hideSeekingOverlay()
        return
      }

      // Swap to the new playlist.  iOS Safari handles the source
      // change and starts playing from the beginning of the new
      // HLS stream (which starts at the seek position thanks to
      // ffmpeg -ss).
      this.videoTarget.src = data.playlist_url
      this.videoTarget.load()
      const p = this.videoTarget.play()
      if (p?.catch) p.catch(() => {})

      // Hide the seeking overlay once playback actually starts.
      const onPlaying = () => {
        this.isSeeking = false
        this.hideSeekingOverlay()
        this.videoTarget.removeEventListener('playing', onPlaying)
      }
      this.videoTarget.addEventListener('playing', onPlaying, { once: true })

      // Safety: hide overlay after 30s even if 'playing' never fires
      setTimeout(() => {
        if (this.isSeeking) {
          this.isSeeking = false
          this.hideSeekingOverlay()
        }
      }, 30000)
    } catch (e) {
      console.warn('HLS seek: error', e)
      this.isSeeking = false
      this.hideSeekingOverlay()
    }
  }

  // Best-effort: tell the backend to kill the ffmpeg HLS process for
  // the current session.  Fire-and-forget — disconnect must not block,
  // and the session TTL cleans up if the request never lands.
  async stopHlsSession() {
    if (!this.hlsSessionId) return
    const sessionId = this.hlsSessionId
    this.hlsSessionId = null
    try {
      const csrfToken = document.querySelector("meta[name='csrf-token']")?.content
      await fetch(`/hls/${sessionId}/stop`, {
        method: 'POST',
        headers: { 'X-CSRF-Token': csrfToken },
        keepalive: true
      })
    } catch {
      // Best-effort — don't block teardown
    }
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

  startStallWatchdog(timeoutMs = STREAM_STALL_TIMEOUT_MS) {
    this.clearStallWatchdog()
    this.stallWatchdogTimer = setTimeout(() => {
      this.stallWatchdogTimer = null
      // Re-check before firing recovery: the video may have resumed
      // from buffer without firing "playing" (the media element
      // doesn't always emit it when transitioning between buffered
      // ranges). If there's buffer ahead and the video isn't paused,
      // the stall resolved — don't reconnect.
      if (!this.videoTarget.paused && this.hasBufferedAhead()) {
        this.hideSeekingOverlay()
        this.startProgressWatchdog()
        return
      }
      this.handleStreamStall()
    }, timeoutMs)
  }

  clearStallWatchdog() {
    if (this.stallWatchdogTimer) {
      clearTimeout(this.stallWatchdogTimer)
      this.stallWatchdogTimer = null
    }
  }

  // ── Progress watchdog (silent freeze detector) ──────────────────
  //
  // The `waiting`-based watchdog only fires when the browser emits a
  // "waiting" event.  In practice, browsers do NOT reliably emit
  // "waiting" when playback reaches the end of buffered data after a
  // fetch has ended early (e.g. the server/Cloudflare closed the
  // response, or ffmpeg exited mid-burst).  The video element sits on
  // the last buffered frame with readyState >= 2, paused === false,
  // and currentTime frozen — and never fires "waiting".  The result
  // is a permanent frozen frame with no "Buffering" indicator, which
  // only recovers when the user manually seeks.
  //
  // This watchdog polls currentTime on a timer.  While the video is
  // supposedly playing (not paused, not ended, not seeking), if
  // currentTime does not advance for PROGRESS_STALL_TIMEOUT_MS, the
  // stream is treated as a silent stall and recovered via the same
  // handleStreamStall() path.  It complements the `waiting` watchdog:
  //   - `waiting` fires → progress watchdog is disarmed, `waiting`
  //     watchdog owns the 60s countdown.
  //   - silent freeze (no `waiting`) → progress watchdog detects it
  //     in PROGRESS_STALL_TIMEOUT_MS instead.
  // The baseline is reset whenever new data is appended, so normal
  // transcoding bursts (which DO keep currentTime advancing) never
  // trip it.

  startProgressWatchdog() {
    if (this.progressWatchdogArmed) return
    this.lastProgressPosition = this.videoTarget.currentTime
    this.lastProgressTime = Date.now()
    this.lastBufferEnd = this.currentBufferEnd()
    this.lastBufferDataTime = Date.now()
    this.lastProgressEventTime = Date.now()
    this.progressWatchdogArmed = true
    this.tickProgressWatchdog()
  }

  tickProgressWatchdog() {
    this.progressWatchdogTimer = setTimeout(() => {
      this.progressWatchdogTimer = null
      this.checkProgressStall()
      if (this.progressWatchdogArmed) this.tickProgressWatchdog()
    }, PROGRESS_WATCHDOG_INTERVAL_MS)
  }

  checkProgressStall() {
    if (!this.progressWatchdogArmed) return
    if (this.streamRecoveryActive || this.isSeeking) return
    // A deliberate user pause is not a stall — the watchdog is
    // disarmed in togglePlay, but guard anyway in case it was armed
    // by onVideoReady before the pause landed.
    if (this.userPaused) return
    // Only meaningful while the video is supposedly playing.
    if (this.videoTarget.paused || this.videoTarget.ended) return
    // Don't count a stall before playback has actually begun.
    if (!this.playbackStarted) return

    const now = Date.now()
    const pos = this.videoTarget.currentTime
    const elapsed = now - this.lastProgressTime
    const playbackAdvanced = pos > this.lastProgressPosition + 0.1

    if (playbackAdvanced) {
      this.lastProgressPosition = pos
      this.lastProgressTime = now
    }

    // ── Download starvation detection (direct/remux play) ─────────
    // Native media elements may intentionally stop requesting data and
    // report only a small buffer while playback remains healthy. Missing
    // progress events are actionable only when the playhead also stopped,
    // readyState lost future data, and the contiguous buffer is dry.
    if (this.isDirectPlay()) {
      const dlStalledMs = now - this.lastProgressEventTime
      const bufEnd = this.currentBufferEnd()
      const bufGrowing = bufEnd > this.lastBufferEnd + 0.5
      if (bufGrowing) {
        this.lastBufferEnd = bufEnd
        this.lastBufferDataTime = now
      }
      const bufStalledMs = now - this.lastBufferDataTime
      const networkQuiet = dlStalledMs > 15000 || (bufStalledMs > 15000 && !bufGrowing)

      if (networkQuiet) {
        const bufferAhead = this.bufferedAheadOfCurrent()
        const genuinelyStarved =
          !playbackAdvanced &&
          this.videoTarget.readyState < 3 &&
          bufferAhead < 0.5

        if (genuinelyStarved) {
          console.warn(`Download starved — no progress event for ${Math.round(dlStalledMs / 1000)}s — reconnecting`)
          this.progressWatchdogArmed = false
          this.handleStreamStall("download_stall")
          return
        }

        this.lastProgressEventTime = now
        this.lastBufferDataTime = now
        this.lastBufferEnd = bufEnd
      }
    }

    // ── Freeze detection (all paths) ──────────────────────────────
    // currentTime has not advanced since the last tick.  If this has
    // persisted longer than the threshold, treat it as a silent stall.
    if (!playbackAdvanced && elapsed >= PROGRESS_STALL_TIMEOUT_MS) {
      console.warn(`Silent freeze detected — currentTime stuck at ${pos} for ${Math.round(elapsed / 1000)}s`)
      this.progressWatchdogArmed = false
      if (this.isHls()) {
        this.handleHlsStall("silent_freeze")
      } else {
        this.handleStreamStall("silent_freeze")
      }
    }
  }

  // Get the end of the buffered range containing currentTime (or the
  // last buffered range).  Used to track whether the download is alive.
  currentBufferEnd() {
    const video = this.videoTarget
    if (!video.buffered.length) return 0
    const ct = video.currentTime
    for (let i = 0; i < video.buffered.length; i++) {
      if (ct >= video.buffered.start(i) && ct <= video.buffered.end(i)) {
        return video.buffered.end(i)
      }
    }
    return video.buffered.end(video.buffered.length - 1)
  }

  resetProgressBaseline() {
    if (!this.progressWatchdogArmed) return
    this.lastProgressPosition = this.videoTarget.currentTime
    this.lastProgressTime = Date.now()
    this.lastBufferEnd = this.currentBufferEnd()
    this.lastBufferDataTime = Date.now()
    this.lastProgressEventTime = Date.now()
  }

  stopProgressWatchdog() {
    this.progressWatchdogArmed = false
    if (this.progressWatchdogTimer) {
      clearTimeout(this.progressWatchdogTimer)
      this.progressWatchdogTimer = null
    }
  }

  // Called when the stall watchdog fires — the video element has been
  // waiting for data longer than STREAM_STALL_TIMEOUT_MS. Aborts the
  // current fetch and reconnects from the current playback position,
  // up to STREAM_MAX_RECOVERY_ATTEMPTS times.
  handleStreamStall(eventType = "stall") {
    // Never trigger recovery while the user has deliberately paused.
    // The stall watchdog and progress watchdog can fire long after a
    // user pause (60s/30s), and reconnectFromCurrentPosition resets
    // userPaused=false via setupMseSource — which would auto-resume
    // playback the user explicitly paused.
    if (this.userPaused) {
      this.clearStallWatchdog()
      this.stopProgressWatchdog()
      return
    }
    if (this.isHls()) return  // iOS HLS handles its own recovery
    if (this.streamRecoveryActive) return
    if (this.streamRecoveryAttempts >= STREAM_MAX_RECOVERY_ATTEMPTS) {
      console.warn("Stream recovery limit reached — giving up.")
      this.showSeekingOverlay("Stream stalled — try seeking to resume.")
      return
    }

    this.streamRecoveryAttempts += 1
    this.streamRecoveryActive = true
    console.warn(`Stream stalled — recovering (attempt ${this.streamRecoveryAttempts}/${STREAM_MAX_RECOVERY_ATTEMPTS})`)
    this.reportStall(eventType)

    // For direct play (including remux), restart the same path — don't
    // switch to MSE/transcode.  The stall watchdog fires on genuine data
    // starvation (ffmpeg died, CDN URL expired).  Switching to MSE would
    // abandon the fast remux path and force a slow transcode from scratch.
    // Instead, reload the same URL — ffmpeg re-seeks to the current
    // position and starts producing data again.
    if (this.isDirectPlay()) {
      this.reconnectDirectPlay()
      return
    }

    this.reconnectFromCurrentPosition()
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
    if (this.userPaused) return
    if (this.isSeeking) return
    if (this.streamRecoveryAttempts >= STREAM_MAX_RECOVERY_ATTEMPTS) {
      console.warn("HLS recovery limit reached — giving up.")
      this.showSeekingOverlay("Stream stalled — tap to retry")
      const overlay = this.seekingOverlayTarget
      const onRetry = () => {
        overlay.removeEventListener("click", onRetry)
        this.hideSeekingOverlay()
        this.streamRecoveryAttempts = 0
        this.handleHlsStall("manual_retry")
      }
      overlay.addEventListener("click", onRetry)
      return
    }

    this.streamRecoveryAttempts += 1
    console.warn(`HLS stall detected — restarting session (attempt ${this.streamRecoveryAttempts}/${STREAM_MAX_RECOVERY_ATTEMPTS})`)
    this.reportStall(eventType)
    const targetSeconds = Math.floor(this.currentPlaybackPosition())
    this.isSeeking = true
    this.showSeekingOverlay("Reconnecting...")
    this.restartHlsSession(targetSeconds)
  }

  // The server reconnects upstream EOFs internally. Once its HTTP response
  // ends, wait for every queued fMP4 box to reach SourceBuffer, then decide
  // whether the buffered timeline is complete or needs recovery.
  handlePrematureStreamEnd() {
    this.mseFetchEnded = true
    this.finishOrRecoverMseEnd()
  }

  finishOrRecoverMseEnd() {
    if (!this.mseFetchEnded) return
    if (this.bufferAppending || this.sourceBuffer?.updating || this.pendingAppendBuffer) return

    this.flushBufferQueue()
    if (this.bufferAppending || this.sourceBuffer?.updating || this.pendingAppendBuffer) return

    const duration = this.effectiveDuration()
    const bufferedEnd = this.currentBufferEnd() + this.playbackTimelineOffset()
    if (duration > 0 && bufferedEnd >= duration * COMPLETION_RATIO) {
      try {
        if (this.mediaSource?.readyState === "open") this.mediaSource.endOfStream()
        if (this.mediaSource?.readyState === "ended") {
          this.mseFetchEnded = false
          this.fmp4Buffer = null
          this.fmp4BufferSize = 0
          clearTimeout(this.prematureEndRecoveryTimer)
          this.prematureEndRecoveryTimer = null
          this.clearStallWatchdog()
          return
        }
      } catch (error) {
        console.warn("Could not finalize completed MSE stream:", error)
      }
    }

    this.mseFetchEnded = false
    if (!this.playbackStarted || !this.sourceBuffer || this.sourceBuffer.buffered.length === 0) {
      console.warn("Stream fetch ended early with no buffer — recovering.")
      this.handleStreamStall("premature_end")
      return
    }

    const bufferedAhead = this.bufferedAheadOfCurrent()
    if (bufferedAhead <= PREMATURE_END_RECOVERY_BUFFER_SECONDS) {
      console.warn(`Stream fetch ended early with ${bufferedAhead.toFixed(1)}s buffer — reconnecting.`)
      this.handleStreamStall("premature_end")
      return
    }

    console.warn(`Stream fetch ended early with ${bufferedAhead.toFixed(1)}s buffer — retaining cushion.`)
    this.schedulePrematureEndRecovery()
  }

  schedulePrematureEndRecovery() {
    clearTimeout(this.prematureEndRecoveryTimer)
    const check = () => {
      this.prematureEndRecoveryTimer = null
      if (this.videoTarget.ended || this.isSeeking) return
      if (this.userPaused) {
        this.prematureEndRecoveryTimer = setTimeout(check, 1000)
        return
      }

      const bufferedAhead = this.bufferedAheadOfCurrent()
      if (bufferedAhead > PREMATURE_END_RECOVERY_BUFFER_SECONDS) {
        const delay = Math.min(1000, Math.max(250,
          (bufferedAhead - PREMATURE_END_RECOVERY_BUFFER_SECONDS) * 1000))
        this.prematureEndRecoveryTimer = setTimeout(check, delay)
        return
      }

      this.handleStreamStall("premature_end")
    }
    this.prematureEndRecoveryTimer = setTimeout(check, 250)
  }

  // How many seconds of buffer are ahead of the current playback position.
  // Finds the buffered range that contains currentTime (or the next range
  // after it) and returns the gap from currentTime to the end of that range.
  // Returns 0 if there's no buffer ahead (currentTime is past all ranges).
  bufferedAheadOfCurrent() {
    // For MSE/transcode, use sourceBuffer.buffered.  For direct/remux
    // play, use videoTarget.buffered (no sourceBuffer exists).
    const ranges = this.sourceBuffer ? this.sourceBuffer.buffered : this.videoTarget.buffered
    if (!ranges || ranges.length === 0) return 0
    const ct = this.videoTarget.currentTime
    for (let i = 0; i < ranges.length; i++) {
      if (ct >= ranges.start(i) && ct < ranges.end(i)) {
        return ranges.end(i) - ct
      }
      // currentTime is before this range (gap ahead) — no contiguous buffer
      if (ct < ranges.start(i)) return 0
    }
    return 0
  }

  // Report one structured event per recovery decision.  No stream URL,
  // filename, token, or API credential is included.
  reportStall(eventType, details = {}) {
    const ranges = this.sourceBuffer?.buffered || this.videoTarget.buffered
    const bufferedRanges = []
    for (let index = 0; index < Math.min(ranges?.length || 0, 8); index++) {
      bufferedRanges.push([
        Math.round(ranges.start(index) * 10) / 10,
        Math.round(ranges.end(index) * 10) / 10
      ])
    }

    const body = JSON.stringify({
      event: eventType,
      playback_id: this.playbackId,
      path: this.playbackPath(),
      position: Math.round(this.currentPlaybackPosition() * 10) / 10,
      buffer_ahead: Math.round(this.bufferedAheadOfCurrent() * 10) / 10,
      recovery_count: this.streamRecoveryAttempts,
      ready_state: this.videoTarget.readyState,
      network_state: this.videoTarget.networkState,
      paused: this.videoTarget.paused,
      ended: this.videoTarget.ended,
      mse_pending_bytes: (this.fmp4BufferSize || 0) + (this.pendingAppendBuffer?.byteLength || 0),
      mse_quota_errors: this.mseQuotaErrorCount,
      system_rebuffer_paused: this.systemRebufferPaused,
      buffered_ranges: bufferedRanges,
      video_codec: this.tracksData?.video_codec,
      video_width: this.tracksData?.video_width,
      video_height: this.tracksData?.video_height,
      start_seconds: this.startSecondsValue,
      ...details
    })
    fetch("/streaming/stall_telemetry", {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-CSRF-Token": document.querySelector("[name='csrf-token']")?.content },
      body,
      keepalive: true
    }).catch(() => {})
  }

  playbackPath() {
    if (this.isHls()) return "hls"
    if (this.isRemuxDirectPlay()) return "remux"
    if (this.isNativeDirectPlay()) return "direct"
    return "mse_transcode"
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
  queueBufferChunk(chunk) {
    const chunkArr = new Uint8Array(chunk)
    const newSize = (this.fmp4BufferSize || 0) + chunkArr.byteLength
    if (!this.fmp4Buffer || this.fmp4Buffer.length < newSize) {
      const allocSize = Math.max(newSize, (this.fmp4Buffer?.length || 4096) * 2)
      const newBuf = new Uint8Array(allocSize)
      if (this.fmp4Buffer) newBuf.set(this.fmp4Buffer.subarray(0, this.fmp4BufferSize || 0), 0)
      this.fmp4Buffer = newBuf
    }
    this.fmp4Buffer.set(chunkArr, this.fmp4BufferSize || 0)
    this.fmp4BufferSize = newSize
    this.flushBufferQueue()
  }

  // Extract complete top-level boxes from fmp4Buffer.  Each fMP4 box
  // starts with a 4-byte big-endian size and a 4-byte type.  We scan
  // forward, collecting boxes.  moof and mdat are paired (a fragment
  // is moof+mdat).  moov (init segment) and other boxes are appended
  // individually.  Returns the bytes to append and leaves partial boxes
  // in fmp4Buffer.
  extractCompleteBoxes() {
    if (!this.fmp4Buffer || this.fmp4BufferSize < 8) return null
    const boxes = []
    let offset = 0
    let lastComplete = 0

    while (offset + 8 <= this.fmp4BufferSize) {
      const size = (this.fmp4Buffer[offset] << 24) |
                   (this.fmp4Buffer[offset + 1] << 16) |
                   (this.fmp4Buffer[offset + 2] << 8) |
                   this.fmp4Buffer[offset + 3]
      const type = String.fromCharCode(
        this.fmp4Buffer[offset + 4],
        this.fmp4Buffer[offset + 5],
        this.fmp4Buffer[offset + 6],
        this.fmp4Buffer[offset + 7]
      )

      if (size === 0) break
      if (size === 1) break
      if (offset + size > this.fmp4BufferSize) break

      if (type === 'moof') {
        const nextOffset = offset + size
        if (nextOffset + 8 <= this.fmp4BufferSize) {
          const mdatSize = (this.fmp4Buffer[nextOffset] << 24) |
                           (this.fmp4Buffer[nextOffset + 1] << 16) |
                           (this.fmp4Buffer[nextOffset + 2] << 8) |
                           this.fmp4Buffer[nextOffset + 3]
          const mdatType = String.fromCharCode(
            this.fmp4Buffer[nextOffset + 4],
            this.fmp4Buffer[nextOffset + 5],
            this.fmp4Buffer[nextOffset + 6],
            this.fmp4Buffer[nextOffset + 7]
          )
          if (mdatType === 'mdat' && nextOffset + mdatSize <= this.fmp4BufferSize) {
            boxes.push({ offset, size: size + mdatSize })
            offset = nextOffset + mdatSize
            lastComplete = offset
            continue
          }
        }
        break
      }

      boxes.push({ offset, size })
      offset += size
      lastComplete = offset
    }

    if (boxes.length === 0) return null

    const totalSize = boxes.reduce((sum, b) => sum + b.size, 0)
    const result = new Uint8Array(totalSize)
    let writeOffset = 0
    for (const box of boxes) {
      result.set(this.fmp4Buffer.subarray(box.offset, box.offset + box.size), writeOffset)
      writeOffset += box.size
    }

    if (lastComplete < this.fmp4BufferSize) {
      this.fmp4Buffer.copyWithin(0, lastComplete, this.fmp4BufferSize)
      this.fmp4BufferSize -= lastComplete
    } else {
      this.fmp4BufferSize = 0
      this.fmp4Buffer = null
    }

    return result.buffer
  }

  flushBufferQueue() {
    if (this.bufferAppending || !this.sourceBuffer || this.sourceBuffer.updating) return
    const data = this.pendingAppendBuffer || this.extractCompleteBoxes()
    if (!data) return

    clearTimeout(this.quotaRetryTimer)
    this.quotaRetryTimer = null
    this.bufferAppending = true
    try {
      this.sourceBuffer.appendBuffer(data)
      this.pendingAppendBuffer = null
      this.quotaBlockedAtTime = null
    } catch (e) {
      this.bufferAppending = false
      if (e.name === "QuotaExceededError") {
        // extractCompleteBoxes has already removed this exact fragment
        // from fmp4Buffer. Retain it until old media can be evicted, then
        // retry the same bytes; dropping it creates a permanent timeline gap.
        this.pendingAppendBuffer = data
        this.quotaBlockedAtTime ??= this.videoTarget.currentTime
        this.mseQuotaErrorCount += 1
        this.reportStall("mse_quota")
        if (!this.evictForQuota()) this.scheduleQuotaRetry()
        this.maybeStartPlayback(true)
      } else {
        console.warn("appendBuffer failed, recovering:", e.name)
        this.pendingAppendBuffer = null
        this.fmp4Buffer = null
        this.fmp4BufferSize = 0
        this.handleStreamStall()
      }
    }
  }

  evictForQuota() {
    if (!this.sourceBuffer || this.sourceBuffer.updating) return false
    const evictBefore = this.videoTarget.currentTime - MSE_QUOTA_BACK_BUFFER_SECONDS
    if (evictBefore <= 0) return false

    for (let index = 0; index < this.sourceBuffer.buffered.length; index++) {
      const start = this.sourceBuffer.buffered.start(index)
      const end = this.sourceBuffer.buffered.end(index)
      if (start >= evictBefore) continue
      try {
        this.sourceBuffer.remove(start, Math.min(end, evictBefore))
        return true
      } catch {
        return false
      }
    }
    return false
  }

  scheduleQuotaRetry() {
    clearTimeout(this.quotaRetryTimer)
    this.quotaRetryTimer = setTimeout(() => {
      this.quotaRetryTimer = null
      if (!this.pendingAppendBuffer) return
      if (!this.evictForQuota()) this.scheduleQuotaRetry()
    }, MSE_QUOTA_RETRY_MS)
  }

  onBufferUpdateEnd() {
    this.bufferAppending = false
    this.evictOldBuffer()
    // Data arrived — the fetch is alive.  Restart the stall watchdog.
    // If the video is paused (rebuffering), use the shorter timeout so
    // trickling data doesn't keep resetting the 60s timer indefinitely —
    // the rebuffer gate may never reach REBUFFER_AHEAD_SECONDS on a
    // slow source, and the shorter timeout triggers recovery sooner.
    // If the video is playing, use the default 60s.
    // Only use the shorter rebuffer watchdog when the video is actually
    // waiting on an empty buffer.  While data is trickling in during a
    // rebuffer, isStalled is still true but the buffer is no longer empty
    // — using REBUFFER_STALL_TIMEOUT_MS there can trip a spurious stall
    // right at the 20s boundary of an otherwise-healthy rebuffer.  Gate
    // on hasBufferedAhead(0.5) so the 20s timer only applies when the
    // buffer is genuinely dry; otherwise the 60s timer is correct.
    const actuallyWaiting = this.isStalled && !this.userPaused && !this.hasBufferedAhead(0.5)
    this.startStallWatchdog(actuallyWaiting ? REBUFFER_STALL_TIMEOUT_MS : STREAM_STALL_TIMEOUT_MS)
    this.resetProgressBaseline()
    this.maybeStartPlayback()
    this.maybeHideBufferingOverlay()
    this.flushBufferQueue()
    this.finishOrRecoverMseEnd()
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
    if (!this.sourceBuffer || this.sourceBuffer.updating) return
    const currentTime = this.videoTarget.currentTime
    const evictBefore = currentTime - MSE_BACK_BUFFER_SECONDS
    if (evictBefore <= 0) return

    for (let index = 0; index < this.sourceBuffer.buffered.length; index++) {
      const start = this.sourceBuffer.buffered.start(index)
      const end = this.sourceBuffer.buffered.end(index)
      if (start >= evictBefore) continue
      const removeEnd = Math.min(end, evictBefore)

      // Range removal resets coded-frame state and may discard dependencies
      // through the next keyframe. Calling remove() after every append made
      // hardware decoders repeatedly reinitialise, showing a black frame even
      // though plenty of forward media was buffered. Keep the same 30-second
      // back buffer, but reclaim the active range only in coarse batches.
      const containsPlayhead = start <= currentTime && currentTime < end
      if (containsPlayhead && removeEnd - start < MSE_BACK_BUFFER_EVICT_BATCH_SECONDS) continue

      try { this.sourceBuffer.remove(start, removeEnd) } catch {}
      return
    }
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
  // kills ffmpeg (TranscodeService ensure block on ClientDisconnected).
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
    this.stopHlsSession()
    this.stopProgressTracking()
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
      url.searchParams.set("show_imdb_id", this.imdbIdValue)
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

    const rawUrl = this.extractRawUrl()
    if (!rawUrl) return

    try {
      const url = new URL(this.tracksUrlValue, window.location.origin)
      url.searchParams.set("url", rawUrl)
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
    // Only resume if the stall was caused by the subtitle hold, not by
    // the user pausing in the meantime.  Without this check, a subtitle
    // load completing while the user has paused would auto-resume.
    if (this.userPaused) return
    const playPromise = this.videoTarget.play()
    if (playPromise?.catch) playPromise.catch(() => {})
  }

  removeTextSubtitleTrack() {
    this.clearSubtitleCues()
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
    // A cleared cue buffer cannot keep claiming its old window is loaded.
    // Cancel stale responses and force the next overlay update to fetch the
    // new playback timeline.
    this.subtitleLoadToken += 1
    this.abortSubtitleLoad()
    this.subtitleLoading = false
    this.resetSubtitleWindow()
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

  startProgressTracking() {
    this.progressAbortController = null
    this.progressInterval = setInterval(() => {
      if (this.videoTarget && !this.videoTarget.paused) this.saveProgress()
    }, 5000)
  }

  stopProgressTracking() {
    if (this.progressInterval) {
      clearInterval(this.progressInterval)
      this.progressInterval = null
    }
    if (this.progressAbortController) {
      this.progressAbortController.abort()
      this.progressAbortController = null
    }
  }

  async saveProgress(completed = false) {
    const video = this.videoTarget
    if (!video) return
    const durationSeconds = this.saveableDurationSeconds()
    const progressSeconds = completed && durationSeconds > 0
      ? durationSeconds
      : Math.floor(this.currentPlaybackPosition())
    if (progressSeconds <= 0) return

    // Abort any previous in-flight progress request.  Without this,
    // slow requests pile up and exhaust the browser's 6-connection
    // per-origin limit, starving the video stream download.
    if (this.progressAbortController) {
      this.progressAbortController.abort()
    }
    this.progressAbortController = new AbortController()

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
        }),
        signal: this.progressAbortController.signal
      })
    } catch (e) {
      if (e.name !== "AbortError") console.warn("Progress save failed:", e)
    } finally {
      if (this.progressAbortController?.signal.aborted) {
        this.progressAbortController = null
      }
    }
  }

  saveProgressSync() {
    const payload = this.progressPayload()
    if (!payload) return

    const csrfToken = document.querySelector("meta[name='csrf-token']")?.content
    fetch(`/streaming/play/progress`, {
      method: "PATCH",
      headers: { "Content-Type": "application/json", "X-CSRF-Token": csrfToken },
      body: JSON.stringify(payload),
      keepalive: true
    })
  }
  progressPayload() {
    const video = this.videoTarget
    if (!video) return null
    const progressSeconds = Math.floor(this.currentPlaybackPosition())
    const durationSeconds = this.saveableDurationSeconds()
    if (progressSeconds <= 0) return null

    return {
      imdb_id: this.imdbIdValue,
      progress_seconds: progressSeconds,
      duration_seconds: durationSeconds,
      type: this.typeValue,
      season: this.seasonValue,
      episode: this.episodeValue,
      title: this.titleValue || null,
      poster_url: this.posterUrlValue || null
    }
  }

  saveableDurationSeconds() {
    const duration = Math.floor(this.effectiveDuration())
    return duration > 0 ? duration : 0
  }
}
