import { Controller } from "@hotwired/stimulus"

// Collapsible global sidebar. Expanded = in the layout; collapsed = a slim rail,
// with the full sidebar sliding over the content as a drawer while the pointer
// is on the rail's edge. "[" toggles. State is remembered per page section in
// localStorage; a page can default to collapsed (data-sidebar-default-value).
export default class extends Controller {
  static targets = ["aside", "toggle"]
  static values = { default: String, page: String }

  connect() {
    this.keyHandler = (e) => this.onKey(e)
    document.addEventListener("keydown", this.keyHandler)
    this.apply(this.stored() || this.defaultValue || "expanded", false)
  }

  disconnect() { document.removeEventListener("keydown", this.keyHandler) }

  storageKey() { return `myjira-sidebar:${this.pageValue || "default"}` }

  stored() {
    try { return localStorage.getItem(this.storageKey()) } catch (_) { return null }
  }

  save(state) {
    try { localStorage.setItem(this.storageKey(), state) } catch (_) {}
  }

  get collapsed() { return document.documentElement.classList.contains("sb-collapsed") }

  apply(state, persist = true) {
    const collapsed = state === "collapsed"
    document.documentElement.classList.toggle("sb-collapsed", collapsed)
    this.asideTarget.classList.remove("sb-peek")
    this.asideTarget.inert = collapsed
    this.toggleTargets.forEach((b) => {
      b.setAttribute("aria-expanded", String(!collapsed))
      b.setAttribute("aria-label", collapsed ? "Expand sidebar ([)" : "Collapse sidebar ([)")
      b.title = b.getAttribute("aria-label")
    })
    if (persist) this.save(state)
  }

  toggle(event) {
    const next = this.collapsed ? "expanded" : "collapsed"
    this.apply(next)
    const visible = this.toggleTargets.find((b) => !!b.closest(".sb-rail") === (next === "collapsed"))
    if (event?.type !== "click" || !visible?.contains(document.activeElement)) visible?.focus()
  }

  peek() {
    if (!this.collapsed) return
    this.asideTarget.inert = false
    this.asideTarget.classList.add("sb-peek")
  }

  unpeek() {
    if (!this.collapsed) return
    this.asideTarget.classList.remove("sb-peek")
    this.asideTarget.inert = true
  }

  // A click inside the open drawer pins the sidebar open again.
  pin(event) {
    if (!this.collapsed || !this.asideTarget.classList.contains("sb-peek")) return
    if (event.target.closest("[data-sidebar-target='toggle']")) return
    this.apply("expanded")
  }

  onKey(e) {
    if (e.key !== "[" || e.metaKey || e.ctrlKey || e.altKey) return
    const t = e.target
    if (["INPUT", "TEXTAREA", "SELECT"].includes(t.tagName) || t.isContentEditable) return
    e.preventDefault()
    this.toggle(e)
  }
}
