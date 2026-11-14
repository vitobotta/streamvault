import assert from "node:assert/strict"
import test from "node:test"
import { readFileSync } from "node:fs"
import vm from "node:vm"
import { createVideoPlayerHarness } from "./support/video_player_harness.mjs"

function fixture(t, path = "hls") {
  const { context, VideoPlayerController, timeRanges } = createVideoPlayerHarness()
  const timers = new Map()
  const listeners = new Map()
  const events = []
  let now = 100_000
  let timerId = 0
  context.Date = class extends Date { static now() { return now } }
  context.setTimeout = (callback, delay) => {
    const id = ++timerId
    timers.set(id, { callback, due: now + delay })
    return id
  }
  context.clearTimeout = (id) => timers.delete(id)
  context.console = { warn() {}, info() {} }
  // Imported services normally use the host clock. Load these real services
  // into the controller VM so every watchdog/seek timer uses this fixture clock.
  const loadService = (filename, name) => {
    const source = readFileSync(new URL(`../../app/javascript/player/${filename}`, import.meta.url), "utf8")
      .replace(`export class ${name}`, `class ${name}`)
    return vm.runInContext(`(() => { ${source}\nreturn ${name} })()`, context)
  }
  const HlsSessionClient = loadService("hls_session_client.js", "HlsSessionClient")
  const MseBufferManager = loadService("mse_buffer_manager.js", "MseBufferManager")
  const PlaybackRecoveryMonitor = loadService("playback_recovery_monitor.js", "PlaybackRecoveryMonitor")
  const player = new VideoPlayerController()
  const video = {
    src: "/hls/old/playlist", get currentSrc() { return this.src },
    currentTime: 10, paused: false, ended: false, seeking: false, readyState: 3,
    autoplay: false, muted: false, buffered: timeRanges([[0, 10.25]]),
    pause() { this.paused = true },
    play() { events.push("raw-play"); this.paused = false; return Promise.resolve() },
    load() { events.push("load"); this.currentTime = 0 },
    addEventListener(name, callback, options = {}) {
      if (!listeners.has(name)) listeners.set(name, new Map())
      listeners.get(name).set(callback, options)
    },
    removeEventListener(name, callback) { listeners.get(name)?.delete(callback) }
  }
  Object.assign(player, {
    videoTarget: video, hasVideoTarget: true,
    element: { dataset: { videoPlayerStartSecondsValue: "300" } },
    startSecondsValue: 300, playbackStarted: true,
    playbackObservation: { source: video.src, position: video.currentTime },
    hlsSessionId: path === "hls" ? "old" : null,
    directPlayActive: false, remuxDirectPlay: false,
    isSeeking: false, userPaused: false, navigatingAway: false,
    isStalled: false, systemRebufferPaused: false, subtitlePlaybackHoldToken: null,
    streamRecoveryActive: false, streamRecoveryAttempts: 0,
    pendingSeekSeconds: null, playPromptCleanup: null,
    hasStartupOverlayTarget: false,
    seekingOverlayTarget: { classList: { add() {}, remove() {} } },
    cancelRemuxLoad() {}, clearSubtitleCues() {}, reloadTextSubtitlesAt() {},
    sourceToken: () => "test-owned-source",
    stopHlsSession: async () => { player.hlsSessionId = null },
    waitForPlaylist: async () => true,
    requestPlayback: async () => {
      events.push("request-playback")
      video.paused = false
      return true
    }
  })
  const client = new HlsSessionClient(player, {
    fetcher: async () => { throw new Error("Unexpected network request") },
    documentRoot: null
  })
  const manager = new MseBufferManager(player)
  const monitor = new PlaybackRecoveryMonitor(player)
  player.hlsSessionClient = () => client
  player.mseBufferManager = () => manager
  player.recoveryMonitor = () => monitor
  client.startSession = async () => ({ session_id: "new", playlist_url: "/hls/new/playlist" })
  t.after(() => {
    // No fake callback or listener survives into another test, including the
    // existing HLS seek timeout which production leaves pending after playing.
    player.clearStallWatchdog()
    player.stopProgressWatchdog()
    timers.clear()
    listeners.clear()
  })
  return {
    player, video, client, events, timers, listeners, timeRanges,
    now: () => now,
    advance(ms) {
      const end = now + ms
      while (true) {
        const next = [...timers].filter(([, timer]) => timer.due <= end)
          .sort((a, b) => a[1].due - b[1].due || a[0] - b[0])[0]
        if (!next) break
        const [id, timer] = next
        now = timer.due
        timers.delete(id)
        timer.callback()
      }
      now = end
    },
    emit(name) {
      for (const [callback, options] of [...(listeners.get(name) || [])]) {
        if (options.once) listeners.get(name).delete(callback)
        callback()
      }
    }
  }
}

function deferred() {
  let resolve
  const promise = new Promise((done) => { resolve = done })
  return { promise, resolve }
}

function flushMicrotasks() {
  return new Promise((resolve) => setImmediate(resolve))
}

test("HLS initial startup requests playback through the common policy", async (t) => {
  const { player, video, client, events } = fixture(t)
  await client.start()
  assert.equal(player.hlsSessionId, "new")
  assert.equal(video.src, "/hls/new/playlist")
  assert.deepEqual(events, ["load", "request-playback"])
})

test("HLS disables implicit autoplay before installing its initial source", async (t) => {
  const { video, client } = fixture(t)
  let src = video.src
  const autoplayAtInstall = []
  video.autoplay = true
  Object.defineProperty(video, "src", {
    get: () => src,
    set: (value) => { autoplayAtInstall.push(video.autoplay); src = value }
  })
  await client.start()
  assert.deepEqual(autoplayAtInstall, [false])
})

test("HLS restart requests playback through the common policy", async (t) => {
  const { player, video, client, events } = fixture(t)
  player.isSeeking = true
  await client.restart(310)
  assert.equal(video.src, "/hls/new/playlist")
  assert.deepEqual(events, ["load", "request-playback"])
})

test("repeated HLS recovery preserves absolute progress and subtitle positions", async (t) => {
  const { player, video, client, emit, listeners } = fixture(t)
  const starts = []
  const subtitlePositions = []
  const installs = []
  let src = video.src
  Object.defineProperty(video, "src", {
    get: () => src,
    set: (value) => {
      installs.push([player.startSecondsValue, player.element.dataset.videoPlayerStartSecondsValue, player.playbackObservation])
      src = value
    }
  })
  player.reloadTextSubtitlesAt = (position) => subtitlePositions.push(position)
  client.startSession = async (source, startSeconds) => {
    assert.equal(source, "test-owned-source")
    starts.push(startSeconds)
    return { session_id: `session-${starts.length}`, playlist_url: `/hls/session-${starts.length}/playlist` }
  }
  player.isSeeking = true
  await client.restart(player.currentPlaybackPosition())
  assert.equal(player.startSecondsValue, 310)
  assert.equal(player.currentPlaybackPosition(), 310)
  assert.equal(player.element.dataset.videoPlayerStartSecondsValue, "310")
  assert.equal(player.playbackObservation, null)
  emit("playing")
  assert.equal(player.isSeeking, false)
  assert.equal(listeners.get("playing").size, 0)

  video.currentTime = 20
  player.playbackObservation = { source: video.src, position: video.currentTime }
  player.isSeeking = true
  await client.restart(player.currentPlaybackPosition())
  assert.equal(player.currentPlaybackPosition(), 330)
  emit("playing")
  assert.deepEqual(starts, [310, 330])
  assert.deepEqual(subtitlePositions, [310, 330])
  assert.deepEqual(installs, [[310, "310", null], [330, "330", null]])
})

for (const ready of [true, false]) {
  test(`HLS pending playlist retains the installed timeline; ready=${ready}`, async (t) => {
    const { player, video, client, events } = fixture(t)
    const playlist = deferred()
    const polling = deferred()
    const oldObservation = player.playbackObservation
    player.isSeeking = true
    player.waitForPlaylist = () => { polling.resolve(); return playlist.promise }
    const restart = client.restart(900)
    await polling.promise
    assert.equal(player.startSecondsValue, 300)
    assert.equal(player.element.dataset.videoPlayerStartSecondsValue, "300")
    assert.equal(player.currentPlaybackPosition(), 310)
    assert.equal(player.playbackObservation, oldObservation)
    assert.equal(video.src, "/hls/old/playlist")
    assert.deepEqual(events, [])
    playlist.resolve(ready)
    await restart
    assert.equal(player.startSecondsValue, ready ? 900 : 300)
    assert.equal(player.currentPlaybackPosition(), ready ? 900 : 310)
    assert.equal(player.element.dataset.videoPlayerStartSecondsValue, ready ? "900" : "300")
    assert.equal(player.playbackObservation, ready ? null : oldObservation)
    assert.equal(video.src, ready ? "/hls/new/playlist" : "/hls/old/playlist")
    if (!ready) {
      assert.equal(player.isSeeking, false)
      assert.deepEqual(events, [])
    }
  })
}

for (const failure of ["no source", "start rejected", "start threw"]) {
  test(`HLS restart leaves the old timeline intact when ${failure}`, async (t) => {
    const { player, video, client, events, timers } = fixture(t)
    const observation = player.playbackObservation
    player.isSeeking = true
    if (failure === "no source") player.sourceToken = () => null
    if (failure === "start rejected") client.startSession = async () => null
    if (failure === "start threw") client.startSession = async () => { throw new Error("Fixture failure") }
    await client.restart(900)
    assert.equal(player.startSecondsValue, 300)
    assert.equal(player.element.dataset.videoPlayerStartSecondsValue, "300")
    assert.equal(player.playbackObservation, observation)
    assert.equal(player.currentPlaybackPosition(), 310)
    assert.equal(video.src, "/hls/old/playlist")
    assert.equal(player.isSeeking, false)
    assert.deepEqual(events, [])
    assert.equal(timers.size, 0)
  })
}

test("HLS restart seek timeout uses the fixture clock", async (t) => {
  const { player, client, timers, advance } = fixture(t)
  player.isSeeking = true
  await client.restart(310)
  assert.equal(player.isSeeking, true)
  assert.equal(timers.size, 1)
  advance(29_999)
  assert.equal(player.isSeeking, true)
  advance(1)
  assert.equal(player.isSeeking, false)
  assert.equal(timers.size, 0)
})

test("confirmed HLS playback arms the real silent-freeze watchdog", (t) => {
  const { player, timers, advance } = fixture(t)
  const recoveryEvents = []
  player.playbackStarted = false
  player.handleHlsStall = (event) => recoveryEvents.push(event)
  player.onVideoReady()
  assert.equal(player.playbackStarted, true)
  assert.equal(player.progressWatchdogArmed, true)
  assert.equal(timers.size, 1)
  advance(21_000)
  assert.deepEqual(recoveryEvents, ["silent_freeze"])
  assert.equal(player.progressWatchdogArmed, false)
  assert.equal(timers.size, 0)
})

test("MSE updateend activity cannot reset the silent-freeze clock", (t) => {
  const { player, video, advance, now } = fixture(t, "mse")
  const recoveryEvents = []
  player.handleStreamStall = (event) => recoveryEvents.push(event)
  player.startProgressWatchdog()
  const lastProgressTime = now()
  for (let update = 0; update < 3; update++) {
    advance(6_000)
    player.onBufferUpdateEnd()
  }
  assert.equal(video.currentTime, 10)
  assert.equal(player.lastProgressTime, lastProgressTime)
  advance(3_000)
  assert.deepEqual(recoveryEvents, ["silent_freeze"])
  assert.equal(player.progressWatchdogArmed, false)
})

test("advancing MSE media time still refreshes the watchdog baseline", (t) => {
  const { player, video, advance, now } = fixture(t, "mse")
  const recoveryEvents = []
  player.handleStreamStall = (event) => recoveryEvents.push(event)
  player.startProgressWatchdog()
  for (let sample = 0; sample < 8; sample++) {
    video.currentTime += 0.25
    player.onBufferUpdateEnd()
    advance(3_000)
    assert.equal(player.lastProgressPosition, video.currentTime)
    assert.equal(player.lastProgressTime, now())
  }
  assert.deepEqual(recoveryEvents, [])
  assert.equal(player.progressWatchdogArmed, true)
})

test("explicit progress-baseline reset still protects a seek", (t) => {
  const { player, video, advance, now } = fixture(t, "mse")
  const recoveryEvents = []
  player.handleStreamStall = (event) => recoveryEvents.push(event)
  player.startProgressWatchdog()
  advance(18_000)
  video.currentTime = 1
  player.resetProgressBaseline()
  assert.equal(player.lastProgressTime, now())
  assert.equal(player.lastProgressPosition, 1)
  advance(3_000)
  assert.deepEqual(recoveryEvents, [])
})

test("a reconnected MSE session rebaselines the silent-freeze clock", (t) => {
  const { player, video, advance } = fixture(t, "mse")
  const recoveryEvents = []
  player.handleStreamStall = (event) => recoveryEvents.push(event)
  video.currentTime = 40
  player.startProgressWatchdog()
  advance(5_000)

  // A seek or recovery installs a new MSE session: the element timeline
  // restarts near zero, well below the previous session's baseline.
  video.currentTime = 0
  player.startProgressWatchdog()
  for (let second = 1; second <= 7; second++) {
    video.currentTime = second
    advance(3_000)
  }

  assert.deepEqual(recoveryEvents, [])
  assert.equal(player.progressWatchdogArmed, true)
})

test("a backwards timeline jump is not mistaken for a silent freeze", (t) => {
  const { player, video, advance } = fixture(t, "mse")
  const recoveryEvents = []
  player.handleStreamStall = (event) => recoveryEvents.push(event)
  video.currentTime = 40
  player.startProgressWatchdog()
  advance(5_000)

  // Recovery can install the new timeline without an explicit re-arm.
  video.currentTime = 0
  for (let second = 1; second <= 7; second++) {
    video.currentTime = second
    advance(3_000)
  }

  assert.deepEqual(recoveryEvents, [])
  assert.equal(player.lastProgressPosition, video.currentTime)
})

test("MSE source setup disarms the previous session's freeze clock", (t) => {
  const { player } = fixture(t, "mse")
  const calls = []
  player.startProgressWatchdog()
  player.playbackEngine = () => ({ setupMseSource: () => calls.push("engine") })

  player.setupMseSource("/transcode?start_seconds=10")

  assert.deepEqual(calls, [ "engine" ])
  assert.equal(player.progressWatchdogArmed, false)
})

// ── Seamless continuation ────────────────────────────────────────────
//
// A continuation appends the replacement response into the live
// SourceBuffer instead of rebuilding the MediaSource (the black frame).
// These fixtures drive the real controller methods with the real
// MseBufferManager, so the join offset, the fallback paths and the gap
// guard are exercised rather than described.

function continuationFixture(t, { ranges = [ [ 0, 104 ] ], currentTime = 60, duration = 1000 } = {}) {
  const { context, VideoPlayerController, harness } = createVideoPlayerHarness()
  const timers = new Map()
  let now = 100_000
  let timerId = 0
  context.Date = class extends Date { static now() { return now } }
  context.setTimeout = (callback, delay) => {
    const id = ++timerId
    timers.set(id, { callback, due: now + delay })
    return id
  }
  context.clearTimeout = (id) => timers.delete(id)
  context.console = { warn() {}, info() {} }

  const loadService = (filename, name) => {
    const source = readFileSync(new URL(`../../app/javascript/player/${filename}`, import.meta.url), "utf8")
      .replace(`export class ${name}`, `class ${name}`)
    return vm.runInContext(`(() => { ${source}\nreturn ${name} })()`, context)
  }
  const MseBufferManager = loadService("mse_buffer_manager.js", "MseBufferManager")
  const PlaybackRecoveryMonitor = loadService("playback_recovery_monitor.js", "PlaybackRecoveryMonitor")

  let bufferedRanges = ranges.map(([ start, end ]) => [ start, end ])
  const buffered = {
    get length() { return bufferedRanges.length },
    start: (index) => bufferedRanges[index][0],
    end: (index) => bufferedRanges[index][1]
  }

  const player = new VideoPlayerController()
  const video = {
    src: "/blob:session",
    get currentSrc() { return this.src },
    currentTime,
    paused: false,
    ended: false,
    seeking: false,
    readyState: 4,
    autoplay: false,
    buffered,
    pause() { this.paused = true },
    play() { this.paused = false; return Promise.resolve() },
    addEventListener() {},
    removeEventListener() {}
  }
  const order = []
  const sourceBuffer = {
    updating: false,
    _offset: 0,
    buffered,
    get timestampOffset() { return this._offset },
    set timestampOffset(value) { this._offset = value; order.push(`offset:${value}`) },
    abort() { order.push("abort"); this.updating = false },
    appendBuffer() { this.updating = true },
    remove() {}
  }
  const reports = []
  const fetches = []
  const swaps = []
  const reconnects = []

  const manager = new MseBufferManager(player)
  const monitor = new PlaybackRecoveryMonitor(player, {
    fetcher: (_url, init) => { reports.push(JSON.parse(init.body)); return Promise.resolve({}) },
    documentRoot: null
  })

  Object.assign(player, {
    videoTarget: video,
    hasVideoTarget: true,
    sourceBuffer,
    mediaSource: { readyState: "open", endOfStream() { this.readyState = "ended" } },
    element: { dataset: {} },
    playbackId: "continuation",
    startSecondsValue: 300,
    streamingUrlValue: "/transcode?source=test-owned-source",
    playbackStarted: true,
    userPaused: false,
    navigatingAway: false,
    playbackDisconnected: false,
    subtitlePlaybackHoldToken: null,
    isSeeking: false,
    streamRecoveryAttempts: 0,
    streamRecoveryActive: false,
    bufferAppending: false,
    pendingAppendBuffer: null,
    fmp4Buffer: null,
    fmp4BufferSize: 0,
    mseReadPaused: false,
    knownDuration: duration,
    selectedAudioStream: null,
    selectedSubtitleStream: null,
    isHls: () => false,
    isDirectPlay: () => false,
    isRemuxDirectPlay: () => false,
    isNativeDirectPlay: () => false,
    burnedSubtitleSelected() { return false },
    mseBufferManager: () => manager,
    recoveryMonitor: () => monitor,
    startStallWatchdog() {},
    clearStallWatchdog() {},
    stopProgressWatchdog() {},
    showSeekingOverlay() {},
    hideSeekingOverlay() {},
    showBufferingOverlay() {},
    maybeHideBufferingOverlay() {},
    clearPlayPrompt() {},
    hideStartupOverlay() {},
    clearSystemRebufferGate() {},
    clearSubtitleCues() {},
    reloadTextSubtitlesAt() {},
    setupMseSource(url) {
      swaps.push(url)
      this.cancelMseContinuation()
      if (this.fetchController) { this.fetchController.abort(); this.fetchController = null }
    },
    reconnectFromCurrentPosition() { reconnects.push("reconnect") },
    continuationGapJump: null,
    startStreamingFetch(url, options = {}) {
      fetches.push([ url, options ])
      return Promise.resolve()
    }
  })

  t.after(() => {
    player.clearStallWatchdog()
    player.stopProgressWatchdog()
    timers.clear()
  })

  return {
    player,
    video,
    sourceBuffer,
    manager,
    monitor,
    harness,
    reports,
    fetches,
    swaps,
    reconnects,
    order,
    VideoPlayerController,
    useRealFetch() {
      player.startStreamingFetch = (url, options = {}) => {
        fetches.push([ url, options ])
        return VideoPlayerController.prototype.startStreamingFetch.call(player, url, options)
      }
    },
    setRanges(next) { bufferedRanges = next.map(([ start, end ]) => [ start, end ]) },
    setAppends(count) { manager.appendCount = count },
    advance(ms) {
      const end = now + ms
      while (true) {
        const next = [ ...timers ].filter(([, timer]) => timer.due <= end)
          .sort((a, b) => a[1].due - b[1].due || a[0] - b[0])[0]
        if (!next) break
        const [ id, timer ] = next
        now = timer.due
        timers.delete(id)
        timer.callback()
      }
      now = end
    }
  }
}

test("a dead body with a healthy cushion continues in the same source buffer", async (t) => {
  const f = continuationFixture(t)
  f.player.fmp4Buffer = new Uint8Array(32)
  f.player.fmp4BufferSize = 32
  f.player.pendingAppendBuffer = new ArrayBuffer(16)
  const sourceBefore = f.video.src

  await f.player.continueMseStream("stream_error")
  await flushMicrotasks()

  assert.deepEqual(f.swaps, [])
  assert.deepEqual(f.reconnects, [])
  assert.equal(f.video.src, sourceBefore)
  assert.equal(f.player.startSecondsValue, 300)
  assert.deepEqual(f.order, [ "abort", "offset:103" ])
  assert.equal(f.player.fmp4Buffer, null)
  assert.equal(f.player.fmp4BufferSize, 0)
  assert.equal(f.player.pendingAppendBuffer, null)
  assert.equal(f.fetches.length, 1)
  assert.match(f.fetches[0][0], /start_seconds=403(&|$)/)
  assert.equal(f.fetches[0][1].continuation, true)
  assert.equal(f.fetches[0][1].loadId, 1)
  assert.equal(f.reports[0].event, "stream_continue")
  assert.equal(f.reports[0].resume_offset_seconds, 103)
  assert.equal(f.reports[0].cushion_seconds, 44)
})

test("a continuation rejected with 502 falls back to exactly one session swap", async (t) => {
  const f = continuationFixture(t)
  const { player } = f
  f.harness.fetchHandler = async () => ({ ok: false, status: 502 })
  f.useRealFetch()

  player.handlePrematureStreamEnd("stream_error")
  await flushMicrotasks()
  await flushMicrotasks()

  assert.deepEqual(f.reconnects, [ "reconnect" ])
  assert.equal(player.continuationFailures, 1)
  assert.equal(player.continuationInFlight, false)
  assert.equal(f.sourceBuffer.timestampOffset, 0)
  assert.ok(f.reports.some((report) => report.event === "continuation_failed"))
})

test("a continuation that never delivers a first chunk falls back before the cushion runs dry", async (t) => {
  const f = continuationFixture(t, { ranges: [ [ 0, 69 ] ], currentTime: 60 })
  const { player } = f
  f.harness.fetchHandler = async () => ({
    ok: true,
    body: { getReader: () => ({ read: () => new Promise(() => {}) }) }
  })
  f.useRealFetch()

  player.handlePrematureStreamEnd("stream_error")
  await flushMicrotasks()
  assert.equal(player.continuationFirstChunkAt, null)
  assert.deepEqual(f.reconnects, [])

  f.advance(4000)
  await flushMicrotasks()

  assert.deepEqual(f.reconnects, [ "reconnect" ])
  assert.ok(f.reports.some((report) => report.event === "continuation_failed"))
})

test("a body that ends near the duration still finalizes instead of continuing", async (t) => {
  const f = continuationFixture(t, { ranges: [ [ 0, 1000 ] ], currentTime: 990 })
  f.player.startSecondsValue = 0

  f.player.handlePrematureStreamEnd("stream_end")
  await flushMicrotasks()

  assert.equal(f.player.mediaSource.readyState, "ended")
  assert.equal(f.player.mseFetchEnded, false)
  assert.deepEqual(f.fetches, [])
})

test("a dead body while the user is paused waits for playback before continuing", async (t) => {
  const f = continuationFixture(t)
  f.player.userPaused = true

  f.player.handlePrematureStreamEnd("stream_error")
  await flushMicrotasks()
  f.advance(250)
  await flushMicrotasks()
  assert.deepEqual(f.fetches, [])

  f.player.userPaused = false
  f.advance(1000)
  await flushMicrotasks()

  assert.equal(f.fetches.length, 1)
  assert.equal(f.fetches[0][1].continuation, true)
})

test("a seek during a continuation leaves the continuation's only fetch aborted", async (t) => {
  const f = continuationFixture(t)
  const { player } = f
  f.harness.fetchHandler = async (_url, init) => ({
    ok: true,
    body: {
      getReader: () => ({
        read: () => new Promise((_resolve, reject) => {
          init.signal.addEventListener("abort", () => {
            const error = new Error("aborted")
            error.name = "AbortError"
            reject(error)
          })
        })
      })
    }
  })
  f.useRealFetch()

  player.handlePrematureStreamEnd("stream_error")
  await flushMicrotasks()
  assert.equal(f.fetches.length, 1)
  assert.equal(player.fetchController !== null, true)

  player.restartPlaybackAt(500)
  await flushMicrotasks()
  await flushMicrotasks()

  assert.equal(f.fetches.length, 1)
  assert.equal(player.fetchController, null)
  assert.equal(f.swaps.length, 1)
  assert.equal(player.startSecondsValue, 500)
})

test("the continuation URL keeps the selected audio and burned subtitle streams", async (t) => {
  const f = continuationFixture(t)
  f.player.selectedAudioStream = "3"
  f.player.selectedSubtitleStream = "7"
  f.player.burnedSubtitleSelected = () => true

  f.player.handlePrematureStreamEnd("stream_end")
  await flushMicrotasks()

  assert.equal(f.fetches.length, 1)
  assert.match(f.fetches[0][0], /audio_stream=3/)
  assert.match(f.fetches[0][0], /subtitle_stream=7/)
})

test("a sub-second hole at the join is jumped once when the playhead reaches it", async (t) => {
  const f = continuationFixture(t, { ranges: [ [ 0, 100 ] ], currentTime: 60 })
  f.player.currentTimeTarget = { textContent: "" }
  f.player.updateSubtitleOverlay = () => {}
  f.player.updateSeekVisuals = () => {}
  f.player.updateBufferBar = () => {}
  f.player.observePlaybackProgress = () => {}
  f.player.updateNextEpisodePrompt = () => {}
  f.player.effectiveDuration = () => 1000

  f.player.handlePrematureStreamEnd("stream_end")
  await flushMicrotasks()

  f.setRanges([ [ 0, 100 ], [ 100.4, 160 ] ])
  f.setAppends(1)
  f.player.finishMseContinuation()

  assert.ok(f.reports.some((report) => report.event === "stream_continue_ok"))
  assert.ok(f.reports.some((report) => report.event === "continuation_gap" && report.continuation_gap_seconds === 0.4))
  assert.deepEqual(f.reconnects, [])

  f.video.currentTime = 99.9
  f.player.onTimeUpdate()
  assert.equal(f.video.currentTime, 100.45)

  const afterJump = f.video.currentTime
  f.player.onTimeUpdate()
  assert.equal(f.video.currentTime, afterJump)
})

test("an init-segment append alone does not count as the continuation's first fragment", async (t) => {
  const f = continuationFixture(t, { ranges: [ [ 0, 100 ] ], currentTime: 60 })

  f.player.handlePrematureStreamEnd("stream_end")
  await flushMicrotasks()

  // The init segment appends, but the timeline does not move yet.
  f.setAppends(1)
  f.player.finishMseContinuation()

  assert.equal(f.reports.some((report) => report.event === "stream_continue_ok"), false)
  assert.equal(f.player.continuationAwaitingFirstAppend, true)

  // The first media fragment extends the buffer and completes the join.
  f.setRanges([ [ 0, 100 ], [ 99, 101 ] ])
  f.player.finishMseContinuation()
  assert.ok(f.reports.some((report) => report.event === "stream_continue_ok"))
})

test("a hole larger than one second at the join takes the swap fallback", async (t) => {
  const f = continuationFixture(t, { ranges: [ [ 0, 100 ] ], currentTime: 60 })

  f.player.handlePrematureStreamEnd("stream_end")
  await flushMicrotasks()

  f.setRanges([ [ 0, 100 ], [ 102, 160 ] ])
  f.setAppends(1)
  f.player.finishMseContinuation()

  assert.deepEqual(f.reconnects, [ "reconnect" ])
  assert.equal(f.player.continuationGapJump, null)
  assert.equal(f.player.continuationFailures, 1)
})
