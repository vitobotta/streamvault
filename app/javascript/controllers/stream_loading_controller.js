import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = { path: String }

  connect() {
    this.onSubmit = this.onSubmit.bind(this)
    document.addEventListener("submit", this.onSubmit, true)
  }

  disconnect() {
    document.removeEventListener("submit", this.onSubmit, true)
  }

  onSubmit(event) {
    const form = event.target
    if (!(form instanceof HTMLFormElement)) return
    try {
      const action = new URL(form.action, window.location.origin)
      if (action.pathname === this.pathValue) {
        this.element.classList.remove("hidden")
        this.element.setAttribute("aria-hidden", "false")
      }
    } catch {}
  }
}
