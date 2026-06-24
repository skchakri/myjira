import { Controller } from "@hotwired/stimulus"

// Toggles the "Import from Jira" modal overlay. Mirrors item_form_controller's
// open/close/backdrop handling (no server round-trip to open).
export default class extends Controller {
  static targets = ["overlay", "input"]

  connect() {
    this.onKey = (e) => { if (e.key === "Escape") this.close() }
    document.addEventListener("keydown", this.onKey)
  }

  disconnect() { document.removeEventListener("keydown", this.onKey) }

  open() {
    this.overlayTarget.classList.remove("hidden")
    if (this.hasInputTarget) this.inputTarget.focus()
  }

  close(e) {
    if (e) e.preventDefault()
    this.overlayTarget.classList.add("hidden")
  }

  backdrop(e) { if (e.target === e.currentTarget) this.close(e) }
}
