import assert from "node:assert/strict"
import test from "node:test"

import { createVideoPlayerHarness } from "./support/video_player_harness.mjs"

function fakeButton(initial = []) {
  const classes = new Set(initial)
  const attributes = new Map()
  return {
    classes,
    attributes,
    classList: {
      add: (...items) => items.forEach((item) => classes.add(item)),
      remove: (...items) => items.forEach((item) => classes.delete(item)),
      contains: (item) => classes.has(item),
      toggle: (item, force) => {
        const on = force ?? !classes.has(item)
        if (on) classes.add(item); else classes.delete(item)
        return on
      }
    },
    setAttribute: (name, value) => attributes.set(name, String(value)),
    getAttribute: (name) => attributes.get(name)
  }
}

// The browser APIs are absent from the Node harness, so each fixture
// installs exactly the surface the test wants the controller to see.
function pipFixture({ standard = false, legacy = false, paused = false, standardRejects = false, ios = false, webkitNoop = false } = {}) {
  const { context, VideoPlayerController } = createVideoPlayerHarness()
  const listeners = new Map()
  const button = fakeButton(["hidden"])
  const calls = { enter: 0, exit: 0, modes: [], playback: 0, fullscreen: 0 }

  const video = {
    paused,
    currentTime: 0,
    src: "blob:fixture",
    readyState: 3,
    webkitPresentationMode: "inline",
    addEventListener: (name, callback) => listeners.set(name, callback),
    removeEventListener: (name, callback) => {
      if (listeners.get(name) === callback) listeners.delete(name)
    },
    dispatch(name) {
      listeners.get(name)?.()
    }
  }

  if (standard) {
    context.document.pictureInPictureEnabled = true
    video.requestPictureInPicture = () => {
      calls.enter += 1
      if (standardRejects) {
        return Promise.reject(Object.assign(new Error("unsupported"), { name: "NotSupportedError" }))
      }
      context.document.pictureInPictureElement = video
      return Promise.resolve()
    }
    context.document.exitPictureInPicture = () => {
      calls.exit += 1
      context.document.pictureInPictureElement = null
      return Promise.resolve()
    }
  }

  if (legacy) {
    video.webkitSupportsPresentationMode = () => true
    video.webkitSetPresentationMode = (mode) => {
      calls.modes.push(mode)
      if (!webkitNoop) video.webkitPresentationMode = mode
    }
  }

  if (ios) {
    video.webkitDisplayingFullscreen = false
    video.webkitEnterFullscreen = () => {
      calls.fullscreen += 1
    }
  }

  const player = new VideoPlayerController()
  Object.assign(player, {
    videoTarget: video,
    hasVideoTarget: true,
    pipButtonTarget: button,
    hasPipButtonTarget: true,
    userPaused: false,
    isIOS: () => ios,
    requestPlayback: () => {
      calls.playback += 1
      video.paused = false
      return Promise.resolve(true)
    }
  })

  return { context, player, video, button, calls, listeners, VideoPlayerController }
}

test("a browser without a PiP API keeps the button hidden", () => {
  const { player, button } = pipFixture()

  player.setupPictureInPicture()

  assert.equal(player.pictureInPictureSupported(), false)
  assert.equal(button.classList.contains("hidden"), true)
})

test("the standard API reveals the button in its inactive state", () => {
  const { player, button } = pipFixture({ standard: true })

  player.setupPictureInPicture()

  assert.equal(player.pictureInPictureSupported(), true)
  assert.equal(button.classList.contains("hidden"), false)
  assert.equal(button.getAttribute("aria-pressed"), "false")
  assert.equal(button.getAttribute("aria-label"), "Picture in picture")
})

test("tapping the control requests picture in picture", async () => {
  const { player, calls } = pipFixture({ standard: true })

  await player.togglePictureInPicture()

  assert.equal(calls.enter, 1)
})

test("tapping again exits picture in picture", async () => {
  const { player, video, calls } = pipFixture({ standard: true })
  video.paused = false
  player.videoTarget = video

  await player.togglePictureInPicture()
  await player.togglePictureInPicture()

  assert.equal(calls.enter, 1)
  assert.equal(calls.exit, 1)
})

test("Safari uses the webkit presentation mode", async () => {
  const { player, calls } = pipFixture({ legacy: true })

  await player.togglePictureInPicture()
  await player.togglePictureInPicture()

  assert.deepEqual(calls.modes, ["picture-in-picture", "inline"])
})

test("a device that refuses the presentation mode keeps the control hidden", () => {
  const { player, video, button } = pipFixture({ legacy: true })
  video.webkitSupportsPresentationMode = () => false

  player.setupPictureInPicture()

  assert.equal(player.pictureInPictureSupported(), false)
  assert.equal(button.classList.contains("hidden"), true)
})

test("a paused stream resumes before it pops out", async () => {
  const { player, calls } = pipFixture({ standard: true, paused: true })

  await player.togglePictureInPicture()

  assert.equal(calls.playback, 1)
  assert.equal(player.userPaused, false)
  assert.equal(calls.enter, 1)
})

test("enter and leave events keep the control in sync", () => {
  const { context, player, video, button } = pipFixture({ standard: true })
  player.setupPictureInPicture()

  context.document.pictureInPictureElement = video
  video.dispatch("enterpictureinpicture")

  assert.equal(button.getAttribute("aria-pressed"), "true")
  assert.equal(button.getAttribute("aria-label"), "Exit picture in picture")
  assert.equal(button.getAttribute("title"), "Exit picture in picture")
  assert.equal(button.classList.contains("text-iris-400"), true)

  context.document.pictureInPictureElement = null
  video.dispatch("leavepictureinpicture")

  assert.equal(button.getAttribute("aria-pressed"), "false")
  assert.equal(button.getAttribute("aria-label"), "Picture in picture")
  assert.equal(button.classList.contains("text-iris-400"), false)
})

test("leaving the player closes an active PiP window and drops its listeners", async () => {
  const { context, player, video, calls, listeners } = pipFixture({ standard: true })
  player.setupPictureInPicture()
  context.document.pictureInPictureElement = video

  player.teardownPictureInPicture()
  await new Promise((resolve) => setTimeout(resolve, 0))

  assert.equal(calls.exit, 1)
  assert.equal(listeners.has("enterpictureinpicture"), false)
  assert.equal(listeners.has("leavepictureinpicture"), false)
  assert.equal(listeners.has("webkitpresentationmodechanged"), false)
})

test("Safari's presentation mode wins when both APIs are available", async () => {
  const { player, calls } = pipFixture({ standard: true, legacy: true })

  await player.togglePictureInPicture()

  assert.deepEqual(calls.modes, ["picture-in-picture"])
  assert.equal(calls.enter, 0)
})

test("a missing pictureInPictureEnabled flag does not hide the control", () => {
  const { context, player, button } = pipFixture({ standard: true })
  delete context.document.pictureInPictureEnabled

  player.setupPictureInPicture()

  assert.equal(player.pictureInPictureSupported(), true)
  assert.equal(button.classList.contains("hidden"), false)
})

test("a webkit switch that does nothing falls through to the standard API", async () => {
  const { player, calls } = pipFixture({ standard: true, legacy: true, webkitNoop: true })

  await player.togglePictureInPicture()

  assert.deepEqual(calls.modes, ["picture-in-picture"])
  assert.equal(calls.enter, 1)
})

test("an iPhone whose inline request rejects opens the native player", async () => {
  const { player, video, calls, listeners } = pipFixture({ standard: true, standardRejects: true, ios: true })

  await player.togglePictureInPicture()

  assert.equal(calls.enter, 1)
  assert.equal(calls.fullscreen, 1)
  assert.equal(listeners.has("webkitbeginfullscreen"), true)

  // The native player is the only place iPhone grants PiP, so entering it
  // retries the request once the element belongs to that player.
  video.dispatch("webkitbeginfullscreen")
  await new Promise((resolve) => setTimeout(resolve, 0))

  assert.equal(calls.enter, 2)
})
