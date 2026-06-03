import { Controller } from "@hotwired/stimulus"

// "Summarize & speak": arms on the button click (priming the speech API within
// the user gesture), then reads the summary aloud the moment the background job
// streams it into the panel. Also supports on-demand Play/Stop.
export default class extends Controller {
  static targets = ["panel", "stop"]

  connect() {
    this.supported = "speechSynthesis" in window
    this.armed = false
    this.spokenText = null
    if (this.hasPanelTarget) {
      this.observer = new MutationObserver(() => this.maybeSpeak())
      this.observer.observe(this.panelTarget, { childList: true, subtree: true })
    }
  }

  disconnect() {
    this.observer?.disconnect()
    if (this.supported) window.speechSynthesis.cancel()
  }

  // Button click: arm + warm up the speech engine inside the gesture, then the
  // form submits and the job runs.
  arm() {
    this.armed = true
    this.prime()
  }

  prime() {
    if (!this.supported) return
    try {
      const u = new SpeechSynthesisUtterance("")
      u.volume = 0
      window.speechSynthesis.speak(u)
    } catch (_) { /* noop */ }
  }

  // Fired by the panel MutationObserver when the streamed summary arrives.
  maybeSpeak() {
    if (!this.armed) return
    const text = this.currentText()
    if (text && text !== this.spokenText) {
      this.spokenText = text
      this.armed = false
      this.speak(text)
    }
  }

  // On-demand replay from the "🔊 Play" button.
  play() {
    this.speak(this.currentText())
  }

  stop() {
    if (this.supported) window.speechSynthesis.cancel()
    this.showStop(false)
  }

  speak(text) {
    if (!this.supported || !text) return
    window.speechSynthesis.cancel()
    const u = new SpeechSynthesisUtterance(text)
    u.rate = 1.0
    u.onstart = () => this.showStop(true)
    u.onend = () => this.showStop(false)
    u.onerror = () => this.showStop(false)
    window.speechSynthesis.speak(u)
  }

  currentText() {
    const el = this.hasPanelTarget && this.panelTarget.querySelector('[data-speak-target="text"]')
    return el ? el.textContent.trim() : ""
  }

  showStop(on) {
    if (!this.hasStopTarget) return
    this.stopTarget.classList.toggle("hidden", !on)
    this.stopTarget.classList.toggle("inline-flex", on)
  }
}
