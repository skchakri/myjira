import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["source", "button"]

  copy() {
    const text = this.sourceTarget.innerText
    navigator.clipboard.writeText(text).then(() => {
      if (!this.hasButtonTarget) return
      const original = this.buttonTarget.innerText
      this.buttonTarget.innerText = "Copied ✓"
      setTimeout(() => { this.buttonTarget.innerText = original }, 1500)
    })
  }
}
