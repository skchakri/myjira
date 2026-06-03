import { Controller } from "@hotwired/stimulus"

// Clears a form after a successful Turbo submit (used by the command composer,
// whose response is a 204 + a broadcast rather than a re-render).
export default class extends Controller {
  reset(event) {
    if (!event.detail || event.detail.success !== false) this.element.reset()
  }
}
