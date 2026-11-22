import { Controller } from "@hotwired/stimulus"

// Work Queue live view: keyboard navigation, multi-select grouping, log
// auto-scroll, voice (Web Speech API) and notifications on status changes.
// All data arrives as Turbo Stream pushes; this controller never polls.
const NEEDS_YOU = ["waiting", "blocked"]
const csrf = () => document.querySelector('meta[name="csrf-token"]')?.content

export default class extends Controller {
  static targets = ["card", "link", "log", "jump", "event", "groupBtn", "groupCount", "speakToggle",
                    "notifyBtn", "help", "question", "answer", "merge"]
  static values = { selected: String, groupUrl: String }

  connect() {
    this.pinned = true
    this.selection = new Set()
    this.keyHandler = (e) => this.onKey(e)
    document.addEventListener("keydown", this.keyHandler)
    try { this.speakToggleTarget.checked = localStorage.getItem("wq-speak") === "1" } catch (_) {}
    if ("Notification" in window && Notification.permission === "granted" && this.hasNotifyBtnTarget) this.notifyBtnTarget.classList.add("hidden")
    this.frameLoad = () => this.afterFrame()
    document.addEventListener("turbo:frame-load", this.frameLoad)
    this.afterFrame()
  }

  disconnect() {
    document.removeEventListener("keydown", this.keyHandler)
    document.removeEventListener("turbo:frame-load", this.frameLoad)
    this.logObserver?.disconnect()
  }

  // ---- selection / navigation --------------------------------------------
  afterFrame() {
    const detail = this.element.querySelector(".wq-detail-grid")
    this.selectedValue = detail?.dataset.key || ""
    this.cardTargets.forEach((c) => c.classList.toggle("wq-card-active", c.dataset.key === this.selectedValue))
    this.pinned = true
    this.scrollLog()
  }

  cardTargetConnected(card) {
    card.classList.toggle("wq-card-active", card.dataset.key === this.selectedValue)
    const box = card.querySelector(".wq-check")
    if (box && this.selection?.has(box.value)) box.checked = true
  }

  visibleCards() { return this.cardTargets.filter((c) => c.offsetParent !== null) }

  move(delta) {
    const cards = this.visibleCards()
    if (!cards.length) return
    let i = cards.findIndex((c) => c.classList.contains("wq-card-focus"))
    if (i < 0) i = cards.findIndex((c) => c.dataset.key === this.selectedValue)
    i = Math.max(0, Math.min(cards.length - 1, i + delta))
    cards.forEach((c) => c.classList.remove("wq-card-focus"))
    cards[i].classList.add("wq-card-focus")
    cards[i].scrollIntoView({ block: "nearest" })
  }

  focused() { return this.cardTargets.find((c) => c.classList.contains("wq-card-focus")) || this.cardTargets.find((c) => c.dataset.key === this.selectedValue) }

  select(event) {
    const box = event.currentTarget
    box.checked ? this.selection.add(box.value) : this.selection.delete(box.value)
    this.groupBtnTarget.classList.toggle("hidden", this.selection.size < 2)
    this.groupCountTarget.textContent = `(${this.selection.size})`
  }

  async group() {
    if (this.selection.size < 2) return
    const body = new FormData()
    this.selection.forEach((k) => body.append("keys[]", k))
    await this.post(this.groupUrlValue, body)
    this.selection.clear()
    this.element.querySelectorAll(".wq-check").forEach((b) => (b.checked = false))
    this.groupBtnTarget.classList.add("hidden")
  }

  async post(url, body) {
    const res = await fetch(url, { method: "POST", body, headers: { "X-CSRF-Token": csrf(), Accept: "text/vnd.turbo-stream.html" } })
    const html = await res.text()
    if (res.ok && window.Turbo) window.Turbo.renderStreamMessage(html)
  }

  // ---- log ------------------------------------------------------------------
  logTargetConnected(log) {
    this.logObserver?.disconnect()
    this.logObserver = new MutationObserver(() => { if (this.pinned) this.scrollLog(); else this.jumpTarget?.classList.remove("hidden") })
    this.logObserver.observe(log, { childList: true, subtree: true })
    this.pinned = true
    requestAnimationFrame(() => this.scrollLog())
  }

  logScrolled() {
    const l = this.logTarget
    this.pinned = l.scrollHeight - l.scrollTop - l.clientHeight < 40
    if (this.pinned && this.hasJumpTarget) this.jumpTarget.classList.add("hidden")
  }

  scrollLog() { if (this.hasLogTarget) this.logTarget.scrollTop = this.logTarget.scrollHeight }

  jumpToEnd() { this.pinned = true; this.scrollLog(); this.jumpTarget.classList.add("hidden") }

  // ---- pushed status changes -----------------------------------------------
  eventTargetConnected(el) {
    const { to, title } = el.dataset
    el.remove()
    if (NEEDS_YOU.includes(to)) {
      this.notify(`${title} needs you`, to === "waiting" ? "It has a question waiting." : "It is blocked.")
      this.chime()
    }
    if (this.speakToggleTarget.checked && (to === "waiting" || to === "review")) {
      this.say(`${title.replace(/^#(\d+)/, "Item $1")} ${to === "waiting" ? "needs your answer" : "is ready for review"}`)
    }
  }

  async enableNotifications() {
    if (!("Notification" in window)) return
    const p = await Notification.requestPermission()
    if (p === "granted") this.notifyBtnTarget.classList.add("hidden")
    this.audio ||= new (window.AudioContext || window.webkitAudioContext)()
  }

  notify(title, body) {
    if ("Notification" in window && Notification.permission === "granted" && document.visibilityState !== "visible") {
      new Notification(title, { body, tag: title })
    }
  }

  chime() {
    try {
      this.audio ||= new (window.AudioContext || window.webkitAudioContext)()
      const o = this.audio.createOscillator(), g = this.audio.createGain()
      o.frequency.value = 880; g.gain.setValueAtTime(0.12, this.audio.currentTime)
      g.gain.exponentialRampToValueAtTime(0.0001, this.audio.currentTime + 0.35)
      o.connect(g).connect(this.audio.destination); o.start(); o.stop(this.audio.currentTime + 0.35)
    } catch (_) {}
  }

  toggleSpeak() {
    try { localStorage.setItem("wq-speak", this.speakToggleTarget.checked ? "1" : "0") } catch (_) {}
    if (this.speakToggleTarget.checked) this.say("Announcements on")
  }

  say(text) {
    if (!("speechSynthesis" in window)) return
    window.speechSynthesis.speak(new SpeechSynthesisUtterance(text))
  }

  // ---- voice input ---------------------------------------------------------
  dictate(event) {
    const Rec = window.SpeechRecognition || window.webkitSpeechRecognition
    const form = event.currentTarget.closest("form")
    const input = form?.querySelector("input[type=text]")
    if (!Rec || !input) { input?.focus(); return }
    const rec = new Rec()
    rec.lang = navigator.language || "en-US"
    rec.interimResults = true
    const btn = event.currentTarget
    btn.classList.add("wq-mic-on")
    rec.onresult = (e) => { input.value = Array.from(e.results).map((r) => r[0].transcript).join(" ") }
    rec.onend = () => {
      btn.classList.remove("wq-mic-on")
      if (input.value.trim()) form.requestSubmit()
    }
    rec.start()
  }

  closeMerge(event) { event.currentTarget.closest("details")?.removeAttribute("open") }
  toggleHelp() { this.helpTarget.classList.toggle("hidden") }

  // ---- keyboard ------------------------------------------------------------
  onKey(e) {
    if (e.metaKey || e.ctrlKey || e.altKey) return
    const typing = ["INPUT", "TEXTAREA", "SELECT"].includes(e.target.tagName) || e.target.isContentEditable
    if (e.key === "Escape") { e.target.blur?.(); this.element.querySelectorAll("details.wq-merge[open]").forEach((d) => d.removeAttribute("open")); return }
    if (typing) return
    const card = this.focused()
    switch (e.key) {
      case "j": this.move(1); break
      case "k": this.move(-1); break
      case "Enter": card?.querySelector(".wq-card-link")?.click(); break
      case "x": { const b = card?.querySelector(".wq-check"); if (b) { b.click() } break }
      case "g": this.group(); break
      case "r": (card || this.element).querySelector("form[action$='/run'] button, .wq-log-h form[action$='/run'] button")?.click(); break
      case "m": { const d = this.element.querySelector(".wq-log-h details.wq-merge") || card?.querySelector("details.wq-merge"); d?.setAttribute("open", ""); d?.querySelector("button[type=submit]")?.focus(); break }
      case "v": this.questionTargets[0]?.querySelector(".wq-mic")?.click(); break
      case "/": e.preventDefault(); this.answerTargets[0]?.focus(); break
      case "?": this.toggleHelp(); break
      default:
        if (/^[1-4]$/.test(e.key)) this.questionTargets[0]?.querySelector(`[data-option="${e.key}"]`)?.click()
        else return
    }
    e.preventDefault()
  }
}
