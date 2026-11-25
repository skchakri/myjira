// myjira Web Push service worker. Shows the notification and focuses/opens the
// task URL on click. Served at site root so its scope covers the whole app.
self.addEventListener("push", (event) => {
  let data = {};
  try { data = event.data ? event.data.json() : {}; } catch (e) { data = {}; }
  const title = data.title || "myjira";
  event.waitUntil(
    self.registration.showNotification(title, {
      body: data.body || "",
      data: { url: data.url || "/" },
      icon: "/icon.svg",
      tag: data.url || "myjira",
    })
  );
});

self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  const url = new URL((event.notification.data && event.notification.data.url) || "/", self.location.origin).href;
  event.waitUntil(
    clients.matchAll({ type: "window", includeUncontrolled: true }).then(async (wins) => {
      const mine = wins.filter((w) => new URL(w.url).origin === self.location.origin);
      const exact = mine.find((w) => w.url === url);
      if (exact) return exact.focus();
      // Reuse an open myjira tab: send it to the thread instead of opening another one.
      for (const w of mine) {
        try { const moved = await w.navigate(url); if (moved) return moved.focus(); } catch (e) { /* uncontrolled tab */ }
      }
      return clients.openWindow(url);
    })
  );
});
