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
    startSecondsValue: 300, playbackStarted: true, playbackEverStarted: true,
    playbackObservation: { source: video.src, position: video.currentTime },
    hlsSessionId: path === "hls" ? "old" : null,
    directPlayActive: false, remuxDirectPlay: false,
    isSeeking: false, userPaused: false, navigatingAway: false,
    isStalled: false, systemRebufferPaused: false, subtitlePlaybackHoldToken: null,
    streamRecoveryActive: false, streamRecoveryAttempts: 0,
    pendingSeekSeconds: null, playPromptCleanup: null,
    hasStartupOverlayTarget: false, hasEnableSoundTarget: false,
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
  player.playbackEverStarted = false
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
