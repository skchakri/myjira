import { Controller } from "@hotwired/stimulus"

// Submit the form this controller is attached to whenever an input fires its
// action (e.g. a status <select> or autopilot toggle changing). Used for the
// board's inline edits, which respond 204 + a refresh broadcast.
//
// Guards against a double-submit race: the <select>/toggle stays interactive
// during the Turbo round-trip, so a second `change` could fire a second PATCH
// before the first morph lands, morphing the board to an intermediate state.
// We bail while a submit is in flight and mark the form `data-turbo-submitting`
// so CSS can dim/lock the control. Controls are NOT disabled — a disabled field
// is dropped from the form body, so we'd lose the value; the in-flight flag plus
// CSS `pointer-events:none` is what blocks re-entry.
export default class extends Controller {
  connect() {
    this.submitting = false
    this.onSubmitEnd = this.onSubmitEnd.bind(this)
    this.element.addEventListener("turbo:submit-end", this.onSubmitEnd)
  }

  disconnect() {
    this.element.removeEventListener("turbo:submit-end", this.onSubmitEnd)
  }

  submit() {
    if (this.submitting) return
    this.submitting = true
    this.element.dataset.turboSubmitting = ""
    this.element.requestSubmit()
  }

  onSubmitEnd() {
    this.submitting = false
    delete this.element.dataset.turboSubmitting
  }
}
