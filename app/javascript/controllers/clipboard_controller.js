import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["source", "button"]

  // A button can carry its own text via data-clipboard-text-param; otherwise
  // copy the source target.
  copy(event) {
    const text = event?.params?.text || this.sourceTarget.innerText
    navigator.clipboard.writeText(text).then(() => {
      if (!this.hasButtonTarget) return
      const original = this.buttonTarget.innerText
      this.buttonTarget.innerText = "Copied ✓"
      setTimeout(() => { this.buttonTarget.innerText = original }, 1500)
    })
  }
}
