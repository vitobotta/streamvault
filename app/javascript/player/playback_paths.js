class NativePath {
  constructor(player) { this.player = player }
  eligible() { return this.player.directPlayEligible() }
  start() { this.player.startDirectPlay() }
}

class HlsPath {
  constructor(player) { this.player = player }
  eligible() { return this.player.isIOS() || this.player.isSafari() }
  start() {
    this.player.primedDirectPlayUrl = null
    this.player.startHlsPlayback()
  }
}

class RemuxPath {
  constructor(player) { this.player = player }
  eligible() { return this.player.remuxDirectEligible() }
  start() {
    this.player.primedDirectPlayUrl = null
    this.player.startRemuxDirectPlay()
  }
}

class MsePath {
  constructor(player) { this.player = player }
  eligible() { return true }
  start() {
    this.player.primedDirectPlayUrl = null
    this.player.setupMseSource(this.player.transcodeUrlWithQuality(this.player.streamingUrlValue))
  }
}

export class PlaybackPaths {
  constructor(player) {
    this.player = player
    this.native = new NativePath(player)
    this.hls = new HlsPath(player)
    this.remux = new RemuxPath(player)
    this.mse = new MsePath(player)
  }

  async start() {
    if (!this.player.streamingUrlValue) return

    if (this.player.isIOS()) {
      await this.player.loadMediaTracks()
      return this.hls.start()
    }

    if (!this.player.mseSupported && !this.player.isSafari()) return this.mse.start()

    // A fixed quality rung has to be encoded by ffmpeg, so direct play and
    // remux (which copy the source bytes as-is) are skipped on the first load.
    const fixedQuality = this.player.fixedQuality()

    const tracks = this.player.loadMediaTracks()
    if (!fixedQuality && this.player.directPlayHintValue) this.player.primeDirectPlay()
    await tracks

    const candidates = fixedQuality
      ? [ this.hls, this.mse ]
      : [ this.native, this.hls, this.remux, this.mse ]
    const path = candidates.find((candidate) => candidate.eligible())
    path.start()
  }
}
