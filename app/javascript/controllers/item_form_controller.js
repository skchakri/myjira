import { Controller } from "@hotwired/stimulus"

// Rich "New board item" composer. Opens a modal, focuses the title, and lets the
// author attach files from any source — drag-drop, paste, or browse — with live
// thumbnail previews and per-file removal. A DataTransfer is the source of truth
// for the file set; it's mirrored back onto the hidden <input> before submit.
export default class extends Controller {
  static targets = ["overlay", "autofocus", "input", "dropzone", "previews"]

  connect() {
    this.dt = new DataTransfer()
    this.urls = []
    this.onKey = (e) => { if (e.key === "Escape" && this.isOpen) this.close() }
    document.addEventListener("keydown", this.onKey)
  }

  disconnect() {
    document.removeEventListener("keydown", this.onKey)
    this.revokeUrls()
    document.body.style.overflow = ""
  }

  get isOpen() { return !this.overlayTarget.classList.contains("hidden") }

  open(e) {
    if (e) e.preventDefault()
    this.overlayTarget.classList.remove("hidden")
    document.body.style.overflow = "hidden"
    if (this.hasAutofocusTarget) requestAnimationFrame(() => this.autofocusTarget.focus())
  }

  close(e) {
    if (e) e.preventDefault()
    this.overlayTarget.classList.add("hidden")
    document.body.style.overflow = ""
  }

  backdrop(e) { if (e.target === this.overlayTarget) this.close(e) }

  // --- attachments ---------------------------------------------------------
  browse(e) { if (e) e.preventDefault(); this.inputTarget.click() }

  dropzoneKey(e) {
    if (e.key === "Enter" || e.key === " ") { e.preventDefault(); this.browse() }
  }

  dragover(e) {
    e.preventDefault()
    const z = this.dropzoneTarget
    z.style.borderColor = "var(--color-amber-ink)"
    z.style.background = "var(--color-paper-sunk)"
    z.style.boxShadow = "inset 0 0 0 2px var(--color-amber-ink)"
  }

  dragleave(e) {
    if (!this.dropzoneTarget.contains(e.relatedTarget)) this.clearDragHint()
  }

  drop(e) {
    e.preventDefault()
    this.clearDragHint()
    this.addFiles(e.dataTransfer.files)
  }

  paste(e) {
    const files = e.clipboardData && e.clipboardData.files
    if (files && files.length) { e.preventDefault(); this.addFiles(files) }
  }

  changed() { this.addFiles(this.inputTarget.files) }

  remove(e) {
    e.preventDefault()
    const idx = Number(e.currentTarget.dataset.index)
    const keep = new DataTransfer()
    Array.from(this.dt.files).forEach((f, i) => { if (i !== idx) keep.items.add(f) })
    this.dt = keep
    this.sync()
  }

  addFiles(fileList) {
    Array.from(fileList || []).forEach((f) => {
      const dup = Array.from(this.dt.files).some(
        (x) => x.name === f.name && x.size === f.size && x.lastModified === f.lastModified
      )
      if (!dup) this.dt.items.add(f)
    })
    this.sync()
  }

  // Mirror the working set back onto the input (programmatic, so no change loop).
  sync() {
    this.inputTarget.files = this.dt.files
    this.render()
  }

  render() {
    this.revokeUrls()
    const files = Array.from(this.dt.files)
    if (!files.length) {
      this.previewsTarget.classList.add("hidden")
      this.previewsTarget.innerHTML = ""
      return
    }
    this.previewsTarget.classList.remove("hidden")
    this.previewsTarget.innerHTML = files.map((f, i) => this.tile(f, i)).join("")
  }

  tile(file, i) {
    const type = file.type || ""
    let media
    if (type.startsWith("image/")) {
      const url = URL.createObjectURL(file); this.urls.push(url)
      media = `<img src="${url}" alt="" class="h-20 w-full object-cover">`
    } else if (type.startsWith("video/")) {
      const url = URL.createObjectURL(file); this.urls.push(url)
      media = `<video src="${url}" class="h-20 w-full object-cover" style="background:#000" muted></video>`
    } else {
      const glyph = type.startsWith("audio/") ? "♪" : this.ext(file.name)
      media = `<div class="h-20 w-full grid place-items-center text-base font-mono" style="background:var(--color-paper-sunk);color:var(--color-ink-soft)">${glyph}</div>`
    }
    const name = this.escape(file.name)
    return `<figure class="relative hair-all rounded overflow-hidden" style="background:var(--color-paper-raised)">
        ${media}
        <button type="button" data-action="item-form#remove" data-index="${i}" aria-label="Remove ${name}"
                class="absolute top-1 right-1 h-6 w-6 grid place-items-center rounded-full text-xs opacity-85 hover:opacity-100 cursor-pointer"
                style="background:var(--color-ink);color:var(--color-paper)">✕</button>
        <figcaption class="px-1.5 py-1 text-[10px] truncate" style="color:var(--color-ink-soft)" title="${name}">${name}</figcaption>
      </figure>`
  }

  ext(name) {
    const m = (name || "").split(".").pop()
    return m && m.length <= 5 ? m.toUpperCase() : "FILE"
  }

  escape(s) {
    return String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]))
  }

  clearDragHint() {
    const z = this.dropzoneTarget
    z.style.borderColor = ""
    z.style.background = ""
    z.style.boxShadow = ""
  }

  revokeUrls() {
    this.urls.forEach((u) => URL.revokeObjectURL(u))
    this.urls = []
  }
}
