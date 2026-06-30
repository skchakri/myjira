# Assisted Board Workflow — Phase 5: true Web Push

> REQUIRED SUB-SKILL: superpowers:executing-plans. Steps use checkbox (`- [ ]`).

**Goal:** Desktop push notifications — fired when an item enters `waiting` — that reach the user even with the myjira tab closed, deep-linking to the task.

**Architecture:** `web-push` gem + VAPID keys (in `.env`, read via ENV; loaded by `dotenv-rails`). A `PushSubscription` model stores each browser's endpoint/keys. A Stimulus `web-push` controller registers `public/sw.js`, requests Notification permission, subscribes to PushManager, and POSTs the subscription. `WebPushNotifier.notify_waiting(task)` sends to every subscription (pruning expired ones); it's fired from a Task callback when an item enters `waiting`. Everything degrades to a no-op when VAPID keys are absent — the in-app blink + `/approvals` inbox remain the reliable surfaces.

**Done already:** `web-push` + `dotenv-rails` added; VAPID keypair generated into `.env` (`VAPID_PUBLIC_KEY`/`VAPID_PRIVATE_KEY`/`VAPID_SUBJECT`).

**Spec:** `docs/superpowers/specs/2026-06-30-assisted-board-workflow-design.md`

> NOTE (manual): the live server runs in the `pyr-myjira` container, which needs `bundle install` (or a rebuild) to pick up the new gems, and the VAPID env vars present in the container. Web Push can only be verified in a real browser (permission grant + a real notification) — the automated tests here stub the send.

---

## Task 1: Migration + `PushSubscription` model

**Files:** Create `db/migrate/20260630000004_create_push_subscriptions.rb`, `app/models/push_subscription.rb`; Test `test/models/push_subscription_test.rb`

- [ ] Migration:

```ruby
class CreatePushSubscriptions < ActiveRecord::Migration[8.0]
  def change
    create_table :push_subscriptions, id: :uuid do |t|
      t.string :endpoint, null: false
      t.string :p256dh,   null: false
      t.string :auth,     null: false
      t.string :user_agent
      t.timestamps
    end
    add_index :push_subscriptions, :endpoint, unique: true
  end
end
```

- [ ] `bin/rails db:migrate`.
- [ ] Test (`test/models/push_subscription_test.rb`):

```ruby
require "test_helper"

class PushSubscriptionTest < ActiveSupport::TestCase
  test "requires endpoint, p256dh, auth and a unique endpoint" do
    attrs = { endpoint: "https://push/1", p256dh: "p", auth: "a" }
    assert PushSubscription.create!(attrs)
    dup = PushSubscription.new(attrs)
    assert_not dup.valid?
    assert_not PushSubscription.new(endpoint: "", p256dh: "p", auth: "a").valid?
  end

  test "upsert_from! creates then updates by endpoint" do
    s1 = PushSubscription.upsert_from!(endpoint: "https://push/x", p256dh: "p1", auth: "a1", user_agent: "ua")
    s2 = PushSubscription.upsert_from!(endpoint: "https://push/x", p256dh: "p2", auth: "a2", user_agent: "ua")
    assert_equal s1.id, s2.id, "same endpoint updates the same row"
    assert_equal "p2", s2.reload.p256dh
  end
end
```

- [ ] Model `app/models/push_subscription.rb`:

```ruby
# One browser/device's Web Push endpoint + keys. Created by the web-push Stimulus
# controller when the user grants notification permission; pruned by WebPushNotifier
# when the push service reports the subscription gone (HTTP 410/404).
class PushSubscription < ApplicationRecord
  validates :endpoint, presence: true, uniqueness: true
  validates :p256dh, :auth, presence: true

  # Idempotent register: a browser re-subscribing with the same endpoint updates
  # its keys rather than creating a duplicate row.
  def self.upsert_from!(endpoint:, p256dh:, auth:, user_agent: nil)
    sub = find_or_initialize_by(endpoint: endpoint)
    sub.update!(p256dh: p256dh, auth: auth, user_agent: user_agent)
    sub
  end
end
```

- [ ] Run the model test → PASS. Commit.

---

## Task 2: `WebPushNotifier` service

**Files:** Create `app/services/web_push_notifier.rb`; Test `test/services/web_push_notifier_test.rb`

- [ ] Test:

```ruby
require "test_helper"

class WebPushNotifierTest < ActiveSupport::TestCase
  setup do
    @project = Project.create!(name: "P", slug: "p-#{SecureRandom.hex(3)}", repo_path: "/tmp/p")
    @task = @project.tasks.create!(title: "Approve me", item_type: "feature", board_state: "waiting",
                                   wait_reason: "awaiting_approval", plan: "p")
    PushSubscription.create!(endpoint: "https://push/1", p256dh: "p", auth: "a")
    PushSubscription.create!(endpoint: "https://push/2", p256dh: "p", auth: "a")
  end

  test "sends to every subscription when VAPID is configured" do
    sent = 0
    WebPushNotifier.stub(:vapid_configured?, true) do
      WebPush.stub(:payload_send, ->(**) { sent += 1 }) do
        WebPushNotifier.notify_waiting(@task)
      end
    end
    assert_equal 2, sent
  end

  test "prunes a subscription the push service reports as expired" do
    WebPushNotifier.stub(:vapid_configured?, true) do
      WebPush.stub(:payload_send, ->(**) { raise WebPush::ExpiredSubscription.new(Net::HTTPGone.new(nil, nil, nil), "host") }) do
        WebPushNotifier.notify_waiting(@task)
      end
    end
    assert_equal 0, PushSubscription.count, "expired subscriptions are deleted"
  end

  test "is a no-op when VAPID is not configured" do
    called = false
    WebPushNotifier.stub(:vapid_configured?, false) do
      WebPush.stub(:payload_send, ->(**) { called = true }) do
        WebPushNotifier.notify_waiting(@task)
      end
    end
    assert_not called
  end
end
```

- [ ] Implement `app/services/web_push_notifier.rb`:

```ruby
# Sends a Web Push notification to every registered browser when a board item
# parks waiting on the human. Best-effort: no-op without VAPID keys, prunes dead
# subscriptions, and never raises into the caller (the blink + /approvals inbox are
# the reliable surfaces).
class WebPushNotifier
  def self.notify_waiting(task)
    return unless vapid_configured?

    title = task.needs_input? ? "Needs your input" : "Plan awaiting approval"
    body  = "#{task.project.name}: #{task.title}"
    url   = "#{base_url}/projects/#{task.project.slug}/tasks/#{task.id}"
    message = { title: title, body: body, url: url }.to_json

    PushSubscription.find_each do |sub|
      WebPush.payload_send(
        message: message, endpoint: sub.endpoint, p256dh: sub.p256dh, auth: sub.auth,
        vapid: vapid, ttl: 600
      )
    rescue WebPush::ExpiredSubscription, WebPush::InvalidSubscription
      sub.destroy
    rescue WebPush::Error => e
      Rails.logger.warn("[webpush] #{sub.endpoint}: #{e.class}: #{e.message}")
    end
  rescue StandardError => e
    Rails.logger.warn("[webpush] notify_waiting failed: #{e.class}: #{e.message}")
  end

  def self.vapid
    { subject: ENV.fetch("VAPID_SUBJECT", "mailto:admin@myjira.local"),
      public_key: ENV["VAPID_PUBLIC_KEY"].to_s, private_key: ENV["VAPID_PRIVATE_KEY"].to_s }
  end

  def self.vapid_configured?
    ENV["VAPID_PUBLIC_KEY"].present? && ENV["VAPID_PRIVATE_KEY"].present?
  end

  def self.base_url
    ENV.fetch("MYJIRA_BASE_URL", "http://localhost:1200")
  end
end
```

- [ ] Run → PASS. Commit.

---

## Task 3: Fire the notifier when an item enters waiting

**Files:** `app/models/task.rb`; Test `test/models/task_test.rb`

- [ ] Test:

```ruby
test "entering waiting with a reason fires a web push" do
  item = @project.tasks.create!(title: "X", item_type: "feature", board_state: "in_progress")
  notified = nil
  WebPushNotifier.stub(:notify_waiting, ->(t) { notified = t.id }) do
    item.submit_plan!(role: "engineering", plan: "p")
  end
  assert_equal item.id, notified
end
```

- [ ] Implement — in `app/models/task.rb`, add a callback (near the other after_update_commit hooks):

```ruby
  # Push a desktop notification the moment an item parks waiting on the human.
  after_update_commit :notify_waiting_push,
                      if: -> { saved_change_to_board_state? && needs_human_now? }
```

predicate + private method:

```ruby
  def needs_human_now?
    board_state == "waiting" && wait_reason.present?
  end
```

```ruby
  def notify_waiting_push
    WebPushNotifier.notify_waiting(self)
  end
```

- [ ] Run → PASS. Commit.

---

## Task 4: Routes + `PushSubscriptionsController`

**Files:** `config/routes.rb`, create `app/controllers/push_subscriptions_controller.rb`; Test `test/integration/push_subscriptions_test.rb`

- [ ] Routes (top-level):

```ruby
  resources :push_subscriptions, only: [:create, :destroy], param: :endpoint
```

> `param: :endpoint` is fine for destroy-by-id too; we destroy by endpoint in the body. Simpler: `resources :push_subscriptions, only: [:create]` plus `delete "push_subscriptions", to: "push_subscriptions#destroy"`. Use:

```ruby
  post   "push_subscriptions", to: "push_subscriptions#create"
  delete "push_subscriptions", to: "push_subscriptions#destroy"
```

- [ ] Test (`test/integration/push_subscriptions_test.rb`):

```ruby
require "test_helper"

class PushSubscriptionsTest < ActionDispatch::IntegrationTest
  test "registers a subscription" do
    assert_difference -> { PushSubscription.count }, 1 do
      post push_subscriptions_path, params: {
        subscription: { endpoint: "https://push/abc", keys: { p256dh: "pk", auth: "ak" } }
      }, as: :json
    end
    assert_response :success
  end

  test "unregisters by endpoint" do
    PushSubscription.create!(endpoint: "https://push/abc", p256dh: "pk", auth: "ak")
    assert_difference -> { PushSubscription.count }, -1 do
      delete push_subscriptions_path, params: { endpoint: "https://push/abc" }, as: :json
    end
  end
end
```

- [ ] Controller `app/controllers/push_subscriptions_controller.rb`:

```ruby
# Browser <-> server registration of Web Push subscriptions. The web-push Stimulus
# controller POSTs the PushManager subscription here; DELETE removes it on unsubscribe.
class PushSubscriptionsController < ApplicationController
  skip_before_action :verify_authenticity_token

  def create
    sub = params.require(:subscription)
    PushSubscription.upsert_from!(
      endpoint: sub[:endpoint],
      p256dh: sub.dig(:keys, :p256dh),
      auth: sub.dig(:keys, :auth),
      user_agent: request.user_agent
    )
    head :ok
  end

  def destroy
    PushSubscription.where(endpoint: params[:endpoint]).destroy_all
    head :no_content
  end
end
```

- [ ] Run → PASS. Commit.

---

## Task 5: Service worker + Stimulus controller + layout wiring

**Files:** Create `public/sw.js`, `app/javascript/controllers/web_push_controller.js`; modify `app/views/layouts/application.html.erb`

- [ ] `public/sw.js`:

```javascript
// myjira Web Push service worker. Shows the notification and focuses/open the
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
```

- [ ] `app/javascript/controllers/web_push_controller.js`:

```javascript
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
```

- [ ] Layout `app/views/layouts/application.html.erb`:
  - In `<head>` after `csp_meta_tag` (line 7): `<meta name="vapid-public-key" content="<%= ENV['VAPID_PUBLIC_KEY'] %>">`.
  - On the body's top-level div (the `data-controller="client-filter"` div, line 33), add the web-push controller + value:
    `data-controller="client-filter web-push" data-web-push-public-key-value="<%= ENV['VAPID_PUBLIC_KEY'] %>"`.

- [ ] Manual verification (real browser): start the container (with the gems bundled + VAPID env present), open myjira, grant the notification prompt, then move an item to `waiting` (e.g. let a plan land) and confirm a desktop notification appears and clicking it opens the task. `bin/rails runner 'WebPushNotifier.notify_waiting(Task.awaiting_human.first)'` is a quick server-side trigger.

- [ ] Commit.

---

## Final verification

- [ ] `bin/rails test test/models/push_subscription_test.rb test/services/web_push_notifier_test.rb test/models/task_test.rb test/integration/push_subscriptions_test.rb` → green.
- [ ] `bin/rubocop` on new Ruby files → clean.
- [ ] Note in the report: container needs `bundle install`/rebuild + VAPID env; browser test is manual.

## Self-Review Notes
- **Spec coverage:** PushSubscription (Task 1), Notifier with prune (Task 2), fire-on-waiting (Task 3), register/unregister endpoints (Task 4), SW + Stimulus + layout (Task 5). Degrades to no-op without keys.
- **Type consistency:** subscription JSON `{ endpoint, keys: { p256dh, auth } }` matches the controller's `upsert_from!`. `WebPushNotifier.vapid_configured?` gates both sending and (implicitly) is stubbed in tests.
