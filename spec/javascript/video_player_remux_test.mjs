import assert from "node:assert/strict"
import test from "node:test"

import { createVideoPlayerHarness } from "./support/video_player_harness.mjs"

const { harness, context, VideoPlayerController, timeRanges } = createVideoPlayerHarness()

test("remux seeks FFmpeg to the target while skipping from the keyframe timeline", async () => {
  const player = new VideoPlayerController()
  player.remuxLoadToken = 0
  player.playbackId = "playback-1"
  player.streamingUrlValue = "/transcode?url=https%3A%2F%2Fexample.test%2Fmovie.mkv"
  player.tracksData = { remux_direct_url: "/transcode?url=https%3A%2F%2Fexample.test%2Fmovie.mkv&remux=1" }
  player.selectedAudioStream = null
  player.selectedSubtitleStream = null
  player.subtitleTracks = []
  player.element = { dataset: {} }
  player.loadRemuxSeekPlan = async () => ({ copy_safe: true, anchor_seconds: 120, input_seek_seconds: 125, skip_seconds: 5 })
  let loadArgs
  player.loadRemuxSource = (...args) => { loadArgs = args }

  await player.loadRemuxAt(125)

  assert.equal(player.startSecondsValue, 120)
  assert.match(loadArgs[0], /start_seconds=125/)
  assert.match(loadArgs[0], /remux=1/)
  assert.match(loadArgs[0], /load_id=1/)
  assert.equal(loadArgs[1], 5)
  assert.equal(loadArgs[2], 125)
  assert.equal(loadArgs[3], 1)
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
  let loadCount = 0
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
    autoplay: true,
    addEventListener: (name, callback) => { listeners[name] = callback },
    removeEventListener: (name, callback) => {
      if (listeners[name] === callback) delete listeners[name]
    },
    load: () => { loadCount += 1 },
    play: () => { playCount += 1; return Promise.resolve() }
  }

  player.loadRemuxSource("/transcode?remux=1", 0, 0, 1)
  assert.equal(player.videoTarget.autoplay, false)
  assert.equal(loadCount, 0)
  listeners.loadeddata()
  assert.equal(playCount, 0)

  ranges = [[0, 0.6]]
  listeners.progress()
  assert.equal(playCount, 1)
})

test("Chromium remux startup measures B-frame presentation offset before seeking", () => {
  const player = new VideoPlayerController()
  const listeners = {}
  const seeks = []
  let currentTime = 0
  let frameCallback
  let playCount = 0
  const buffered = timeRanges([[0, 6]])
  player.remuxLoadToken = 1
  player.remuxLoadCleanup = null
  player.startSecondsValue = 120
  player.element = { dataset: {} }
  player.isChromium = () => true
  player.videoTarget = {
    buffered,
    readyState: 2,
    autoplay: true,
    get currentTime() { return currentTime },
    set currentTime(value) { currentTime = value; seeks.push(value) },
    addEventListener: (name, callback) => { listeners[name] = callback },
    removeEventListener: (name, callback) => {
      if (listeners[name] === callback) delete listeners[name]
    },
    requestVideoFrameCallback: (callback) => {
      frameCallback = callback
      return 17
    },
    cancelVideoFrameCallback: () => {},
    play: () => { playCount += 1; return Promise.resolve() }
  }

  player.loadRemuxSource("/transcode?remux=1", 5, 125, 1)
  listeners.loadeddata()
  assert.deepEqual(seeks, [0.001])

  frameCallback(0, { mediaTime: 0.083 })

  assert.equal(seeks.length, 2)
  assert.ok(Math.abs(seeks[1] - 5.083) < 0.000001)
  assert.ok(Math.abs(player.startSecondsValue - 119.917) < 0.000001)
  assert.equal(player.element.dataset.videoPlayerStartSecondsValue, "119.917")
  assert.equal(playCount, 0)

  listeners.seeked()
  assert.equal(playCount, 1)
})

test("Safari remux startup never waits for a paused video-frame callback", () => {
  const player = new VideoPlayerController()
  const listeners = {}
  const seeks = []
  let currentTime = 0
  let frameRequests = 0
  let playCount = 0
  player.remuxLoadToken = 1
  player.remuxLoadCleanup = null
  player.isChromium = () => false
  player.isSafari = () => true
  player.videoTarget = {
    buffered: timeRanges([[0, 6]]),
    readyState: 2,
    autoplay: true,
    get currentTime() { return currentTime },
    set currentTime(value) { currentTime = value; seeks.push(value) },
    addEventListener: (name, callback) => { listeners[name] = callback },
    removeEventListener: (name, callback) => {
      if (listeners[name] === callback) delete listeners[name]
    },
    requestVideoFrameCallback: () => { frameRequests += 1; return 17 },
    play: () => { playCount += 1; return Promise.resolve() }
  }

  player.loadRemuxSource("/transcode?remux=1", 5, 125, 1)
  listeners.loadeddata()

  assert.equal(frameRequests, 0)
  assert.deepEqual(seeks, [5])
  listeners.seeked()
  assert.equal(playCount, 1)
})

test("a missing Chromium frame callback cannot hold remux startup open", async () => {
  const player = new VideoPlayerController()
  const listeners = {}
  const seeks = []
  let currentTime = 0
  let cancelledCallbacks = 0
  let playCount = 0
  player.remuxLoadToken = 1
  player.remuxLoadCleanup = null
  player.isChromium = () => true
  player.videoTarget = {
    buffered: timeRanges([[0, 6]]),
    readyState: 2,
    autoplay: true,
    get currentTime() { return currentTime },
    set currentTime(value) { currentTime = value; seeks.push(value) },
    addEventListener: (name, callback) => { listeners[name] = callback },
    removeEventListener: (name, callback) => {
      if (listeners[name] === callback) delete listeners[name]
    },
    requestVideoFrameCallback: () => 17,
    cancelVideoFrameCallback: () => { cancelledCallbacks += 1 },
    play: () => { playCount += 1; return Promise.resolve() }
  }

  player.loadRemuxSource("/transcode?remux=1", 5, 125, 1)
  listeners.loadeddata()
  assert.deepEqual(seeks, [0.001])

  await new Promise((resolve) => setTimeout(resolve, 550))

  assert.deepEqual(seeks, [0.001, 5])
  assert.equal(cancelledCallbacks, 1)
  listeners.seeked()
  assert.equal(playCount, 1)
})

test("Safari remux falls back when assigning the local seek throws", () => {
  const player = new VideoPlayerController()
  const listeners = {}
  let fallbackTarget
  player.remuxLoadToken = 1
  player.remuxLoadCleanup = null
  player.isChromium = () => false
  player.videoTarget = {
    buffered: timeRanges([[0, 6]]),
    readyState: 2,
    autoplay: true,
    currentTime: 0,
    set currentTime(_value) { throw new Error("not seekable") },
    addEventListener: (name, callback) => { listeners[name] = callback },
    removeEventListener: (name, callback) => {
      if (listeners[name] === callback) delete listeners[name]
    },
    play: () => Promise.resolve()
  }
  player.fallbackRemuxToMse = (target) => { fallbackTarget = target }

  player.loadRemuxSource("/transcode?remux=1", 5, 125, 1)
  listeners.loadeddata()

  assert.equal(fallbackTarget, 125)
})

test("Safari remux falls back when a buffered local seek never completes", async () => {
  const player = new VideoPlayerController()
  const listeners = {}
  let currentTime = 0
  let fallbackTarget
  player.remuxLoadToken = 1
  player.remuxLoadCleanup = null
  player.isChromium = () => false
  player.videoTarget = {
    buffered: timeRanges([[0, 6]]),
    readyState: 2,
    autoplay: true,
    get currentTime() { return currentTime },
    set currentTime(value) { currentTime = value },
    addEventListener: (name, callback) => { listeners[name] = callback },
    removeEventListener: (name, callback) => {
      if (listeners[name] === callback) delete listeners[name]
    },
    play: () => Promise.resolve()
  }
  player.fallbackRemuxToMse = (target) => { fallbackTarget = target }

  player.loadRemuxSource("/transcode?remux=1", 5, 125, 1)
  listeners.loadeddata()
  await new Promise((resolve) => setTimeout(resolve, 550))

  assert.equal(fallbackTarget, 125)
})

test("remux startup falls back when native playback clamps the local seek", () => {
  const player = new VideoPlayerController()
  const listeners = {}
  let currentTime = 0
  let fallbackTarget
  let playCount = 0
  player.remuxLoadToken = 1
  player.remuxLoadCleanup = null
  player.videoTarget = {
    buffered: timeRanges([[0, 6]]),
    readyState: 2,
    autoplay: true,
    get currentTime() { return currentTime },
    set currentTime(_value) { currentTime = 0.083 },
    addEventListener: (name, callback) => { listeners[name] = callback },
    removeEventListener: (name, callback) => {
      if (listeners[name] === callback) delete listeners[name]
    },
    play: () => { playCount += 1; return Promise.resolve() }
  }
  player.fallbackRemuxToMse = (target) => { fallbackTarget = target }

  player.loadRemuxSource("/transcode?remux=1", 5, 125, 1)
  listeners.loadeddata()
  listeners.seeked()

  assert.equal(fallbackTarget, 125)
  assert.equal(playCount, 0)
})
