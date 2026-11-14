import assert from "node:assert/strict"
import test from "node:test"

import { createVideoPlayerHarness } from "./support/video_player_harness.mjs"

const { VideoPlayerController } = createVideoPlayerHarness()

function keyboardPlayer({ duration = 1000, position = 100, seeking = false } = {}) {
  const player = new VideoPlayerController()
  player.knownDuration = duration
  player.isSeeking = seeking
  player.playbackTimelineOffset = () => 0
  player.videoTarget = { currentTime: position, paused: true }
  player.currentTimeTarget = { textContent: "" }
  player.updateSeekVisuals = () => {}
  player.showOverlayUi = () => {}
  player.isInteractiveElement = () => false
  player.seekTargets = []
  player.restartPlaybackAt = (seconds) => { player.seekTargets.push(seconds) }
  return player
}

function keyEvent(key, overrides = {}) {
  return {
    key,
    repeat: false,
    metaKey: false,
    ctrlKey: false,
    altKey: false,
    shiftKey: false,
    target: null,
    defaultPrevented: false,
    preventDefault() { this.defaultPrevented = true },
    ...overrides
  }
}

test("ArrowRight skips 15 seconds forward", () => {
  const player = keyboardPlayer({ position: 100 })
  const event = keyEvent("ArrowRight")

  player.onKeyDown(event)

  assert.equal(event.defaultPrevented, true)
  assert.deepEqual(player.seekTargets, [115])
  assert.equal(player.currentTimeTarget.textContent, "1:55")
})

test("ArrowLeft skips 15 seconds backward", () => {
  const player = keyboardPlayer({ position: 100 })

  player.onKeyDown(keyEvent("ArrowLeft"))

  assert.deepEqual(player.seekTargets, [85])
})

test("backward skip clamps at the start and forward skip clamps at the duration", () => {
  const player = keyboardPlayer({ position: 5 })
  player.onKeyDown(keyEvent("ArrowLeft"))
  assert.deepEqual(player.seekTargets, [0])

  const nearEnd = keyboardPlayer({ position: 995 })
  nearEnd.onKeyDown(keyEvent("ArrowRight"))
  assert.deepEqual(nearEnd.seekTargets, [1000])
})

test("modifier chords, repeats, and interactive targets do not seek", () => {
  const player = keyboardPlayer()
  player.seekBySeconds = () => { throw new Error("must not seek") }

  const chords = [
    keyEvent("ArrowRight", { metaKey: true }),
    keyEvent("ArrowLeft", { ctrlKey: true }),
    keyEvent("ArrowRight", { altKey: true }),
    keyEvent("ArrowLeft", { shiftKey: true }),
    keyEvent("ArrowRight", { repeat: true })
  ]
  for (const event of chords) {
    player.onKeyDown(event)
    assert.equal(event.defaultPrevented, false)
  }

  const interactive = keyEvent("ArrowRight")
  player.isInteractiveElement = () => true
  player.onKeyDown(interactive)
  assert.equal(interactive.defaultPrevented, false)
})

test("unhandled keys are left to the browser", () => {
  const player = keyboardPlayer()
  player.seekBySeconds = () => { throw new Error("must not seek") }
  const event = keyEvent("ArrowUp")

  player.onKeyDown(event)

  assert.equal(event.defaultPrevented, false)
})

test("space still toggles playback", () => {
  const player = keyboardPlayer()
  player.togglePlay = () => { player.toggled = true }
  const event = keyEvent(" ")

  player.onKeyDown(event)

  assert.equal(event.defaultPrevented, true)
  assert.equal(player.toggled, true)
})

test("a seek already in flight queues the keyboard target", () => {
  const player = keyboardPlayer({ position: 100, seeking: true })
  player.isRemuxDirectPlay = () => false

  player.onKeyDown(keyEvent("ArrowRight"))

  assert.deepEqual(player.seekTargets, [])
  assert.equal(player.pendingSeekSeconds, 115)
})
