import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["pill"]

  connect() {
    this.pillTargets.forEach(pill => {
      pill.addEventListener("click", (e) => {
        e.preventDefault()
        const input = pill.querySelector("input")
        input.checked = !input.checked
        pill.dataset.selected = input.checked
        pill.style.backgroundColor = input.checked ? "var(--color-iris-600)" : "oklch(1 0 0 / 0.05)"
        pill.style.color = input.checked ? "var(--color-on-accent)" : "var(--color-ink-300)"
      })
    })
  }
}
