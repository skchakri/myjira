import { Controller } from "@hotwired/stimulus"

// Native drag-to-reorder for the board (no external lib). Rows carry
// draggable="true" + data-sortable-item; each status group is a
// data-sortable-list drop container tagged with its board state. Dragging within
// a group reorders priority; dragging into another group also changes the item's
// board_state. On drop we POST the full new order (+ any moved item's new state)
// to the reorder endpoint; the server's refresh broadcast morphs every board.
//
// Events are delegated on the controller root so they survive Turbo morphs that
// replace the row elements underneath.
export default class extends Controller {
  static values = { url: String }

  connect() {
    this.dragged = null
    this.fromState = null
    this.element.addEventListener("dragstart", this.onStart)
    this.element.addEventListener("dragover", this.onOver)
    this.element.addEventListener("drop", this.onDrop)
    this.element.addEventListener("dragend", this.onEnd)
  }

  disconnect() {
    this.element.removeEventListener("dragstart", this.onStart)
    this.element.removeEventListener("dragover", this.onOver)
    this.element.removeEventListener("drop", this.onDrop)
    this.element.removeEventListener("dragend", this.onEnd)
  }

  onStart = (e) => {
    const item = e.target.closest("[data-sortable-item]")
    if (!item || !this.element.contains(item)) return
    this.dragged = item
    this.fromState = item.closest("[data-sortable-list]")?.dataset.boardState
    e.dataTransfer.effectAllowed = "move"
    requestAnimationFrame(() => item.classList.add("opacity-40"))
  }

  onOver = (e) => {
    if (!this.dragged) return
    const list = e.target.closest("[data-sortable-list]")
    if (!list) return
    e.preventDefault()
    const after = this.afterElement(list, e.clientY)
    if (after == null) list.appendChild(this.dragged)
    else list.insertBefore(this.dragged, after)
  }

  onDrop = (e) => { if (this.dragged) e.preventDefault() }

  onEnd = () => {
    if (!this.dragged) return
    const moved = this.dragged
    moved.classList.remove("opacity-40")
    this.dragged = null
    const toState = moved.closest("[data-sortable-list]")?.dataset.boardState
    const order = Array.from(this.element.querySelectorAll("[data-sortable-item]")).map((el) => el.dataset.id)
    this.persist(order, moved.dataset.id, toState !== this.fromState ? toState : null)
  }

  // The item the dragged row should sit *before*, found by vertical midpoint.
  afterElement(list, y) {
    const els = Array.from(list.querySelectorAll("[data-sortable-item]")).filter((el) => el !== this.dragged)
    let best = { offset: Number.NEGATIVE_INFINITY, el: null }
    for (const el of els) {
      const box = el.getBoundingClientRect()
      const offset = y - box.top - box.height / 2
      if (offset < 0 && offset > best.offset) best = { offset, el }
    }
    return best.el
  }

  persist(order, movedId, movedState) {
    const body = new URLSearchParams()
    order.forEach((id) => body.append("order[]", id))
    if (movedId && movedState) {
      body.append("moved_id", movedId)
      body.append("moved_state", movedState)
    }
    fetch(this.urlValue, {
      method: "POST",
      headers: {
        "X-CSRF-Token": document.querySelector("meta[name=csrf-token]")?.content || "",
        "Content-Type": "application/x-www-form-urlencoded",
        "Accept": "text/vnd.turbo-stream.html, text/html"
      },
      body
    }).catch(() => {})
  }
}
