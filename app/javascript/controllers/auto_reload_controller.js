import { Controller } from "@hotwired/stimulus"

// Periodically reloads the Turbo Frame it's attached to (e.g. the "Live now"
// strip) so it stays fresh without a full page reload. Two safeguards over a bare
// setInterval:
//   1. aria-busy — the frame is marked busy while a reload is in flight, so
//      assistive tech announces the update instead of content changing silently.
//   2. failure back-off + halt — if the frame's src starts failing (404/500/
//      network), the interval backs off exponentially and then stops entirely,
//      so a dead frame never polls forever in the background.
export default class extends Controller {
  static values = { interval: Number, maxFailures: { type: Number, default: 5 } }

  connect() {
    this.baseMs = this.intervalValue || 15000
    this.failures = 0
    this.onRequest = () => this.element.setAttribute("aria-busy", "true")
    this.onResponse = (e) => this.settle(e.detail?.fetchResponse?.response?.ok !== false)
    this.onError = () => this.settle(false)
    this.element.addEventListener("turbo:before-fetch-request", this.onRequest)
    this.element.addEventListener("turbo:before-fetch-response", this.onResponse)
    this.element.addEventListener("turbo:fetch-request-error", this.onError)
    this.schedule(this.baseMs)
  }

  schedule(ms) {
    clearTimeout(this.timer)
    this.timer = setTimeout(() => this.reload(), ms)
  }

  reload() {
    if (typeof this.element.reload === "function") this.element.reload()
    // Back off proportionally to consecutive failures (capped at 16×); a healthy
    // frame keeps failures at 0 and so reloads at the base interval.
    this.schedule(this.baseMs * Math.min(2 ** this.failures, 16))
  }

  // Called when a reload settles: clear the busy flag, then reset on success or
  // escalate and finally give up after maxFailures consecutive failures.
  settle(ok) {
    this.element.removeAttribute("aria-busy")
    if (ok) { this.failures = 0; return }
    this.failures += 1
    if (this.failures >= this.maxFailuresValue) clearTimeout(this.timer)
  }

  disconnect() {
    clearTimeout(this.timer)
    this.element.removeEventListener("turbo:before-fetch-request", this.onRequest)
    this.element.removeEventListener("turbo:before-fetch-response", this.onResponse)
    this.element.removeEventListener("turbo:fetch-request-error", this.onError)
  }
}
