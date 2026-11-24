import { Controller } from "@hotwired/stimulus"

// The inbox page: keyboard triage over every entry that needs the person, drafts that
// survive a refresh (same sessionStorage keys as the Work Queue question box), a
// one-line "answered" row after an action, and a debounced reload of the list when
// the Work Queue stream reports a change.
const DONE_KEY = "wq-inbox-done"
const DONE_TTL = 5 * 60 * 1000

export default class extends Controller {
  static targets = ["entry", "frame", "help"]
  static values = { url: String }

  connect() {
    this.keyHandler = (e) => this.onKey(e)
    document.addEventListener("keydown", this.keyHandler)
    this.streamHandler = (e) => this.onStream(e)
    document.addEventListener("turbo:before-stream-render", this.streamHandler)
    this.inputHandler = (e) => this.saveDraft(e)
    this.element.addEventListener("input", this.inputHandler)
    this.element.addEventListener("change", this.inputHandler)
    this.submitHandler = (e) => this.submitted(e)
    this.element.addEventListener("turbo:submit-end", this.submitHandler)
    this.clickHandler = (e) => this.clicked(e)
    this.element.addEventListener("click", this.clickHandler)
    this.blurHandler = () => { if (this.refreshWaiting) this.scheduleRefresh() }
    this.element.addEventListener("focusout", this.blurHandler)
  }

  disconnect() {
    document.removeEventListener("keydown", this.keyHandler)
    document.removeEventListener("turbo:before-stream-render", this.streamHandler)
    this.element.removeEventListener("input", this.inputHandler)
    this.element.removeEventListener("change", this.inputHandler)
    this.element.removeEventListener("turbo:submit-end", this.submitHandler)
    this.element.removeEventListener("click", this.clickHandler)
    this.element.removeEventListener("focusout", this.blurHandler)
    clearTimeout(this.refreshTimer)
  }

  // ---- entries ---------------------------------------------------------------

  entryTargetConnected(entry) {
    const box = entry.querySelector(".wq-qbox[data-item-key]")
    if (box) this.restoreDraft(box)
    const done = this.readDone()[entry.dataset.key]
    if (done && done.sig === entry.dataset.sig) this.collapse(entry, done.text)
    if (this.focusKey && entry.dataset.key === this.focusKey) this.focus(entry, { scroll: false })
  }

  live() { return this.entryTargets.filter((e) => !e.classList.contains("inbox-entry-done")) }
  current() { return this.entryTargets.find((e) => e.classList.contains("inbox-entry-focus")) }

  focus(entry, { scroll = true } = {}) {
    if (!entry) return
    this.entryTargets.forEach((e) => e.classList.toggle("inbox-entry-focus", e === entry))
    this.focusKey = entry.dataset.key
    if (scroll) entry.scrollIntoView({ block: "nearest" })
  }

  move(delta) {
    const list = this.live()
    if (!list.length) return
    const at = list.indexOf(this.current())
    this.focus(list[Math.min(Math.max(at + delta, 0), list.length - 1)] || list[0])
  }

  collapse(entry, text) {
    entry.classList.add("inbox-entry-done")
    entry.querySelector(".inbox-entry-b")?.classList.add("hidden")
    entry.querySelector(".inbox-now")?.classList.add("hidden")
    const done = entry.querySelector(".inbox-done")
    done?.classList.remove("hidden")
    const label = done?.querySelector("[data-inbox-done-text]")
    if (label && text) label.textContent = text
  }

  // ---- what an action did -----------------------------------------------------

  submitted(e) {
    if (!e.detail?.success) return
    const entry = e.target.closest("[data-inbox-target~='entry']")
    if (!entry) return
    const box = e.target.closest(".wq-qbox[data-item-key]")
    if (box) { try { sessionStorage.removeItem(this.draftKey(box)) } catch (_) {} }
    const text = e.target.dataset.inboxDone || (box ? "Answered" : "Done")
    const all = this.readDone()
    all[entry.dataset.key] = { sig: entry.dataset.sig, text, at: Date.now() }
    this.writeDone(all)
    const list = this.live()
    const next = list[list.indexOf(entry) + 1] || list[list.indexOf(entry) - 1]
    this.collapse(entry, text)
    if (next) this.focus(next)
    this.scheduleRefresh()
  }

  readDone() {
    try {
      const all = JSON.parse(sessionStorage.getItem(DONE_KEY) || "{}")
      const now = Date.now()
      Object.keys(all).forEach((k) => { if (now - all[k].at > DONE_TTL) delete all[k] })
      return all
    } catch (_) { return {} }
  }

  writeDone(all) { try { sessionStorage.setItem(DONE_KEY, JSON.stringify(all)) } catch (_) {} }

  // The merge panel's Cancel button is wired to the Work Queue controller; close it here.
  clicked(e) {
    const cancel = e.target.closest("[data-action*='closeMerge']")
    if (cancel) cancel.closest("details")?.removeAttribute("open")
    const entry = e.target.closest("[data-inbox-target~='entry']")
    if (entry && !entry.classList.contains("inbox-entry-done")) this.focus(entry, { scroll: false })
  }

  // ---- drafts (shared with the Work Queue question box) -------------------------

  draftKey(box) { return `wq-draft:${box.dataset.itemKey}` }

  saveDraft(e) {
    const box = e.target.closest?.(".wq-qbox[data-item-key]")
    const form = box?.querySelector("form")
    if (!form) return
    const draft = {}
    form.querySelectorAll("textarea[name], input[type=radio][name]:checked").forEach((el) => {
      if (el.type === "radio" || el.value) draft[el.name] = el.value
    })
    try {
      if (Object.keys(draft).length) sessionStorage.setItem(this.draftKey(box), JSON.stringify(draft))
      else sessionStorage.removeItem(this.draftKey(box))
    } catch (_) {}
  }

  restoreDraft(box) {
    let draft = null
    try { draft = JSON.parse(sessionStorage.getItem(this.draftKey(box)) || "null") } catch (_) {}
    if (!draft) return
    box.querySelectorAll("textarea[name]").forEach((el) => { if (draft[el.name] != null) el.value = draft[el.name] })
    box.querySelectorAll("input[type=radio][name]").forEach((el) => { if (draft[el.name] === el.value) el.checked = true })
  }

  // ---- live refresh -------------------------------------------------------------

  // Any Work Queue stream (a card, a project block, a status event) means the list may be stale.
  onStream(e) {
    if (e.target?.getAttribute?.("target") === "wq_toasts") return
    this.scheduleRefresh()
  }

  scheduleRefresh() {
    clearTimeout(this.refreshTimer)
    this.refreshTimer = setTimeout(() => this.refresh(), 2000)
  }

  // Never reload under someone who is typing: wait until they leave the text box.
  refresh() {
    const a = document.activeElement
    if (a && this.element.contains(a) && a.tagName === "TEXTAREA") { this.refreshWaiting = true; return }
    if (this.element.querySelector("details.wq-merge[open]")) { this.refreshWaiting = true; this.scheduleRefresh(); return }
    this.refreshWaiting = false
    const frame = this.frameTarget
    if (frame.getAttribute("src")) frame.reload(); else frame.src = this.urlValue
  }

  // ---- keyboard -----------------------------------------------------------------

  toggleHelp() { this.helpTarget.classList.toggle("hidden") }

  onKey(e) {
    if (e.metaKey || e.ctrlKey || e.altKey) return
    const typing = ["INPUT", "TEXTAREA", "SELECT"].includes(e.target.tagName) || e.target.isContentEditable
    if (e.key === "Escape") { e.target.blur?.(); return }
    if (typing) return
    const entry = this.current()
    switch (e.key) {
      case "j": this.move(1); break
      case "k": this.move(-1); break
      case "?": this.toggleHelp(); break
      case "o": entry?.querySelector("[data-inbox-open]")?.click(); break
      case "r": entry?.querySelector("[data-inbox-resume]")?.click(); break
      case "a": entry?.querySelector("[data-allow-all]")?.click(); break
      case "/": { const t = entry?.querySelector(".wq-qbox textarea"); if (t) { e.preventDefault(); t.focus() } break }
      case "Enter": this.send(entry, e); break
      case "1": case "2": case "3": case "4": this.pick(entry, e.key); break
      default: return
    }
  }

  // Tick option N on the first question of the entry that has no answer yet.
  pick(entry, n) {
    const sets = [...(entry?.querySelectorAll(".wq-qbox fieldset.wq-question") || [])]
    const open = sets.find((f) => !f.querySelector("input[type=radio]:checked") && !f.querySelector("textarea")?.value.trim()) || sets[0]
    const radio = open?.querySelector(`input[type=radio][data-option="${n}"]`)
    if (!radio) return
    radio.checked = true
    radio.dispatchEvent(new Event("change", { bubbles: true }))
  }

  // Enter: send the picked answers, or do the entry's main action (approve, resume, open).
  send(entry, e) {
    if (!entry || e.target.closest("button, a, summary")) return
    const form = entry.querySelector(".wq-qbox form")
    if (form) {
      const picked = form.querySelector("input[type=radio]:checked") || [...form.querySelectorAll("textarea")].some((t) => t.value.trim())
      if (picked) { e.preventDefault(); form.requestSubmit(form.querySelector("button[type=submit]:not([name])")) }
      return
    }
    const main = entry.querySelector("[data-inbox-main]")
    if (main) { e.preventDefault(); main.click() }
  }
}
