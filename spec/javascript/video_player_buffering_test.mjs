import assert from "node:assert/strict"
import test from "node:test"

import { createVideoPlayerHarness } from "./support/video_player_harness.mjs"

const { harness, context, VideoPlayerController, timeRanges } = createVideoPlayerHarness()

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

test("premature MSE end retains a substantial cushion before recovery", () => {
  const player = new VideoPlayerController()
  let immediateRecoveries = 0
  let scheduledRecoveries = 0
  const buffered = timeRanges([[0, 129.9]])
  player.knownDuration = 1000
  player.startSecondsValue = 0
  player.videoTarget = { currentTime: 100, duration: 1000, buffered }
  player.sourceBuffer = { updating: false, buffered }
  player.playbackStarted = true
  player.bufferedAheadOfCurrent = () => 29.9
  player.handleStreamStall = () => { immediateRecoveries += 1 }
  player.schedulePrematureEndRecovery = () => { scheduledRecoveries += 1 }

  player.handlePrematureStreamEnd()

  assert.equal(immediateRecoveries, 0)
  assert.equal(scheduledRecoveries, 1)
})

test("premature MSE end reconnects immediately only when its cushion is nearly dry", () => {
  const player = new VideoPlayerController()
  let recoveryEvent
  const buffered = timeRanges([[0, 104.9]])
  player.knownDuration = 1000
  player.startSecondsValue = 0
  player.videoTarget = { currentTime: 100, duration: 1000, buffered }
  player.sourceBuffer = { updating: false, buffered }
  player.playbackStarted = true
  player.bufferedAheadOfCurrent = () => 4.9
  player.handleStreamStall = (event) => { recoveryEvent = event }

  player.handlePrematureStreamEnd()

  assert.equal(recoveryEvent, "premature_end")
})

test("completed MSE response finalizes the media source", () => {
  const player = new VideoPlayerController()
  let finalized = false
  const buffered = timeRanges([[0, 99]])
  player.knownDuration = 100
  player.startSecondsValue = 0
  player.videoTarget = { currentTime: 90, duration: 100, buffered }
  player.sourceBuffer = { updating: false, buffered }
  player.mediaSource = {
    readyState: "open",
    endOfStream() {
      finalized = true
      this.readyState = "ended"
    }
  }
  player.playbackStarted = true
  player.clearStallWatchdog = () => {}

  player.handlePrematureStreamEnd()

  assert.equal(finalized, true)
  assert.equal(player.mseFetchEnded, false)
})

test("ended shows save completion before navigating to autoplay resume", async () => {
  const player = new VideoPlayerController()
  let completedSave
  context.window.location.href = ""
  player.typeValue = "show"
  player.imdbIdValue = "tt0903747"
  player.resumeUrlValue = "/streaming/resume"
  player.saveProgress = async (completed) => { completedSave = completed }

  await player.onVideoEnded()

  assert.equal(completedSave, true)
  assert.match(context.window.location.href, /show_imdb_id=tt0903747/)
  assert.match(context.window.location.href, /autoplay=1/)
})

test("completed progress persists the full known duration", async () => {
  const player = new VideoPlayerController()
  let payload
  harness.fetchHandler = async (_url, options) => {
    payload = JSON.parse(options.body)
    return { ok: true }
  }
  player.videoTarget = { currentTime: 97, duration: 100 }
  player.knownDuration = 100
  player.startSecondsValue = 0
  player.directPlayActive = false
  player.remuxDirectPlay = false
  player.progressAbortController = null
  player.imdbIdValue = "tt0903747"
  player.typeValue = "show"
  player.seasonValue = "1"
  player.episodeValue = "1"

  await player.saveProgress(true)

  assert.equal(payload.progress_seconds, 100)
  assert.equal(payload.duration_seconds, 100)
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

test("normal MSE back-buffer eviction is batched instead of running after every append", () => {
  const player = new VideoPlayerController()
  let ranges = [[0, 100]]
  const removals = []
  const buffered = {
    get length() { return ranges.length },
    start: (index) => ranges[index][0],
    end: (index) => ranges[index][1]
  }
  player.videoTarget = { currentTime: 61 }
  player.sourceBuffer = {
    updating: false,
    buffered,
    remove: (start, end) => { removals.push([start, end]) }
  }

  player.evictOldBuffer()
  assert.deepEqual(removals, [[0, 31]])

  ranges = [[31, 101]]
  player.videoTarget.currentTime = 62
  player.evictOldBuffer()
  player.videoTarget.currentTime = 90.9
  player.evictOldBuffer()
  assert.deepEqual(removals, [[0, 31]])

  player.videoTarget.currentTime = 91
  player.evictOldBuffer()
  assert.deepEqual(removals, [[0, 31], [31, 61]])
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
  harness.fetchHandler = async (url, options) => { request = { url, options }; return { ok: true } }
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
