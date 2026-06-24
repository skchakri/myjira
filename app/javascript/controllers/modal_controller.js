import { Controller } from "@hotwired/stimulus"

// Wraps content rendered into the #board_modal turbo-frame (plan / PR diff).
// Closes on the close button, a backdrop click, or Escape — by emptying the
// frame so it can be re-opened cleanly.
export default class extends Controller {
  connect() {
    this.onKey = (e) => { if (e.key === "Escape") this.close() }
    document.addEventListener("keydown", this.onKey)
  }

  disconnect() { document.removeEventListener("keydown", this.onKey) }

  close(e) {
    if (e) e.preventDefault()
    const frame = document.getElementById("board_modal")
    if (frame) frame.innerHTML = ""
  }

  backdrop(e) { if (e.target === e.currentTarget) this.close(e) }
}
