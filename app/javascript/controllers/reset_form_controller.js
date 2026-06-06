import { Controller } from "@hotwired/stimulus"

// Clears the form after a successful Turbo submit (the command composer's
// response is a 204 + a broadcast, so the form isn't re-rendered). Resetting the
// form also fires its native `reset` event, which clears the file-name preview.
export default class extends Controller {
  reset(event) {
    if (event.detail && event.detail.success === false) return
    const form = (event.target && event.target.closest("form")) || this.element.querySelector("form")
    form?.reset()
  }
}
