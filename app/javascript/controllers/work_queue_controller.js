import { Controller } from "@hotwired/stimulus"

// Work Queue live view: keyboard navigation, multi-select grouping, log
// auto-scroll, voice (Web Speech API) and notifications on status changes.
// All data arrives as Turbo Stream pushes; this controller never polls.
const NEEDS_YOU = ["waiting", "blocked"]
const csrf = () => document.querySelector('meta[name="csrf-token"]')?.content

export default class extends Controller {
  static targets = ["card", "link", "log", "jump", "event", "groupBtn", "groupCount", "mineBtn", "mineCount", "speakToggle",
                    "notifyBtn", "help", "question", "suggestions", "answer", "merge",
                    "composer", "composerText", "inlineAdd", "inlineHome", "inlineLabel", "files", "fileList", "project", "counts", "search", "projectFilter",
                    "confirm", "confirmText", "instruct", "refChips", "frame", "tab", "grid"]
  static values = { errandsUrl: String, selected: String, groupUrl: String }

  // Target callbacks can fire before connect(), so set up shared state here.
  initialize() {
    this.flowFilter = "all"
    this.selection = new Set()
    try { this.collapsed = new Set(JSON.parse(localStorage.getItem("wq-collapsed") || "[]")) } catch (_) { this.collapsed = new Set() }
    try { this.collapsedNodes = new Set(JSON.parse(localStorage.getItem("wq-collapsed-nodes") || "[]")) } catch (_) { this.collapsedNodes = new Set() }
    // Projects whose older finished tasks are opened, for this browser session.
    try { this.olderOpen = new Set(JSON.parse(sessionStorage.getItem("wq-older") || "[]")) } catch (_) { this.olderOpen = new Set() }
    this.olderLoading = new Set()
  }

  // Collapse / expand one parent's follow-ups in the tree; remembered per browser.
  toggleNode(e) {
    const li = e.currentTarget.closest("li.wq-li")
    const key = li?.dataset.key
    if (!key) return
    this.collapsedNodes.has(key) ? this.collapsedNodes.delete(key) : this.collapsedNodes.add(key)
    try { localStorage.setItem("wq-collapsed-nodes", JSON.stringify([...this.collapsedNodes])) } catch (_) {}
    this.applyNode(li)
  }

  applyNode(li, force) {
    const btn = li.querySelector(":scope > .wq-twisty")
    if (!btn) return
    const closed = force === false ? false : this.collapsedNodes.has(li.dataset.key)
    btn.setAttribute("aria-expanded", closed ? "false" : "true")
    li.querySelector(":scope > ul.wq-kids")?.classList.toggle("hidden", closed)
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
    this.streamRender = (e) => { this.keepDraftAcrossStream(e); this.keepInlineAddAcrossStream(e) }
    document.addEventListener("turbo:before-stream-render", this.streamRender)
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
    document.removeEventListener("turbo:before-stream-render", this.streamRender)
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
    if (this.hasMineBtnTarget) {
      this.mineBtnTarget.classList.toggle("hidden", this.selection.size < 1)
      this.mineCountTarget.textContent = `(${this.selection.size})`
    }
  }

  // "Mark as mine": the ticked tasks become errands for the person (any project).
  async markMine() {
    if (!this.selection.size) return
    const body = new FormData()
    this.selection.forEach((k) => body.append("keys[]", k))
    await this.post(this.errandsUrlValue, body)
    this.selection.clear()
    this.element.querySelectorAll(".wq-check").forEach((b) => (b.checked = false))
    this.mineBtnTarget.classList.add("hidden")
    this.groupBtnTarget.classList.add("hidden")
  }

  // "No" on the "looks like an errand" hint.
  hideHint(e) { if (e.detail?.success) e.target.closest(".wq-errand-hint")?.remove() }

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
    if (this.hasMineBtnTarget) this.mineBtnTarget.classList.add("hidden")
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
    if (this.needsOlder()) this.projectTargets.forEach((p) => this.loadOlder(p))
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
      p.querySelectorAll("li.wq-li-parent").forEach((li) => this.applyNode(li, q || f !== "all" ? false : null))
    })
    this.updateCounts()
  }

  updateCounts() {
    if (!this.hasTabTarget) return
    // True totals from the server (each project's title bar carries its own), since
    // older finished tasks are not in the page until asked for.
    const totals = {}
    this.countsTargets.forEach((el) => {
      let counts = {}
      try { counts = JSON.parse(el.dataset.counts || "{}") } catch (_) {}
      Object.entries(counts).forEach(([tag, n]) => { totals[tag] = (totals[tag] || 0) + n })
    })
    this.tabTargets.forEach((t) => {
      const n = totals[t.dataset.f] || 0
      const span = t.querySelector("[data-count]")
      if (span) span.textContent = n
      // Empty filters only add rows; keep "All" and the one in use.
      t.classList.toggle("hidden", n === 0 && t.dataset.f !== "all" && t.getAttribute("aria-pressed") !== "true")
    })
  }

  toggleProject(e) {
    const p = e.currentTarget.closest("[data-work-queue-target~='project']")
    const slug = p.dataset.slug
    this.collapsed.has(slug) ? this.collapsed.delete(slug) : this.collapsed.add(slug)
    try { localStorage.setItem("wq-collapsed", JSON.stringify([...this.collapsed])) } catch (_) {}
    this.applyCollapsed(p)
  }

  expandAll() { this.setAllCollapsed(false) }
  collapseAll() { this.setAllCollapsed(true) }

  setAllCollapsed(closed) {
    this.collapsed = new Set(closed ? this.projectTargets.map((p) => p.dataset.slug) : [])
    try { localStorage.setItem("wq-collapsed", JSON.stringify([...this.collapsed])) } catch (_) {}
    this.projectTargets.forEach((p) => this.applyCollapsed(p))
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
    // A fresh block arrives with the default cut: reopen its older tasks if they were open.
    if (this.olderOpen.has(p.dataset.slug)) this.loadOlder(p)
    this.filter()
  }

  countsTargetConnected() { this.scheduleCounts() }

  // ---- older finished tasks (not drawn until asked for) ---------------------
  // Filters that match finished tasks, and any search, need every task in the page.
  needsOlder() {
    const q = this.hasSearchTarget ? this.searchTarget.value.trim() : ""
    return Boolean(q) || ["ok", "open", "closed"].includes(this.flowFilter)
  }

  // Fetches the project's block with every task (all = true) or the default cut.
  loadOlder(p, all = true) {
    const slug = p.dataset.slug
    if (!Number(p.dataset.older) || (p.dataset.all === "true") === all || this.olderLoading.has(slug)) return
    this.olderLoading.add(slug)
    const url = new URL(p.dataset.olderUrl, window.location.origin)
    url.searchParams.set("older", all ? "1" : "0")
    if (this.selectedValue) url.searchParams.set("item", this.selectedValue)
    fetch(url, { headers: { Accept: "text/vnd.turbo-stream.html" } })
      .then((r) => (r.ok ? r.text() : ""))
      .then((html) => { if (html) window.Turbo.renderStreamMessage(html) })
      .catch(() => {})
      .finally(() => this.olderLoading.delete(slug))
  }

  rememberOlder(slug, open) {
    open ? this.olderOpen.add(slug) : this.olderOpen.delete(slug)
    try { sessionStorage.setItem("wq-older", JSON.stringify([...this.olderOpen])) } catch (_) {}
  }

  showOlder(e) {
    const p = e.currentTarget.closest("[data-work-queue-target~='project']")
    this.rememberOlder(p.dataset.slug, true)
    this.loadOlder(p)
  }

  hideOlder(e) {
    const p = e.currentTarget.closest("[data-work-queue-target~='project']")
    this.rememberOlder(p.dataset.slug, false)
    if (!this.needsOlder()) this.loadOlder(p, false)
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

  resetForm(e) { if (e.detail.success) { e.target.reset(); this.clearFiles(e.target); this.scanRefs() } }

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
        const label = `${inner.children.length} ${last?.dataset.tool === "Bash" ? "commands" : `${last?.dataset.tool} calls`}`
        const summary = el.querySelector("summary")
        if (summary.textContent !== label) summary.textContent = label
        continue
      }
      if (el.dataset.tool && (!run.length || run[0].dataset.tool === el.dataset.tool)) { run.push(el); continue }
      flush()
      if (el.dataset.tool) run.push(el)
    }
    // Keep the newest run ungrouped while it's still streaming; group once it's 3+.
    flush()
  }

  // ---- Question-box drafts: typed answers + picked chips survive live re-renders and task switches.
  draftKey(box) { return `wq-draft:${box.dataset.itemKey}` }

  readDraft(box) {
    const form = box.querySelector("form")
    const draft = {}
    if (!form) return draft
    form.querySelectorAll("textarea[name], input[type=radio][name]:checked").forEach((el) => {
      if (el.type === "radio" || el.value) draft[el.name] = el.value
    })
    return draft
  }

  writeDraft(box, draft) {
    box.querySelectorAll("textarea[name]").forEach((el) => { if (draft[el.name] != null) el.value = draft[el.name] })
    box.querySelectorAll("input[type=radio][name]").forEach((el) => { if (draft[el.name] === el.value) el.checked = true })
  }

  saveDraft(e) {
    const box = e.currentTarget
    const draft = this.readDraft(box)
    try {
      if (Object.keys(draft).length) sessionStorage.setItem(this.draftKey(box), JSON.stringify(draft))
      else sessionStorage.removeItem(this.draftKey(box))
    } catch (_) {}
    this.updateSendStatus(box)
  }

  // One open question: a chip pick is the answer, send it now. Several: show "N of M picked — not sent yet".
  chipPicked(e) {
    if (!e.target.matches?.(".wq-chip-input")) return
    const box = e.currentTarget
    const form = box.querySelector("form.wq-qbox-form")
    if (form && box.querySelectorAll("fieldset.wq-question").length === 1) { form.requestSubmit(); return }
    this.updateSendStatus(box)
  }

  updateSendStatus(box) {
    const status = box.querySelector("[data-send-status]")
    if (!status) return
    const sets = [...box.querySelectorAll("fieldset.wq-question")]
    const picked = sets.filter((f) => f.querySelector(".wq-chip-input:checked") || f.querySelector("textarea")?.value.trim()).length
    status.hidden = picked === 0
    status.textContent = picked ? `${picked} of ${sets.length} picked, not sent yet. Press Send answers.` : ""
  }

  clearDraft(e) {
    if (!e.detail?.success) return
    try { sessionStorage.removeItem(this.draftKey(e.currentTarget)) } catch (_) {}
  }

  questionTargetConnected(box) { this.restoreBox(box) }

  // A suggestions block can be replaced on its own (its own stream target): re-apply the draft + focus.
  suggestionsTargetConnected(el) {
    const box = el.closest(".wq-qbox[data-item-key]")
    if (box) this.restoreBox(box)
  }

  restoreBox(box) {
    let draft = null
    try { draft = JSON.parse(sessionStorage.getItem(this.draftKey(box)) || "null") } catch (_) {}
    if (draft) this.writeDraft(box, draft)
    this.updateSendStatus(box)
    const f = this.pendingFocus
    if (f && f.key === box.dataset.itemKey) {
      const el = f.id && document.getElementById(f.id)
      if (el && box.contains(el)) {
        el.focus({ preventScroll: true })
        try { if (f.start != null) el.setSelectionRange(f.start, f.end) } catch (_) {}
      }
      this.pendingFocus = null
    }
  }

  // Before a stream swaps the header, snapshot the live form (in memory + sessionStorage) and the caret.
  keepDraftAcrossStream(e) {
    const target = e.target?.getAttribute?.("target")
    const selector = e.target?.getAttribute?.("targets")
    let olds = []
    if (target) olds = [document.getElementById(target)].filter(Boolean)
    else if (selector) { try { olds = [...document.querySelectorAll(selector)] } catch (_) {} }
    if (!olds.length) return
    const boxes = [...new Set(olds.flatMap((old) => {
      const up = old.closest?.(".wq-qbox[data-item-key]")
      return up ? [up] : [...old.querySelectorAll(".wq-qbox[data-item-key]")]
    }))]
    if (!boxes.length) return
    boxes.forEach((box) => {
      const draft = this.readDraft(box)
      try { if (Object.keys(draft).length) sessionStorage.setItem(this.draftKey(box), JSON.stringify(draft)) } catch (_) {}
    })
    const a = document.activeElement
    const box = a && boxes.find((b) => b.contains(a))
    if (box) {
      const sel = typeof a.selectionStart === "number" ? { start: a.selectionStart, end: a.selectionEnd } : {}
      this.pendingFocus = { key: box.dataset.itemKey, id: a.id, ...sel }
    }
  }

  logTargetConnected(log) {
    this.logObserver?.disconnect()
    this.logObserver = new MutationObserver(() => {
      if (this.grouping) return
      this.grouping = true
      this.groupTools()
      // Drop the records our own regrouping just queued, or the observer re-fires forever.
      this.logObserver.takeRecords()
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
    const { to, title, key } = el.dataset
    el.remove()
    if (to === "waiting") this.toast(`${title}: new question`, "warn")
    if (NEEDS_YOU.includes(to)) {
      this.notify(`${title} needs you`, to === "waiting" ? "It has a question waiting." : "It is blocked.", key)
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

  // Clicking the alert brings this tab forward and opens that item's thread.
  notify(title, body, key) {
    if ("Notification" in window && Notification.permission === "granted" && document.visibilityState !== "visible") {
      const n = new Notification(title, { body, tag: title })
      n.onclick = () => { window.focus(); n.close(); if (key) this.openItem(key) }
    }
  }

  // Open an item's thread: in place when its card is on the page, else load the page for it.
  openItem(key) {
    const link = this.cardTargets.find((c) => c.dataset.key === key)?.querySelector(".wq-card-link")
    if (link) return link.click()
    const url = `/work_queue?item=${encodeURIComponent(key)}`
    window.Turbo ? window.Turbo.visit(url) : window.location.assign(url)
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
  // Any [data-wq-drop] zone holds its own file input and name list, so every box
  // (new item, in-project add, instruction) takes dropped and pasted files.
  dropZone(el) { return el.closest("[data-wq-drop]") }
  pickFiles(e) { this.dropZone(e.currentTarget)?.querySelector("input[type=file]")?.click() }
  dragOver(e) { e.preventDefault(); this.dropZone(e.currentTarget)?.classList.add("wq-drop-over") }
  dragLeave(e) { this.dropZone(e.currentTarget)?.classList.remove("wq-drop-over") }

  drop(e) {
    e.preventDefault()
    const zone = this.dropZone(e.currentTarget)
    zone?.classList.remove("wq-drop-over")
    this.addFiles(zone, e.dataTransfer.files)
  }

  // Pasted files (a screenshot, a copied file) attach; pasted text behaves as usual.
  paste(e) {
    const files = Array.from(e.clipboardData?.files || [])
    if (!files.length) return
    e.preventDefault()
    this.addFiles(this.dropZone(e.currentTarget), files)
  }

  filesPicked(e) { this.listFiles(this.dropZone(e.currentTarget)) }

  addFiles(zone, files) {
    const input = zone?.querySelector("input[type=file]")
    if (!input) return
    const ok = Array.from(files).filter((f) => /^(image\/|text\/|application\/(pdf|json)$)/.test(f.type) || /\.(md|txt|log|csv|json|ya?ml)$/i.test(f.name))
    const skipped = files.length - ok.length
    const dt = new DataTransfer()
    Array.from(input.files).forEach((f) => dt.items.add(f))
    ok.forEach((f, n) => {
      // Pasted screenshots all arrive as "image.png": give each its own name.
      const name = f.name === "image.png" ? `pasted-${Date.now()}-${n}.png` : f.name
      dt.items.add(name === f.name ? f : new File([f], name, { type: f.type }))
    })
    input.files = dt.files
    this.listFiles(zone)
    if (skipped) this.toast(`${skipped} file${skipped > 1 ? "s" : ""} skipped: only images, PDFs and text files attach`, "warn")
  }

  listFiles(zone) {
    const input = zone?.querySelector("input[type=file]")
    const list = zone?.querySelector("[data-wq-files]")
    if (!input || !list) return
    list.replaceChildren(...Array.from(input.files).map((f) => {
      const chip = document.createElement("span")
      chip.className = "wq-file-chip"
      chip.textContent = f.name
      return chip
    }))
    if (input.files.length) {
      const clear = document.createElement("button")
      clear.type = "button"
      clear.className = "wq-file-clear"
      clear.textContent = "remove all"
      clear.addEventListener("click", () => { input.value = ""; this.listFiles(zone) })
      list.append(clear)
    }
  }

  clearFiles(form) { form.querySelectorAll("[data-wq-drop]").forEach((z) => { const i = z.querySelector("input[type=file]"); if (i) i.value = ""; this.listFiles(z) }); if (form.matches("[data-wq-drop]")) { const i = form.querySelector("input[type=file]"); if (i) i.value = ""; this.listFiles(form) } }

  // "+ Add" on a project's title bar: show the add form inside that project's block.
  addToProject(e) {
    const { slug, label } = e.currentTarget.dataset
    const form = this.inlineAddTarget
    if (form.closest("[data-work-queue-target~='project']")?.dataset.slug === slug) return this.closeInlineAdd()
    form.querySelector("input[name='slug']").value = slug
    this.inlineLabelTarget.textContent = label
    this.placeInlineAdd(slug)
    form.querySelector("textarea").focus()
  }

  placeInlineAdd(slug) {
    const bar = this.projectTargets.find((p) => p.dataset.slug === slug)?.querySelector(".wq-proj-bar")
    bar ? bar.after(this.inlineAddTarget) : this.inlineHomeTarget.append(this.inlineAddTarget)
  }

  closeInlineAdd() { this.inlineHomeTarget.append(this.inlineAddTarget) }

  inlineSent(e) {
    if (!e.detail.success) return
    e.target.reset()
    this.clearFiles(e.target)
    this.closeInlineAdd()
  }

  // A live update replaces the whole project block: carry the open add form (and what is typed) across.
  keepInlineAddAcrossStream(e) {
    if (!this.hasInlineAddTarget) return
    const form = this.inlineAddTarget
    const old = document.getElementById(e.target?.getAttribute?.("target") || "")
    if (!old?.contains(form)) return
    const slug = form.querySelector("input[name='slug']").value
    const focused = form.contains(document.activeElement) ? document.activeElement : null
    const render = e.detail.render
    e.detail.render = async (stream) => {
      this.closeInlineAdd()
      await render(stream)
      this.placeInlineAdd(slug)
      focused?.focus()
    }
  }

  composerSent(e) {
    if (!e.detail.success) return
    e.target.reset()
    this.clearFiles(e.target)
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
      case "a": this.questionTargets[0]?.querySelector("[data-allow-all]")?.click(); break
      default:
        if (/^[1-4]$/.test(e.key)) this.questionTargets[0]?.querySelector(`[data-option="${e.key}"]`)?.click()
        else return
    }
    e.preventDefault()
  }
}
