import assert from "node:assert/strict"
import test from "node:test"
import { createVideoPlayerHarness } from "./support/video_player_harness.mjs"
import { PlaybackRecoveryMonitor } from "../../app/javascript/player/playback_recovery_monitor.js"
import { MseBufferManager } from "../../app/javascript/player/mse_buffer_manager.js"

// Diagnostic contract for the playback micro-stall investigation. These
// fields are what turns "the video pauses sometimes" into a ranked cause:
// bytes actually read, the real Fetch error message, how long the read loop
// was parked, and whether a rebuffer or an eviction preceded the pause.

function captureReports(player) {
  const reports = []
  player.reportStall = (event, details = {}) => { reports.push([event, details]) }
  return reports
}

test("stream_error records bytes read, the error message and the read pause", async () => {
  const { harness, context, VideoPlayerController, timeRanges } = createVideoPlayerHarness()
  context.setTimeout = () => 0
  context.clearTimeout = () => {}
  const chunks = [new Uint8Array([1, 2, 3, 4]), new Uint8Array([5, 6, 7, 8])]
  harness.fetchHandler = async () => ({
    ok: true,
    body: {
      getReader: () => ({
        read: async () => {
          if (chunks.length) return { done: false, value: chunks.shift() }
          throw new TypeError("network error")
        }
      })
    }
  })
  const player = new VideoPlayerController()
  const reports = captureReports(player)
  Object.assign(player, {
    playbackId: "playback-1",
    playbackStarted: true,
    sourceToken: () => "test-owned-source",
    videoTarget: { currentTime: 12, buffered: timeRanges([]) },
    startStallWatchdog() {},
    waitForMseReadCapacity: async () => true,
    queueBufferChunk() {},
    handlePrematureStreamEnd() {}
  })

  await player.startStreamingFetch("/transcode?source=test-owned-source")

  assert.equal(reports.length, 1)
  const [event, details] = reports[0]
  assert.equal(event, "stream_error")
  assert.equal(details.fetch_error, "TypeError")
  assert.equal(details.fetch_error_message, "network error")
  assert.equal(details.first_chunk, false)
  assert.ok(details.last_chunk_age_ms >= 0)
  assert.equal(player.streamBytesRead, 8)
  // These counters ride along on every payload (see the monitor test below).
  assert.equal(player.readPauseCount, 0)
})

test("a body that ends cleanly is still reported as stream_end with its byte count", async () => {
  const { harness, context, VideoPlayerController, timeRanges } = createVideoPlayerHarness()
  context.setTimeout = () => 0
  context.clearTimeout = () => {}
  harness.fetchHandler = async () => ({
    ok: true,
    body: { getReader: () => ({ read: async () => ({ done: true }) }) }
  })
  const player = new VideoPlayerController()
  const reports = captureReports(player)
  Object.assign(player, {
    playbackId: "playback-1",
    playbackStarted: true,
    videoTarget: { currentTime: 0, buffered: timeRanges([]) },
    startStallWatchdog() {},
    waitForMseReadCapacity: async () => true,
    queueBufferChunk() {},
    handlePrematureStreamEnd() {}
  })

  await player.startStreamingFetch("/transcode?source=test-owned-source")

  assert.equal(reports.length, 1)
  assert.equal(reports[0][0], "stream_end")
  assert.equal(reports[0][1].first_chunk, true)
  assert.equal(player.streamBytesRead, 0)
})

test("time parked in the MSE capacity gate is counted, not hidden", async () => {
  const { harness, context, VideoPlayerController, timeRanges } = createVideoPlayerHarness()
  context.setTimeout = () => 0
  context.clearTimeout = () => {}
  harness.fetchHandler = async () => ({
    ok: true,
    body: {
      getReader: () => {
        let delivered = false
        return {
          read: async () => {
            if (!delivered) { delivered = true; return { done: false, value: new Uint8Array([1]) } }
            throw new TypeError("network error")
          }
        }
      }
    }
  })
  const player = new VideoPlayerController()
  const reports = captureReports(player)
  let gated = 0
  Object.assign(player, {
    playbackId: "playback-1",
    playbackStarted: true,
    videoTarget: { currentTime: 0, buffered: timeRanges([]) },
    startStallWatchdog() {},
    waitForMseReadCapacity: async () => {
      if (gated === 0) { gated = 1; await new Promise((resolve) => setTimeout(resolve, 25)) }
      return true
    },
    queueBufferChunk() {},
    handlePrematureStreamEnd() {}
  })

  await player.startStreamingFetch("/transcode?source=test-owned-source")

  const [, details] = reports[0]
  assert.equal(details.fetch_error, "TypeError")
  assert.ok(player.readPausedMs >= 20, `expected a measured pause, got ${player.readPausedMs}`)
  assert.equal(player.readPauseCount, 1)
})

test("a system rebuffer is reported with the buffer state it started from", () => {
  const { context, VideoPlayerController, timeRanges } = createVideoPlayerHarness()
  context.setTimeout = () => 0
  context.clearTimeout = () => {}
  const player = new VideoPlayerController()
  const reports = captureReports(player)
  Object.assign(player, {
    videoTarget: {
      currentTime: 40, paused: false, ended: false, seeking: false,
      buffered: timeRanges([[0, 40.4]]), pause() { this.paused = true }
    },
    userPaused: false,
    isSeeking: false,
    playbackStarted: true,
    bufferedAheadOfCurrent: () => 0.4,
    showBufferingOverlay() {},
    stopProgressWatchdog() {},
    maybeStartPlayback() {},
    maybeHideBufferingOverlay() {}
  })

  player.beginSystemRebuffer()

  assert.equal(reports.length, 1)
  assert.equal(reports[0][0], "rebuffer_begin")
  assert.equal(reports[0][1].ahead_at_begin, 0.4)
  assert.equal(player.videoTarget.paused, true)
  assert.ok(player.rebufferStartedAt > 0)
})

test("rebuffer end reports how long the hold actually lasted", () => {
  const { VideoPlayerController } = createVideoPlayerHarness()
  const player = new VideoPlayerController()
  const reports = captureReports(player)
  Object.assign(player, {
    videoTarget: { currentTime: 41, paused: true },
    userPaused: false,
    isSeeking: false,
    playbackStarted: true,
    systemRebufferPaused: true,
    rebufferStartedAt: Date.now() - 1500,
    rebufferAheadAtBegin: 0.4,
    bufferedAheadOfCurrent: () => 12,
    maybeStartPlayback() {},
    maybeHideBufferingOverlay() {}
  })

  player.clearSystemRebufferGate()

  assert.equal(reports.length, 1)
  assert.equal(reports[0][0], "rebuffer_end")
  assert.ok(reports[0][1].duration_ms >= 1400)
  assert.equal(reports[0][1].ahead_at_end, 12)
  assert.equal(player.systemRebufferPaused, false)
  assert.equal(player.rebufferStartedAt, null)
})

test("idle gate clearing does not invent a rebuffer end", () => {
  const { VideoPlayerController } = createVideoPlayerHarness()
  const player = new VideoPlayerController()
  const reports = captureReports(player)
  Object.assign(player, { systemRebufferPaused: false, bufferedAheadOfCurrent: () => 5 })

  player.clearSystemRebufferGate()

  assert.deepEqual(reports, [])
})

test("an MSE recovery reports the cushion it threw away", async () => {
  const { VideoPlayerController } = createVideoPlayerHarness()
  const player = new VideoPlayerController()
  const reports = captureReports(player)
  Object.assign(player, {
    streamingUrlValue: "/transcode?source=test-owned-source",
    startSecondsValue: 400,
    streamRecoveryAttempts: 1,
    loadedTracks: [],
    element: { dataset: {} },
    currentPlaybackPosition: () => 812.4,
    bufferedAheadOfCurrent: () => 27.5,
    setupMseSource() {},
    clearSubtitleCues() {},
    reloadTextSubtitlesAt() {}
  })
  player.audioTracks = []
  player.selectedAudioStream = null
  player.burnedSubtitleSelected = () => false

  await player.reconnectFromCurrentPosition()

  assert.equal(reports.length, 1)
  assert.equal(reports[0][0], "mse_swap")
  assert.equal(reports[0][1].cushion_seconds, 27.5)
})

test("back-buffer eviction is reported with its size and accumulated in the payload", () => {
  const reports = []
  let ranges = [[0, 100]]
  const player = {
    videoTarget: { currentTime: 61 },
    sourceBuffer: {
      updating: false,
      buffered: {
        get length() { return ranges.length },
        start: (index) => ranges[index][0],
        end: (index) => ranges[index][1]
      },
      remove() {}
    },
    reportStall: (event, details = {}) => { reports.push([event, details]) }
  }

  new MseBufferManager(player).evictOldBuffer()

  assert.equal(reports.length, 1)
  assert.equal(reports[0][0], "eviction")
  assert.equal(reports[0][1].kind, "back")
  assert.equal(reports[0][1].removed_seconds, 31)
  assert.equal(player.evictionCount, 1)
  assert.equal(player.evictedSecondsTotal, 31)
  assert.ok(player.lastEvictionAt > 0)
})

test("the telemetry payload carries the stall counters that explain a pause", () => {
  const posts = []
  const player = {
    playbackId: "playback-1",
    startSecondsValue: 400,
    videoTarget: { currentTime: 12, seeking: false, readyState: 4, networkState: 2, paused: false, ended: false, buffered: { length: 0 } },
    sourceBuffer: null,
    streamRecoveryAttempts: 0,
    streamBytesRead: 4096,
    streamStartedAt: Date.now() - 60000,
    readPausedMs: 12000,
    readPauseCount: 3,
    evictionCount: 2,
    evictedSecondsTotal: 62,
    lastEvictionAt: Date.now() - 4000,
    fmp4BufferSize: 0,
    pendingAppendBuffer: null,
    mseQuotaErrorCount: 0,
    systemRebufferPaused: false,
    tracksData: { video_codec: "h264", video_width: 1920, video_height: 1080 },
    isHls: () => false,
    isRemuxDirectPlay: () => false,
    isNativeDirectPlay: () => false,
    currentPlaybackPosition: () => 412,
    lastProgressPosition: 12,
    lastProgressTime: Date.now() - 500,
    playbackPath: () => "mse_transcode",
    bufferedAheadOfCurrent: () => 8.5
  }
  const monitor = new PlaybackRecoveryMonitor(player, {
    fetcher: (url, init) => { posts.push(JSON.parse(init.body)); return Promise.resolve({}) },
    documentRoot: null
  })

  monitor.report("rebuffer_begin", { ahead_at_begin: 8.5 })

  assert.equal(posts.length, 1)
  const payload = posts[0]
  assert.equal(payload.event, "rebuffer_begin")
  assert.equal(payload.bytes_read, 4096)
  assert.equal(payload.read_paused_ms, 12000)
  assert.equal(payload.read_pause_count, 3)
  assert.equal(payload.evictions_count, 2)
  assert.equal(payload.evicted_seconds_total, 62)
  assert.ok(payload.last_eviction_age_ms >= 3900 && payload.last_eviction_age_ms <= 4200)
  assert.ok(payload.stream_age_ms >= 59000)
  assert.equal(payload.ahead_at_begin, 8.5)
})
