// Chapter timestamps and duration are on the original source timeline, even
// when the browser is playing a remux/transcode that starts at a seek offset.
export function nextEpisodePromptStart({ duration, chapters = [], fallbackSeconds = 90 }) {
  if (!Number.isFinite(duration) || duration <= 0) return null

  const credits = (Array.isArray(chapters) ? chapters : []).filter((chapter) => {
    const title = chapter?.title
    const start = chapter?.start_time
    const end = chapter?.end_time
    return typeof title === "string" &&
      /\b(credits|end titles)\b/i.test(title) && !/\b(opening|intro)\b/i.test(title) &&
      Number.isFinite(start) && Number.isFinite(end) &&
      start >= duration / 2 && start < duration && end > start && end <= duration
  })
  if (credits.length) return Math.min(...credits.map((chapter) => chapter.start_time))

  // Zero disables only the estimated trigger, not real chapter markers.
  if (!Number.isFinite(fallbackSeconds) || fallbackSeconds <= 0) return null
  // Avoid showing the prompt through most of a short episode.
  return duration - Math.min(fallbackSeconds, duration * 0.1)
}
