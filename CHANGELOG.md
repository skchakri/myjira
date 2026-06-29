# Changelog

## Unreleased

### Added
- **Resolve & merge button for conflicting in-review PRs** (board item `648d274e`, PR #32, commit `a290298`)
  - `pr_mergeable` and `conflict_resolution_at` columns on tasks
  - `conflicting?`, `resolving_conflicts?`, `request_conflict_resolution!` model methods
  - pr_sync polling persists GitHub `mergeable` verdict
  - `resolve_conflicts` controller action + route (`POST board/items/:id/resolve_conflicts`)
  - ⚠ button on kanban card and item detail view when PR has conflicts
  - `launch_resolve_conflicts!` pipeline service to queue `/board-resolve-conflicts` agent session
  - 7 tests covering all conflict-resolution paths
