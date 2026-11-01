# haunt Claude Code plugin

Reports Claude Code session, task, subagent, tool and permission events to the haunt terminal. Events go over haunt's Unix socket when there is one, and as OSC 777 notifications otherwise. haunt-core parses both (`core/src/event.rs`).

## Install

From a checkout of this repo:

```sh
claude plugin marketplace add ./hooks
claude plugin install haunt@haunt
```

`hooks/` is both the marketplace (`.claude-plugin/marketplace.json`) and the plugin (`.claude-plugin/plugin.json`, `hooks/hooks.json`). After editing the script, run `claude plugin update haunt@haunt`, or start Claude Code with `claude --plugin-dir ./hooks` to load the plugin without installing it.

Requirements: `bash` and `jq` 1.6 or newer on `PATH`. The socket path also needs `nc` with `-U` (macOS ships one). OSC delivery without a tty needs Claude Code 2.1.141 or newer.

## Tests

```sh
hooks/tests/run.sh
```

These are plain bash plus jq, `nc` and a perl listener that stands in for the socket. They cover every event's shape over the socket, the nonce, HAUNT gating, control-character stripping, truncation, a dead socket, the status-only OSC body and its 255-byte cap, both OSC delivery paths, each fallback to OSC, and `bash -n`. `cargo test -p haunt-core --test hook_e2e` runs the script against the real core socket.

## Environment

| Variable | Set by | Effect |
|---|---|---|
| `HAUNT=1` | haunt, per surface | The hook emits nothing unless this is exactly `1`. |
| `HAUNT_HOOK_NONCE` | haunt, per surface, 128-bit random | Copied into `nonce` on socket lines (never into OSC). jq reads it with `$ENV`, so it never appears on a command line. If it is unset or empty, `nonce` is omitted. |
| `HAUNT_SURFACE_ID` | haunt, per surface | Copied into `surface_id` on socket lines only. |
| `HAUNT_SOCK` | haunt | The socket path, normally `~/.haunt/sock`. |
| `HAUNT_HOOK_TTY` | tests only | Overrides `/dev/tty`. |
| `HAUNT_HOOK_SOCK_MAX` | tests only | Lowers the socket line limit so truncation can be tested on small inputs. |

## Delivery

**Socket (primary).** If `HAUNT_SOCK` is a socket, `HAUNT_SURFACE_ID` is set and `nc` exists, the hook writes one JSON line per event to `nc -U -w 2 "$HAUNT_SOCK"` and stops there. Only socket events whose `nonce` matches count as verified in the core (`docs/core-api.md`).

If the socket is there but the send fails (haunt died and left the socket file), the event is dropped. It is never downgraded to OSC.

**OSC 777 (fallback).** The hook falls back to OSC only when the socket isn't there: `HAUNT_SOCK` is unset, missing or not a socket, `HAUNT_SURFACE_ID` is unset, or `nc` is missing. Each event is one sequence: `ESC ] 777 ; notify ; haunt://cli-agent ; <json> BEL`. A hook that fires several events concatenates them. Any program in the pty can print these sequences, so the core treats OSC events as status-only. The body therefore carries only what moves status and progress: `{v, agent, event, agent_id, agent_type, task_id, task_status, tool_name, tool_count, todos_done, notification_type}`, with absent fields omitted. It never carries the nonce, the cwd, the session id, prompts, commands or any other free text. Ghostty also delivers at most one notification per second and only the first sequence of a burst, so the fallback is coarse by nature.

1. The hook first tries to write the sequences to `/dev/tty`. That works on older Claude Code, which rejects unknown output fields but still gives hooks a terminal.
2. If `/dev/tty` cannot be opened, the hook prints `{"terminalSequence":"<sequences>"}` and Claude Code writes the sequences itself. That is the path from Claude Code 2.1.141 on, where hooks have no controlling terminal.

The hook always exits 0 and never blocks the agent for longer than `nc`'s 2-second timeout.

## Protocol (v1)

Each body is one line of compact JSON. Fields that are null or absent are omitted. Size limits:

- socket lines: at most **60,000 bytes**, under the core's 64 KB line limit
- OSC bodies: at most **254 bytes**, because Ghostty cuts a notification body at 255. A body that is still too big drops `agent_type`, and is dropped if even that doesn't make it fit

Every string is stripped of C0 controls (U+0000 to U+001F), DEL and C1 controls (U+007F to U+009F) before it is encoded. The body therefore never contains a control character or a `\u00XX` escape for one. The core rejects an OSC body containing a raw control character. Strings that decode to one anyway have it stripped (whitespace becomes a space).

### Envelope (every event)

| Field | Type | Notes |
|---|---|---|
| `v` | int | Always `1`. |
| `agent` | string | Always `"claude"`. |
| `event` | string | The event name, listed below. |
| `session_id` | string | Claude Code session UUID. |
| `cwd` | string | The working directory of the hook. |
| `agent_id` | string | Set inside a subagent. On `subagent_result`, it is the id of the finished subagent. |
| `agent_type` | string | The subagent type. |
| `permission_mode` | string | `default`, `plan`, `acceptEdits` and so on. |
| `surface_id` | string | Socket lines only: `$HAUNT_SURFACE_ID`. The core drops lines for surfaces it doesn't know. |
| `nonce` | string | Proves the event came from this hook and not from program output. Without a match (over the socket), the event counts for status only: never for history, decisions, the allowlist or permission answers. |
| `truncated` | bool | `true` if any field was shortened. Shortened strings end with `…`. |

`tool_input` is always an object holding a subset of `command`, `url` and `file_path`. Other inputs, such as Edit bodies and prompts, are never sent.

### Events

| `event` | Hook | Extra fields |
|---|---|---|
| `session_start` | SessionStart | `model`, `source` (`startup`/`resume`/`clear`/`compact`), `plugin_version` |
| `prompt_submit` | UserPromptSubmit | `query`: the prompt text |
| `task_created` | TaskCreated | `task_id` (string), `task_subject` |
| `tool_start` | PreToolUse | `tool_name`, `tool_use_id`, `tool_input` |
| `subagent_spawn` | PreToolUse (Agent) | `agent_type` (default `general-purpose`), `description` |
| `task_updated` | PostToolUse (TaskUpdate with a status) | `task_id` (string), `task_status` |
| `subagent_result` | PostToolUse (Agent, status `completed`) | `agent_id`, `agent_type`, `description`, `tool_count`, `duration_ms` |
| `plan_exit` | PostToolUse (ExitPlanMode) | `summary`: the plan text |
| `question_answered` | PostToolUse (AskUserQuestion with answers) | `summary`: the answers joined with `", "` |
| `todos_written` | PostToolUse (TodoWrite) | `tool_count` (todos), `todos_done` (completed) |
| `file_edited` | PostToolUse (Edit/Write/MultiEdit/NotebookEdit) | `tool_name`, `tool_input.file_path` |
| `tool_done` | PostToolUse | `tool_name`, `tool_use_id`, `tool_input` |
| `tool_ran` | PostToolUse | `tool_name`, `tool_use_id`, `tool_input` (`command`/`file_path` only), for matching a pending permission prompt against the call that ran |
| `subagent_tool` | PostToolUse inside a subagent | `tool_name` |
| `tool_failed` | PostToolUseFailure | `tool_name`, `tool_use_id`, `tool_input` |
| `permission_seen` | PermissionRequest | `tool_name`, `tool_input` (`command`/`file_path` only) |
| `notification` | Notification | `notification_type` (such as `permission_prompt` or `idle_prompt`), `message` |
| `subagent_start` | SubagentStart | none |
| `subagent_stop` | SubagentStop | none |
| `stop` | Stop | none |

A PostToolUse fires its events in table order: the tool-specific event, then `tool_done`, `tool_ran` and `subagent_tool`.

### Parsing in haunt-core

`core/src/event.rs` parses every event above. The tool events share one `ToolCall { tool_name, tool_use_id, command, url, file_path }`: `ToolStart`, `ToolDone`, `ToolFailed`, `ToolRan` and `PermissionSeen` (which has no `tool_use_id`, because Claude Code's PermissionRequest input has none). `Notification { notification_type, message }` and `TodosWritten { count, done }` cover the rest. `tool_input` is always present, but may be `{}`.

Example socket lines (`HAUNT_HOOK_NONCE=3f9c`, without the `surface_id` every line also carries):

```json
{"v":1,"agent":"claude","event":"tool_start","session_id":"s1","cwd":"/w","nonce":"3f9c","tool_name":"Bash","tool_use_id":"toolu_01","tool_input":{"command":"cargo test"}}
{"v":1,"agent":"claude","event":"tool_done","session_id":"s1","cwd":"/w","nonce":"3f9c","tool_name":"WebFetch","tool_use_id":"toolu_02","tool_input":{"url":"https://x.dev"}}
{"v":1,"agent":"claude","event":"tool_failed","session_id":"s1","cwd":"/w","nonce":"3f9c","tool_name":"Bash","tool_use_id":"toolu_03","tool_input":{"command":"false"}}
{"v":1,"agent":"claude","event":"permission_seen","session_id":"s1","cwd":"/w","nonce":"3f9c","tool_name":"Bash","tool_input":{"command":"rm -rf build"}}
{"v":1,"agent":"claude","event":"notification","session_id":"s1","cwd":"/w","nonce":"3f9c","notification_type":"permission_prompt","message":"Claude needs your permission to use Bash"}
{"v":1,"agent":"claude","event":"todos_written","session_id":"s1","cwd":"/w","nonce":"3f9c","tool_count":3,"todos_done":1}
```

Any of these bodies may also carry `truncated: true`.

### Truncation

On the socket, bulky strings are cut, in this order, until the body fits: `tool_input.command`, `tool_input.url`, `tool_input.file_path`, `summary`, `query`, `message`, `description`, `task_subject`, `cwd`. `v`, `agent`, `event`, the ids, `tool_name` and `nonce` are never cut.

If the body still does not fit, it is reduced to `{v, agent, event, surface_id, session_id, agent_id, tool_use_id, task_id, tool_name, nonce, truncated}`. If even that is too big, the event is dropped. A truncated `tool_ran` no longer matches its permission prompt exactly, so the core never matches an event with `truncated: true`. The socket's larger limit makes truncation rare there.
