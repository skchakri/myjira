# MCP Manager

myjira's MCP manager lets you browse a curated catalog and one-click-add MCP
servers to Claude Code, per project or globally. Because the Rails app runs
containerised it can't run `claude mcp …` itself: it writes an **intent row**
(`McpInstall`) that the host-side launcher daemon polls and executes on the host
as an arg-list (never a shell), PATCHing status back. The resulting
`McpServer` rows mirror `claude mcp list` and store only env-var **names**, never
secret values.

- `app/models/mcp_install.rb` — the add/remove intent + its validations.
- `app/models/mcp_server.rb` — the read-only synced mirror.
- `app/data/mcp_catalog.json` — the curated one-click catalog.
- Host daemon: `~/.claude/bin/myjira_session_launcher.py` (out of this repo's tree).

## Validation

An add intent must carry a complete spec before the daemon will run it:

| Transport | Required |
|-----------|----------|
| `stdio`   | `command` |
| `http` / `sse` | `url` matching `\Ahttps?://` |

The `https?://` requirement (`McpInstall::REMOTE_URL_FORMAT`, mirrored on
`McpServer`) is the repo-side hardening for the **2026-07-28 MCP spec**: remote
servers are now stateless and URL-only, so a malformed or relative URL must not
reach the host CLI. myjira never touches the wire protocol
(`initialize` / `Mcp-Session-Id` / `.well-known`) — the Claude Code runtime owns
all of that — so existing installs survive the spec change untouched.

## Idle timeouts (host-side follow-up)

Since Claude Code **v2.1.187**, a remote MCP tool call aborts if the server goes
idle. The timeout is governed by the **`CLAUDE_CODE_MCP_TOOL_IDLE_TIMEOUT`
environment variable read by the host CLI process** — it is **not** a
`claude mcp add` flag, so it cannot be set per-server from this repo or via an
`McpInstall`. (`claude mcp add --help` exposes `--transport`, `--scope`,
`--env`, `--header`, and `--`; there is no timeout option.)

To raise the idle timeout for slow remote servers, set the env var where the host
CLI runs. For the myjira-launched agents that means adding one line to
`cli_env()` in `~/.claude/bin/myjira_session_launcher.py`, e.g.:

```python
# in cli_env():
env.setdefault("CLAUDE_CODE_MCP_TOOL_IDLE_TIMEOUT", "120000")  # ms; tune per slowest remote
```

This lives in the **out-of-tree host daemon**, so it is tracked as a follow-up
rather than shipped in a repo PR. After editing the launcher, restart it:
`systemctl --user restart myjira-session-launcher.service`.

## Removed tools

`TeamCreate` / `TeamDelete` were removed from Claude Code in **v2.1.178** (the
implicit-team model replaced them). `test/lib/removed_cc_tools_test.rb` is a
permanent CI guard that fails if either name reappears in shipped source
(`app/ lib/ config/ .claude/`). Cite the changelog version when extending its
denylist.
