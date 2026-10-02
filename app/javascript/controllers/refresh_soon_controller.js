import { Controller } from "@hotwired/stimulus"

// Re-visits the current page once after a short delay. Rendered only while a
// transient server-side state is settling (e.g. the launcher daemon spawning a
// session), so the page polls just until that element stops being rendered.
export default class extends Controller {
  static values = { after: { type: Number, default: 2000 } }

  connect() {
    this.timer = setTimeout(() => {
      window.Turbo?.visit(window.location.href, { action: "replace" })
    }, this.afterValue)
  }

  disconnect() {
    clearTimeout(this.timer)
  }
}
