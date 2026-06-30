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
  const url = (event.notification.data && event.notification.data.url) || "/";
  event.waitUntil(
    clients.matchAll({ type: "window", includeUncontrolled: true }).then((wins) => {
      for (const w of wins) { if (w.url === url && "focus" in w) return w.focus(); }
      return clients.openWindow(url);
    })
  );
});
