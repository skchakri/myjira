import { Controller } from "@hotwired/stimulus"

// Toggles the bottom-right "Humanize" popover. The summary itself is filled in
// by Turbo Streams (loading state on submit, then the result from the job).
export default class extends Controller {
  static targets = ["panel"]

  open() {
    if (this.hasPanelTarget) this.panelTarget.classList.remove("hidden")
  }

  close() {
    if (this.hasPanelTarget) this.panelTarget.classList.add("hidden")
  }
}
