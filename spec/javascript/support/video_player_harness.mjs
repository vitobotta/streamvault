import fs from "node:fs"
import vm from "node:vm"
import { HlsSessionClient } from "../../../app/javascript/player/hls_session_client.js"
import { MseBufferManager } from "../../../app/javascript/player/mse_buffer_manager.js"
import { PlaybackEngine } from "../../../app/javascript/player/playback_engine.js"
import { PlaybackRecoveryMonitor } from "../../../app/javascript/player/playback_recovery_monitor.js"
import { ProgressReporter } from "../../../app/javascript/player/progress_reporter.js"
import { SubtitlePipeline } from "../../../app/javascript/player/subtitle_pipeline.js"
import { WebVttParser } from "../../../app/javascript/player/web_vtt_parser.js"

export function createVideoPlayerHarness() {
  const harness = {
    fetchHandler: async () => ({ ok: true })
  }
  const source = fs
    .readFileSync(new URL("../../../app/javascript/controllers/video_player_controller.js", import.meta.url), "utf8")
    .replace(/^import .*$/gm, "")
  const context = vm.createContext({
    Controller: class Controller {},
    HlsSessionClient,
    MseBufferManager,
    PlaybackEngine,
    PlaybackRecoveryMonitor,
    ProgressReporter,
    SubtitlePipeline,
    WebVttParser,
    AbortController,
    URL,
    URLSearchParams,
    clearTimeout,
    console,
    setTimeout,
    document: { querySelector: () => ({ content: "csrf-token" }) },
    fetch: (...args) => harness.fetchHandler(...args),
    window: { location: { origin: "https://streamvault.test" } }
  })
  vm.runInContext(
    source.replace("export default class", "globalThis.VideoPlayerController = class"),
    context
  )

  return {
    harness,
    context,
    VideoPlayerController: context.VideoPlayerController,
    timeRanges
  }
}

function timeRanges(ranges) {
  return {
    length: ranges.length,
    start: (index) => ranges[index][0],
    end: (index) => ranges[index][1]
  }
}
