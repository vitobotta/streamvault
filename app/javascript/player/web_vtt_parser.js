export class WebVttParser {
  parse(text, offsetSeconds = 0) {
    const cues = text
      .replace(/^\uFEFF/, "")
      .split(/\r?\n\s*\r?\n/)
      .filter((block) => block.includes("-->"))
      .map((block) => this.parseCue(block))
      .filter(Boolean)

    if (offsetSeconds <= 0 || cues.some((cue) => cue.start >= offsetSeconds - 30)) {
      return cues
    }

    return cues.map((cue) => ({
      ...cue,
      start: cue.start + offsetSeconds,
      end: cue.end + offsetSeconds
    }))
  }

  parseCue(block) {
    const lines = block.split(/\r?\n/).map((line) => line.trim()).filter(Boolean)
    const timingIndex = lines.findIndex((line) => line.includes("-->"))
    if (timingIndex < 0) return null

    const [startText, endAndSettings] = lines[timingIndex].split("-->").map((part) => part.trim())
    const endText = endAndSettings?.split(/\s+/)[0]
    const start = this.parseTimestamp(startText)
    const end = this.parseTimestamp(endText)
    if (!Number.isFinite(start) || !Number.isFinite(end) || end <= start) return null

    const cueText = lines
      .slice(timingIndex + 1)
      .map((line) => this.cleanText(line))
      .join("\n")
      .trim()

    if (!cueText) return null
    return { start, end, text: cueText }
  }

  parseTimestamp(value) {
    const parts = value?.split(":") || []
    if (parts.length < 2 || parts.length > 3) return NaN

    const seconds = Number(parts.pop().replace(",", "."))
    const minutes = Number(parts.pop())
    const hours = parts.length === 1 ? Number(parts.pop()) : 0
    if (![hours, minutes, seconds].every(Number.isFinite)) return NaN

    return (hours * 3600) + (minutes * 60) + seconds
  }

  cleanText(text) {
    return text
      .replace(/<[^>]+>/g, "")
      .replace(/&amp;/g, "&")
      .replace(/&lt;/g, "<")
      .replace(/&gt;/g, ">")
      .replace(/&quot;/g, "\"")
      .replace(/&#39;/g, "'")
  }
}
