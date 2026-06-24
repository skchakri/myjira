import { Controller } from "@hotwired/stimulus"

// Night mode. Persists a preference (light | dark | auto) in localStorage and
// resolves it to a concrete theme on <html data-theme>. An inline <head> script
// applies the same logic before first paint to avoid a flash of light mode;
// this controller drives the segmented toggle and keeps "auto" live with the OS.
const KEY = "myjira-theme"
const VALUES = ["light", "auto", "dark"]

export default class extends Controller {
  static targets = ["option"]

  connect() {
    this.media = window.matchMedia("(prefers-color-scheme: dark)")
    this.onMediaChange = () => { if (this.preference === "auto") this.apply() }
    this.media.addEventListener("change", this.onMediaChange)
    this.render()
  }

  disconnect() {
    this.media?.removeEventListener("change", this.onMediaChange)
  }

  get preference() {
    const v = localStorage.getItem(KEY)
    return VALUES.includes(v) ? v : "auto"
  }

  set preference(v) {
    localStorage.setItem(KEY, v)
  }

  select(event) {
    const v = event.currentTarget.dataset.themeValue
    if (!VALUES.includes(v)) return
    this.preference = v
    this.apply()
    this.render()
  }

  // Resolve the preference and set the concrete theme on <html>.
  apply() {
    const pref = this.preference
    const dark = pref === "dark" || (pref === "auto" && this.media.matches)
    document.documentElement.setAttribute("data-theme", dark ? "dark" : "light")
  }

  // Reflect the stored preference onto the segmented control.
  render() {
    const pref = this.preference
    this.optionTargets.forEach((el) => {
      const active = el.dataset.themeValue === pref
      el.setAttribute("aria-pressed", active ? "true" : "false")
      el.classList.toggle("theme-seg-on", active)
    })
  }
}
