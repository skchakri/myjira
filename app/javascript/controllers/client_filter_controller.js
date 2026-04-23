import { Controller } from "@hotwired/stimulus"

// Live-filter the client list in the sidebar.
// Cmd/Ctrl-K focuses the input from anywhere on the page.
export default class extends Controller {
  static targets = ["input", "row", "empty", "count"]

  connect() {
    this._onKey = (e) => {
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "k") {
        e.preventDefault()
        this.inputTarget.focus()
        this.inputTarget.select()
      }
    }
    document.addEventListener("keydown", this._onKey)
    this.filter()
  }

  disconnect() {
    document.removeEventListener("keydown", this._onKey)
  }

  filter() {
    const q = (this.inputTarget.value || "").trim().toLowerCase()
    let shown = 0
    for (const row of this.rowTargets) {
      const hay = (row.dataset.hay || "").toLowerCase()
      const match = !q || hay.includes(q)
      row.dataset.hidden = match ? "false" : "true"
      if (match) shown += 1
    }
    if (this.hasEmptyTarget) this.emptyTarget.hidden = shown !== 0
    if (this.hasCountTarget) this.countTarget.textContent = String(shown)
  }

  clear(e) {
    if (e.key === "Escape") {
      this.inputTarget.value = ""
      this.filter()
      this.inputTarget.blur()
    }
  }
}
