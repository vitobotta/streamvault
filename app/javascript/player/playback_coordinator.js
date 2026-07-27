import { PlaybackEngine } from "player/playback_engine"
import { ProgressReporter } from "player/progress_reporter"
import { SubtitlePipeline } from "player/subtitle_pipeline"
import { MseBufferManager } from "player/mse_buffer_manager"
import { HlsSessionClient } from "player/hls_session_client"
import { PlaybackRecoveryMonitor } from "player/playback_recovery_monitor"

export class PlaybackCoordinator {
  constructor(
    player,
    {
      fetcher = (...args) => globalThis.fetch(...args),
      documentRoot = globalThis.document,
      origin = globalThis.location?.origin,
      userAgent = () => globalThis.navigator?.userAgent || "",
      createMediaSource = () => new globalThis.MediaSource(),
      createObjectUrl = (value) => globalThis.URL.createObjectURL(value),
      revokeObjectUrl = (value) => globalThis.URL.revokeObjectURL(value)
    } = {}
  ) {
    this.player = player
    this.engine = new PlaybackEngine(player, { userAgent, createMediaSource, createObjectUrl, revokeObjectUrl })
    this.progress = new ProgressReporter(player, { fetcher, documentRoot })
    this.subtitles = new SubtitlePipeline(player, { fetcher, origin })
    this.buffer = new MseBufferManager(player)
    this.hls = new HlsSessionClient(player, { fetcher, documentRoot })
    this.recovery = new PlaybackRecoveryMonitor(player, { fetcher, documentRoot })
    this.connected = false
  }

  connect() {
    if (this.connected) return
    this.connected = true
    this.progress.start()
    void this.engine.ensureSource()
  }

  disconnect() {
    if (!this.connected) return
    this.connected = false
    void this.hls.stop()
    this.progress.stop()
    this.recovery.clearStallWatchdog()
    this.recovery.stopProgressWatchdog()
  }
}
