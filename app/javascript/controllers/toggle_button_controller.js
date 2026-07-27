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
    this.container = this.element.closest(".flex.gap-3.mt-6")
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
    this.element.title = active ? `In your ${this.stateValue} — click to remove` : `Add to ${this.stateValue}`

    if (this.stateValue === "library") {
      this.element.innerHTML = active
        ? '<svg class="w-5 h-5" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2"><path stroke-linecap="round" stroke-linejoin="round" d="M5 13l4 4L19 7"/></svg>'
        : '<svg class="w-5 h-5" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2"><path stroke-linecap="round" stroke-linejoin="round" d="M12 4v16m8-8H4"/></svg>'
    } else {
      this.element.innerHTML = `<svg class="w-5 h-5" fill="${active ? "currentColor" : "none"}" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2"><path d="M4.318 6.318a4.5 4.5 0 000 6.364L12 20.364l7.682-7.682a4.5 4.5 0 00-6.364-6.364L12 7.636l-1.318-1.318a4.5 4.5 0 00-6.364 0z"/></svg>`
    }
  }
}
