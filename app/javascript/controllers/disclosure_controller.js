import { Controller } from "@hotwired/stimulus"

// A <details> that remembers whether it was left open (localStorage, per key).
// force = the server wants it open no matter what (the current page lives inside it);
// that visit is not saved, so leaving the page restores the person's own choice.
export default class extends Controller {
  static values = { key: String, force: Boolean }

  connect() {
    if (this.forceValue) { this.element.open = true; return }
    const saved = this.read()
    if (saved !== null) this.element.open = saved === "open"
  }

  // toggle->disclosure#save
  save() {
    if (this.forceValue) return
    try { localStorage.setItem(this.storageKey(), this.element.open ? "open" : "closed") } catch (_) {}
  }

  // Something inside needs to be seen (e.g. ⌘K focusing the project filter).
  open() { this.element.open = true }

  storageKey() { return `myjira-disclosure:${this.keyValue || "default"}` }

  read() {
    try { return localStorage.getItem(this.storageKey()) } catch (_) { return null }
  }
}
