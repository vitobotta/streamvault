import { Controller } from "@hotwired/stimulus"

// Shows a loading overlay during full-page navigations:
//   - Search form submit → spinner with "Searching..."
//   - Content link clicks → spinner with "Loading..."
//
// Navigation uses traditional full-page loads. The overlay is added to the
// layout, hidden when the controller connects, and reset when a page is
// restored from the browser's back/forward cache.
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
    this.onSubmit = this.onSubmit.bind(this)
    this.onClick = this.onClick.bind(this)
    this.onPageShow = this.hideOverlay.bind(this)
    this.hideOverlay()
    document.addEventListener("submit", this.onSubmit, true)
    document.addEventListener("click", this.onClick, true)
    window.addEventListener("pageshow", this.onPageShow)
  }

  disconnect() {
    document.removeEventListener("submit", this.onSubmit, true)
    document.removeEventListener("click", this.onClick, true)
    window.removeEventListener("pageshow", this.onPageShow)
    this.hideOverlay()
  }

  onSubmit(event) {
    const form = event.target
    if (!(form instanceof HTMLFormElement)) return

    const confirmation = event.submitter?.dataset.confirm || form.dataset.confirm
    if (confirmation && !window.confirm(confirmation)) {
      event.preventDefault()
      return
    }
    const source = form.dataset.pageLoader ? form : event.submitter
    const mode = source?.dataset.pageLoader
    if (!mode || !form.reportValidity()) return

    if (mode === "search") {
      const query = form.querySelector("input[type='text'], input[name='q']")?.value?.trim()
      if (!query) return
    }

    event.preventDefault()
    const defaultMessage = mode === "search" ? "Searching..." : "Finding a working stream..."
    this.showOverlay(source.dataset.pageLoaderMessage || defaultMessage)
    requestAnimationFrame(() => form.submit())
  }

  onClick(event) {
    const link = event.target.closest?.("a[data-page-loader='link']")
    if (!link || event.defaultPrevented || event.button !== 0) return
    if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return
    if (link.target === "_blank" || link.hasAttribute("download")) return

    event.preventDefault()
    this.showOverlay(link.dataset.pageLoaderMessage || "Loading...")
    requestAnimationFrame(() => {
      window.location.href = link.href
    })
  }

  showOverlay(message) {
    if (this.hasOverlayTarget) {
      this.overlayTarget.classList.remove("hidden")
      this.overlayTarget.setAttribute("aria-hidden", "false")
    }
    if (this.hasMessageTarget) this.messageTarget.textContent = message
  }

  hideOverlay() {
    if (!this.hasOverlayTarget) return

    this.overlayTarget.classList.add("hidden")
    this.overlayTarget.setAttribute("aria-hidden", "true")
  }
}
