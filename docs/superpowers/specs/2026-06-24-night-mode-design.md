# Night Mode — Design Spec

**Date:** 2026-06-24
**Status:** Approved (design), pending implementation plan

## Summary

Add a night (dark) mode to myjira. The app already styles entirely through a
single set of `--color-*` CSS custom properties defined in one `@theme` block
(`app/assets/tailwind/application.css`). Night mode is therefore implemented as
**one override block** that re-defines those tokens under a dark scope; every
view, component class (`.paper`, `.clink`, `.pill-*`, `.dot-*`, `.track-*`), and
`color-mix` wash inherits the change automatically with no per-view edits.

## Decisions

- **Trigger:** Manual toggle with a remembered choice. Three preference states:
  `auto` (default — follows the OS), `light`, `dark`. Once the user picks a
  state explicitly, it sticks.
- **Persistence:** `localStorage["myjira-theme"]` (per-device). No server
  `Setting` row — this is a localhost single-user tool and per-device is
  correct, plus it avoids a server round-trip and lets us apply the theme
  before first paint.
- **Toggle UI:** A compact 3-segment control in the **sidebar footer** (next to
  the `local` pill): Light · Auto · Dark.

## Architecture

### Preference vs. resolved theme
- **Preference** (`light` | `dark` | `auto`) lives in
  `localStorage["myjira-theme"]`, default `auto`.
- **Resolved theme** (`light` | `dark`) is what CSS keys on, set as
  `data-theme` on the `<html>` element. `auto` resolves via
  `matchMedia('(prefers-color-scheme: dark)')`.

### FOUC prevention
A small **synchronous inline `<script>` in `<head>`** (not an importmap module —
those are deferred) reads the stored preference, resolves it, and sets
`document.documentElement.dataset.theme` **before the body paints**. This avoids
a flash of light mode on initial load and on Turbo navigations.

### Stimulus controller
`app/javascript/controllers/theme_controller.js`:
- Reads/writes the preference in `localStorage`.
- On a segment click: store preference → resolve → set `data-theme` on `<html>`
  → update the active segment's `aria-pressed`/visual state.
- While preference is `auto`, attach a `matchMedia` `change` listener so the app
  live-updates when the OS theme flips; detach when preference is explicit.
- On connect, sync the control's visual state to the current stored preference.

### Why not a Tailwind `dark:` variant
The app styles almost entirely through `var(--color-*)` and component classes,
not `dark:` utilities. Overriding the token values at a more specific selector
(`html[data-theme="dark"]`) cascades to every utility and component that
references those vars — far less invasive than retrofitting `dark:` across all
views, and it keeps existing markup untouched.

## Dark palette

A warm-dark mirror of the existing warm-paper identity: deep warm charcoal
canvas, soft warm off-white ink, the **same burnt-amber accent lifted slightly**
for legibility on dark. All foreground/background pairs tuned to **WCAG AA**
(consistent with prior contrast work on `--color-ink-faint`). Starting values
(refined for AA during implementation):

| token | light | dark (initial) |
|---|---|---|
| `--color-paper` | `#F7F4ED` | `#1A1714` |
| `--color-paper-raised` | `#FCFAF5` | `#221E19` |
| `--color-paper-sunk` | `#EFEBE1` | `#15120F` |
| `--color-ink` | `#1A1814` | `#F2ECE0` |
| `--color-ink-soft` | `#4A463E` | `#C9C1B2` |
| `--color-ink-faint` | `#736D60` | `#968D7C` |
| `--color-hair` | `#E4DDCC` | `#332E27` |
| `--color-hair-soft` | `#EDE7D8` | `#2A2520` |
| `--color-amber-ink` | `#B8502A` | `#E0834A` |
| `--color-amber-ink-hover` | `#994320` | `#EC9560` |
| `--color-amber-wash` | `#F5E8DD` | `#3A2418` |
| `--color-pass-ink` / `-wash` | `#2F6F4F` / `#E4EFE6` | `#6BBF8F` / `#1B2E22` |
| `--color-fail-ink` / `-wash` | `#9F2D2D` / `#F4E1DE` | `#E97070` / `#3A1E1E` |
| `--color-block-ink` / `-wash` | `#8A5A1E` / `#F4E9D6` | `#D9A24E` / `#322716` |
| `--color-skip-ink` / `-wash` | `#6A6254` / `#EDE7D8` | `#A89E8C` / `#2A2520` |

### Hard-coded colors needing a dark variant
- `body` `background-image` — the radial washes + SVG paper-grain texture are
  light-tuned. Override under `html[data-theme="dark"] body` to soft dark washes
  and a subtle dark-appropriate grain (or drop the grain).
- `.md pre` fenced code blocks are already dark (`#14110D`) — left unchanged.
- The brand SVG logo gradient is self-contained and stays legible — unchanged.
- `.clink-active` uses `var(--color-ink)`/`var(--color-paper)`, so it inverts
  correctly in dark with no extra work.

## Files touched

- `app/assets/tailwind/application.css` — dark token override block + dark
  `body` background. Rebuild Tailwind afterward (`tailwindcss:build`); the
  container watcher can leave the build stale.
- `app/views/layouts/application.html.erb` — inline FOUC `<head>` script; render
  the toggle partial in the sidebar footer; add `data-controller="theme"`.
- `app/views/layouts/_theme_toggle.html.erb` — **new**, the segmented control.
- `app/javascript/controllers/theme_controller.js` — **new** Stimulus controller.

## Accessibility

- Segmented control: `role="group"` with an `aria-label`; each segment a
  `<button>` with `aria-pressed` reflecting the active preference.
- Respects `prefers-reduced-motion` (existing global rule already covers
  transitions).
- All token pairs verified to meet WCAG AA contrast in dark mode.

## Testing

- Layout/integration test: the toggle partial and `data-controller="theme"`
  render in the layout; the three segments are present and labeled.
- Visual / JS behavior: run the app and verify both modes; quick Playwright
  check that clicking a segment flips `<html data-theme>` and persists across a
  reload.
- No server-side state — nothing to unit-test on the model/controller side.

## Out of scope (YAGNI)

- Server-side / cross-device theme persistence (`Setting` model).
- Per-project or scheduled theming.
- A full theming framework beyond the single light/dark token pair.
