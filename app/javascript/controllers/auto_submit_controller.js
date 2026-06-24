import { Controller } from "@hotwired/stimulus"

// Submit the form this controller is attached to whenever an input fires its
// action (e.g. a status <select> or autopilot toggle changing). Used for the
// board's inline edits, which respond 204 + a refresh broadcast.
export default class extends Controller {
  submit() {
    this.element.requestSubmit()
  }
}
