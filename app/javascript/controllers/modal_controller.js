import { Controller } from "@hotwired/stimulus"

// Wraps content rendered into the #board_modal turbo-frame (plan / PR diff).
// Closes on the close button, a backdrop click, or Escape — by emptying the
// frame so it can be re-opened cleanly. On open, focus moves into the dialog
// and is trapped (Tab cycles within); on teardown focus returns to the trigger.
export default class extends Controller {
  connect() {
    this.previouslyFocused = document.activeElement
    this.onKey = (e) => {
      if (e.key === "Escape") this.close()
      else if (e.key === "Tab") this.trapTab(e)
    }
    document.addEventListener("keydown", this.onKey)
    // Move focus into the dialog once it's laid out.
    requestAnimationFrame(() => {
      const focusables = this.focusables()
      ;(focusables[0] || this.dialog())?.focus()
    })
  }

  disconnect() {
    document.removeEventListener("keydown", this.onKey)
    // Restore focus to whatever opened the modal, if it's still around.
    if (this.previouslyFocused && document.contains(this.previouslyFocused)) {
      this.previouslyFocused.focus()
    }
  }

  close(e) {
    if (e) e.preventDefault()
    const frame = document.getElementById("board_modal")
    if (frame) frame.innerHTML = "" // empties the frame → disconnect restores focus
  }

  backdrop(e) { if (e.target === e.currentTarget) this.close(e) }

  // The dialog panel (the .paper element carrying role=dialog inside the backdrop).
  dialog() { return this.element.querySelector("[role=dialog]") || this.element }

  focusables() {
    const sel = 'a[href], button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])'
    return Array.from(this.dialog().querySelectorAll(sel)).filter((el) => el.offsetParent !== null)
  }

  trapTab(e) {
    const f = this.focusables()
    if (!f.length) { e.preventDefault(); return }
    const first = f[0]
    const last = f[f.length - 1]
    const active = document.activeElement
    if (e.shiftKey && (active === first || !this.dialog().contains(active))) {
      e.preventDefault(); last.focus()
    } else if (!e.shiftKey && (active === last || !this.dialog().contains(active))) {
      e.preventDefault(); first.focus()
    }
  }
}
