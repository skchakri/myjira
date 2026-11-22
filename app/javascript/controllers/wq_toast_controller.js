import { Controller } from "@hotwired/stimulus"

// A Work Queue toast: auto-dismisses unless it carries a command to copy.
export default class extends Controller {
  connect() {
    if (!this.element.querySelector("[data-text]")) this.timer = setTimeout(() => this.dismiss(), 4500)
  }

  disconnect() { clearTimeout(this.timer) }

  async copy(event) {
    const text = event.currentTarget.dataset.text
    try {
      await navigator.clipboard.writeText(text)
      event.currentTarget.textContent = "Copied"
    } catch (_) {
      event.currentTarget.textContent = "Select and copy"
    }
  }

  dismiss() { this.element.remove() }
}
