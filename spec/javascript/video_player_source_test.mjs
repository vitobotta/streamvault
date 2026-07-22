import assert from "node:assert/strict"
import test from "node:test"

import { createVideoPlayerHarness } from "./support/video_player_harness.mjs"

const { harness, context, VideoPlayerController, timeRanges } = createVideoPlayerHarness()

test("native direct play uses absolute media time while fragment streams add their offset", () => {
  const player = new VideoPlayerController()
  player.videoTarget = { currentTime: 300 }
  player.startSecondsValue = 300
  player.directPlayActive = true
  player.remuxDirectPlay = false

  assert.equal(player.currentPlaybackPosition(), 300)

  player.remuxDirectPlay = true
  assert.equal(player.currentPlaybackPosition(), 600)

  player.directPlayActive = false
  player.remuxDirectPlay = false
  assert.equal(player.currentPlaybackPosition(), 600)
})

test("direct-play errors preserve the absolute playhead when falling back", () => {
  const player = new VideoPlayerController()
  player.videoTarget = {
    currentTime: 360,
    currentSrc: "https://streamvault.test/direct",
    error: { code: 3, message: "decode failed" },
    src: "https://streamvault.test/direct"
  }
  player.startSecondsValue = 300
  player.directPlayActive = true
  player.remuxDirectPlay = false
  player.hlsSessionId = null
  player.element = {
    dataset: { videoPlayerStreamingUrlValue: "/transcode?url=https%3A%2F%2Fexample.test%2Fmovie.mp4&start_seconds=300" }
  }

  let restartPosition
  player.restartPlaybackAt = (position) => { restartPosition = position }
  player.onVideoError({})

  assert.equal(restartPosition, 360)
  assert.equal(player.directPlayActive, false)
})

test("known page duration skips the redundant remote duration probe", async () => {
  const player = new VideoPlayerController()
  let fetchCount = 0
  harness.fetchHandler = async () => {
    fetchCount += 1
    return { json: async () => ({ duration: 8_888 }) }
  }
  player.knownDuration = 8_888

  await player.probeDuration()

  assert.equal(fetchCount, 0)
})

test("bitmap subtitle selection leaves native direct play for the transcode path", () => {
  const player = new VideoPlayerController()
  player.hlsSessionId = null
  player.directPlayActive = true
  player.remuxDirectPlay = false
  player.videoTarget = { currentTime: 300 }
  player.startSecondsValue = 0
  player.element = { dataset: {} }
  player.streamingUrlValue = "/transcode?url=https%3A%2F%2Fexample.test%2Fmovie.mp4"
  player.selectedAudioStream = null
  player.selectedSubtitleStream = "4"
  player.subtitleTracks = [{ index: 4, text_supported: false }]
  player.showSeekingOverlay = () => {}
  player.clearSubtitleCues = () => {}
  player.reloadTextSubtitlesAt = () => {}

  let transcodeUrl
  player.setupMseSource = (url) => { transcodeUrl = url }
  player.restartPlaybackAt(420)

  assert.equal(player.directPlayActive, false)
  assert.match(transcodeUrl, /start_seconds=420/)
  assert.match(transcodeUrl, /subtitle_stream=4/)
})

test("clearing cues cancels stale loads and invalidates the remembered window", () => {
  const player = new VideoPlayerController()
  let aborted = false
  player.subtitleLoadToken = 7
  player.subtitleAbortController = { abort: () => { aborted = true } }
  player.subtitleLoading = true
  player.subtitleWindowStart = 100
  player.subtitleWindowEnd = 115
  player.subtitleCues = [{ start: 101, end: 103, text: "Hello" }]
  player.hasSubtitleOverlayTarget = false

  player.clearSubtitleCues()

  assert.equal(aborted, true)
  assert.equal(player.subtitleLoadToken, 8)
  assert.equal(player.subtitleLoading, false)
  assert.equal(player.subtitleWindowStart, null)
  assert.equal(player.subtitleWindowEnd, null)
  assert.equal(player.subtitleCues.length, 0)
})

test("HLS receives selected audio and bitmap subtitle tracks but not text overlays", () => {
  const player = new VideoPlayerController()
  player.selectedAudioStream = "2"
  player.selectedSubtitleStream = "4"
  player.subtitleTracks = [{ index: 4, text_supported: false }]

  const bitmapParams = new URLSearchParams()
  player.appendSelectedHlsTracks(bitmapParams)
  assert.equal(bitmapParams.get("audio_stream"), "2")
  assert.equal(bitmapParams.get("subtitle_stream"), "4")

  player.selectedSubtitleStream = "3"
  player.subtitleTracks = [{ index: 3, text_supported: true }]
  const textParams = new URLSearchParams()
  player.appendSelectedHlsTracks(textParams)
  assert.equal(textParams.get("audio_stream"), "2")
  assert.equal(textParams.has("subtitle_stream"), false)
})

test("starting HLS clears an installed play prompt before its fetch settles", async () => {
  const player = new VideoPlayerController()
  const calls = []
  let settleFetch
  const previousFetchHandler = harness.fetchHandler
  harness.fetchHandler = async () => {
    calls.push("fetch")
    return new Promise((resolve) => { settleFetch = resolve })
  }
  player.directUrlValue = "https://example.test/movie.mkv"
  player.cancelRemuxLoad = () => { calls.push("cancel-remux") }
  player.clearHlsPlayPrompt = () => { calls.push("clear-prompt") }

  try {
    const start = player.startHlsPlayback()

    assert.deepEqual(calls, ["cancel-remux", "clear-prompt", "fetch"])

    settleFetch({ ok: false, status: 503 })
    await start
  } finally {
    harness.fetchHandler = previousFetchHandler
  }
})

test("iOS loads track metadata before starting HLS playback", async () => {
  const player = new VideoPlayerController()
  const calls = []
  player.streamingUrlValue = "/transcode?url=https%3A%2F%2Fexample.test%2Fmovie.mkv"
  player.isIOS = () => true
  player.loadMediaTracks = async () => { calls.push("tracks") }
  player.startHlsPlayback = () => { calls.push("hls") }

  await player.ensureVideoSource()

  assert.deepEqual(calls, ["tracks", "hls"])
})

test("macOS Safari uses native HLS when direct play is unavailable", async () => {
  const player = new VideoPlayerController()
  const calls = []
  player.streamingUrlValue = "/transcode?url=https%3A%2F%2Fexample.test%2Fmovie.mkv"
  player.mseSupported = true
  player.isIOS = () => false
  player.isSafari = () => true
  player.loadMediaTracks = async () => { calls.push("tracks") }
  player.directPlayEligible = () => false
  player.startHlsPlayback = () => { calls.push("hls") }
  player.startRemuxDirectPlay = () => { calls.push("remux") }
  player.setupMseSource = () => { calls.push("mse") }

  await player.ensureVideoSource()

  assert.deepEqual(calls, ["tracks", "hls"])
})

test("Safari HLS play prompt retries playback from a user gesture", async () => {
  const player = new VideoPlayerController()
  const listeners = {}
  const attributes = {}
  const classes = new Set()
  const spinner = { style: {} }
  const label = { textContent: "" }
  const sub = { textContent: "" }
  const overlay = {
    classList: {
      add: (...values) => values.forEach((value) => classes.add(value)),
      remove: (...values) => values.forEach((value) => classes.delete(value))
    },
    setAttribute: (name, value) => { attributes[name] = value },
    removeAttribute: (name) => { delete attributes[name] },
    querySelector: (selector) => {
      if (selector === ".animate-spin") return spinner
      if (selector === "span.text-white") return label
      return sub
    },
    addEventListener: (name, callback) => { listeners[name] = callback },
    removeEventListener: (name, callback) => {
      if (listeners[name] === callback) delete listeners[name]
    }
  }
  let playCount = 0
  player.hasStartupOverlayTarget = true
  player.startupOverlayTarget = overlay
  player.videoTarget = {
    play: () => {
      playCount += 1
      return Promise.resolve()
    }
  }
  player.hlsPlayPromptCleanup = null

  player.showHlsPlayPrompt()

  assert.equal(attributes.role, "button")
  assert.equal(attributes.tabindex, "0")
  assert.equal(label.textContent, "Play")
  assert.equal(spinner.style.display, "none")

  listeners.click({ type: "click", preventDefault() {}, stopPropagation() {} })
  await new Promise((resolve) => setTimeout(resolve, 0))

  assert.equal(playCount, 1)
  assert.equal(attributes.role, "status")
  assert.equal(classes.has("opacity-0"), true)
  assert.equal(attributes["aria-hidden"], "true")
  assert.equal(listeners.click, undefined)
})

test("macOS Safari explains autoplay settings only on the first policy block", async () => {
  const player = new VideoPlayerController()
  const overlayAttributes = {}
  const overlayClasses = new Set()
  const statusClasses = new Set()
  const guidanceClasses = new Set(["hidden"])
  const buttonListeners = {}
  const spinner = { style: {} }
  const label = { textContent: "" }
  const sub = { textContent: "" }
  const storage = new Map()
  const previousStorage = context.window.localStorage
  let focused = false
  let playCount = 0

  const classList = (classes) => ({
    add: (...values) => values.forEach((value) => classes.add(value)),
    remove: (...values) => values.forEach((value) => classes.delete(value))
  })
  const overlay = {
    classList: classList(overlayClasses),
    setAttribute: (name, value) => { overlayAttributes[name] = value },
    removeAttribute: (name) => { delete overlayAttributes[name] },
    querySelector: (selector) => {
      if (selector === ".animate-spin") return spinner
      if (selector === "span.text-white") return label
      return sub
    }
  }
  const playButton = {
    addEventListener: (name, callback) => { buttonListeners[name] = callback },
    removeEventListener: (name, callback) => {
      if (buttonListeners[name] === callback) delete buttonListeners[name]
    },
    focus: () => { focused = true }
  }
  context.window.localStorage = {
    getItem: (key) => storage.get(key) ?? null,
    setItem: (key, value) => storage.set(key, value)
  }
  player.isSafari = () => true
  player.isIOS = () => false
  player.hasStartupOverlayTarget = true
  player.startupOverlayTarget = overlay
  player.hasStartupStatusTarget = true
  player.startupStatusTarget = { classList: classList(statusClasses) }
  player.hasAutoplayGuidanceTarget = true
  player.autoplayGuidanceTarget = { classList: classList(guidanceClasses) }
  player.hasAutoplayPlayButtonTarget = true
  player.autoplayPlayButtonTarget = playButton
  player.videoTarget = {
    play: () => {
      playCount += 1
      return Promise.resolve()
    }
  }
  player.hlsPlayPromptCleanup = null

  try {
    player.handleHlsAutoplayFailure({ name: "NotAllowedError" })

    assert.equal(overlayAttributes.role, "dialog")
    assert.equal(overlayAttributes["aria-modal"], "true")
    assert.equal(statusClasses.has("hidden"), true)
    assert.equal(guidanceClasses.has("hidden"), false)
    assert.equal(focused, true)
    assert.equal(storage.get("streamvault:safari-autoplay-guidance-seen"), "1")
    assert.equal(player.shouldShowSafariAutoplayGuidance(), false)

    buttonListeners.click({ type: "click", preventDefault() {}, stopPropagation() {} })
    await new Promise((resolve) => setTimeout(resolve, 0))

    assert.equal(playCount, 1)
    assert.equal(overlayAttributes.role, "status")
    assert.equal(overlayClasses.has("opacity-0"), true)
    assert.equal(overlayAttributes["aria-hidden"], "true")
    assert.equal(guidanceClasses.has("hidden"), true)
    assert.equal(buttonListeners.click, undefined)
  } finally {
    context.window.localStorage = previousStorage
  }
})

test("direct-play hint primes the native MP4 while track validation is pending", async () => {
  const player = new VideoPlayerController()
  const calls = []
  let finishTracks
  player.streamingUrlValue = "/transcode?url=https%3A%2F%2Fexample.test%2Fmovie.mp4"
  player.directPlayHintValue = true
  player.mseSupported = true
  player.isIOS = () => false
  player.loadMediaTracks = () => {
    calls.push("tracks")
    return new Promise((resolve) => { finishTracks = resolve })
  }
  player.primeDirectPlay = () => { calls.push("prime") }
  player.directPlayEligible = () => true
  player.startDirectPlay = () => { calls.push("direct") }

  const sourcePromise = player.ensureVideoSource()
  assert.deepEqual(calls, ["tracks", "prime"])

  finishTracks()
  await sourcePromise
  assert.deepEqual(calls, ["tracks", "prime", "direct"])
})

test("native direct-play priming starts resource selection without forcing load", () => {
  const player = new VideoPlayerController()
  let loadCount = 0
  player.playbackId = "playback-1"
  player.directStreamUrlValue = "/direct_stream?url=https%3A%2F%2Fexample.test%2Fmovie.mp4"
  player.selectedAudioStream = null
  player.selectedSubtitleStream = null
  player.videoTarget = {
    autoplay: true,
    preload: "none",
    src: "",
    load: () => { loadCount += 1 }
  }

  player.primeDirectPlay()

  assert.equal(player.videoTarget.autoplay, false)
  assert.equal(player.videoTarget.preload, "auto")
  assert.match(player.videoTarget.src, /playback_id=playback-1/)
  assert.equal(loadCount, 0)
})

test("native direct play assigns its source without restarting it with load", () => {
  const player = new VideoPlayerController()
  let loadCount = 0
  let playCount = 0
  player.playbackId = "playback-1"
  player.directStreamUrlValue = "/direct_stream?url=https%3A%2F%2Fexample.test%2Fmovie.mp4"
  player.startSecondsValue = 0
  player.mediaSource = null
  player.fetchController = null
  player.videoTarget = {
    autoplay: true,
    readyState: 0,
    src: "",
    addEventListener: () => {},
    load: () => { loadCount += 1 },
    play: () => { playCount += 1; return Promise.resolve() }
  }

  player.startDirectPlay()

  assert.match(player.videoTarget.src, /playback_id=playback-1/)
  assert.equal(loadCount, 0)
  assert.equal(playCount, 1)
})

test("MSE fallback creates a High Profile Level 4.0 AVC SourceBuffer", () => {
  const player = new VideoPlayerController()
  let mediaSource
  let sourceBufferMime
  let fetchedUrl
  const sourceBuffer = {
    mode: null,
    addEventListener: () => {}
  }
  const OriginalMediaSource = context.MediaSource
  const originalCreateObjectUrl = context.URL.createObjectURL
  context.MediaSource = class {
    constructor() {
      mediaSource = this
      this.readyState = "closed"
    }

    addEventListener(name, callback) {
      this[name] = callback
    }

    addSourceBuffer(mime) {
      sourceBufferMime = mime
      return sourceBuffer
    }
  }
  context.URL.createObjectURL = () => "blob:streamvault-mse"

  try {
    player.fetchController = null
    player.videoTarget = { src: "" }
    player.mseSupported = true
    player.clearSystemRebufferGate = () => {}
    player.clearStallWatchdog = () => {}
    player.startStreamingFetch = (url) => { fetchedUrl = url }

    player.setupMseSource("/transcode?start_seconds=125")
    mediaSource.sourceopen()

    assert.equal(sourceBufferMime, 'video/mp4; codecs="avc1.640028,mp4a.40.2"')
    assert.equal(sourceBuffer.mode, "segments")
    assert.equal(fetchedUrl, "/transcode?start_seconds=125")
  } finally {
    context.MediaSource = OriginalMediaSource
    context.URL.createObjectURL = originalCreateObjectUrl
  }
})

test("HEVC MP4 direct play is selected only when the browser supports HEVC", () => {
  const player = new VideoPlayerController()
  player.directStreamUrlValue = "/direct_stream?url=movie.mp4"
  player.streamRecoveryAttempts = 0
  player.selectedAudioStream = null
  player.tracksData = { direct_playable: true, video_codec: "hevc" }
  player.burnedSubtitleSelected = () => false
  player.browserCanPlayCodec = () => false

  assert.equal(player.directPlayEligible(), false)

  player.browserCanPlayCodec = () => true
  assert.equal(player.directPlayEligible(), true)
})

test("Safari direct-plays HEVC only when the MP4 sample entry is hvc1", () => {
  const player = new VideoPlayerController()
  player.directStreamUrlValue = "/direct_stream?url=movie.mp4"
  player.streamRecoveryAttempts = 0
  player.selectedAudioStream = null
  player.burnedSubtitleSelected = () => false
  player.browserCanPlayCodec = () => true
  player.isSafari = () => true
  player.tracksData = { direct_playable: true, video_codec: "hevc", video_codec_tag: "hev1" }

  assert.equal(player.directPlayEligible(), false)

  player.tracksData.video_codec_tag = "hvc1"
  assert.equal(player.directPlayEligible(), true)
})

test("UHD HEVC skips native remux while 1080p HEVC keeps the fast path", () => {
  const player = new VideoPlayerController()
  player.streamRecoveryAttempts = 0
  player.burnedSubtitleSelected = () => false
  player.browserCanPlayCodec = () => true
  player.tracksData = {
    remux_direct_playable: true,
    video_codec: "hevc",
    video_width: 3840,
    video_height: 2160,
    video_pix_fmt: "yuv420p10le"
  }

  assert.equal(player.remuxDirectEligible(), false)

  player.tracksData.video_width = 1920
  player.tracksData.video_height = 1080
  assert.equal(player.remuxDirectEligible(), true)

  player.isSafari = () => true
  assert.equal(player.remuxDirectEligible(), false)
})

test("native direct network failure falls back to remux before video transcoding", () => {
  const player = new VideoPlayerController()
  let remuxStarts = 0
  player.videoTarget = {
    error: { code: 2, message: "network failed" },
    src: "/direct_stream",
    currentSrc: "/direct_stream",
    readyState: 0,
    networkState: 3
  }
  player.directPlayActive = true
  player.remuxDirectPlay = false
  player.streamRecoveryAttempts = 0
  player.tracksData = { remux_direct_playable: true, video_codec: "hevc" }
  player.element = { dataset: {} }
  player.currentPlaybackPosition = () => 120.9
  player.isHls = () => false
  player.burnedSubtitleSelected = () => false
  player.browserCanPlayCodec = () => true
  player.showBufferingOverlay = () => {}
  player.startRemuxDirectPlay = () => { remuxStarts += 1 }

  player.onVideoError({})

  assert.equal(remuxStarts, 1)
  assert.equal(player.startSecondsValue, 120)
  assert.equal(player.element.dataset.videoPlayerStartSecondsValue, "120")
})

test("Safari native playback errors fall back to HLS at the same position", () => {
  const player = new VideoPlayerController()
  let hlsStarts = 0
  let transcodeTarget
  player.videoTarget = {
    error: { code: 4, message: "" },
    src: "/transcode?remux=1",
    currentSrc: "/transcode?remux=1",
    readyState: 0,
    networkState: 3
  }
  player.directPlayActive = true
  player.remuxDirectPlay = true
  player.element = { dataset: {} }
  player.currentPlaybackPosition = () => 120.9
  player.isHls = () => false
  player.isSafari = () => true
  player.showBufferingOverlay = () => {}
  player.startHlsPlayback = () => { hlsStarts += 1 }
  player.restartPlaybackAt = (target) => { transcodeTarget = target }

  player.onVideoError({})

  assert.equal(hlsStarts, 1)
  assert.equal(transcodeTarget, undefined)
  assert.equal(player.startSecondsValue, 120)
  assert.equal(player.element.dataset.videoPlayerStartSecondsValue, "120")
})

test("native HEVC decode and unsupported-source errors bypass copy remux", () => {
  for (const code of [3, 4]) {
    const player = new VideoPlayerController()
    let remuxStarts = 0
    let transcodeTarget
    player.videoTarget = {
      error: { code, message: "cannot decode" },
      src: "/direct_stream",
      currentSrc: "/direct_stream",
      readyState: 0,
      networkState: 3
    }
    player.directPlayActive = true
    player.remuxDirectPlay = false
    player.streamRecoveryAttempts = 0
    player.tracksData = { remux_direct_playable: true, video_codec: "hevc" }
    player.element = {
      dataset: { videoPlayerStreamingUrlValue: "/transcode?url=movie.mp4" }
    }
    player.currentPlaybackPosition = () => 120.9
    player.isHls = () => false
    player.burnedSubtitleSelected = () => false
    player.browserCanPlayCodec = () => true
    player.startRemuxDirectPlay = () => { remuxStarts += 1 }
    player.restartPlaybackAt = (target) => { transcodeTarget = target }

    player.onVideoError({})

    assert.equal(remuxStarts, 0)
    assert.equal(transcodeTarget, 120)
    assert.equal(player.directPlayActive, false)
    assert.equal(player.remuxDirectPlay, false)
  }
})

