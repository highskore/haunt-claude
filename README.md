# haunt Claude Code plugin

Reports Claude Code session, task, subagent, tool and permission events to the haunt terminal as OSC 777 notifications. haunt-core parses them (`core/src/event.rs`).

## Install

From a checkout of this repo:

```sh
claude plugin marketplace add ./hooks
claude plugin install haunt@haunt
```

`hooks/` is both the marketplace (`.claude-plugin/marketplace.json`) and the plugin (`.claude-plugin/plugin.json`, `hooks/hooks.json`). After editing the script, run `claude plugin update haunt@haunt`, or start Claude Code with `claude --plugin-dir ./hooks` to load the plugin without installing it.

Requirements: `bash` and `jq` 1.6 or newer on `PATH`, and Claude Code 2.1.141 or newer for delivery without a tty.

## Tests

```sh
hooks/tests/run.sh
```

These are plain bash plus jq. They cover every event's shape, the nonce, HAUNT gating, both delivery paths, control-character stripping, truncation, and `bash -n`.

## Environment

| Variable | Set by | Effect |
|---|---|---|
| `HAUNT=1` | haunt, per surface | The hook emits nothing unless this is exactly `1`. |
| `HAUNT_HOOK_NONCE` | haunt, per surface, 128-bit random | Copied into `nonce`. jq reads it with `$ENV`, so it never appears on a command line. If it is unset or empty, `nonce` is omitted. |
| `HAUNT_HOOK_TTY` | tests only | Overrides `/dev/tty`. |

## Delivery

Each event is one sequence: `ESC ] 777 ; notify ; haunt://cli-agent ; <json> BEL`. A hook that fires several events concatenates them.

1. The hook first tries to write the sequences to `/dev/tty`. That works on older Claude Code, which rejects unknown output fields but still gives hooks a terminal.
2. If `/dev/tty` cannot be opened, the hook prints `{"terminalSequence":"<sequences>"}` and Claude Code writes the sequences itself. That is the path from Claude Code 2.1.141 on, where hooks have no controlling terminal.

The hook always exits 0 and never blocks the agent.

## Protocol (v1)

The body is one line of compact JSON, no more than **2,000 bytes**. libghostty's OSC buffer is 2,048 bytes and also holds `777;notify;haunt://cli-agent;`. Fields that are null or absent are omitted.

Every string is stripped of C0 controls (U+0000 to U+001F), DEL and C1 controls (U+007F to U+009F) before it is encoded. The body therefore never contains a control character or a `\u00XX` escape for one. The core rejects any body that does.

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
| `nonce` | string | Proves the event came from this hook and not from program output. Without it, the event counts for status only: never for history, decisions or the allowlist. |
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

### Not yet parsed by haunt-core

`core/src/event.rs` reports these as `EventKind::Unknown`, or ignores the new field. The shapes below are exact. The envelope fields are present when known. "Optional" means the key may be absent. `tool_input` is always present, but may be `{}`.

| `event` | Fields beyond the envelope | Suggested variant |
|---|---|---|
| `tool_start` | `tool_name`: string, required. `tool_use_id`: string, optional. `tool_input`: `{command?, url?, file_path?}`, all strings. | `ToolStart { tool_name, tool_use_id: Option, command: Option, url: Option, file_path: Option }` |
| `tool_done` | Same as `tool_start` | `ToolDone { … }`, same fields |
| `tool_failed` | Same as `tool_start` | `ToolFailed { … }`, same fields |
| `permission_seen` | `tool_name`: string, required. `tool_input`: `{command?, file_path?}`. No `tool_use_id`, because Claude Code's PermissionRequest input has none. | `PermissionSeen { tool_name, command: Option, file_path: Option }` |
| `notification` | `notification_type`: string, optional (`permission_prompt`, `idle_prompt`, `auth_success`, …). `message`: string, optional. Truncated if long. | `Notification { notification_type: Option, message: Option }` |
| `todos_written` (existing) | Already parsed: `tool_count`, int, the todo count. New: `todos_done`, int, the number with status `completed`, for a done/total progress bar. | add `done: Option<u64>` to `TodosWritten` |

`tool_ran` already carries `tool_use_id` (optional string). The current `ToolRan` variant ignores it, but it is the better key for matching a permission prompt to a call.

Example bodies (`HAUNT_HOOK_NONCE=3f9c`):

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

Bulky strings are cut, in this order, until the body fits: `tool_input.command`, `tool_input.url`, `tool_input.file_path`, `summary`, `query`, `message`, `description`, `task_subject`, `cwd`. `v`, `agent`, `event`, the ids, `tool_name` and `nonce` are never cut.

If the body still does not fit, it is reduced to `{v, agent, event, session_id, agent_id, tool_use_id, task_id, tool_name, nonce, truncated}`. If even that is too big, the event is dropped. A truncated `tool_ran` command no longer matches its permission prompt exactly. The core should treat `truncated: true` as "no match".
