import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["select", "url"]
  static values = { map: Object }

  connect() { this.update() }

  update() {
    const id = this.selectTarget.value
    this.urlTarget.textContent = (this.mapValue[id] || "").trim() || "—"
  }
}
