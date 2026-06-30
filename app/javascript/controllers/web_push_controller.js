import { Controller } from "@hotwired/stimulus"

// Registers the service worker, asks for notification permission, subscribes to
// PushManager with the server's VAPID public key, and registers the subscription.
// Silent no-op when push is unsupported or the public key is absent.
export default class extends Controller {
  static values = { publicKey: String }

  async connect() {
    if (!("serviceWorker" in navigator) || !("PushManager" in window)) return
    if (!this.publicKeyValue) return
    if (Notification.permission === "denied") return
    try {
      const reg = await navigator.serviceWorker.register("/sw.js")
      if (Notification.permission === "default") {
        const perm = await Notification.requestPermission()
        if (perm !== "granted") return
      } else if (Notification.permission !== "granted") {
        return
      }
      const existing = await reg.pushManager.getSubscription()
      const sub = existing || await reg.pushManager.subscribe({
        userVisibleOnly: true,
        applicationServerKey: this.#urlBase64ToUint8Array(this.publicKeyValue),
      })
      await this.#register(sub)
    } catch (e) { console.warn("[web-push]", e) }
  }

  async #register(sub) {
    const json = sub.toJSON()
    await fetch("/push_subscriptions", {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-CSRF-Token": this.#csrf() },
      body: JSON.stringify({ subscription: { endpoint: sub.endpoint, keys: json.keys } }),
    })
  }

  #csrf() {
    const el = document.querySelector("meta[name=csrf-token]")
    return el ? el.content : ""
  }

  #urlBase64ToUint8Array(base64String) {
    const padding = "=".repeat((4 - (base64String.length % 4)) % 4)
    const base64 = (base64String + padding).replace(/-/g, "+").replace(/_/g, "/")
    const raw = atob(base64)
    return Uint8Array.from([...raw].map((c) => c.charCodeAt(0)))
  }
}
