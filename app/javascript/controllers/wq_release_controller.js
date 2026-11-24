import { Controller } from "@hotwired/stimulus"

// The in-page deploy confirm on the Releases page (a <details>): Cancel and Esc close it.
export default class extends Controller {
  close() { this.element.removeAttribute("open") }

  key(e) { if (e.key === "Escape") this.close() }
}
