import { Controller } from "@hotwired/stimulus"

// Shows the names of files chosen in the hidden file input, and clears them when
// the form resets after submit.
export default class extends Controller {
  static targets = ["input", "list"]

  changed() {
    const files = Array.from(this.inputTarget.files || [])
    if (!this.hasListTarget) return
    if (files.length) {
      this.listTarget.textContent = "📎 " + files.map((f) => f.name).join(", ")
      this.listTarget.classList.remove("hidden")
    } else {
      this.clear()
    }
  }

  clear() {
    if (this.hasListTarget) {
      this.listTarget.textContent = ""
      this.listTarget.classList.add("hidden")
    }
  }
}
