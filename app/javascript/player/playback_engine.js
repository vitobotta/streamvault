const MSE_MIME_TYPE = 'video/mp4; codecs="avc1.640028,mp4a.40.2"'

export class PlaybackEngine {
  constructor(
    player,
    {
      userAgent = () => globalThis.navigator?.userAgent || "",
      createMediaSource = () => new globalThis.MediaSource(),
      createObjectUrl = (value) => globalThis.URL.createObjectURL(value),
      revokeObjectUrl = (value) => globalThis.URL.revokeObjectURL(value)
    } = {}
  ) {
    this.player = player
    this.userAgent = userAgent
    this.createMediaSource = createMediaSource
    this.createObjectUrl = createObjectUrl
    this.revokeObjectUrl = revokeObjectUrl
  }

  async ensureSource() {
    const player = this.player
    if (!player.streamingUrlValue) return
    if (player.isIOS()) {
      await player.loadMediaTracks()
      player.startHlsPlayback()
      return
    }

    const safari = player.isSafari()
    if (!player.mseSupported && !safari) {
      player.videoTarget.src = player.streamingUrlValue
      return
    }

    const tracksPromise = player.loadMediaTracks()
    if (player.directPlayHintValue) player.primeDirectPlay()
    await tracksPromise
    if (player.directPlayEligible()) {
      console.log("[Player] Path: direct play (native <video>, no ffmpeg)")
      player.startDirectPlay()
    } else if (safari) {
      player.primedDirectPlayUrl = null
      console.log("[Player] Path: native HLS (Safari)")
      player.startHlsPlayback()
    } else if (player.remuxDirectEligible()) {
      player.primedDirectPlayUrl = null
      console.log("[Player] Path: remux direct play (-c:v copy, no re-encode)")
      player.startRemuxDirectPlay()
    } else {
      player.primedDirectPlayUrl = null
      console.log("[Player] Path: MSE/transcode (hardware decode + encode)")
      player.setupMseSource(player.streamingUrlValue)
    }
  }

  primeDirectPlay() {
    const player = this.player
    if (!player.directStreamUrlValue) return
    if (player.selectedAudioStream || player.selectedSubtitleStream) return

    const directUrl = player.urlWithPlaybackId(player.directStreamUrlValue)
    player.primedDirectPlayUrl = directUrl
    player.videoTarget.autoplay = false
    player.videoTarget.preload = "auto"
    player.videoTarget.src = directUrl
  }

  setupMseSource(streamUrl) {
    const player = this.player
    if (player.fetchController) {
      player.fetchController.abort()
      player.fetchController = null
    }
    player.bufferQueue = []
    player.fmp4Buffer = null
    player.fmp4BufferSize = 0
    player.pendingAppendBuffer = null
    player.mseFetchEnded = false
    player.quotaBlockedAtTime = null
    player.mseReadPaused = false
    clearTimeout(player.quotaRetryTimer)
    player.quotaRetryTimer = null
    player.clearSystemRebufferGate()
    clearTimeout(player.bufferAheadDeadlineTimer)
    player.bufferAheadDeadlineTimer = null
    clearTimeout(player.prematureEndRecoveryTimer)
    player.prematureEndRecoveryTimer = null
    player.playbackStarted = false
    player.isStalled = false
    player.userPaused = false
    player.directPlayActive = false
    player.remuxDirectPlay = false
    player.bufferAheadDeadline = null
    player.rebufferDeadline = null
    player.clearStallWatchdog()

    if (player.mediaSource) {
      if (player.mediaSource.readyState === "open") {
        try { player.mediaSource.endOfStream() } catch {}
      }
      player.mediaSource = null
      player.sourceBuffer = null
    }
    if (player.videoTarget.src.startsWith("blob:")) this.revokeObjectUrl(player.videoTarget.src)

    if (!player.mseSupported) {
      player.videoTarget.src = streamUrl
      player.videoTarget.load()
      const playPromise = player.videoTarget.play()
      if (playPromise?.catch) playPromise.catch(() => {})
      return
    }

    player.mediaSource = this.createMediaSource()
    player.videoTarget.src = this.createObjectUrl(player.mediaSource)
    player.mediaSource.addEventListener("sourceopen", () => {
      player.sourceBuffer = player.mediaSource.addSourceBuffer(MSE_MIME_TYPE)
      player.sourceBuffer.mode = "segments"
      player.sourceBuffer.addEventListener("updateend", () => player.onBufferUpdateEnd())
      player.startStreamingFetch(streamUrl)
    }, { once: true })
  }

  isIOS() {
    const ua = this.userAgent()
    return /iPhone|iPod/.test(ua) && !/iPad/.test(ua)
  }

  isSafari() {
    const ua = this.userAgent()
    return /Safari/.test(ua) && !/(Chrome|Chromium|CriOS|FxiOS|Edg|OPR|Android)/.test(ua)
  }

  isChromium() {
    return /(Chrome|Chromium|CriOS|Edg|OPR)/.test(this.userAgent())
  }

  isHls() {
    return !!this.player.hlsSessionId
  }

  isDirectPlay() {
    return !!this.player.directPlayActive
  }

  isNativeDirectPlay() {
    return this.player.isDirectPlay() && !this.player.isRemuxDirectPlay()
  }

  timelineOffset() {
    return this.player.isNativeDirectPlay() ? 0 : this.player.startSecondsValue
  }

  isRemuxDirectPlay() {
    return !!this.player.remuxDirectPlay
  }

  directPlayEligible() {
    const player = this.player
    if (!player.directStreamUrlValue || player.streamRecoveryAttempts > 0) return false
    if (player.burnedSubtitleSelected()) return false
    if (player.selectedAudioStream && player.selectedAudioStream !== player.defaultAudioStreamIndex()) return false
    if (player.tracksData?.direct_playable !== true) return false

    const codec = player.tracksData?.video_codec
    if (!codec) return false
    const hevc = codec === "hevc" || codec === "h265"
    if (hevc && player.isSafari() && player.tracksData?.video_codec_tag !== "hvc1") return false
    return codec === "h264" || player.browserCanPlayCodec(codec)
  }

  defaultAudioStreamIndex() {
    const defaultTrack = this.player.audioTracks.find((track) => track.default) || this.player.audioTracks[0]
    return defaultTrack?.index?.toString() || null
  }

  remuxDirectEligible() {
    const player = this.player
    if (player.isSafari() || player.streamRecoveryAttempts > 0 || player.burnedSubtitleSelected()) return false
    if (!player.tracksData?.remux_direct_playable) return false

    const codec = player.tracksData?.video_codec
    const hevc = codec === "hevc" || codec === "h265"
    const width = Number(player.tracksData?.video_width) || 0
    const height = Number(player.tracksData?.video_height) || 0
    if (hevc && (width > 1920 || height > 1080)) return false
    if (codec && codec !== "h264" && !player.browserCanPlayCodec(codec)) return false
    return true
  }

  browserCanPlayCodec(codec) {
    const hevc = codec === "hevc" || codec === "h265"
    const mime = hevc ? 'video/mp4; codecs="hvc1"' : `video/mp4; codecs="${codec}"`
    const result = this.player.videoTarget.canPlayType(mime)
    if (result === "probably" || result === "maybe") return true
    return hevc && this.player.platformSupportsHevc()
  }

  platformSupportsHevc() {
    const ua = this.userAgent()
    if (/Mac OS X/.test(ua) && !/Windows/.test(ua)) return true
    if (/iPhone|iPad|iPod/.test(ua)) return true
    if (/Android/.test(ua)) return true
    return false
  }
}
