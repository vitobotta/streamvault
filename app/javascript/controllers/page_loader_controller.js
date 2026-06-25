import { Controller } from "@hotwired/stimulus"

// Shows a loading overlay during full-page navigations:
//   - Search form submit → spinner with "Searching..."
//   - Content link clicks → spinner with "Loading..."
//
// Turbo Drive is not loaded, so all navigation is traditional full-page
// loads. The overlay is added to the layout and auto-hides on page
// load (DOMContentLoaded) since the new page replaces the document.
//
// Usage:
//   <div data-controller="page-loader">
//     Search forms:  add data-action="page-loader#search"
//     Content links: add data-action="page-loader#navigate"
//   </div>
//
// Or programmatically via data attributes on links/forms:
//   data-page-loader-target="search"  → on a <form>
//   data-page-loader-target="link"    → on an <a>
export default class extends Controller {
  static targets = ["overlay", "message"]

  connect() {
    this.hideOverlay()

    // Intercept search form submits
    document.querySelectorAll("form[data-page-loader='search']").forEach((form) => {
      form.addEventListener("submit", (e) => this.onSearch(e))
    })

    // Intercept content navigation link clicks
    document.querySelectorAll("a[data-page-loader='link']").forEach((link) => {
      link.addEventListener("click", (e) => this.onNavigate(e))
    })
  }

  disconnect() {
    this.hideOverlay()
  }

  onSearch(event) {
    const form = event.target
    const query = form.querySelector("input[type='text'], input[name='q']")?.value?.trim()
    if (!query) return

    this.showOverlay("Searching...")
  }

  onNavigate(event) {
    // Only show for unmodified clicks (not cmd+click, etc.)
    if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return

    this.showOverlay("Loading...")
  }

  showOverlay(message) {
    if (this.hasOverlayTarget) {
      this.overlayTarget.classList.remove("hidden")
      this.overlayTarget.setAttribute("aria-hidden", "false")
    }
    if (this.hasMessageTarget) {
      this.messageTarget.textContent = message
    }
  }

  hideOverlay() {
    if (this.hasOverlayTarget) {
      this.overlayTarget.classList.add("hidden")
      this.overlayTarget.setAttribute("aria-hidden", "true")
    }
  }
}
