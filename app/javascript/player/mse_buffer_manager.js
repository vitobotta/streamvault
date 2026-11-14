const QUOTA_RETRY_MS = 250
const BACK_BUFFER_SECONDS = 30
const BACK_BUFFER_EVICT_BATCH_SECONDS = 30
const QUOTA_BACK_BUFFER_SECONDS = 2
const REBUFFER_STALL_TIMEOUT_MS = 20000
const STREAM_STALL_TIMEOUT_MS = 60000

export class MseBufferManager {
  constructor(player) {
    this.player = player
    this.appendCount = 0
    this.updateEndWaiters = new Set()
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

  // The one scan both the extractor and the reader's append gate use, so
  // "complete box" means the same thing in both places: the contiguous
  // prefix of the queue that can be handed to appendBuffer right now.
  #completeBoxes() {
    if (!this.player.fmp4Buffer || (this.player.fmp4BufferSize || 0) < 8) return []
    const boxes = []
    let offset = 0

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
            continue
          }
        }
        break
      }

      boxes.push({ offset, size })
      offset += size
    }

    return boxes
  }

  // True when the queued bytes already hold at least one complete box.
  // The reader must not pull the next chunk while such a box waits behind
  // an append in flight; with nothing complete pending it must keep
  // reading, because a fragment only becomes appendable once it is whole.
  hasCompleteBoxPending() {
    return this.#completeBoxes().length > 0
  }

  // Resolves on the next updateend, or after `timeoutMs`.  The reader uses
  // this to pace itself by appends instead of a timer poll, so a fragment
  // that finished arriving is appended before more bytes are pulled in.
  awaitUpdateEnd(timeoutMs = 1000) {
    if (!this.player.bufferAppending && !this.player.sourceBuffer?.updating) return Promise.resolve()

    return new Promise((resolve) => {
      let timer = null
      const waiter = {
        resolve: () => {
          if (timer) clearTimeout(timer)
          this.updateEndWaiters.delete(waiter)
          resolve()
        }
      }
      timer = setTimeout(waiter.resolve, timeoutMs)
      this.updateEndWaiters.add(waiter)
    })
  }

  resolveUpdateEndWaiters() {
    for (const waiter of [...this.updateEndWaiters]) waiter.resolve()
  }

  extractCompleteBoxes() {
    const boxes = this.#completeBoxes()
    if (boxes.length === 0) return null

    const totalSize = boxes.reduce((sum, box) => sum + box.size, 0)
    const result = new Uint8Array(totalSize)
    let writeOffset = 0
    for (const box of boxes) {
      result.set(this.player.fmp4Buffer.subarray(box.offset, box.offset + box.size), writeOffset)
      writeOffset += box.size
    }

    const lastBox = boxes[boxes.length - 1]
    const lastComplete = lastBox.offset + lastBox.size
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
      this.appendCount += 1
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
        this.reportEviction("quota", Math.min(end, evictBefore) - start)
        return true
      } catch {
        return false
      }
    }
    return false
  }

  // Every range removal during playback mutates the decoder's buffer.
  // Recording it (with its size) is what lets a later rebuffer or black
  // gap be attributed to maintenance instead of to the network.
  reportEviction(kind, removedSeconds) {
    const player = this.player
    const removed = Math.max(0, removedSeconds)
    player.evictionCount = (player.evictionCount || 0) + 1
    player.evictedSecondsTotal = (player.evictedSecondsTotal || 0) + removed
    player.lastEvictionAt = Date.now()
    try {
      player.reportStall?.("eviction", {
        kind,
        removed_seconds: Math.round(removed * 10) / 10
      })
    } catch {
      // Telemetry must never interrupt buffer maintenance.
    }
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
    this.player.maybeStartPlayback()
    this.player.maybeHideBufferingOverlay()
    this.player.flushBufferQueue()
    this.player.finishOrRecoverMseEnd()
    // Resolve readers last: by now a queued fragment has been appended, so
    // the read loop re-checks the true pending state instead of a stale one.
    this.resolveUpdateEndWaiters()
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
      this.reportEviction("back", removeEnd - start)
      return
    }
  }
}
