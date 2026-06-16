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
        pill.style.backgroundColor = input.checked ? "var(--color-sv-accent)" : "var(--color-sv-surface-hover)"
        pill.style.color = input.checked ? "white" : "var(--color-sv-text-muted)"
      })
    })
  }
}
