import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["track", "prevBtn", "nextBtn"]

  connect() {
    this.scrollAmount = 300
    this.updateTimer = null
    this.updateButtons()
  }

  disconnect() {
    if (this.updateTimer) {
      clearTimeout(this.updateTimer)
      this.updateTimer = null
    }
  }

  prev() {
    this.trackTarget.scrollBy({ left: -this.scrollAmount * 2, behavior: "smooth" })
    this.updateTimer = setTimeout(() => this.updateButtons(), 350)
  }

  next() {
    this.trackTarget.scrollBy({ left: this.scrollAmount * 2, behavior: "smooth" })
    this.updateTimer = setTimeout(() => this.updateButtons(), 350)
  }

  updateButtons() {
    const track = this.trackTarget
    if (!this.hasPrevBtnTarget || !this.hasNextBtnTarget) return
    this.updateTimer = null
    this.prevBtnTarget.classList.toggle("invisible", track.scrollLeft <= 10)
    this.nextBtnTarget.classList.toggle("invisible", track.scrollLeft + track.clientWidth >= track.scrollWidth - 10)
  }
}
