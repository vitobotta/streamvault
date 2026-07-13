import assert from "node:assert/strict"
import fs from "node:fs"
import test from "node:test"
import vm from "node:vm"

const source = fs
  .readFileSync(new URL("../../app/javascript/controllers/video_player_controller.js", import.meta.url), "utf8")
  .replace(/^import .*$/m, "class Controller {}")
  .replace("export default class", "globalThis.VideoPlayerController = class")

let fetchHandler = async () => ({ ok: true })

const context = vm.createContext({
  AbortController,
  URL,
  URLSearchParams,
  clearTimeout,
  console,
  setTimeout,
  document: { querySelector: () => ({ content: "csrf-token" }) },
  fetch: (...args) => fetchHandler(...args),
  window: { location: { origin: "https://streamvault.test" } }
})
vm.runInContext(source, context)
const VideoPlayerController = context.VideoPlayerController

function timeRanges(ranges) {
  return {
    length: ranges.length,
    start: (index) => ranges[index][0],
    end: (index) => ranges[index][1]
  }
}

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

test("remux seek uses the preceding keyframe and skips pre-roll locally", async () => {
  const player = new VideoPlayerController()
  player.remuxLoadToken = 0
  player.playbackId = "playback-1"
  player.streamingUrlValue = "/transcode?url=https%3A%2F%2Fexample.test%2Fmovie.mkv"
  player.tracksData = { remux_direct_url: "/transcode?url=https%3A%2F%2Fexample.test%2Fmovie.mkv&remux=1" }
  player.selectedAudioStream = null
  player.selectedSubtitleStream = null
  player.subtitleTracks = []
  player.element = { dataset: {} }
  player.loadRemuxSeekPlan = async () => ({ copy_safe: true, anchor_seconds: 120, skip_seconds: 5 })
  let loadArgs
  player.loadRemuxSource = (...args) => { loadArgs = args }

  await player.loadRemuxAt(125)

  assert.equal(player.startSecondsValue, 120)
  assert.match(loadArgs[0], /start_seconds=120/)
  assert.match(loadArgs[0], /remux=1/)
  assert.equal(loadArgs[1], 5)
  assert.equal(loadArgs[2], 125)
})

test("failed remux seek planning falls back to an exact MSE transcode", async () => {
  const player = new VideoPlayerController()
  player.remuxLoadToken = 0
  player.streamingUrlValue = "/transcode?url=https%3A%2F%2Fexample.test%2Fmovie.mkv"
  player.element = { dataset: {} }
  player.selectedAudioStream = null
  player.selectedSubtitleStream = null
  player.subtitleTracks = []
  player.loadRemuxSeekPlan = async () => null
  let fallbackUrl
  player.setupMseSource = (url) => { fallbackUrl = url }

  await player.loadRemuxAt(125)

  assert.equal(player.directPlayActive, false)
  assert.equal(player.remuxDirectPlay, false)
  assert.match(fallbackUrl, /start_seconds=125/)
})

test("remux timeline seek pauses old-position playback before keyframe planning", () => {
  const player = new VideoPlayerController()
  let pauseCount = 0
  let planCount = 0
  player.element = { dataset: {} }
  player.videoTarget = { pause: () => { pauseCount += 1 } }
  player.isHls = () => false
  player.isRemuxDirectPlay = () => true
  player.showSeekingOverlay = () => {}
  player.stopProgressWatchdog = () => {}
  player.clearSubtitleCues = () => {}
  player.reloadTextSubtitlesAt = () => {}
  player.resetProgressBaseline = () => {}
  player.loadRemuxAt = () => {
    assert.equal(pauseCount, 1)
    planCount += 1
  }

  player.restartPlaybackAt(125)

  assert.equal(player.isSeeking, true)
  assert.equal(pauseCount, 1)
  assert.equal(planCount, 1)
})

test("a newer remux seek aborts the previous keyframe plan", () => {
  const player = new VideoPlayerController()
  const signals = []
  player.remuxLoadToken = 0
  player.remuxSeekController = null
  player.remuxLoadCleanup = null
  player.loadRemuxSeekPlan = (_target, signal) => {
    signals.push(signal)
    return new Promise(() => {})
  }

  void player.loadRemuxAt(100)
  void player.loadRemuxAt(200)

  assert.equal(signals.length, 2)
  assert.equal(signals[0].aborted, true)
  assert.equal(signals[1].aborted, false)
  player.cancelRemuxLoad()
})

test("remux source starts with a playable native buffer instead of waiting for a deep cushion", () => {
  const player = new VideoPlayerController()
  const listeners = {}
  let ranges = [[0, 0.4]]
  let playCount = 0
  const buffered = {
    get length() { return ranges.length },
    start: (index) => ranges[index][0],
    end: (index) => ranges[index][1]
  }
  player.remuxLoadToken = 1
  player.remuxLoadCleanup = null
  player.videoTarget = {
    buffered,
    currentTime: 0,
    addEventListener: (name, callback) => { listeners[name] = callback },
    removeEventListener: (name, callback) => {
      if (listeners[name] === callback) delete listeners[name]
    },
    load: () => {},
    play: () => { playCount += 1; return Promise.resolve() }
  }

  player.loadRemuxSource("/transcode?remux=1", 0, 0, 1)
  listeners.loadeddata()
  assert.equal(playCount, 0)

  ranges = [[0, 0.6]]
  listeners.progress()
  assert.equal(playCount, 1)
})

test("confirmed MSE waiting explicitly pauses for the rebuffer gate", () => {
  const player = new VideoPlayerController()
  let pauseCount = 0
  player.videoTarget = {
    paused: false,
    pause: () => { pauseCount += 1; player.videoTarget.paused = true }
  }
  player.userPaused = false
  player.stopProgressWatchdog = () => {}
  player.showBufferingOverlay = () => {}
  player.rebufferDeadlineTimer = null

  player.beginSystemRebuffer()

  assert.equal(pauseCount, 1)
  assert.equal(player.systemRebufferPaused, true)
  assert.equal(player.isStalled, true)
  player.clearSystemRebufferGate()
})

test("tiny MSE append cannot bypass the rebuffer high-water gate", () => {
  const player = new VideoPlayerController()
  let playCount = 0
  const buffered = timeRanges([[0, 2]])
  player.sourceBuffer = { buffered }
  player.videoTarget = {
    buffered,
    currentTime: 0,
    ended: false,
    play: () => { playCount += 1; return Promise.resolve() }
  }
  player.playbackStarted = true
  player.systemRebufferPaused = true
  player.isStalled = true
  player.userPaused = false
  player.isSeeking = false
  player.rebufferDeadline = Date.now() + 10_000
  player.rebufferDeadlineTimer = null

  player.maybeStartPlayback(false)
  assert.equal(playCount, 0)
  assert.equal(player.systemRebufferPaused, true)

  player.maybeStartPlayback(true)
  assert.equal(playCount, 1)
  assert.equal(player.systemRebufferPaused, false)
})

test("a tiny append and modest progress during MSE debounce still enter the rebuffer gate", async () => {
  const player = new VideoPlayerController()
  let bufferedAhead = false
  let rebufferCount = 0
  let watchdogCount = 0
  player.videoTarget = { currentTime: 0 }
  player.bufferingOverlayTimer = null
  player.playbackStarted = true
  player.isHls = () => false
  player.isDirectPlay = () => false
  player.hasBufferedAhead = () => bufferedAhead
  player.bufferedAheadOfCurrent = () => bufferedAhead ? 2 : 0
  player.beginSystemRebuffer = () => { rebufferCount += 1 }
  player.startStallWatchdog = () => { watchdogCount += 1 }

  player.onVideoWaiting()
  bufferedAhead = true
  player.videoTarget.currentTime = 0.2
  await new Promise((resolve) => setTimeout(resolve, 250))

  assert.equal(rebufferCount, 1)
  assert.equal(watchdogCount, 1)
})

test("a dry MSE wait can resolve after reaching the full rebuffer high-water mark", async () => {
  const player = new VideoPlayerController()
  let bufferedAhead = false
  let rebufferCount = 0
  player.videoTarget = { currentTime: 0 }
  player.bufferingOverlayTimer = null
  player.playbackStarted = true
  player.isHls = () => false
  player.isDirectPlay = () => false
  player.hasBufferedAhead = () => bufferedAhead
  player.bufferedAheadOfCurrent = () => bufferedAhead ? 10 : 0
  player.beginSystemRebuffer = () => { rebufferCount += 1 }
  player.startStallWatchdog = () => {}

  player.onVideoWaiting()
  bufferedAhead = true
  player.videoTarget.currentTime = 0.2
  await new Promise((resolve) => setTimeout(resolve, 250))

  assert.equal(rebufferCount, 0)
})

test("an advancing remux wait remains browser-managed instead of forcing a system pause", async () => {
  const player = new VideoPlayerController()
  let pauseCount = 0
  let rebufferCount = 0
  const buffered = timeRanges([[0, 2.2]])
  player.videoTarget = {
    buffered,
    currentTime: 0,
    paused: false,
    pause: () => { pauseCount += 1; player.videoTarget.paused = true }
  }
  player.userPaused = false
  player.bufferingOverlayTimer = null
  player.isHls = () => false
  player.isDirectPlay = () => true
  player.isRemuxDirectPlay = () => true
  player.beginSystemRebuffer = () => { rebufferCount += 1 }
  player.showBufferingOverlay = () => {}
  player.startProgressWatchdog = () => {}

  player.onVideoWaiting()
  player.videoTarget.currentTime = 0.2
  await new Promise((resolve) => setTimeout(resolve, 1550))

  assert.equal(pauseCount, 0)
  assert.equal(rebufferCount, 0)
  assert.equal(player.systemRebufferPaused, undefined)
})

test("quota failure retries the exact fragment instead of dropping it", () => {
  const player = new VideoPlayerController()
  const fragment = new ArrayBuffer(32)
  let appended
  let retryCount = 0
  player.sourceBuffer = {
    updating: false,
    buffered: timeRanges([]),
    appendBuffer: () => {
      const error = new Error("quota")
      error.name = "QuotaExceededError"
      throw error
    }
  }
  player.videoTarget = { currentTime: 0, buffered: timeRanges([]) }
  player.bufferAppending = false
  player.pendingAppendBuffer = null
  player.mseQuotaErrorCount = 0
  player.quotaRetryTimer = null
  player.extractCompleteBoxes = () => fragment
  player.evictForQuota = () => false
  player.scheduleQuotaRetry = () => { retryCount += 1 }
  player.maybeStartPlayback = () => {}
  player.reportStall = () => {}

  player.flushBufferQueue()
  assert.equal(player.pendingAppendBuffer, fragment)
  assert.equal(retryCount, 1)

  player.sourceBuffer.appendBuffer = (value) => { appended = value }
  player.flushBufferQueue()
  assert.equal(appended, fragment)
  assert.equal(player.pendingAppendBuffer, null)
})

test("full native buffer suppresses false download-stall recovery", () => {
  const player = new VideoPlayerController()
  const now = Date.now()
  let recoveryCount = 0
  player.progressWatchdogArmed = true
  player.streamRecoveryActive = false
  player.isSeeking = false
  player.userPaused = false
  player.playbackStarted = true
  player.videoTarget = { paused: false, ended: false, currentTime: 50 }
  player.lastProgressTime = now
  player.lastProgressPosition = 50
  player.lastProgressEventTime = now - 16_000
  player.lastBufferDataTime = now - 16_000
  player.lastBufferEnd = 100
  player.knownDuration = 300
  player.isDirectPlay = () => true
  player.currentBufferEnd = () => 100
  player.bufferedAheadOfCurrent = () => 30
  player.playbackTimelineOffset = () => 0
  player.handleStreamStall = () => { recoveryCount += 1 }

  player.checkProgressStall()

  assert.equal(recoveryCount, 0)
})

test("advancing remux playback is not reconnected when native progress events are quiet", () => {
  const player = new VideoPlayerController()
  const now = Date.now()
  let recoveryCount = 0
  player.progressWatchdogArmed = true
  player.streamRecoveryActive = false
  player.isSeeking = false
  player.userPaused = false
  player.playbackStarted = true
  player.videoTarget = { paused: false, ended: false, currentTime: 103, readyState: 4 }
  player.lastProgressTime = now - 21_000
  player.lastProgressPosition = 100
  player.lastProgressEventTime = now - 16_000
  player.lastBufferDataTime = now - 16_000
  player.lastBufferEnd = 105.4
  player.isDirectPlay = () => true
  player.currentBufferEnd = () => 105.4
  player.bufferedAheadOfCurrent = () => 2.4
  player.handleStreamStall = () => { recoveryCount += 1 }

  player.checkProgressStall()

  assert.equal(recoveryCount, 0)
  assert.equal(player.lastProgressPosition, 103)
})

test("quiet direct-play download still recovers once playback is genuinely starved", () => {
  const player = new VideoPlayerController()
  const now = Date.now()
  let recoveryEvent
  player.progressWatchdogArmed = true
  player.streamRecoveryActive = false
  player.isSeeking = false
  player.userPaused = false
  player.playbackStarted = true
  player.videoTarget = { paused: false, ended: false, currentTime: 100, readyState: 2 }
  player.lastProgressTime = now - 10_000
  player.lastProgressPosition = 100
  player.lastProgressEventTime = now - 16_000
  player.lastBufferDataTime = now - 16_000
  player.lastBufferEnd = 100
  player.isDirectPlay = () => true
  player.currentBufferEnd = () => 100
  player.bufferedAheadOfCurrent = () => 0
  player.handleStreamStall = (event) => { recoveryEvent = event }

  player.checkProgressStall()

  assert.equal(recoveryEvent, "download_stall")
})

test("native direct reconnect seeks back to the absolute playhead", () => {
  const player = new VideoPlayerController()
  const listeners = {}
  let playCount = 0
  player.playbackId = "playback-1"
  player.directStreamUrlValue = "/direct_stream?url=https%3A%2F%2Fexample.test%2Fmovie.mp4"
  player.element = { dataset: {} }
  player.currentPlaybackPosition = () => 120
  player.isRemuxDirectPlay = () => false
  player.showBufferingOverlay = () => {}
  player.clearStallWatchdog = () => {}
  player.stopProgressWatchdog = () => {}
  player.startStallWatchdog = () => {}
  player.videoTarget = {
    currentTime: 0,
    addEventListener: (name, callback) => { listeners[name] = callback },
    load: () => {},
    play: () => { playCount += 1; return Promise.resolve() }
  }

  player.reconnectDirectPlay()
  listeners.loadedmetadata()
  assert.equal(player.videoTarget.currentTime, 120)
  listeners.seeked()
  assert.equal(playCount, 1)
})

test("stall telemetry sends the correlated JSON request body", () => {
  const player = new VideoPlayerController()
  let request
  fetchHandler = async (url, options) => { request = { url, options }; return { ok: true } }
  player.playbackId = "playback-1"
  player.videoTarget = {
    readyState: 3,
    networkState: 2,
    paused: false,
    ended: false,
    buffered: timeRanges([[0, 45]])
  }
  player.sourceBuffer = null
  player.fmp4BufferSize = 1024
  player.pendingAppendBuffer = null
  player.mseQuotaErrorCount = 1
  player.systemRebufferPaused = false
  player.streamRecoveryAttempts = 2
  player.startSecondsValue = 100
  player.tracksData = { video_codec: "hevc", video_width: 3840, video_height: 2160 }
  player.currentPlaybackPosition = () => 125
  player.bufferedAheadOfCurrent = () => 20
  player.playbackPath = () => "mse_transcode"

  player.reportStall("mse_quota")

  const body = JSON.parse(request.options.body)
  assert.equal(request.url, "/streaming/stall_telemetry")
  assert.equal(body.playback_id, "playback-1")
  assert.equal(body.event, "mse_quota")
  assert.equal(body.path, "mse_transcode")
  assert.equal(body.mse_quota_errors, 1)
  assert.deepEqual(body.buffered_ranges, [[0, 45]])
})
