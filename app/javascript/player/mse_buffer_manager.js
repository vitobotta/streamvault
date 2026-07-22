const QUOTA_RETRY_MS = 250
const BACK_BUFFER_SECONDS = 30
const BACK_BUFFER_EVICT_BATCH_SECONDS = 30
const QUOTA_BACK_BUFFER_SECONDS = 2
const REBUFFER_STALL_TIMEOUT_MS = 20000
const STREAM_STALL_TIMEOUT_MS = 60000

export class MseBufferManager {
  constructor(player) {
    this.player = player
  }

  queueChunk(chunk) {
    const bytes = new Uint8Array(chunk)
    const newSize = (this.player.fmp4BufferSize || 0) + bytes.byteLength
    if (!this.player.fmp4Buffer || this.player.fmp4Buffer.length < newSize) {
      const allocationSize = Math.max(newSize, (this.player.fmp4Buffer?.length || 4096) * 2)
      const buffer = new Uint8Array(allocationSize)
      if (this.player.fmp4Buffer) buffer.set(this.player.fmp4Buffer.subarray(0, this.player.fmp4BufferSize || 0), 0)
      this.player.fmp4Buffer = buffer
    }
    this.player.fmp4Buffer.set(bytes, this.player.fmp4BufferSize || 0)
    this.player.fmp4BufferSize = newSize
    this.player.flushBufferQueue()
  }

  extractCompleteBoxes() {
    if (!this.player.fmp4Buffer || this.player.fmp4BufferSize < 8) return null
    const boxes = []
    let offset = 0
    let lastComplete = 0

    while (offset + 8 <= this.player.fmp4BufferSize) {
      const size = (this.player.fmp4Buffer[offset] << 24) |
                   (this.player.fmp4Buffer[offset + 1] << 16) |
                   (this.player.fmp4Buffer[offset + 2] << 8) |
                   this.player.fmp4Buffer[offset + 3]
      const type = String.fromCharCode(
        this.player.fmp4Buffer[offset + 4],
        this.player.fmp4Buffer[offset + 5],
        this.player.fmp4Buffer[offset + 6],
        this.player.fmp4Buffer[offset + 7]
      )

      if (size === 0 || size === 1 || offset + size > this.player.fmp4BufferSize) break

      if (type === "moof") {
        const nextOffset = offset + size
        if (nextOffset + 8 <= this.player.fmp4BufferSize) {
          const mdatSize = (this.player.fmp4Buffer[nextOffset] << 24) |
                           (this.player.fmp4Buffer[nextOffset + 1] << 16) |
                           (this.player.fmp4Buffer[nextOffset + 2] << 8) |
                           this.player.fmp4Buffer[nextOffset + 3]
          const mdatType = String.fromCharCode(
            this.player.fmp4Buffer[nextOffset + 4],
            this.player.fmp4Buffer[nextOffset + 5],
            this.player.fmp4Buffer[nextOffset + 6],
            this.player.fmp4Buffer[nextOffset + 7]
          )
          if (mdatType === "mdat" && nextOffset + mdatSize <= this.player.fmp4BufferSize) {
            boxes.push({ offset, size: size + mdatSize })
            offset = nextOffset + mdatSize
            lastComplete = offset
            continue
          }
        }
        break
      }

      boxes.push({ offset, size })
      offset += size
      lastComplete = offset
    }

    if (boxes.length === 0) return null

    const totalSize = boxes.reduce((sum, box) => sum + box.size, 0)
    const result = new Uint8Array(totalSize)
    let writeOffset = 0
    for (const box of boxes) {
      result.set(this.player.fmp4Buffer.subarray(box.offset, box.offset + box.size), writeOffset)
      writeOffset += box.size
    }

    if (lastComplete < this.player.fmp4BufferSize) {
      this.player.fmp4Buffer.copyWithin(0, lastComplete, this.player.fmp4BufferSize)
      this.player.fmp4BufferSize -= lastComplete
    } else {
      this.player.fmp4BufferSize = 0
      this.player.fmp4Buffer = null
    }

    return result.buffer
  }

  flush() {
    if (this.player.bufferAppending || !this.player.sourceBuffer || this.player.sourceBuffer.updating) return
    const data = this.player.pendingAppendBuffer || this.player.extractCompleteBoxes()
    if (!data) return

    clearTimeout(this.player.quotaRetryTimer)
    this.player.quotaRetryTimer = null
    this.player.bufferAppending = true
    try {
      this.player.sourceBuffer.appendBuffer(data)
      this.player.pendingAppendBuffer = null
      this.player.quotaBlockedAtTime = null
    } catch (error) {
      this.player.bufferAppending = false
      if (error.name === "QuotaExceededError") {
        this.player.pendingAppendBuffer = data
        this.player.quotaBlockedAtTime ??= this.player.videoTarget.currentTime
        this.player.mseQuotaErrorCount += 1
        this.player.reportStall("mse_quota")
        if (!this.player.evictForQuota()) this.player.scheduleQuotaRetry()
        this.player.maybeStartPlayback(true)
      } else {
        console.warn("appendBuffer failed, recovering:", error.name)
        this.player.pendingAppendBuffer = null
        this.player.fmp4Buffer = null
        this.player.fmp4BufferSize = 0
        this.player.handleStreamStall()
      }
    }
  }

  evictForQuota() {
    if (!this.player.sourceBuffer || this.player.sourceBuffer.updating) return false
    const evictBefore = this.player.videoTarget.currentTime - QUOTA_BACK_BUFFER_SECONDS
    if (evictBefore <= 0) return false

    for (let index = 0; index < this.player.sourceBuffer.buffered.length; index++) {
      const start = this.player.sourceBuffer.buffered.start(index)
      const end = this.player.sourceBuffer.buffered.end(index)
      if (start >= evictBefore) continue
      try {
        this.player.sourceBuffer.remove(start, Math.min(end, evictBefore))
        return true
      } catch {
        return false
      }
    }
    return false
  }

  scheduleQuotaRetry() {
    clearTimeout(this.player.quotaRetryTimer)
    this.player.quotaRetryTimer = setTimeout(() => {
      this.player.quotaRetryTimer = null
      if (!this.player.pendingAppendBuffer) return
      if (!this.player.evictForQuota()) this.player.scheduleQuotaRetry()
    }, QUOTA_RETRY_MS)
  }

  onUpdateEnd() {
    this.player.bufferAppending = false
    this.player.evictOldBuffer()
    const actuallyWaiting = this.player.isStalled && !this.player.userPaused && !this.player.hasBufferedAhead(0.5)
    this.player.startStallWatchdog(actuallyWaiting ? REBUFFER_STALL_TIMEOUT_MS : STREAM_STALL_TIMEOUT_MS)
    this.player.resetProgressBaseline()
    this.player.maybeStartPlayback()
    this.player.maybeHideBufferingOverlay()
    this.player.flushBufferQueue()
    this.player.finishOrRecoverMseEnd()
  }

  evictOldBuffer() {
    if (!this.player.sourceBuffer || this.player.sourceBuffer.updating) return
    const currentTime = this.player.videoTarget.currentTime
    const evictBefore = currentTime - BACK_BUFFER_SECONDS
    if (evictBefore <= 0) return

    for (let index = 0; index < this.player.sourceBuffer.buffered.length; index++) {
      const start = this.player.sourceBuffer.buffered.start(index)
      const end = this.player.sourceBuffer.buffered.end(index)
      if (start >= evictBefore) continue
      const removeEnd = Math.min(end, evictBefore)
      const containsPlayhead = start <= currentTime && currentTime < end
      if (containsPlayhead && removeEnd - start < BACK_BUFFER_EVICT_BATCH_SECONDS) continue

      try { this.player.sourceBuffer.remove(start, removeEnd) } catch {}
      return
    }
  }
}
