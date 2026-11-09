import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = {
    state: String,
    url: String,
    active: Boolean,
    params: String,
    statusUrl: String
  }

  connect() {
    this.onStateChanged = (event) => this.render(event.detail.state === this.stateValue)
    this.onPageShow = (event) => { if (event.persisted) void this.refresh() }
    this.container = this.element.closest("[data-collection-actions]") || this.element.closest(".flex.gap-3.mt-6")
    this.container?.addEventListener("collection-state:changed", this.onStateChanged)
    window.addEventListener("pageshow", this.onPageShow)
  }

  disconnect() {
    this.container?.removeEventListener("collection-state:changed", this.onStateChanged)
    window.removeEventListener("pageshow", this.onPageShow)
  }

  async toggle(event) {
    event.preventDefault()
    event.stopPropagation()
    if (this.container?.dataset.collectionPending === "true") return

    const state = this.activeValue ? "none" : this.stateValue
    this.setPending(true)

    try {
      const response = await fetch(this.urlValue, {
        method: "PATCH",
        headers: {
          "Accept": "application/json",
          "Content-Type": "application/x-www-form-urlencoded",
          "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content
        },
        body: this.body(state)
      })
      const data = await response.json()
      if (!response.ok) throw new Error(data.error || "Could not update collection")

      this.container?.dispatchEvent(new CustomEvent("collection-state:changed", {
        detail: { state: data.state }, bubbles: false
      }))
    } catch (error) {
      this.element.title = error.message
      this.element.classList.add("text-sv-danger")
      setTimeout(() => this.element.classList.remove("text-sv-danger"), 1500)
    } finally {
      this.setPending(false)
    }
  }

  async refresh() {
    if (!this.statusUrlValue) return

    try {
      const response = await fetch(this.statusUrlValue, { headers: { "Accept": "application/json" } })
      if (!response.ok) return
      const data = await response.json()
      this.render(data.state === this.stateValue)
    } catch {}
  }

  body(state) {
    const params = new URLSearchParams(this.paramsValue)
    params.set("state", state)
    return params
  }

  setPending(pending) {
    if (!this.container) return

    this.container.dataset.collectionPending = pending ? "true" : "false"
    this.container.classList.toggle("pointer-events-none", pending)
    this.container.setAttribute("aria-busy", pending ? "true" : "false")
  }

  render(active) {
    this.activeValue = active
    this.element.classList.toggle("text-sv-accent", active)
    this.element.classList.toggle("text-sv-text-muted", !active)
    this.element.classList.toggle("collection-btn--active", active)
    this.element.setAttribute("aria-pressed", String(active))
    this.element.title = active ? `In your ${this.stateValue} - click to remove` : `Add to ${this.stateValue}`

    // Labelled action buttons keep their text; only the glyph swaps.
    const icon = this.element.querySelector("[data-toggle-icon]")
    const label = this.element.querySelector("[data-toggle-label]")
    if (label) {
      label.textContent = active
        ? (this.stateValue === "library" ? "In library" : "On wishlist")
        : (this.stateValue === "library" ? "Library" : "Wishlist")
    }

    // Static glyph markup only, never user data - safe for innerHTML.
    const markup = this.stateValue === "library"
      ? (active
        ? '<svg class="w-4 h-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="m5 12.5 4.5 4.5L19 7"/></svg>'
        : '<svg class="w-4 h-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M12 5v14M5 12h14"/></svg>')
      : '<svg class="w-4 h-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M12 20s-7.5-4.6-7.5-9.6A4.4 4.4 0 0 1 12 7.4a4.4 4.4 0 0 1 7.5 3C19.5 15.4 12 20 12 20Z"/></svg>'

    if (icon) {
      icon.innerHTML = markup
    } else {
      this.element.innerHTML = markup
    }
  }
}
