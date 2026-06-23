import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = {
    kind: String,
    addUrl: String,
    destroyUrl: String,
    addTitle: String,
    addedTitle: String,
    added: Boolean,
    statusUrl: String
  }

  connect() {
    this._onSiblingAdded = this._onSiblingAdded.bind(this)
    this._onPageShow = this._onPageShow.bind(this)
    this.container = this.element.closest(".flex.gap-3.mt-6")
    this.container?.addEventListener("toggle-button:added", this._onSiblingAdded)
    window.addEventListener("pageshow", this._onPageShow)
  }

  disconnect() {
    this.container?.removeEventListener("toggle-button:added", this._onSiblingAdded)
    window.removeEventListener("pageshow", this._onPageShow)
  }

  async toggle(event) {
    event.preventDefault()
    event.stopPropagation()

    if (this.addedValue) {
      await this.remove()
    } else {
      await this.add()
    }
  }

  async add() {
    if (!this.addUrlValue) return

    const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content

    try {
      const response = await fetch(this.addUrlValue, {
        method: "POST",
        headers: {
          "Accept": "application/json",
          "X-CSRF-Token": csrfToken
        },
        body: new URLSearchParams(this._addParams())
      })

      const data = await response.json().catch(() => ({ ok: false, error: "Unexpected response from server." }))

      if (response.ok && data.ok) {
        this.destroyUrlValue = data.destroy_url
        this.markAdded()
        this.element.dispatchEvent(new CustomEvent("toggle-button:added", {
          detail: { kind: this.kindValue },
          bubbles: true
        }))
      } else {
        this.showError(data.error || "Could not add. Please try again.")
      }
    } catch (e) {
      this.showError("Network error. Please try again.")
    }
  }

  async remove() {
    if (!this.destroyUrlValue) return

    const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content

    try {
      const response = await fetch(this.destroyUrlValue, {
        method: "DELETE",
        headers: {
          "Accept": "application/json",
          "X-CSRF-Token": csrfToken
        }
      })

      const data = await response.json().catch(() => ({ ok: false, error: "Unexpected response from server." }))

      if (response.ok && data.ok) {
        this.destroyUrlValue = ""
        this.markRemoved()
      } else {
        this.showError(data.error || "Could not remove. Please try again.")
      }
    } catch (e) {
      this.showError("Network error. Please try again.")
    }
  }

  _addParams() {
    const params = {}
    this.element.dataset.toggleButtonParams
      .split("&")
      .filter(Boolean)
      .forEach(pair => {
        const [key, value] = pair.split("=")
        params[decodeURIComponent(key)] = decodeURIComponent(value || "")
      })
    return params
  }

  markAdded() {
    this.addedValue = true
    this.element.disabled = false
    this.element.classList.remove("text-sv-text-muted", "hover:text-sv-accent")
    this.element.classList.add("text-sv-accent")
    this.element.dataset.added = "true"
    this.element.title = this.addedTitleValue

    if (this.kindValue === "library") {
      this.element.innerHTML = `<svg class="w-5 h-5" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2"><path stroke-linecap="round" stroke-linejoin="round" d="M5 13l4 4L19 7"/></svg>`
    } else if (this.kindValue === "wishlist") {
      this.element.innerHTML = `<svg class="w-5 h-5" fill="currentColor" viewBox="0 0 24 24"><path d="M4.318 6.318a4.5 4.5 0 000 6.364L12 20.364l7.682-7.682a4.5 4.5 0 00-6.364-6.364L12 7.636l-1.318-1.318a4.5 4.5 0 00-6.364 0z"/></svg>`
    }
  }

  markRemoved() {
    this.addedValue = false
    this.element.disabled = false
    this.element.classList.remove("text-sv-accent")
    this.element.classList.add("text-sv-text-muted", "hover:text-sv-accent")
    delete this.element.dataset.added
    this.element.title = this.addTitleValue

    if (this.kindValue === "library") {
      this.element.innerHTML = `<svg class="w-5 h-5" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2"><path stroke-linecap="round" stroke-linejoin="round" d="M12 4v16m8-8H4"/></svg>`
    } else if (this.kindValue === "wishlist") {
      this.element.innerHTML = `<svg class="w-5 h-5" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2"><path stroke-linecap="round" stroke-linejoin="round" d="M4.318 6.318a4.5 4.5 0 000 6.364L12 20.364l7.682-7.682a4.5 4.5 0 00-6.364-6.364L12 7.636l-1.318-1.318a4.5 4.5 0 00-6.364 0z"/></svg>`
    }
  }

  showError(message) {
    this.element.title = message
    this.element.classList.add("text-sv-danger")
    setTimeout(() => {
      this.element.classList.remove("text-sv-danger")
    }, 1500)
  }

  _onSiblingAdded(event) {
    // Adding to library removes the matching wishlist entry server-side,
    // so a wishlist button in the "added" state reverts to addable.
    if (event.detail.kind === "library" && this.kindValue === "wishlist" && this.addedValue) {
      this.destroyUrlValue = ""
      this.markRemoved()
    }
  }

  async _onPageShow(event) {
    // Only re-sync when the page is restored from bfcache
    if (!event.persisted) return
    if (!this.statusUrlValue) return

    try {
      const response = await fetch(this.statusUrlValue, { headers: { "Accept": "application/json" } })
      const data = await response.json()
      if (!response.ok || !data) return

      const isIn = this.kindValue === "library" ? data.in_library : data.in_wishlist
      const entryId = this.kindValue === "library" ? data.library_entry_id : data.wishlist_entry_id

      if (isIn && entryId) {
        this.destroyUrlValue = this.kindValue === "library" ? `/library/${entryId}` : `/wishlist/${entryId}`
        if (!this.addedValue) this.markAdded()
      } else {
        this.destroyUrlValue = ""
        if (this.addedValue) this.markRemoved()
      }
    } catch (e) {
      // If re-sync fails, leave the current state — better than breaking
    }
  }
}
