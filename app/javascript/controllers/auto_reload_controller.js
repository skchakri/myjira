import { Controller } from "@hotwired/stimulus"

// Periodically reloads the Turbo Frame it's attached to (used for the
// "Live now" strip so live sessions stay fresh without a full page reload).
export default class extends Controller {
  static values = { interval: Number }

  connect() {
    const ms = this.intervalValue || 15000
    this.timer = setInterval(() => {
      if (typeof this.element.reload === "function") this.element.reload()
    }, ms)
  }

  disconnect() {
    clearInterval(this.timer)
  }
}
