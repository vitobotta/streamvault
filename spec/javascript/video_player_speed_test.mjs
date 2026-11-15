import assert from "node:assert/strict"
import test from "node:test"

import { createVideoPlayerHarness } from "./support/video_player_harness.mjs"

const { VideoPlayerController } = createVideoPlayerHarness()

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

function option(rate) {
  return {
    dataset: { videoPlayerSpeed: String(rate) },
    attributes: {},
    classList: { toggled: [], toggle(name) { this.toggled.push(name) } },
    focused: false,
    setAttribute(name, value) { this.attributes[name] = value },
    focus() { this.focused = true }
  }
}

function speedPlayer({ open = true } = {}) {
  const options = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2].map(option)
  const toggleButton = { focused: false, focus() { this.focused = true } }
  const menu = {
    hidden: !open,
    classList: {
      add(name) { if (name === "hidden") menu.hidden = true },
      remove(name) { if (name === "hidden") menu.hidden = false },
      contains(name) { return name === "hidden" ? menu.hidden : false },
      toggle(name, force) { if (name === "hidden") menu.hidden = force === undefined ? !menu.hidden : force }
    },
    querySelectorAll: () => options
  }

  const player = new VideoPlayerController()
  player.playbackRate = 1
  player.videoTarget = {
    playbackRate: 1,
    defaultPlaybackRate: 1,
    paused: true,
    pause() {},
    play: async () => {}
  }
  player.speedButtonLabelTarget = { textContent: "1×" }
  player.hasSpeedButtonLabelTarget = true
  player.speedMenuTarget = menu
  player.hasSpeedMenuTarget = true
  player.speedControlsTarget = { querySelector: () => toggleButton }
  player.hasSpeedControlsTarget = true
  player.showOverlayUi = () => { player.overlayShown = true }
  player.closeTrackMenus = () => { player.menusClosed = true }
  return { player, options, menu, toggleButton }
}

test("selecting a speed applies it to the video and marks only that option", () => {
  const { player, options } = speedPlayer()
  const event = { currentTarget: { dataset: { speed: "1.5" } }, defaultPrevented: false, preventDefault() { this.defaultPrevented = true } }

  player.selectSpeed(event)

  assert.equal(event.defaultPrevented, true)
  assert.equal(player.playbackRate, 1.5)
  assert.equal(player.videoTarget.playbackRate, 1.5)
  assert.equal(player.speedButtonLabelTarget.textContent, "1.5×")
  assert.equal(player.menusClosed, true)
  assert.deepEqual(
    options.filter((entry) => entry.attributes["aria-checked"] === "true").map((entry) => entry.dataset.videoPlayerSpeed),
    ["1.5"]
  )
})

test("the chosen speed also becomes the default rate so it survives a reload", () => {
  const { player } = speedPlayer()

  player.applyPlaybackRate(2)

  assert.equal(player.videoTarget.defaultPlaybackRate, 2)
  assert.equal(player.videoTarget.playbackRate, 2)
  assert.equal(player.speedButtonLabelTarget.textContent, "2×")
})

test("a non-numeric speed is ignored instead of poisoning playback", () => {
  const { player } = speedPlayer()

  player.selectSpeed({ currentTarget: { dataset: { speed: "" } }, preventDefault() {}, defaultPrevented: false })

  assert.equal(player.playbackRate, 1)
  assert.equal(player.videoTarget.playbackRate, 1)
})

test("arrow keys move focus through the speed options and wrap at both ends", () => {
  const { player, options } = speedPlayer()

  const down = Object.assign(keyEvent("ArrowDown"), { target: options[0] })
  player.onSpeedMenuKeydown(down)
  assert.equal(down.defaultPrevented, true)
  assert.equal(options[1].focused, true)

  const atEnd = Object.assign(keyEvent("ArrowDown"), { target: options[options.length - 1] })
  player.onSpeedMenuKeydown(atEnd)
  assert.equal(options[0].focused, true)

  const atStart = Object.assign(keyEvent("ArrowUp"), { target: options[0] })
  player.onSpeedMenuKeydown(atStart)
  assert.equal(options[options.length - 1].focused, true)
})

test("arrow keys entered from outside the list start at the matching end", () => {
  const { player, options } = speedPlayer()

  player.onSpeedMenuKeydown(Object.assign(keyEvent("ArrowDown"), { target: {} }))
  assert.equal(options[0].focused, true)

  player.onSpeedMenuKeydown(Object.assign(keyEvent("ArrowUp"), { target: {} }))
  assert.equal(options[options.length - 1].focused, true)
})

test("Escape closes the speed menu and returns focus to its toggle", () => {
  const { player, toggleButton, menu } = speedPlayer()

  const event = keyEvent("Escape")
  player.onSpeedMenuKeydown(event)

  assert.equal(event.defaultPrevented, true)
  assert.equal(player.menusClosed, true)
  assert.equal(menu.hidden, true)
  assert.equal(toggleButton.focused, true)
})

test("keys the menu does not own are left to the browser", () => {
  const { player, options } = speedPlayer()

  for (const key of ["ArrowLeft", "Tab", "a"]) {
    const event = Object.assign(keyEvent(key), { target: options[0] })
    player.onSpeedMenuKeydown(event)
    assert.equal(event.defaultPrevented, false, `expected ${key} to be ignored`)
  }
})

test("the skip buttons seek by their own offset", () => {
  const { player } = speedPlayer()
  const offsets = []
  player.seekRelative = (offset) => offsets.push(offset)

  const back = { currentTarget: { dataset: { seekOffset: "-10" } }, preventDefault() {}, defaultPrevented: false }
  const forward = { currentTarget: { dataset: { seekOffset: "10" } }, preventDefault() {}, defaultPrevented: false }

  player.seekBy(back)
  player.seekBy(forward)

  assert.deepEqual(offsets, [-10, 10])
  assert.equal(player.overlayShown, true)
})

test("f toggles fullscreen and m toggles mute", () => {
  const { player } = speedPlayer()
  const calls = []
  player.toggleFullscreen = () => calls.push("fullscreen")
  player.toggleMute = () => calls.push("mute")
  player.isInteractiveElement = () => false

  const f = keyEvent("f")
  const m = keyEvent("m")
  player.onKeyDown(f)
  player.onKeyDown(m)

  assert.deepEqual(calls, ["fullscreen", "mute"])
  assert.equal(f.defaultPrevented, true)
  assert.equal(m.defaultPrevented, true)
})

test("shortcut keys respect modifiers, repeats and focused controls", () => {
  const { player } = speedPlayer()
  player.toggleFullscreen = () => { throw new Error("must not toggle") }
  player.toggleMute = () => { throw new Error("must not toggle") }
  player.isInteractiveElement = () => false

  for (const event of [keyEvent("f", { ctrlKey: true }), keyEvent("m", { repeat: true })]) {
    player.onKeyDown(event)
    assert.equal(event.defaultPrevented, false)
  }

  player.isInteractiveElement = () => true
  const inField = keyEvent("f")
  player.onKeyDown(inField)
  assert.equal(inField.defaultPrevented, false)
})
