import { Controller } from "@hotwired/stimulus"

// Highlights the settings section currently in view. The section index is
// sticky, so without this the reader loses their place in a long form.
export default class extends Controller {
  static targets = ["link"]

  connect() {
    this.sections = this.linkTargets
      .map((link) => document.getElementById(link.dataset.section))
      .filter(Boolean)

    this.onScroll = this.onScroll.bind(this)
    window.addEventListener("scroll", this.onScroll, { passive: true })
    this.onScroll()
  }

  disconnect() {
    window.removeEventListener("scroll", this.onScroll)
  }

  onScroll() {
    const offset = 180
    let active = this.sections[0]

    for (const section of this.sections) {
      if (section.getBoundingClientRect().top <= offset) active = section
    }

    this.linkTargets.forEach((link) => {
      const isActive = Boolean(active) && link.dataset.section === active.id
      link.classList.toggle("settings-nav--active", isActive)
      if (isActive) {
        link.setAttribute("aria-current", "true")
      } else {
        link.removeAttribute("aria-current")
      }
    })
  }
}
