import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["episode", "drawer", "drawerContent", "chevron"]
  static values = { url: String, imdbId: String, showTitle: String }

  connect() {
    this.openEpisode = null
  }

  async toggle(event) {
    const button = event.currentTarget
    const season = button.dataset.season
    const episode = button.dataset.episode
    const episodeTitle = button.dataset.title || `Episode ${episode}`
    const index = this.episodeTargets.findIndex(el => el.contains(button))
    const episodeEl = this.episodeTargets[index]
    const drawer = this.drawerTargets[index]
    const drawerContent = this.drawerContentTargets[index]
    const chevron = this.chevronTargets[index]

    // If this episode is already open, close it
    if (this.openEpisode === index) {
      drawer.classList.add("hidden")
      chevron.style.transform = ""
      this.openEpisode = null
      return
    }

    // Close any previously open episode
    if (this.openEpisode !== null) {
      const prevDrawer = this.drawerTargets[this.openEpisode]
      const prevChevron = this.chevronTargets[this.openEpisode]
      prevDrawer.classList.add("hidden")
      prevChevron.style.transform = ""
    }

    // Open this episode
    drawer.classList.remove("hidden")
    chevron.style.transform = "rotate(180deg)"
    this.openEpisode = index

    // Fetch streams
    drawerContent.innerHTML = `
      <div class="flex items-center gap-2 text-sv-text-muted text-sm">
        <div class="w-4 h-4 border-2 border-sv-accent border-t-transparent rounded-full animate-spin"></div>
        Loading streams...
      </div>
    `

    try {
      const params = new URLSearchParams({
        season: season,
        episode: episode,
        show_title: this.showTitleValue
      })
      const response = await fetch(`${this.urlValue}?${params}`, {
        headers: { "Accept": "text/html" }
      })

      if (response.ok) {
        drawerContent.innerHTML = await response.text()
      } else {
        drawerContent.innerHTML = '<p class="text-sm text-sv-text-muted">Failed to load streams.</p>'
      }
    } catch (e) {
      drawerContent.innerHTML = '<p class="text-sm text-sv-text-muted">Failed to load streams.</p>'
    }
  }
}
