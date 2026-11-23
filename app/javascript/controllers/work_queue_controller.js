import { Controller } from "@hotwired/stimulus"

// Work Queue live view: keyboard navigation, multi-select grouping, log
// auto-scroll, voice (Web Speech API) and notifications on status changes.
// All data arrives as Turbo Stream pushes; this controller never polls.
const NEEDS_YOU = ["waiting", "blocked"]
const csrf = () => document.querySelector('meta[name="csrf-token"]')?.content

export default class extends Controller {
  static targets = ["card", "link", "log", "jump", "event", "groupBtn", "groupCount", "speakToggle",
                    "notifyBtn", "help", "question", "answer", "merge",
                    "composer", "composerText", "files", "fileList", "project", "search", "projectFilter",
                    "confirm", "confirmText", "instruct", "refChips", "frame", "tab", "grid"]
  static values = { selected: String, groupUrl: String }

  // Target callbacks can fire before connect(), so set up shared state here.
  initialize() {
    this.flowFilter = "all"
    this.selection = new Set()
    try { this.collapsed = new Set(JSON.parse(localStorage.getItem("wq-collapsed") || "[]")) } catch (_) { this.collapsed = new Set() }
  }

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
    this.groupTools()
    try { const w = parseInt(localStorage.getItem("wq-list-w"), 10); if (w) this.setListWidth(w) } catch (_) {}
  }

  // Drag the divider between the task tree and the detail panel; width persists per browser.
  setListWidth(px) {
    if (!this.hasGridTarget) return
    const max = Math.max(320, this.gridTarget.clientWidth - 360)
    this.listWidth = Math.min(Math.max(px, 260), max)
    this.gridTarget.style.setProperty("--wq-list-w", `${this.listWidth}px`)
  }

  startResize(e) {
    e.preventDefault()
    const handle = e.currentTarget
    const left = this.gridTarget.getBoundingClientRect().left
    handle.classList.add("is-drag")
    document.body.style.userSelect = "none"
    const move = (ev) => this.setListWidth(ev.clientX - left)
    const up = () => {
      handle.classList.remove("is-drag")
      document.body.style.userSelect = ""
      window.removeEventListener("pointermove", move)
      window.removeEventListener("pointerup", up)
      try { localStorage.setItem("wq-list-w", String(this.listWidth)) } catch (_) {}
    }
    window.addEventListener("pointermove", move)
    window.addEventListener("pointerup", up)
  }

  resetResize() {
    this.gridTarget.style.removeProperty("--wq-list-w")
    try { localStorage.removeItem("wq-list-w") } catch (_) {}
  }

  disconnect() {
    document.removeEventListener("keydown", this.keyHandler)
    document.removeEventListener("turbo:frame-load", this.frameLoad)
    this.logObserver?.disconnect()
  }

  // ---- selection / navigation --------------------------------------------
  afterFrame() {
    const detail = this.element.querySelector(".wq-detail-grid")
    if (detail) this.highlight(detail.dataset.key)
    if (detail && this.hasFrameTarget) this.frameTarget.removeAttribute("aria-busy")
    if (detail) {
      const url = new URL(window.location.href)
      if (url.searchParams.get("item") !== detail.dataset.key) {
        url.searchParams.set("item", detail.dataset.key)
        history.replaceState(history.state, "", url)
      }
    }
    this.pinned = true
    this.scrollLog()
  }

  highlight(key) {
    this.selectedValue = key || ""
    this.cardTargets.forEach((c) => {
      const on = c.dataset.key === this.selectedValue
      c.classList.toggle("wq-card-active", on)
      c.querySelector(".wq-card-link")?.setAttribute("aria-current", on ? "true" : "false")
    })
  }

  // Card click: highlight at once and show a loading state; the frame fetches
  // only this item's detail (the list is not re-rendered).
  open(event) {
    const card = event.currentTarget.closest("[data-key]")
    if (card) this.highlight(card.dataset.key)
  }

  frameLoading() {
    if (!this.hasFrameTarget) return
    this.frameTarget.setAttribute("aria-busy", "true")
    const log = this.frameTarget.querySelector(".wq-log")
    if (log) log.classList.add("wq-loading")
  }

  cardTargetConnected(card) {
    card.classList.toggle("wq-card-active", card.dataset.key === this.selectedValue)
    card.querySelector(".wq-card-link")?.setAttribute("aria-current", card.dataset.key === this.selectedValue ? "true" : "false")
    const box = card.querySelector(".wq-check")
    if (box && this.selection?.has(box.value)) box.checked = true
    this.scheduleCounts()
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
    const slugs = new Set([...this.selection].map((k) => k.split(":")[0]))
    if (slugs.size > 1) return this.toast("Can't merge items from different projects", "error")
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

  // ---- filter + project tree ----------------------------------------------------
  // Chips filter by the server-computed data-tags on each node (WorkQueue::Flow);
  // a parent stays visible while any of its follow-ups matches.
  pickFilter(e) {
    this.flowFilter = e.currentTarget.dataset.f
    this.tabTargets.forEach((t) => t.setAttribute("aria-pressed", t === e.currentTarget ? "true" : "false"))
    this.filter()
  }

  matches(card, q, f) {
    const tags = (card.dataset.tags || "").split(" ")
    if (!tags.includes(f)) return false
    return !q || `#${card.dataset.n} ${card.dataset.title}`.toLowerCase().includes(q)
  }

  filter() {
    const q = this.hasSearchTarget ? this.searchTarget.value.trim().toLowerCase() : ""
    const slug = this.hasProjectFilterTarget ? this.projectFilterTarget.value : ""
    const f = this.flowFilter || "all"
    this.projectTargets.forEach((p) => {
      const inProject = !slug || p.dataset.slug === slug
      const lis = [...p.querySelectorAll("li.wq-li")].reverse() // children before parents
      let shown = 0
      lis.forEach((li) => {
        const card = li.querySelector(":scope > .wq-card")
        const kid = [...li.querySelectorAll(":scope > ul > li.wq-li")].some((c) => !c.classList.contains("hidden"))
        const hit = inProject && card && this.matches(card, q, f)
        li.classList.toggle("hidden", !(hit || kid))
        card?.classList.toggle("wq-node-context", !hit && kid)
        if (hit) shown++
      })
      p.classList.toggle("hidden", !inProject || shown === 0)
      this.applyCollapsed(p, (q || f !== "all") && shown ? false : null)
    })
    this.updateCounts()
  }

  updateCounts() {
    if (!this.hasTabTarget) return
    const cards = this.cardTargets
    this.tabTargets.forEach((t) => {
      const n = cards.filter((c) => (c.dataset.tags || "").split(" ").includes(t.dataset.f)).length
      const span = t.querySelector("[data-count]")
      if (span) span.textContent = n
    })
  }

  toggleProject(e) {
    const p = e.currentTarget.closest("[data-work-queue-target~='project']")
    const slug = p.dataset.slug
    this.collapsed.has(slug) ? this.collapsed.delete(slug) : this.collapsed.add(slug)
    try { localStorage.setItem("wq-collapsed", JSON.stringify([...this.collapsed])) } catch (_) {}
    this.applyCollapsed(p)
  }

  // force: false = open regardless (a filter/search hit), null/undefined = remembered state.
  applyCollapsed(p, force) {
    const closed = force === false ? false : this.collapsed.has(p.dataset.slug)
    p.querySelector(".wq-proj")?.setAttribute("aria-expanded", closed ? "false" : "true")
    p.querySelector(".wq-tree")?.classList.toggle("hidden", closed)
  }

  projectTargetConnected(p) {
    this.applyCollapsed(p)
    this.highlight(this.selectedValue)
    this.filter()
  }

  cardTargetDisconnected() { this.scheduleCounts() }
  scheduleCounts() { cancelAnimationFrame(this.countsFrame); this.countsFrame = requestAnimationFrame(() => this.filter()) }

  // ---- drag a card onto another to merge -------------------------------------
  cardDragStart(e) {
    this.dragged = e.currentTarget
    this.dragged.classList.add("wq-card-dragging")
    e.dataTransfer.effectAllowed = "move"
    e.dataTransfer.setData("text/plain", this.dragged.dataset.key)
  }

  cardDragOver(e) {
    const target = e.currentTarget
    if (!this.dragged || target === this.dragged) return
    if (target.dataset.slug !== this.dragged.dataset.slug) {
      target.classList.add("wq-drop-no")
      target.title = "different project"
      e.dataTransfer.dropEffect = "none"
      return
    }
    e.preventDefault()
    e.dataTransfer.dropEffect = "move"
    target.classList.add("wq-drop-ok")
  }

  cardDragLeave(e) { this.clearDrop(e.currentTarget) }

  clearDrop(el) {
    el.classList.remove("wq-drop-ok", "wq-drop-no")
    if (el.title === "different project") el.removeAttribute("title")
  }

  cardDrop(e) {
    e.preventDefault()
    const target = e.currentTarget
    this.clearDrop(target)
    if (!this.dragged || target.dataset.slug !== this.dragged.dataset.slug) return
    this.pendingMerge = { from: this.dragged.dataset.key, to: target.dataset.key }
    target.classList.add("wq-drop-ok")
    this.mergeTargetEl = target
    this.confirmTextTarget.textContent = `Merge #${this.dragged.dataset.n} into #${target.dataset.n}?`
    this.confirmTarget.classList.remove("hidden")
    this.confirmTarget.querySelector("button").focus()
  }

  cardDragEnd() {
    this.dragged?.classList.remove("wq-card-dragging")
    this.cardTargets.forEach((c) => { if (c !== this.mergeTargetEl) this.clearDrop(c) })
    this.dragged = null
  }

  async confirmMerge() {
    const m = this.pendingMerge
    this.cancelMerge()
    if (!m) return
    const body = new FormData()
    body.append("keys[]", m.from); body.append("keys[]", m.to)
    body.append("target", m.to.split(":")[1])
    await this.post(this.groupUrlValue, body)
  }

  cancelMerge() {
    this.confirmTarget.classList.add("hidden")
    if (this.mergeTargetEl) this.clearDrop(this.mergeTargetEl)
    this.mergeTargetEl = null
    this.pendingMerge = null
  }

  // ---- questions popover ------------------------------------------------------
  peek(e) { e.currentTarget.setAttribute("open", "") }
  unpeek(e) { const d = e.currentTarget; if (!d.contains(document.activeElement)) d.removeAttribute("open") }

  // ---- copy references / pasted references --------------------------------------
  async copyRef(e) {
    const text = e.currentTarget.dataset.text
    try { await navigator.clipboard.writeText(text); this.toast("Copied", "ok") } catch (_) { this.toast("Copy blocked by the browser", "error") }
    e.currentTarget.closest("details")?.removeAttribute("open")
  }

  scanRefs() {
    if (!this.hasRefChipsTarget) return
    const keys = [...new Set([...this.instructTarget.value.matchAll(/\[wq-ref ([A-Za-z0-9-]+:\d+)\]/g)].map((m) => m[1]))]
    this.refChipsTarget.replaceChildren(...keys.map((k) => {
      const a = document.createElement("a")
      a.className = "wq-chip-static wq-ref"
      a.href = `?item=${encodeURIComponent(k)}`
      a.dataset.turboFrame = "wq_detail"
      a.textContent = `linked #${k.split(":")[1]}`
      return a
    }))
  }

  instructKey(e) {
    if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); e.currentTarget.form.requestSubmit() }
  }

  resetForm(e) { if (e.detail.success) { e.target.reset(); this.scanRefs() } }

  toast(message, level = "ok") {
    const el = document.createElement("div")
    el.className = `wq-toast wq-toast-${level}`
    el.setAttribute("data-controller", "wq-toast")
    el.textContent = message
    document.getElementById("wq_toasts")?.append(el)
  }

  // ---- log ------------------------------------------------------------------
  // Fold runs of 3+ consecutive calls to the same tool into one expandable group.
  groupTools() {
    const list = this.element.querySelector("#wq_log_entries")
    if (!list) return
    let run = []
    const flush = () => {
      if (run.length >= 3) {
        const li = document.createElement("li")
        li.className = "wq-entry wq-group-li"
        const d = document.createElement("details")
        d.className = "wq-group"
        const s = document.createElement("summary")
        const tool = run[0].dataset.tool
        s.textContent = `${run.length} ${tool === "Bash" ? "commands" : `${tool} calls`}`
        const ol = document.createElement("ol")
        run[0].before(li)
        run.forEach((r) => ol.append(r))
        d.append(s, ol); li.append(d)
      }
      run = []
    }
    for (const el of [...list.children]) {
      if (el.classList.contains("wq-group-li")) {
        const inner = el.querySelector("ol")
        const last = inner.lastElementChild
        const next = el.nextElementSibling
        if (next?.dataset.tool && next.dataset.tool === last?.dataset.tool) { inner.append(next) }
        el.querySelector("summary").textContent = `${inner.children.length} ${last?.dataset.tool === "Bash" ? "commands" : `${last?.dataset.tool} calls`}`
        continue
      }
      if (el.dataset.tool && (!run.length || run[0].dataset.tool === el.dataset.tool)) { run.push(el); continue }
      flush()
      if (el.dataset.tool) run.push(el)
    }
    // Keep the newest run ungrouped while it's still streaming; group once it's 3+.
    flush()
  }

  logTargetConnected(log) {
    this.logObserver?.disconnect()
    this.logObserver = new MutationObserver(() => {
      if (this.grouping) return
      this.grouping = true
      this.groupTools()
      this.grouping = false
      if (this.pinned) this.scrollLog(); else this.jumpTarget?.classList.remove("hidden")
    })
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
    if (to === "waiting") this.toast(`${title}: new question`, "warn")
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
    const input = event.currentTarget.parentElement?.querySelector("textarea, input[type=text]") || form?.querySelector("textarea, input[type=text]")
    if (!Rec || !input) { input?.focus(); return }
    const rec = new Rec()
    rec.lang = navigator.language || "en-US"
    rec.interimResults = true
    const btn = event.currentTarget
    btn.classList.add("wq-mic-on")
    rec.onresult = (e) => { input.value = Array.from(e.results).map((r) => r[0].transcript).join(" ") }
    rec.onend = () => {
      btn.classList.remove("wq-mic-on")
      if (input.value.trim() && input.tagName !== "TEXTAREA") form.requestSubmit()
    }
    rec.start()
  }

  // ---- composer ------------------------------------------------------------
  pickFiles() { this.filesTarget.click() }
  dragOver(e) { e.preventDefault(); e.currentTarget.classList.add("wq-drop-over") }
  dragLeave(e) { e.currentTarget.classList.remove("wq-drop-over") }

  drop(e) {
    e.preventDefault()
    e.currentTarget.classList.remove("wq-drop-over")
    const dt = new DataTransfer()
    Array.from(this.filesTarget.files).forEach((f) => dt.items.add(f))
    Array.from(e.dataTransfer.files).filter((f) => f.type.startsWith("image/")).forEach((f) => dt.items.add(f))
    this.filesTarget.files = dt.files
    this.fileListTarget.textContent = Array.from(dt.files).map((f) => f.name).join(", ")
  }

  composerSent(e) {
    if (!e.detail.success) return
    e.target.reset()
    this.fileListTarget.textContent = ""
    this.composerTarget.removeAttribute("open")
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
      case "/": e.preventDefault(); (this.hasInstructTarget ? this.instructTarget : this.answerTargets[0])?.focus(); break
      case "?": this.toggleHelp(); break
      case "n": this.composerTarget.setAttribute("open", ""); this.composerTextTarget.focus(); break
      case "s": this.element.querySelector(".wq-log-h form[action$='/stop'] button")?.click(); break
      default:
        if (/^[1-4]$/.test(e.key)) this.questionTargets[0]?.querySelector(`[data-option="${e.key}"]`)?.click()
        else return
    }
    e.preventDefault()
  }
}
