# Self-improvement agent

A closed loop that keeps myjira improving: it maps the app, scouts competitors and
emerging trends, audits the UI/UX, synthesizes a **prioritized backlog logged into
myjira itself**, and opens a **draft PR** implementing the safest high-value pick.
It never merges and never pushes to `main`.

## Why it's shaped this way

In this ecosystem a **subagent cannot spawn other subagents** — only a top-level
session can fan out with the `Task` tool. So "an agent that uses other agents" is a
**slash command** (the orchestrator, runs top-level) that delegates to **specialist
subagents**. The orchestrator is also discoverable and **schedulable** through
myjira's existing agent strip + `agent_schedules`, which is how the "monitor latest
trends" requirement is met (schedule the `trends` lane weekly).

## Pieces

| File | Kind | Role |
|---|---|---|
| `.claude/commands/self-improve.md` | command (orchestrator) | Runs the cycle, fans out, logs to myjira, opens the PR |
| `.claude/agents/competitor-scout.md` | subagent (research) | Diffs myjira vs. Linear/Jira/Plane/Huly/… → missing features |
| `.claude/agents/trend-scout.md` | subagent (research) | Latest in Claude/Claude Code/MCP/Rails-Hotwire/agent-workflows |
| `.claude/agents/ux-auditor.md` | subagent (frontend) | UI/UX audit of the real ERB views + Tailwind |
| `.claude/agents/feature-gap-analyst.md` | subagent (research) | Dedupes + RICE-scores everything → "build next" slice |
| built-in **Explore** agent | reused | Maps the app's current feature surface |
| built-in **`/code-review`** | reused | Reviews the implemented diff before the PR |
| `ui-ux-pro-max` / `design-is` skills | reused | Design intelligence for the UX audit |

Working files land in `tmp/self-improve/` (`app-map.md`, `competitors.md`,
`trends.md`, `ux-audit.md`, `backlog.md`). The **durable** record is myjira tasks
(features) and gaps (UX/tech-debt), tagged `[self-improve] <date>`.

## Running it

```bash
# from the myjira repo, in a Claude Code session:
/self-improve                # full cycle: map → scout → synthesize → log → PR
/self-improve trends         # just the trend scan + log (cheap; good for schedules)
/self-improve competitors    # just the competitor scan + log
/self-improve ux             # just the UX audit + log
/self-improve gaps           # re-synthesize existing tmp/ into a backlog
/self-improve apply          # implement the top "build next" item from the backlog
```

You can also trigger it from the **myjira agent strip** (it appears under
*Research* once the launcher daemon next syncs this repo's `.claude/`), or
**schedule** it: open the project's agents, schedule `self-improve` with args
`trends` weekly so the app keeps current automatically. Each scheduled run logs new
findings as myjira tasks/gaps you can triage.

## MCP servers — recommendation

**Nothing is strictly required.** The scouts use Claude Code's built-in
**WebSearch** and **WebFetch** for competitor/trend research, and **context7**
(already installed) supplies up-to-date library docs when implementing. Optional
quality boosts, addable in one click via myjira's own **MCP manager** (or
`claude mcp add`):

| MCP | Why | Needs |
|---|---|---|
| **Tavily** or **Exa** | AI-optimized search — cleaner research results than generic web search | API key |
| **GitHub** | Read competitor open-source roadmaps/releases/issues; smoother PR creation | GitHub token |
| **Fetch** | Robust HTML→markdown if `WebFetch` struggles on a source | `uvx` on host |
| context7 *(installed)* | Current Rails/Hotwire/Claude API docs at implement time | — |

If you add Tavily/Exa or GitHub, the scouts will prefer them automatically (they
ask for "the best available search/fetch tool"); no edit to the agents needed.

## Guardrails

- User is the sole git author — no `Co-Authored-By` lines (per global CLAUDE.md).
- Branches only (`self-improve/<date>-<slug>`), draft PRs, never merges, never
  touches `main`, auth/secrets, deploy/CI, or other projects.
- Every competitor/trend claim is sourced; unverified items are marked.
