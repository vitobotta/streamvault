import assert from "node:assert/strict"
import test from "node:test"
import { readFileSync } from "node:fs"
import { createVideoPlayerHarness } from "./support/video_player_harness.mjs"

function target(initial = []) {
  const classes = new Set(initial)
  const attributes = new Map()
  const listeners = new Map()
  const spinner = { style: {} }
  const label = { textContent: "Starting playback" }
  const detail = { textContent: "Preparing stream..." }
  return {
    classes, attributes, listeners, spinner, label, detail,
    classList: {
      add: (...items) => items.forEach((item) => classes.add(item)),
      remove: (...items) => items.forEach((item) => classes.delete(item)),
      contains: (item) => classes.has(item),
      toggle: (item, force) => {
        const add = force ?? !classes.has(item)
        if (add) classes.add(item); else classes.delete(item)
        return add
      }
    },
    setAttribute: (name, value) => attributes.set(name, value),
    getAttribute: (name) => attributes.get(name),
    removeAttribute: (name) => attributes.delete(name),
    addEventListener: (name, callback) => listeners.set(name, callback),
    removeEventListener: (name, callback) => {
      if (listeners.get(name) === callback) listeners.delete(name)
    },
    querySelector: (selector) => selector === ".animate-spin" ? spinner :
      selector === "span.text-white" ? label : detail
  }
}

function fixture(path = "mse") {
  const { context, VideoPlayerController, timeRanges } = createVideoPlayerHarness()
  const timers = new Map()
  let timerId = 0
  context.setTimeout = (callback, delay) => {
    const id = ++timerId
    timers.set(id, { callback, delay })
    return id
  }
  context.clearTimeout = (id) => timers.delete(id)
  const player = new VideoPlayerController()
  const video = {
    ...target(), src: "blob:fixture", currentSrc: "blob:fixture", currentTime: 10,
    readyState: 3, paused: false, ended: false, seeking: false, muted: false,
    buffered: timeRanges([[0, 10.25]]),
    play() { this.paused = false; return Promise.resolve() },
    pause() { this.paused = true }
  }
  Object.assign(player, {
    videoTarget: video, hasVideoTarget: true,
    hasStartupOverlayTarget: true, startupOverlayTarget: target(),
    hasSeekingOverlayMessageTarget: true, seekingOverlayMessageTarget: target(),
    seekingOverlayTarget: target(),
    currentTimeTarget: { textContent: "" },
    subtitlePlaybackHoldToken: null, pendingSeekSeconds: null,
    isSeeking: false, userPaused: false, navigatingAway: false,
    systemRebufferPaused: false, isStalled: true, playbackStarted: true,
    streamRecoveryAttempts: 1, streamRecoveryActive: false,
    playPromptCleanup: null, startSecondsValue: 0,
    isDirectPlay: () => path === "direct" || path === "remux",
    isHls: () => path === "hls", isSafari: () => false, isIOS: () => false,
    clearStallWatchdog() {}, startProgressWatchdog() {}, stopProgressWatchdog() {},
    currentPlaybackPosition: () => video.currentTime, effectiveDuration: () => 100,
    updateSubtitleOverlay() {}, updateSeekVisuals() {}, updateBufferBar() {}
  })
  return {
    context, player, video, timers, timeRanges,
    fire(delay) {
      for (const [id, timer] of [...timers]) {
        if (timer.delay !== delay || !timers.has(id)) continue
        timers.delete(id)
        timer.callback()
      }
    }
  }
}

function connectedFixture() {
  const f = fixture()
  const { context, player } = f
  Object.assign(context.document, target())
  Object.assign(context.window, target())
  Object.assign(player, {
    element: { ...target(), dataset: {} }, sourceInfoTarget: target(),
    sourceUrlTarget: target(), sourceFilenameTarget: target(),
    showOverlayUi() {}, updateDurationDisplay() {}, probeDuration() {},
    playbackCoordinator: () => ({ connect() {}, disconnect() {} }),
    saveProgressSync() {}, cancelSeekDrag() {}, removeTextSubtitleTrack() {}, pauseAndDetachVideo() {}
  })
  player.connect()
  return f
}

for (const path of ["direct", "remux", "hls", "mse"]) {
  test(`playing clears shallow-buffer overlays: ${path}`, () => {
    const { player } = fixture(path)
    player.onVideoReady()
    assert.equal(player.startupOverlayTarget.attributes.get("aria-hidden"), "true")
    assert.equal(player.seekingOverlayTarget.classes.has("hidden"), true)
    assert.equal(player.isStalled, false)
    assert.equal(player.playbackStarted, true)
  })

  test(`forward progress clears overlays without another playing event: ${path}`, () => {
    const { player, video } = fixture(path)
    player.isStalled = false
    player.playbackStarted = false
    player.onTimeUpdate()
    assert.equal(player.seekingOverlayTarget.classes.has("hidden"), false)
    video.currentTime += 0.25
    player.onTimeUpdate()
    assert.equal(player.seekingOverlayTarget.classes.has("hidden"), true)
    assert.equal(player.startupOverlayTarget.attributes.get("aria-hidden"), "true")
  })
}

for (const condition of ["paused", "ended", "seeking", "userPaused", "isSeeking", "systemRebufferPaused", "subtitleHold", "navigatingAway"]) {
  test(`progress must not clear an owned hold: ${condition}`, () => {
    const { player, video } = fixture()
    player.onTimeUpdate()
    if (["paused", "ended", "seeking"].includes(condition)) video[condition] = true
    else if (condition === "subtitleHold") player.subtitlePlaybackHoldToken = 7
    else player[condition] = true
    video.currentTime += 5
    player.onTimeUpdate()
    assert.equal(player.seekingOverlayTarget.classes.has("hidden"), false)
    assert.notEqual(player.startupOverlayTarget.attributes.get("aria-hidden"), "true")
  })
}

for (const path of ["direct", "remux", "hls", "mse"]) {
  test(`unchanged time and downloaded data are not playback: ${path}`, () => {
    const { player, video, timeRanges } = fixture(path)
    player.onTimeUpdate()
    player.onTimeUpdate()
    video.buffered = timeRanges([[0, 60]])
    player.onProgress()
    player.maybeHideBufferingOverlay()
    assert.equal(player.seekingOverlayTarget.classes.has("hidden"), false)
  })
}

test("a seek completed between observations cannot confirm playback", () => {
  const { player, video } = fixture("direct")
  player.element = { dataset: {} }
  player.burnedSubtitleSelected = () => false
  player.clearSubtitleCues = () => {}
  player.reloadTextSubtitlesAt = () => {}
  player.resetProgressBaseline = () => {}
  player.onTimeUpdate()
  player.restartPlaybackAt(40)
  player.onTimeUpdate()
  assert.equal(player.seekingOverlayTarget.classes.has("hidden"), false)
  video.currentTime += 0.2
  player.onTimeUpdate()
  assert.equal(player.seekingOverlayTarget.classes.has("hidden"), true)
})

test("the first unblocked observation is a baseline, not a seek or pause jump", () => {
  const { player, video } = fixture()
  player.onTimeUpdate()
  video.seeking = true
  player.onTimeUpdate()
  video.currentTime = 60
  video.seeking = false
  player.onTimeUpdate()
  assert.equal(player.seekingOverlayTarget.classes.has("hidden"), false)
  video.currentTime += 0.2
  player.onTimeUpdate()
  assert.equal(player.seekingOverlayTarget.classes.has("hidden"), true)
})

test("small progress accumulates across progress and append notifications", () => {
  const { player, video } = fixture()
  player.onTimeUpdate()
  for (let i = 0; i < 4; i += 1) {
    video.currentTime += 0.04
    player.onProgress()
    player.maybeHideBufferingOverlay()
  }
  assert.equal(player.seekingOverlayTarget.classes.has("hidden"), true)
})

test("source replacement cannot be progress while currentSrc still names the old source", () => {
  const { player, video } = fixture()
  player.onTimeUpdate()
  video.src = "blob:replacement"
  video.currentTime = 30
  player.onTimeUpdate()
  assert.equal(player.seekingOverlayTarget.classes.has("hidden"), false)
})

test("repeated playback confirmation does not postpone the startup fade", () => {
  const { player, fire, timers } = fixture()
  player.onVideoReady()
  const firstTimer = player.startupOverlayHideTimer
  player.onVideoReady()
  assert.equal(player.startupOverlayHideTimer, firstTimer)
  assert.equal(timers.size, 1)
  fire(220)
  assert.equal(player.startupOverlayTarget.classes.has("hidden"), true)
})

test("startup keeps sound enabled even when muted autoplay would be allowed", async () => {
  const { player, video } = fixture()
  const muteStates = []
  video.paused = true
  video.play = () => {
    muteStates.push(video.muted)
    if (!video.muted) return Promise.reject({ name: "NotAllowedError" })
    video.paused = false
    return Promise.resolve()
  }

  await player.requestPlayback()

  assert.equal(video.muted, false, "a policy rejection must not silently turn sound off")
  assert.deepEqual(muteStates, [false], "do not replace audible playback with a muted retry")
  assert.equal(video.paused, true)
  assert.equal(player.startupOverlayTarget.label.textContent, "Play")
})

test("audible startup calls play synchronously without changing the sound state", async () => {
  const { player, video } = fixture()
  let calls = 0
  let resolvePlay
  video.paused = true
  video.play = () => {
    calls += 1
    assert.equal(video.muted, false)
    video.paused = false
    return new Promise((resolve) => { resolvePlay = resolve })
  }

  const pending = player.requestPlayback()
  assert.equal(calls, 1, "preserve any activation available in the caller's event")
  resolvePlay()
  assert.equal(await pending, true)
  assert.equal(video.muted, false)
  assert.equal(player.startupOverlayTarget.attributes.get("aria-hidden"), "true")
})

for (const browser of ["Chromium", "Safari"]) {
  for (const mode of ["audible", "user-muted", "blocked", "abort", "unsupported"]) {
    test(`autoplay outcome ${browser}: ${mode}`, async () => {
      const { player, video } = fixture()
      const calls = []
      const prompts = []
      const failures = []
      video.paused = true
      video.muted = mode === "user-muted"
      player.isSafari = () => browser === "Safari"
      player.showPlayPrompt = (options) => prompts.push(options)
      player.showPlaybackFailure = (error) => failures.push(error.name)
      video.play = () => {
        calls.push(video.muted)
        if (mode === "abort") return Promise.reject({ name: "AbortError" })
        if (mode === "unsupported") return Promise.reject({ name: "NotSupportedError" })
        if (mode === "blocked") {
          return Promise.reject({ name: "NotAllowedError" })
        }
        video.paused = false
        return Promise.resolve()
      }
      assert.equal(await player.requestPlayback(), mode === "audible" || mode === "user-muted")
      assert.deepEqual(calls, [mode === "user-muted"])
      assert.equal(prompts.length, mode === "blocked" ? 1 : 0)
      assert.deepEqual(failures, mode === "unsupported" ? ["NotSupportedError"] : [])
      assert.equal(video.muted, mode === "user-muted")
    })
  }
}

for (const outcome of ["reject", "resolve"]) {
  for (const change of ["source", "newRequest", "userPause", "navigation", "invalidate"]) {
    test(`stale play ${outcome} cannot display UI after ${change}`, async () => {
      const { player, video } = fixture()
      let settle
      let prompts = 0
      video.paused = true
      player.showPlayPrompt = () => { prompts += 1 }
      video.play = () => new Promise((resolve, reject) => { settle = outcome === "reject" ? reject : resolve })
      const first = player.requestPlayback()
      if (change === "source") video.src = "blob:replacement"
      if (change === "userPause") player.userPaused = true
      if (change === "navigation") player.navigatingAway = true
      if (change === "invalidate") player.invalidatePlaybackRequest()
      if (change === "newRequest") {
        video.play = () => { video.paused = false; return Promise.resolve() }
        await player.requestPlayback()
      }
      settle({ name: "NotAllowedError" })
      assert.equal(await first, false)
      assert.equal(prompts, 0)
      assert.equal(video.muted, false)
      if (change !== "newRequest") assert.notEqual(player.startupOverlayTarget.attributes.get("aria-hidden"), "true")
    })
  }
}

test("recovery never silently mutes a previously started video", async () => {
  const { player, video } = fixture()
  let calls = 0
  let prompts = 0
  assert.equal(await player.requestPlayback(), true)
  video.paused = true
  player.showPlayPrompt = () => { prompts += 1 }
  video.play = () => { calls += 1; return Promise.reject({ name: "NotAllowedError" }) }
  assert.equal(await player.requestPlayback(), false)
  assert.equal(calls, 1)
  assert.equal(video.muted, false)
  assert.equal(prompts, 1)
})

test("an interrupted audible request preserves sound state without a prompt", async () => {
  const { player, video } = fixture()
  let prompts = 0
  video.paused = true
  player.showPlayPrompt = () => { prompts += 1 }
  video.play = () => Promise.reject({ name: "AbortError" })
  assert.equal(await player.requestPlayback(), false)
  assert.equal(video.muted, false)
  assert.equal(prompts, 0)
})

for (const change of ["source", "invalidate", "newRequest"]) {
  test(`a pending audible request preserves sound state after ${change}`, async () => {
    const { player, video } = fixture()
    let rejectPlay
    video.paused = true
    video.play = () => new Promise((_resolve, reject) => { rejectPlay = reject })
    const first = player.requestPlayback()
    assert.equal(typeof rejectPlay, "function")
    assert.equal(video.muted, false)
    if (change === "source") video.src = "blob:replacement"
    if (change === "invalidate") player.invalidatePlaybackRequest()
    if (change === "newRequest") {
      video.play = () => { assert.equal(video.muted, false); video.paused = false; return Promise.resolve() }
      assert.equal(await player.requestPlayback(), true)
    }
    rejectPlay({ name: "NotAllowedError" })
    assert.equal(await first, false)
    assert.equal(video.muted, false)
    assert.equal(player.playPromptCleanup, null)
  })
}

test("a user mute before a policy rejection prevents an automatic retry", async () => {
  const { player, video } = fixture()
  let reject
  let calls = 0
  video.paused = true
  video.play = () => { calls += 1; return new Promise((_resolve, r) => { reject = r }) }
  const pending = player.requestPlayback()
  player.toggleMute()
  reject({ name: "NotAllowedError" })
  assert.equal(await pending, false)
  assert.equal(calls, 1)
  assert.equal(video.muted, true)
  assert.equal(player.playPromptCleanup, null)
})

test("successful playback resolution cannot dismiss a subtitle hold", async () => {
  const { player, video } = fixture()
  let resolve
  video.play = () => new Promise(r => { resolve = r })
  const pending = player.requestPlayback()
  player.subtitlePlaybackHoldToken = 4
  resolve()
  assert.equal(await pending, false)
  assert.notEqual(player.startupOverlayTarget.attributes.get("aria-hidden"), "true")
})

test("synchronous unsupported errors produce an error, not a play prompt", async () => {
  const { player, video } = fixture()
  video.paused = true
  video.play = () => { throw { name: "NotSupportedError" } }
  assert.equal(await player.requestPlayback(), false)
  assert.equal(player.startupOverlayTarget.label.textContent, "Unable to start playback")
  assert.equal(player.startupOverlayTarget.spinner.style.display, "none")
  assert.equal(player.playPromptCleanup, null)
})

for (const outcome of ["unsupported", "abort", "replaced", "paused", "navigation"]) {
  test(`async play rejection after the element becomes unpaused: ${outcome}`, async () => {
    const { player, video } = fixture()
    let reject
    let calls = 0
    video.paused = true
    video.play = () => {
      calls += 1
      video.paused = false // Resource selection starts before actual playback.
      return new Promise((_resolve, fail) => { reject = fail })
    }
    const pending = player.requestPlayback()
    if (outcome === "replaced") video.src = "blob:replacement"
    if (outcome === "paused") player.togglePlay()
    if (outcome === "navigation") player.navigatingAway = true
    reject({ name: outcome === "abort" ? "AbortError" : "NotSupportedError" })
    assert.equal(await pending, false)
    assert.equal(calls, 1)
    assert.equal(video.muted, false)
    assert.equal(player.playPromptCleanup, null)
    assert.equal(player.startupOverlayTarget.label.textContent,
      outcome === "unsupported" ? "Unable to start playback" : "Starting playback")
    if (outcome === "unsupported") assert.equal(player.startupOverlayTarget.spinner.style.display, "none")
  })
}

test("all transport playback calls use the common policy helper", () => {
  const controller = readFileSync(new URL("../../app/javascript/controllers/video_player_controller.js", import.meta.url), "utf8")
  const withoutHelper = controller.replace(/  async requestPlayback\([\s\S]*?\n  showPlaybackFailure\(/, "  showPlaybackFailure(")
  assert.doesNotMatch(withoutHelper, /\b(?:video|this\.videoTarget)\.play\(/)
  for (const file of ["playback_engine.js", "hls_session_client.js", "subtitle_pipeline.js"]) {
    const source = readFileSync(new URL(`../../app/javascript/player/${file}`, import.meta.url), "utf8")
    assert.doesNotMatch(source, /\b(?:video|player\.videoTarget|this\.player\.videoTarget)\.play\(/)
    assert.match(source, /requestPlayback\(/)
  }
})

test("a new play prompt cannot be hidden by an old startup fade timer", () => {
  const { player, fire } = fixture()
  player.hideStartupOverlay()
  player.showPlayPrompt()
  fire(220)
  assert.equal(player.startupOverlayTarget.classes.has("hidden"), false)
  assert.equal(player.startupOverlayTarget.attributes.get("role"), "button")
})

for (const gesture of ["click", "Enter", " "]) {
  test(`blocked autoplay remains recoverable synchronously by ${gesture}`, async () => {
    const { player, video } = fixture()
    video.paused = true
    video.play = () => Promise.reject({ name: "NotAllowedError" })
    assert.equal(await player.requestPlayback(), false)
    let calls = 0
    video.play = () => { calls += 1; assert.equal(video.muted, false); video.paused = false; return Promise.resolve() }
    const type = gesture === "click" ? "click" : "keydown"
    player.startupOverlayTarget.listeners.get(type)({ type, key: gesture, preventDefault() {}, stopPropagation() {} })
    assert.equal(calls, 1)
    await new Promise(setImmediate)
    assert.equal(player.playPromptCleanup, null)
    assert.equal(player.startupOverlayTarget.attributes.get("aria-hidden"), "true")
  })
}

test("starting playback preserves the selected volume", async () => {
  const { player, video } = fixture()
  video.paused = true
  video.volume = 0.35
  video.play = () => {
    assert.equal(video.muted, false)
    assert.equal(video.volume, 0.35)
    video.paused = false
    return Promise.resolve()
  }
  assert.equal(await player.requestPlayback(), true)
  assert.equal(video.volume, 0.35)
  assert.equal(player.startupOverlayTarget.attributes.get("aria-hidden"), "true")
})

test("unmuting a deliberately paused video does not resume it", () => {
  const { player, video } = fixture()
  video.paused = true
  video.muted = true
  player.userPaused = true
  video.play = () => { assert.fail("must preserve the user pause") }
  player.toggleMute()
  assert.equal(video.muted, false)
  assert.equal(video.paused, true)
  assert.equal(player.userPaused, true)
})

test("player keeps the mute control without requiring a separate sound opt-in", () => {
  const view = readFileSync(new URL("../../app/views/streaming/show.html.erb", import.meta.url), "utf8")
  assert.match(view, /<button[^>]*data-action="click->video-player#toggleMute"/s)
  assert.doesNotMatch(view, /enableSound|Enable sound/)
  assert.doesNotMatch(view.match(/<video\b[^>]*>/s)?.[0] || "", /\bmuted\b/)
})

test("the video template cannot bypass controlled startup buffering", () => {
  const view = readFileSync(new URL("../../app/views/streaming/show.html.erb", import.meta.url), "utf8")
  const videoTag = view.match(/<video\b[^>]*>/s)?.[0]
  assert.ok(videoTag)
  assert.match(videoTag, /\bplaysinline\b/)
  assert.doesNotMatch(videoTag, /\bautoplay\b/)
})

test("MSE setup disables implicit autoplay before assigning a source and preserves a user pause", () => {
  const { player, video } = fixture()
  const assignments = []
  let src = ""
  video.autoplay = true
  player.userPaused = true
  Object.defineProperty(video, "src", {
    get: () => src,
    set: (value) => { assignments.push(video.autoplay); src = value }
  })
  player.mseSupported = true
  player.clearSystemRebufferGate = () => {}
  const engine = player.playbackEngine()
  engine.createMediaSource = () => ({ addEventListener() {} })
  engine.createObjectUrl = () => "blob:mse-fixture"
  engine.setupMseSource("/transcode?source=test-owned-placeholder")
  assert.deepEqual(assignments, [false])
  assert.equal(player.userPaused, true)
})

function pausedSeekFixture(path = "mse") {
  const f = fixture(path)
  const { player, video, timeRanges } = f
  Object.assign(player, {
    element: { dataset: {} }, streamingUrlValue: "/transcode?source=local-fixture",
    knownDuration: 100, mseSupported: true, remuxDirectPlay: path === "remux",
    burnedSubtitleSelected: () => false, clearSubtitleCues() {}, reloadTextSubtitlesAt() {},
    resetProgressBaseline() {}, renderAudioControls() {}, closeTrackMenus() {},
    startStreamingFetch() {}, isChromium: () => false, remuxLoadToken: 0
  })
  const engine = player.playbackEngine()
  engine.createMediaSource = () => ({
    ...target(), readyState: "open", endOfStream() {},
    addSourceBuffer: () => ({ ...target(), buffered: video.buffered })
  })
  engine.createObjectUrl = () => "blob:replacement"
  engine.revokeObjectUrl = () => {}
  player.togglePlay()
  assert.equal(player.userPaused, true)
  assert.equal(video.paused, true)
  video.buffered = timeRanges([])
  let plays = 0
  video.play = () => { plays += 1; video.paused = false; return Promise.resolve() }
  return { ...f, plays: () => plays }
}

for (const action of ["seek", "audio change"]) {
  test(`paused MSE ${action} completes on readiness without playback and can explicitly resume`, async () => {
    const { player, video, timeRanges, plays } = pausedSeekFixture()
    if (action === "seek") player.performSeek(0.5)
    else player.selectAudioTrack({ currentTarget: { dataset: { audioStream: "2" } } })
    assert.equal(player.isSeeking, true)
    assert.equal(player.seekingOverlayTarget.classes.has("hidden"), false)
    player.mediaSource.listeners.get("sourceopen")()
    video.currentTime = 0
    player.maybeStartPlayback(true)
    assert.equal(player.isSeeking, true, "an empty replacement is not ready")

    video.buffered = timeRanges([[0, 80]])
    player.sourceBuffer.buffered = video.buffered
    player.maybeStartPlayback()
    assert.equal(plays(), 0)
    assert.equal(player.userPaused, true)
    assert.equal(video.paused, true)
    assert.equal(player.playbackStarted, false, "readiness is not playback")
    assert.equal(player.isSeeking, false)
    assert.equal(player.seekingOverlayTarget.classes.has("hidden"), true)
    if (action === "audio change") assert.match(player.streamingUrlValue, /audio_stream=2/)
    player.togglePlay()
    await new Promise(setImmediate)
    assert.equal(plays(), 1)
    assert.equal(player.userPaused, false)
    assert.equal(video.paused, false)
  })
}

test("ready paused MSE seeks drain the queued seek without playing the old source", () => {
  const { player, video, timeRanges, plays } = pausedSeekFixture()
  player.performSeek(0.5)
  player.mediaSource.listeners.get("sourceopen")()
  player.performSeek(0.7)
  assert.equal(player.pendingSeekSeconds, 70)
  video.currentTime = 0
  video.buffered = timeRanges([[0, 80]])
  player.sourceBuffer.buffered = video.buffered
  player.maybeStartPlayback()
  assert.equal(player.pendingSeekSeconds, null)
  assert.equal(player.startSecondsValue, 70)
  assert.equal(player.isSeeking, true, "the queued replacement still needs readiness")
  assert.equal(plays(), 0)
  assert.equal(player.userPaused, true)
})

for (const hold of ["subtitle", "navigation", "native seek", "disconnected"]) {
  test(`paused MSE readiness cannot finish a seek during ${hold}`, () => {
    const { player, video, timeRanges, plays } = pausedSeekFixture()
    player.performSeek(0.5)
    player.mediaSource.listeners.get("sourceopen")()
    video.currentTime = 0
    video.buffered = timeRanges([[0, 80]])
    player.sourceBuffer.buffered = video.buffered
    if (hold === "subtitle") player.subtitlePlaybackHoldToken = 4
    if (hold === "navigation") player.navigatingAway = true
    if (hold === "native seek") video.seeking = true
    if (hold === "disconnected") player.playbackDisconnected = true
    player.maybeStartPlayback()
    assert.equal(player.isSeeking, true)
    assert.equal(player.seekingOverlayTarget.classes.has("hidden"), false)
    assert.equal(plays(), 0)
  })
}

for (const skipSeconds of [0, 3]) {
  test(`paused remux seek completes after native readiness and pre-roll (${skipSeconds}s)`, async () => {
    const { player, video, timeRanges, plays } = pausedSeekFixture("remux")
    player.loadRemuxSeekPlan = async () => ({ anchor_seconds: 50 - skipSeconds, input_seek_seconds: 50, skip_seconds: skipSeconds })
    player.performSeek(0.5)
    await new Promise(setImmediate)
    video.currentTime = 0
    video.listeners.get("loadeddata")()
    assert.equal(player.isSeeking, true, "an empty replacement is not ready")
    video.buffered = timeRanges([[0, 8]])
    video.listeners.get("progress")()
    if (skipSeconds > 0) {
      assert.equal(player.isSeeking, true, "native pre-roll seek must finish first")
      video.listeners.get("seeked")()
    }
    assert.equal(video.currentTime, skipSeconds)
    assert.equal(player.isSeeking, false)
    assert.equal(player.seekingOverlayTarget.classes.has("hidden"), true)
    assert.equal(player.userPaused, true)
    assert.equal(video.paused, true)
    assert.equal(plays(), 0)
    assert.equal(player.remuxLoadCleanup, null)
    player.togglePlay()
    await new Promise(setImmediate)
    assert.equal(plays(), 1)
    assert.equal(video.paused, false)
  })
}

test("HLS startup does not re-enable implicit autoplay", () => {
  const source = readFileSync(new URL("../../app/javascript/player/hls_session_client.js", import.meta.url), "utf8")
  assert.doesNotMatch(source, /\.autoplay\s*=\s*true/)
})

test("pause during system rebuffer remains paused through the deadline", () => {
  const { player, video, fire, timeRanges } = fixture()
  player.beginSystemRebuffer()
  player.togglePlay()
  assert.equal(player.userPaused, true)
  video.buffered = timeRanges([[0, 80]])
  player.sourceBuffer = { buffered: video.buffered }
  video.play = () => { assert.fail("deadline must not resume a user pause") }
  fire(12000)
  player.maybeStartPlayback(true)
  assert.equal(video.paused, true)
})

test("HLS seeking leaves the old timeline offset until the source is installed", () => {
  const { player } = fixture("hls")
  player.startSecondsValue = 100
  player.element = { dataset: { videoPlayerStartSecondsValue: "100" } }
  let targetSeconds
  player.restartHlsSession = (position) => { targetSeconds = position }
  player.restartPlaybackAt(250)
  assert.equal(targetSeconds, 250)
  assert.equal(player.startSecondsValue, 100)
  assert.equal(player.element.dataset.videoPlayerStartSecondsValue, "100")
})

test("pre-wait movement is not evidence that a new MSE wait has recovered", () => {
  const { player, video, fire } = fixture()
  player.onTimeUpdate()
  video.currentTime += 0.5
  let pauses = 0
  player.beginSystemRebuffer = () => { pauses += 1 }
  player.startStallWatchdog = () => {}
  player.onVideoWaiting()
  player.onProgress()
  fire(200)
  assert.equal(pauses, 1)
})

test("startup synchronization cannot infer playback from readyState or a resumed timestamp", () => {
  const { player, fire, context } = fixture()
  context.HTMLMediaElement = { HAVE_CURRENT_DATA: 2 }
  player.syncStartupOverlay()
  fire(0)
  assert.notEqual(player.startupOverlayTarget.attributes.get("aria-hidden"), "true")
})

for (const path of ["direct", "hls"]) {
  test(`same-source ${path} restart invalidates outstanding policy rejections`, async () => {
    const { player, video } = fixture(path)
    player.element = { dataset: {} }
    player.burnedSubtitleSelected = () => false
    player.clearSubtitleCues = () => {}
    player.reloadTextSubtitlesAt = () => {}
    player.resetProgressBaseline = () => {}
    player.restartHlsSession = () => {}
    let reject
    let calls = 0
    video.paused = true
    video.play = () => {
      calls += 1
      return calls === 1 ? new Promise((_resolve, r) => { reject = r }) : Promise.reject({ name: "NotAllowedError" })
    }
    const pending = player.requestPlayback()
    player.restartPlaybackAt(30)
    reject({ name: "NotAllowedError" })
    assert.equal(await pending, false)
    assert.equal(calls, 1)
    assert.equal(player.playPromptCleanup, null)
  })
}

test("a genuine MSE startup pause is not consumed by the buffer gate", () => {
  const { player, video, timeRanges } = fixture()
  player.playbackStarted = false
  player.userPaused = true
  player.sourceBuffer = { buffered: timeRanges([[0, 80]]) }
  video.buffered = player.sourceBuffer.buffered
  video.play = () => { assert.fail("startup must preserve a user pause") }
  player.maybeStartPlayback(true)
  assert.equal(player.playbackStarted, false)
})

test("starting playback respects a deliberate user mute", async () => {
  const { player, video } = fixture()
  video.paused = true
  video.muted = true
  assert.equal(await player.requestPlayback(), true)
  assert.equal(video.muted, true)
})

test("native unmute updates the volume icon without changing playback", () => {
  const { player, video } = fixture()
  player.volumeIconTarget = target()
  player.muteIconTarget = target()
  video.muted = true
  player.updateVolumeIcon()
  assert.equal(player.muteIconTarget.classes.has("hidden"), false)
  assert.equal(player.volumeIconTarget.classes.has("hidden"), true)
  video.muted = false
  video.play = () => { assert.fail("volumechange must not start playback") }
  player.updateVolumeIcon()
  assert.equal(player.muteIconTarget.classes.has("hidden"), true)
  assert.equal(player.volumeIconTarget.classes.has("hidden"), false)
})

for (const event of ["seeking", "seeked", "emptied"]) {
  test(`native ${event} clears playback observations and disconnect removes the listener`, () => {
    const { player, video } = connectedFixture()
    player.onTimeUpdate()
    video.listeners.get(event)()
    video.currentTime = 40
    player.onTimeUpdate()
    assert.equal(player.seekingOverlayTarget.classes.has("hidden"), false)
    video.currentTime += 0.2
    player.onTimeUpdate()
    assert.equal(player.seekingOverlayTarget.classes.has("hidden"), true)
    player.disconnect()
    assert.equal(video.listeners.has(event), false)
  })
}

for (const action of ["disconnect", "stopPlaybackForNavigation", "togglePlay"]) {
  test(`a real ${action} invalidates pending policy rejection`, async () => {
    const { player, video } = connectedFixture()
    let reject
    video.play = () => new Promise((_resolve, r) => { reject = r })
    const pending = player.requestPlayback()
    player[action]()
    reject({ name: "NotAllowedError" })
    assert.equal(await pending, false)
    assert.equal(player.playPromptCleanup, null)
    assert.equal(video.muted, false)
  })
}

test("a native seek retires a waiting callback even when the URL is unchanged", () => {
  const { player, video, fire } = connectedFixture()
  let pauses = 0
  player.beginSystemRebuffer = () => { pauses += 1 }
  player.bufferedAheadOfCurrent = () => 0
  player.startStallWatchdog = () => {}
  player.onVideoWaiting()
  video.listeners.get("seeking")()
  video.currentTime = 30
  video.listeners.get("seeked")()
  fire(200)
  assert.equal(pauses, 0)
})

for (const path of ["direct", "remux", "hls", "mse"]) {
  test(`old waiting callback cannot interrupt confirmed playback: ${path}`, () => {
    const { player, video, fire } = fixture(path)
    let pauses = 0
    let watchdogs = 0
    player.beginSystemRebuffer = () => { pauses += 1 }
    player.startStallWatchdog = () => { watchdogs += 1 }
    player.onVideoWaiting()
    video.currentTime += 0.2
    player.onVideoReady()
    fire(path === "direct" || path === "remux" ? 1500 : 200)
    assert.equal(pauses, 0)
    assert.equal(watchdogs, 0)
    assert.equal(player.seekingOverlayTarget.classes.has("hidden"), true)
  })

  for (const change of ["source", "userPause", "navigation", "ended", "seeking", "subtitleHold"]) {
    test(`pending wait is invalid after ${change}: ${path}`, () => {
      const { player, video, fire } = fixture(path)
      let effects = 0
      player.beginSystemRebuffer = () => { effects += 1 }
      player.startStallWatchdog = () => { effects += 1 }
      player.showBufferingOverlay = () => { effects += 1 }
      player.onVideoWaiting()
      if (change === "source") video.src = "blob:new-source"
      if (change === "userPause") player.userPaused = true
      if (change === "navigation") player.navigatingAway = true
      if (change === "ended") video.ended = true
      if (change === "seeking") video.seeking = true
      if (change === "subtitleHold") player.subtitlePlaybackHoldToken = 7
      fire(path === "direct" || path === "remux" ? 1500 : 200)
      assert.equal(effects, 0)
    })
  }
}
