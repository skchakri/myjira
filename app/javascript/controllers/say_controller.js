import { Controller } from "@hotwired/stimulus"

// Per-message speaker icon: reads that one message aloud (toggles stop). Speaks
// the rendered text of the bubble, so markdown symbols aren't read out.
export default class extends Controller {
  static targets = ["content", "btn"]

  toggle() {
    if (!("speechSynthesis" in window)) return
    const synth = window.speechSynthesis

    // second click on the one that's speaking → stop
    if (this.speaking) {
      synth.cancel()
      this.speaking = false
      this.mark(false)
      return
    }

    synth.cancel() // stop any other message that's mid-read
    const text = this.hasContentTarget ? this.contentTarget.textContent.trim() : ""
    if (!text) return

    const u = new SpeechSynthesisUtterance(text)
    u.rate = 1.0
    u.onend = () => { this.speaking = false; this.mark(false) }
    u.onerror = () => { this.speaking = false; this.mark(false) }
    this.speaking = true
    this.mark(true)
    synth.speak(u)
  }

  mark(on) {
    if (this.hasBtnTarget) this.btnTarget.dataset.speaking = on ? "true" : "false"
  }

  disconnect() {
    if (this.speaking && "speechSynthesis" in window) window.speechSynthesis.cancel()
  }
}
