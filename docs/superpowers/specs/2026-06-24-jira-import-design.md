# Jira Import — Design

**Date:** 2026-06-24
**Status:** Approved (pending spec review)

## Summary

Add a reusable **"Import from Jira"** feature to myjira. On any project board, the
user pastes an Atlassian Jira ticket URL (`https://<site>.atlassian.net/browse/PROJ-123`)
and myjira fetches that issue through the **Jira Cloud REST API v3** and creates — or
idempotently updates — a fully-formed `pending` board item in that project: title,
description, type, priority, comments, and downloaded attachments.

Because Jira supplies structured fields, imported items **skip the triage pipeline**
and land complete.

## Decisions (locked during brainstorming)

| Question | Decision |
|---|---|
| Scope | Reusable feature built into myjira (not a one-off). |
| Auth | Jira Cloud REST API, HTTP Basic auth with Atlassian `email` + API token. |
| Field scope | Full import: core fields + comments + attachments. |
| Re-import | Idempotent — dedupe on the Jira key, **update** the existing item. |
| Token storage | Encrypted at rest via `encrypts :api_token`; AR encryption keys in Rails credentials. |
| Entry point | "Import from Jira" button on a project board → item lands in **that** project. |

## Non-goals (YAGNI)

- No live/two-way sync. Import is one-way and on-demand (re-run to refresh).
- No webhook listener / background polling.
- No bulk import (JQL, whole-project). One ticket per import.
- No editing of Jira from myjira.
- Multiple Atlassian sites: a single global connection (one account); the pasted
  URL's host must match the configured `site_url`.

## Architecture

Small, single-purpose units communicating through narrow interfaces.

### `JiraConnection` (model — singleton row)
- Columns: `site_url:string`, `email:string`, `api_token:string` (encrypted), timestamps.
- `encrypts :api_token` (Rails 8 Active Record encryption).
- Class helpers: `JiraConnection.current` (first row, memoized), `configured?`
  (all three present).
- `auth_header` → `"Basic " + Base64.strict_encode64("#{email}:#{api_token}")`.
- `host` → host of `site_url`, used to validate pasted URLs.

### `Jira::Client` (service)
Thin wrapper over `Net::HTTP` (stdlib — no new gem). Constructed with a
`JiraConnection`.
- `fetch_issue(key)` → `GET {site}/rest/api/3/issue/{key}?fields=summary,description,issuetype,priority,status,assignee,reporter,labels,comment,attachment`. Returns the parsed issue hash.
- `download_attachment(content_url)` → authenticated `GET`, follows the
  `content` redirect, returns the raw bytes + content-type.
- All requests send `Authorization: connection.auth_header` and `Accept: application/json`.
- Maps HTTP failures to `Jira::Error` subclasses: `NotConfigured`, `Unauthorized`
  (401), `NotFound` (403/404), `RequestError` (other / timeout / network).
- Timeouts: open 5s, read 15s.

### `Jira::AdfConverter` (service)
Converts an **Atlassian Document Format** body (the JSON used by `description` and
each comment) to Markdown.
- Handles: `doc`, `paragraph`, `text` (+ `strong`/`em`/`code`/`link` marks),
  `heading`, `bulletList`/`orderedList`/`listItem`, `codeBlock`, `blockquote`,
  `rule`, `hardBreak`, `mention`, `emoji`, `inlineCard`.
- **Fallback:** any unrecognised node recurses into its `content` and emits the
  contained text — the converter never raises on an unknown node type.
- `nil` / empty body → `""`.

### `Jira::Importer` (service)
The orchestrator. `Jira::Importer.import(url:, project:)`:
1. `parse(url)` → extract `{ host, key }`. Reject if no key, or host ≠
   `connection.host` (`Jira::Error`).
2. `Jira::Client.new(connection).fetch_issue(key)`.
3. Build `description` = ADF(description) + (if comments) `\n\n---\n\n### Comments\n`
   + each comment as `**Author — date**\n\n` + ADF(comment body).
4. `task = project.tasks.find_or_initialize_by(external_ref: key)`.
5. Assign `title`, `description`, `item_type` (TYPE_MAP), `priority` (PRIORITY_MAP),
   `source: "jira"`, `external_ref: key`, `external_url: url`. On **create** only:
   `board_state: "pending"`. On update: leave `board_state` untouched.
6. `task.save!`
7. `sync_attachments(task, issue)` — for each Jira attachment not already attached
   (matched by `filename` + `byte_size`), download and attach.
8. Return `Result(task:, created:, attachments_added:)`.

#### Mapping tables
```
TYPE_MAP     = { "Bug"=>"issue", "Story"=>"task", "Task"=>"task", "Sub-task"=>"task",
                 "Epic"=>"feature", "Improvement"=>"feature", "New Feature"=>"feature",
                 "Question"=>"ask" }          # default "task"
PRIORITY_MAP = { "Highest"=>"urgent", "Critical"=>"urgent", "High"=>"high",
                 "Medium"=>"normal", "Low"=>"low", "Lowest"=>"low" }  # default "normal"
```

### `JiraImportsController`
Scoped `projects/:project_id/jira_imports`.
- `new` → renders the import modal (paste-URL form) into the board's
  `#board_modal` turbo-frame, following the existing modal pattern.
- `create` → `Jira::Importer.import(url:, project:)`; on success redirect to
  `board_path(project)` with a notice naming the item and attachment count; on
  `Jira::Error` redirect back with a friendly alert. If `!JiraConnection.configured?`,
  the alert links to the connection form.

### `JiraConnectionsController`
- `edit` / `update` for `site_url`, `email`, `api_token`. Singleton — operates on
  `JiraConnection.current` or builds one. The token field renders blank and is only
  written when non-blank (so saving other fields doesn't wipe it).

## Schema changes

- **Migration:** add `external_url:string` to `tasks` (generic back-link column;
  reused beyond Jira). `external_ref` already exists **and is indexed** — it is the
  dedupe key, no change needed.
- **Migration:** create `jira_connections` (`site_url`, `email`, `api_token`, timestamps).
- **Active Record encryption:** generate keys via `bin/rails db:encryption:init` and
  store `primary_key` / `deterministic_key` / `key_derivation_salt` under
  `active_record_encryption` in `config/credentials.yml.enc`. The container already
  has `RAILS_MASTER_KEY` / `config/master.key`.

## Data flow

```
Project board
  └─ "Import from Jira" button → GET .../jira_imports/new  (modal in #board_modal)
       └─ submit URL → POST .../jira_imports
            ├─ JiraConnection.configured? ──no──▶ alert + link to connection form
            └─ yes
                 Jira::Importer.import(url, project)
                   ├─ parse url → key; guard host == connection.host
                   ├─ Jira::Client.fetch_issue(key)
                   ├─ map fields (TYPE_MAP / PRIORITY_MAP), build description+comments
                   ├─ find_or_initialize_by(external_ref: key)  ── update vs create
                   ├─ save!
                   └─ sync_attachments (download, dedupe by name+size)
                 redirect → board, notice "Imported PROJ-123 — '<title>' (N attachments)"
```

## Error handling

| Condition | Result |
|---|---|
| No connection configured | Alert "Connect Jira first" + link to connection form. Nothing created. |
| URL has no issue key / wrong host | Alert "That doesn't look like a Jira ticket URL for <site>." |
| 401 | Alert "Jira rejected the credentials — check email/API token." |
| 403 / 404 | Alert "Can't access PROJ-123 (not found or no permission)." |
| Network / timeout | Alert "Couldn't reach Jira — try again." |
| Attachment download fails | Item still imported; notice mentions skipped attachment(s). Import never fails wholesale on one bad attachment. |

## UI

- **Board header:** an "Import from Jira" button beside the existing add-item
  control, opening the modal via the established `modal_controller` + turbo-frame
  pattern. Styled with current Tailwind tokens (no new arbitrary classes — per the
  Tailwind build gotcha).
- **Import modal:** single URL text field, Import button, and a subtle
  "Jira not connected — set it up" link when unconfigured.
- **Connection form:** `site_url`, `email`, `api_token` (password field, blank on
  edit), Save. Reachable from the modal link and a small "Jira settings" affordance.
- **Imported item:** description carries the comments section; the item links back to
  Jira via `external_url`; attachments show with the existing attachment UI.

## Testing (Minitest + WebMock — per project stack)

- `Jira::Client`: WebMock-stubbed 200 (issue JSON), 401, 404; attachment download.
- `Jira::AdfConverter`: paragraph, headings, nested lists, code block, link mark,
  hardBreak, unknown-node fallback, nil body.
- `Jira::Importer`: happy path (fields + type/priority mapping), idempotent re-import
  (no duplicate, fields refreshed, `board_state` preserved), attachment dedupe by
  name+size, host-mismatch rejection.
- `JiraImportsController#create`: success redirect/notice, not-configured alert,
  `Jira::Error` alert.
- `JiraConnectionsController#update`: blank token leaves existing token intact.

## Open / deferred

- **Field overwrite policy on re-import:** current design refreshes Jira-derived
  fields (title/description/type/priority) but **preserves** `board_state` and board
  `position` (your workflow placement wins). If you later want a hard "mirror Jira"
  mode, add it as a toggle — out of scope for v1.
- Status mapping (Jira status → board_state) is intentionally **not** imported;
  imported items start `pending` and move through myjira's own pipeline.
