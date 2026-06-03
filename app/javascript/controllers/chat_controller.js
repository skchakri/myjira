import { Controller } from "@hotwired/stimulus"

// Drives the relay thread like a chat pane:
//  - keeps the scroll pinned to the newest message (on load + as Turbo Stream
//    appends arrive from the API/long-poll),
//  - sends on Enter (Shift+Enter inserts a newline),
//  - lets the kind chips set a hidden field so a posted turn can be a
//    note / instruction / answer / question.
export default class extends Controller {
  static targets = ["scroll", "input", "kind", "chip"]

  connect() {
    this.scrollToBottom()
    if (this.hasScrollTarget) {
      this.observer = new MutationObserver(() => this.scrollToBottom())
      this.observer.observe(this.scrollTarget, { childList: true, subtree: true })
    }
  }

  disconnect() {
    this.observer?.disconnect()
  }

  scrollToBottom() {
    if (this.hasScrollTarget) {
      this.scrollTarget.scrollTop = this.scrollTarget.scrollHeight
    }
  }

  // Enter sends; Shift+Enter (or Cmd/Ctrl+Enter) keeps a newline.
  keydown(event) {
    if (event.key === "Enter" && !event.shiftKey) {
      event.preventDefault()
      if (this.inputTarget.value.trim()) {
        this.inputTarget.form.requestSubmit()
      }
    }
  }

  pick(event) {
    if (this.hasKindTarget) this.kindTarget.value = event.params.kind
    this.chipTargets.forEach((c) => {
      const active = c === event.currentTarget
      c.classList.toggle("pill-accent", active)
      c.classList.toggle("pill-quiet", !active)
    })
  }
}
