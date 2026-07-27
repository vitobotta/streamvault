import fs from "node:fs"
import vm from "node:vm"
import { HlsSessionClient } from "../../../app/javascript/player/hls_session_client.js"
import { MseBufferManager } from "../../../app/javascript/player/mse_buffer_manager.js"
import { PlaybackPaths } from "../../../app/javascript/player/playback_paths.js"
import { PlaybackRecoveryMonitor } from "../../../app/javascript/player/playback_recovery_monitor.js"
import { ProgressReporter } from "../../../app/javascript/player/progress_reporter.js"
import { SubtitlePipeline } from "../../../app/javascript/player/subtitle_pipeline.js"
import { WebVttParser } from "../../../app/javascript/player/web_vtt_parser.js"

const playerModuleContext = vm.createContext({
  HlsSessionClient,
  MseBufferManager,
  PlaybackPaths,
  PlaybackRecoveryMonitor,
  ProgressReporter,
  SubtitlePipeline,
  AbortController,
  URL,
  clearTimeout,
  console,
  setTimeout
})
const PlaybackEngine = loadPlayerClass("playback_engine.js", "PlaybackEngine", playerModuleContext)
playerModuleContext.PlaybackEngine = PlaybackEngine
const PlaybackCoordinator = loadPlayerClass("playback_coordinator.js", "PlaybackCoordinator", playerModuleContext)

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
    PlaybackCoordinator,
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

function loadPlayerClass(filename, className, context) {
  const source = fs
    .readFileSync(new URL(`../../../app/javascript/player/${filename}`, import.meta.url), "utf8")
    .replace(/^import .*$/gm, "")
    .replace(`export class ${className}`, `globalThis.${className} = class ${className}`)
  vm.runInContext(source, context)
  return context[className]
}

function timeRanges(ranges) {
  return {
    length: ranges.length,
    start: (index) => ranges[index][0],
    end: (index) => ranges[index][1]
  }
}
