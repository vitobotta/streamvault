import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["message"]

  connect() {
    this.hideTimer = setTimeout(() => this.dismiss(), 5000)
  }

  disconnect() {
    if (this.hideTimer) {
      clearTimeout(this.hideTimer)
      this.hideTimer = null
    }
  }

  dismiss() {
    this.element.classList.add("opacity-0", "transition-opacity", "duration-500")
    this.hideTimer = setTimeout(() => this.element.classList.add("hidden"), 500)
  }
}
