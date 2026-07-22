const STREAM_STALL_TIMEOUT_MS = 60000
const PROGRESS_STALL_TIMEOUT_MS = 20000
const PROGRESS_WATCHDOG_INTERVAL_MS = 3000
const MAX_RECOVERY_ATTEMPTS = 3
const PREMATURE_END_BUFFER_SECONDS = 5
const COMPLETION_RATIO = 0.98

export class PlaybackRecoveryMonitor {
  constructor(player, { fetcher = globalThis.fetch, documentRoot = globalThis.document } = {}) {
    this.player = player
    this.fetcher = fetcher
    this.documentRoot = documentRoot
  }

  startStallWatchdog(timeoutMs = STREAM_STALL_TIMEOUT_MS) {
    this.player.clearStallWatchdog()
    this.player.stallWatchdogTimer = setTimeout(() => {
      this.player.stallWatchdogTimer = null
      if (!this.player.videoTarget.paused && this.player.hasBufferedAhead()) {
        this.player.hideSeekingOverlay()
        this.player.startProgressWatchdog()
        return
      }
      this.player.handleStreamStall()
    }, timeoutMs)
  }

  clearStallWatchdog() {
    if (!this.player.stallWatchdogTimer) return
    clearTimeout(this.player.stallWatchdogTimer)
    this.player.stallWatchdogTimer = null
  }

  startProgressWatchdog() {
    if (this.player.progressWatchdogArmed) return
    this.player.lastProgressPosition = this.player.videoTarget.currentTime
    this.player.lastProgressTime = Date.now()
    this.player.lastBufferEnd = this.player.currentBufferEnd()
    this.player.lastBufferDataTime = Date.now()
    this.player.lastProgressEventTime = Date.now()
    this.player.progressWatchdogArmed = true
    this.player.tickProgressWatchdog()
  }

  tickProgressWatchdog() {
    this.player.progressWatchdogTimer = setTimeout(() => {
      this.player.progressWatchdogTimer = null
      this.player.checkProgressStall()
      if (this.player.progressWatchdogArmed) this.player.tickProgressWatchdog()
    }, PROGRESS_WATCHDOG_INTERVAL_MS)
  }

  checkProgressStall() {
    const player = this.player
    if (!player.progressWatchdogArmed || player.streamRecoveryActive || player.isSeeking) return
    if (player.userPaused || player.videoTarget.paused || player.videoTarget.ended || !player.playbackStarted) return

    const now = Date.now()
    const position = player.videoTarget.currentTime
    const elapsed = now - player.lastProgressTime
    const playbackAdvanced = position > player.lastProgressPosition + 0.1

    if (playbackAdvanced) {
      player.lastProgressPosition = position
      player.lastProgressTime = now
    }

    if (player.isDirectPlay()) {
      const downloadStalledMs = now - player.lastProgressEventTime
      const bufferEnd = player.currentBufferEnd()
      const bufferGrowing = bufferEnd > player.lastBufferEnd + 0.5
      if (bufferGrowing) {
        player.lastBufferEnd = bufferEnd
        player.lastBufferDataTime = now
      }
      const bufferStalledMs = now - player.lastBufferDataTime
      const networkQuiet = downloadStalledMs > 15000 || (bufferStalledMs > 15000 && !bufferGrowing)

      if (networkQuiet) {
        const genuinelyStarved = !playbackAdvanced && player.videoTarget.readyState < 3 && player.bufferedAheadOfCurrent() < 0.5
        if (genuinelyStarved) {
          console.warn(`Download starved — no progress event for ${Math.round(downloadStalledMs / 1000)}s — reconnecting`)
          player.progressWatchdogArmed = false
          player.handleStreamStall("download_stall")
          return
        }

        player.lastProgressEventTime = now
        player.lastBufferDataTime = now
        player.lastBufferEnd = bufferEnd
      }
    }

    if (!playbackAdvanced && elapsed >= PROGRESS_STALL_TIMEOUT_MS) {
      console.warn(`Silent freeze detected — currentTime stuck at ${position} for ${Math.round(elapsed / 1000)}s`)
      player.progressWatchdogArmed = false
      if (player.isHls()) {
        player.handleHlsStall("silent_freeze")
      } else {
        player.handleStreamStall("silent_freeze")
      }
    }
  }

  currentBufferEnd() {
    const video = this.player.videoTarget
    if (!video.buffered.length) return 0
    const currentTime = video.currentTime
    for (let index = 0; index < video.buffered.length; index++) {
      if (currentTime >= video.buffered.start(index) && currentTime <= video.buffered.end(index)) {
        return video.buffered.end(index)
      }
    }
    return video.buffered.end(video.buffered.length - 1)
  }

  resetProgressBaseline() {
    if (!this.player.progressWatchdogArmed) return
    this.player.lastProgressPosition = this.player.videoTarget.currentTime
    this.player.lastProgressTime = Date.now()
    this.player.lastBufferEnd = this.player.currentBufferEnd()
    this.player.lastBufferDataTime = Date.now()
    this.player.lastProgressEventTime = Date.now()
  }

  stopProgressWatchdog() {
    this.player.progressWatchdogArmed = false
    if (!this.player.progressWatchdogTimer) return
    clearTimeout(this.player.progressWatchdogTimer)
    this.player.progressWatchdogTimer = null
  }

  handleStreamStall(eventType = "stall") {
    const player = this.player
    if (player.userPaused) {
      player.clearStallWatchdog()
      player.stopProgressWatchdog()
      return
    }
    if (player.isHls() || player.streamRecoveryActive) return
    if (player.streamRecoveryAttempts >= MAX_RECOVERY_ATTEMPTS) {
      console.warn("Stream recovery limit reached — giving up.")
      player.showSeekingOverlay("Stream stalled — try seeking to resume.")
      return
    }

    player.streamRecoveryAttempts += 1
    player.streamRecoveryActive = true
    console.warn(`Stream stalled — recovering (attempt ${player.streamRecoveryAttempts}/${MAX_RECOVERY_ATTEMPTS})`)
    player.reportStall(eventType)

    if (player.isDirectPlay()) {
      player.reconnectDirectPlay()
      return
    }
    player.reconnectFromCurrentPosition()
  }

  handleHlsStall(eventType = "hls_stall") {
    const player = this.player
    if (player.userPaused || player.isSeeking) return
    if (player.streamRecoveryAttempts >= MAX_RECOVERY_ATTEMPTS) {
      console.warn("HLS recovery limit reached — giving up.")
      player.showSeekingOverlay("Stream stalled — tap to retry")
      const overlay = player.seekingOverlayTarget
      const onRetry = () => {
        overlay.removeEventListener("click", onRetry)
        player.hideSeekingOverlay()
        player.streamRecoveryAttempts = 0
        player.handleHlsStall("manual_retry")
      }
      overlay.addEventListener("click", onRetry)
      return
    }

    player.streamRecoveryAttempts += 1
    console.warn(`HLS stall detected — restarting session (attempt ${player.streamRecoveryAttempts}/${MAX_RECOVERY_ATTEMPTS})`)
    player.reportStall(eventType)
    const targetSeconds = Math.floor(player.currentPlaybackPosition())
    player.isSeeking = true
    player.showSeekingOverlay("Reconnecting...")
    player.restartHlsSession(targetSeconds)
  }

  handlePrematureEnd() {
    this.player.mseFetchEnded = true
    this.player.finishOrRecoverMseEnd()
  }

  finishOrRecoverMseEnd() {
    const player = this.player
    if (!player.mseFetchEnded) return
    if (player.bufferAppending || player.sourceBuffer?.updating || player.pendingAppendBuffer) return

    player.flushBufferQueue()
    if (player.bufferAppending || player.sourceBuffer?.updating || player.pendingAppendBuffer) return

    const duration = player.effectiveDuration()
    const bufferedEnd = player.currentBufferEnd() + player.playbackTimelineOffset()
    if (duration > 0 && bufferedEnd >= duration * COMPLETION_RATIO) {
      try {
        if (player.mediaSource?.readyState === "open") player.mediaSource.endOfStream()
        if (player.mediaSource?.readyState === "ended") {
          player.mseFetchEnded = false
          player.fmp4Buffer = null
          player.fmp4BufferSize = 0
          clearTimeout(player.prematureEndRecoveryTimer)
          player.prematureEndRecoveryTimer = null
          player.clearStallWatchdog()
          return
        }
      } catch (error) {
        console.warn("Could not finalize completed MSE stream:", error)
      }
    }

    player.mseFetchEnded = false
    if (!player.playbackStarted || !player.sourceBuffer || player.sourceBuffer.buffered.length === 0) {
      console.warn("Stream fetch ended early with no buffer — recovering.")
      player.handleStreamStall("premature_end")
      return
    }

    const bufferedAhead = player.bufferedAheadOfCurrent()
    if (bufferedAhead <= PREMATURE_END_BUFFER_SECONDS) {
      console.warn(`Stream fetch ended early with ${bufferedAhead.toFixed(1)}s buffer — reconnecting.`)
      player.handleStreamStall("premature_end")
      return
    }

    console.warn(`Stream fetch ended early with ${bufferedAhead.toFixed(1)}s buffer — retaining cushion.`)
    player.schedulePrematureEndRecovery()
  }

  schedulePrematureEndRecovery() {
    const player = this.player
    clearTimeout(player.prematureEndRecoveryTimer)
    const check = () => {
      player.prematureEndRecoveryTimer = null
      if (player.videoTarget.ended || player.isSeeking) return
      if (player.userPaused) {
        player.prematureEndRecoveryTimer = setTimeout(check, 1000)
        return
      }

      const bufferedAhead = player.bufferedAheadOfCurrent()
      if (bufferedAhead > PREMATURE_END_BUFFER_SECONDS) {
        const delay = Math.min(1000, Math.max(250, (bufferedAhead - PREMATURE_END_BUFFER_SECONDS) * 1000))
        player.prematureEndRecoveryTimer = setTimeout(check, delay)
        return
      }
      player.handleStreamStall("premature_end")
    }
    player.prematureEndRecoveryTimer = setTimeout(check, 250)
  }

  bufferedAhead() {
    const ranges = this.player.sourceBuffer ? this.player.sourceBuffer.buffered : this.player.videoTarget.buffered
    if (!ranges || ranges.length === 0) return 0
    const currentTime = this.player.videoTarget.currentTime
    for (let index = 0; index < ranges.length; index++) {
      if (currentTime >= ranges.start(index) && currentTime < ranges.end(index)) return ranges.end(index) - currentTime
      if (currentTime < ranges.start(index)) return 0
    }
    return 0
  }

  report(eventType, details = {}) {
    const player = this.player
    const ranges = player.sourceBuffer?.buffered || player.videoTarget.buffered
    const bufferedRanges = []
    for (let index = 0; index < Math.min(ranges?.length || 0, 8); index++) {
      bufferedRanges.push([
        Math.round(ranges.start(index) * 10) / 10,
        Math.round(ranges.end(index) * 10) / 10
      ])
    }

    const body = JSON.stringify({
      event: eventType,
      playback_id: player.playbackId,
      path: player.playbackPath(),
      position: Math.round(player.currentPlaybackPosition() * 10) / 10,
      buffer_ahead: Math.round(player.bufferedAheadOfCurrent() * 10) / 10,
      recovery_count: player.streamRecoveryAttempts,
      ready_state: player.videoTarget.readyState,
      network_state: player.videoTarget.networkState,
      paused: player.videoTarget.paused,
      ended: player.videoTarget.ended,
      mse_pending_bytes: (player.fmp4BufferSize || 0) + (player.pendingAppendBuffer?.byteLength || 0),
      mse_quota_errors: player.mseQuotaErrorCount,
      system_rebuffer_paused: player.systemRebufferPaused,
      buffered_ranges: bufferedRanges,
      video_codec: player.tracksData?.video_codec,
      video_width: player.tracksData?.video_width,
      video_height: player.tracksData?.video_height,
      start_seconds: player.startSecondsValue,
      ...details
    })

    this.fetcher("/streaming/stall_telemetry", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-CSRF-Token": this.documentRoot?.querySelector("[name='csrf-token']")?.content
      },
      body,
      keepalive: true
    }).catch(() => {})
  }

  path() {
    if (this.player.isHls()) return "hls"
    if (this.player.isRemuxDirectPlay()) return "remux"
    if (this.player.isNativeDirectPlay()) return "direct"
    return "mse_transcode"
  }
}
