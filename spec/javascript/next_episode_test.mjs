import assert from "node:assert/strict"
import test from "node:test"
import { nextEpisodePromptStart } from "../../app/javascript/player/next_episode_prompt.js"
import { ProgressReporter } from "../../app/javascript/player/progress_reporter.js"
import { createVideoPlayerHarness } from "./support/video_player_harness.mjs"

const chapter = (start, end, title = "End Credits") => ({ title, start_time: start, end_time: end })

test("credits markers override the estimate, including shorter and longer credits", () => {
  assert.equal(nextEpisodePromptStart({ duration: 2400, chapters: [chapter(2100, 2300)] }), 2100)
  assert.equal(nextEpisodePromptStart({ duration: 2400, chapters: [chapter(2380, 2400)] }), 2380)
})

test("fallback uses the last 90 seconds, capped to the final tenth for short episodes", () => {
  assert.equal(nextEpisodePromptStart({ duration: 2400 }), 2310)
  assert.equal(nextEpisodePromptStart({ duration: 300 }), 270)
  assert.equal(nextEpisodePromptStart({ duration: 2400, fallbackSeconds: 120 }), 2280)
})

test("zero disables estimates but preserves credits markers", () => {
  assert.equal(nextEpisodePromptStart({ duration: 2400, fallbackSeconds: 0 }), null)
  assert.equal(nextEpisodePromptStart({ duration: 2400, fallbackSeconds: 0, chapters: [chapter(2100, 2400)] }), 2100)
})

test("ignore openings, generic chapters and malformed/out-of-range timings", () => {
  const chapters = [null, chapter(15, 45), chapter(2100, 2300, "Opening Credits"),
    chapter(2100, 2300, "Chapter 12"), chapter(2500, 2600), chapter(2100, 2050),
    chapter(NaN, 2400), chapter(2100, Infinity), chapter(2100, 2500), chapter("2100", 2400)]
  assert.equal(nextEpisodePromptStart({ duration: 2400, chapters }), 2310)
  assert.equal(nextEpisodePromptStart({ duration: 2400, chapters: {} }), 2310)
})

for (const duration of [0, -10, NaN, Infinity, undefined]) {
  test(`unknown/invalid duration never shows a prompt: ${duration}`, () => {
    assert.equal(nextEpisodePromptStart({ duration }), null)
  })
}

function fixture() {
  const { VideoPlayerController, harness, context } = createVideoPlayerHarness()
  const player = new VideoPlayerController()
  const classes = new Set(["hidden"])
  Object.assign(player, {
    typeValue: "show", nextEpisodeUrlValue: "/streaming/play/next_episode?playback=fixture",
    nextEpisodePromptSecondsValue: 90, nextEpisode: { url: "/streaming/resume?after=fixture" },
    nextEpisodePromptTarget: { classList: {
      toggle(name, force) { if (force) classes.add(name); else classes.delete(name) }
    } },
    hasNextEpisodePromptTarget: true, nextEpisodeButtonTarget: { disabled: false },
    hasNextEpisodeStatusTarget: true, nextEpisodeStatusTarget: { textContent: "" },
    playbackStarted: true, knownDuration: 2400, startSecondsValue: 0,
    isSeeking: false, userPaused: false, playbackDisconnected: false, navigatingAway: false,
    videoTarget: { currentTime: 2310, seeking: false, ended: false, duration: 2400 },
    playbackTimelineOffset: () => 0,
    stopPlaybackForNavigation() { this.navigatingAway = true }
  })
  return { player, harness, context, classes }
}

test("prompt appears at threshold and hides when seeking backwards without stopping playback", () => {
  const { player, classes } = fixture()
  player.updateNextEpisodePrompt()
  assert.equal(classes.has("hidden"), false)
  player.videoTarget.currentTime = 100
  player.updateNextEpisodePrompt()
  assert.equal(classes.has("hidden"), true)
})

for (const path of ["direct", "remux", "mse", "hls"]) {
  test(`prompt uses the absolute source timeline after seeking: ${path}`, () => {
    const { player, classes } = fixture()
    player.videoTarget.currentTime = path === "direct" ? 2310 : 110
    player.playbackTimelineOffset = () => path === "direct" ? 0 : 2200
    player.updateNextEpisodePrompt()
    assert.equal(classes.has("hidden"), false)
  })
}

for (const override of [
  { typeValue: "movie" }, { nextEpisode: null }, { playbackStarted: false },
  { playbackDisconnected: true }, { navigatingAway: true }, { isSeeking: true },
  { knownDuration: 0, videoTarget: { currentTime: 2310, duration: Infinity } }
]) {
  test(`prompt stays hidden when ineligible: ${Object.keys(override).join()}`, () => {
    const { player, classes } = fixture()
    Object.assign(player, override)
    player.updateNextEpisodePrompt()
    assert.equal(classes.has("hidden"), true)
  })
}

test("late chapter metadata overrides the estimate", () => {
  const { player, classes } = fixture()
  player.tracksData = { chapters: [chapter(2350, 2400)] }
  player.updateNextEpisodePrompt()
  assert.equal(classes.has("hidden"), true)
  player.videoTarget.currentTime = 2350
  player.updateNextEpisodePrompt()
  assert.equal(classes.has("hidden"), false)
})

test("background next-episode lookup is deduplicated and updates the prompt", async () => {
  const { player, harness, classes } = fixture()
  player.nextEpisode = null
  let requests = 0
  harness.fetchHandler = async () => {
    requests++
    return { ok: true, json: async () => ({ available: true, url: "/streaming/resume?after=fixture" }) }
  }
  await Promise.all([player.loadNextEpisode(), player.loadNextEpisode()])
  assert.equal(requests, 1)
  assert.equal(classes.has("hidden"), false)
})

test("late next-episode response is ignored after disconnect", async () => {
  const { player, harness } = fixture()
  player.nextEpisode = null
  harness.fetchHandler = async () => {
    player.playbackDisconnected = true
    return { ok: true, json: async () => ({ available: true, url: "/streaming/resume?after=fixture" }) }
  }
  await player.loadNextEpisode()
  assert.equal(player.nextEpisode, null)
})

test("lookup failure leaves playback alone and can retry", async () => {
  const { player, harness, classes } = fixture()
  player.nextEpisode = null
  harness.fetchHandler = async () => ({ ok: false })
  await player.loadNextEpisode()
  assert.equal(classes.has("hidden"), true)
  harness.fetchHandler = async () => ({ ok: true, json: async () => ({ available: true, url: "/streaming/resume?after=fixture" }) })
  await player.loadNextEpisode()
  assert.equal(classes.has("hidden"), false)
})

test("skip saves completion once before navigation and suppresses duplicate clicks/ended", async () => {
  const { player, context } = fixture()
  let finish
  let saves = 0
  player.saveProgress = (completed) => {
    assert.equal(completed, true)
    saves++
    return new Promise((resolve) => { finish = resolve })
  }
  const skip = player.skipToNextEpisode()
  await player.skipToNextEpisode()
  await player.onVideoEnded()
  assert.equal(saves, 1)
  assert.equal(context.window.location.href, undefined)
  finish(true)
  await skip
  assert.equal(context.window.location.href, "/streaming/resume?after=fixture")
  assert.equal(player.navigatingAway, true)
})

test("failed completion save stays on the current episode and permits retry", async () => {
  const { player, context } = fixture()
  player.saveProgress = async () => false
  await player.skipToNextEpisode()
  assert.equal(context.window.location.href, undefined)
  assert.equal(player.advancingEpisode, false)
  assert.equal(player.nextEpisodeButtonTarget.disabled, false)
  assert.match(player.nextEpisodeStatusTarget.textContent, /try again/i)
  player.saveProgress = async () => true
  await player.skipToNextEpisode()
  assert.equal(context.window.location.href, "/streaming/resume?after=fixture")
})

test("natural end still advances without requiring a click; movies and finales do not navigate", async () => {
  const { player, context } = fixture()
  player.loadNextEpisode = async () => {}
  player.saveProgress = async () => true
  await player.onVideoEnded()
  assert.equal(context.window.location.href, "/streaming/resume?after=fixture")
  const finale = fixture()
  finale.player.nextEpisode = null
  finale.player.loadNextEpisode = async () => {}
  let saved = 0
  finale.player.saveProgress = async () => { saved++; return true }
  await finale.player.onVideoEnded()
  assert.equal(saved, 1)
  assert.equal(finale.context.window.location.href, undefined)
  finale.player.typeValue = "movie"
  await finale.player.onVideoEnded()
  assert.equal(saved, 1)
})

test("completion waits for in-flight progress; periodic/unload writes cannot undo it", async () => {
  const { player } = fixture()
  let finishFirst
  const payloads = []
  const reporter = new ProgressReporter(player, { fetcher: (_url, options) => {
    payloads.push(JSON.parse(options.body))
    return payloads.length === 1 ? new Promise((resolve) => { finishFirst = resolve }) : Promise.resolve({ ok: true })
  } })
  const first = reporter.save()
  player.advancingEpisode = true
  const completed = reporter.save(true)
  await reporter.save()
  reporter.saveSync()
  assert.equal(payloads.length, 1)
  finishFirst({ ok: true })
  await first
  assert.equal(await completed, true)
  assert.deepEqual(payloads.map((p) => p.progress_seconds), [2310, 2400])
})

test("progress save returns failure for non-OK HTTP responses", async () => {
  const { player } = fixture()
  const reporter = new ProgressReporter(player, { fetcher: async () => ({ ok: false }) })
  assert.equal(await reporter.save(true), false)
})
