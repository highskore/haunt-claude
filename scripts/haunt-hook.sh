#!/bin/bash
# Forwards Claude Code hook events to haunt as OSC 777 `notify;haunt://cli-agent;<json>` sequences.
# Usage: haunt-hook.sh <session_start|prompt_submit|task_created|pre_tool|post_tool|post_tool_failure|
#                      permission_request|notification|subagent_start|subagent_stop|stop>  (hook JSON on stdin)

# Outside haunt nobody parses these, and hooks run inline with the agent, so bail out first.
[ "$HAUNT" = 1 ] || exit 0

KIND="$1"
INPUT=$(cat)
# libghostty's OSC buffer is 2,048 bytes and also holds "777;notify;haunt://cli-agent;".
MAX_BYTES=2000
TTY="${HAUNT_HOOK_TTY:-/dev/tty}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

LIB='
def nonce: ($ENV.HAUNT_HOOK_NONCE // "") | if . == "" then null else . end;
def base($e): {v:1, agent:"claude", event:$e, session_id, cwd, agent_id, agent_type, permission_mode, hook_nonce:nonce};
def preview: (.tool_input // {}) | if type == "object" then {command, url, file_path} | with_entries(select(.value != null)) else {} end;
def tool: {tool_name, tool_use_id, tool_input:preview};
def clean: if type == "string" then explode | map(select(. >= 32 and (. < 127 or . > 159))) | implode else . end;
def bytes: tojson | utf8bytelength;
def shrink($p):
  if bytes <= $max then .
  else (getpath($p) | if type == "string" then rtrimstr("…") else . end) as $s
  | if ($s | type) != "string" or ($s | length) == 0 then .
    else ($s | tojson | utf8bytelength) as $sb
    | ([($s | length) - ((bytes - $max + 3) * ($s | length) / $sb | ceil), 0] | max) as $keep
    | setpath($p; $s[:$keep] + "…") | .truncated = true
    | if $keep == 0 then . else shrink($p) end
    end
  end;
def fit:
  reduce (["tool_input","command"], ["tool_input","url"], ["tool_input","file_path"], ["summary"], ["query"],
          ["message"], ["description"], ["task_subject"], ["cwd"]) as $p (.; shrink($p))
  | if bytes <= $max then .
    else {v, agent, event, session_id, agent_id, tool_use_id, task_id, tool_name, hook_nonce}
      | with_entries(select(.value != null)) + {truncated:true}
    end
  # An event whose ids alone overflow cannot be delivered intact, so it is dropped.
  | select(bytes <= $max);
def finalize: with_entries(select(.value != null)) | walk(clean) | fit;
'

case "$KIND" in
    session_start)
        EXPR='base("session_start") + {model:(.model | if type == "object" then (.id // .display_name) else . end), source, plugin_version:$version}'
        ;;
    prompt_submit)
        EXPR='base("prompt_submit") + {query:.prompt}'
        ;;
    task_created)
        EXPR='base("task_created") + {task_id:(.task_id | tostring), task_subject}'
        ;;
    pre_tool)
        EXPR='(base("tool_start") + tool),
              (if .tool_name == "Agent" then base("subagent_spawn") + {agent_type:(.tool_input.subagent_type // "general-purpose"), description:.tool_input.description} else empty end)'
        ;;
    post_tool)
        EXPR='(if .tool_name == "TaskUpdate" and .tool_input.status then base("task_updated") + {task_id:(.tool_input.taskId | tostring), task_status:.tool_input.status} else empty end),
              # Background launches return before the subagent finishes; only completed results are final.
              (if .tool_name == "Agent" and .tool_response.status == "completed" then base("subagent_result") + {agent_id:.tool_response.agentId, agent_type:.tool_response.agentType, description:.tool_input.description, tool_count:.tool_response.totalToolUseCount, duration_ms:.tool_response.totalDurationMs} else empty end),
              (if .tool_name == "ExitPlanMode" then base("plan_exit") + {summary:.tool_input.plan} else empty end),
              (if .tool_name == "AskUserQuestion" then (base("question_answered") + {summary:(try ([(.tool_response.answers // .tool_input.answers // {})[] | tostring] | join(", ")) catch "")}) | select(.summary != "") else empty end),
              (if .tool_name == "TodoWrite" then base("todos_written") + {tool_count:(.tool_input.todos | length), todos_done:([.tool_input.todos[]? | select(.status == "completed")] | length)} else empty end),
              (if .tool_name | IN("Edit", "Write", "MultiEdit", "NotebookEdit") then base("file_edited") + {tool_name, tool_input:{file_path:(.tool_input.file_path // .tool_input.notebook_path)}} else empty end),
              (base("tool_done") + tool),
              # Exact input, so a pending permission prompt resolves only against the call that ran.
              (base("tool_ran") + {tool_name, tool_use_id, tool_input:(preview | del(.url))}),
              (if .agent_id then base("subagent_tool") + {tool_name} else empty end)'
        ;;
    post_tool_failure)
        EXPR='base("tool_failed") + tool'
        ;;
    permission_request)
        EXPR='base("permission_seen") + {tool_name, tool_input:(preview | del(.url))}'
        ;;
    notification)
        EXPR='base("notification") + {notification_type, message}'
        ;;
    subagent_start|subagent_stop|stop)
        EXPR="base(\"$KIND\")"
        ;;
    *)
        exit 0
        ;;
esac

VERSION=""
[ "$KIND" = session_start ] && VERSION=$(jq -r '.version // empty' "$ROOT/.claude-plugin/plugin.json" 2>/dev/null)

BODIES=$(printf '%s' "$INPUT" | jq -c --argjson max "$MAX_BYTES" --arg version "$VERSION" \
    "$LIB ($EXPR) | finalize | if .plugin_version == \"\" then del(.plugin_version) else . end" 2>/dev/null) || exit 0

SEQS=""
while IFS= read -r body; do
    [ -n "$body" ] && SEQS+=$(printf '\033]777;notify;haunt://cli-agent;%s\007' "$body")
done <<< "$BODIES"
[ -n "$SEQS" ] || exit 0

# Older Claude Code rejects unknown output fields but has a terminal, so write there when we can.
{ printf '%s' "$SEQS" > "$TTY"; } 2>/dev/null && exit 0
# Claude Code >= 2.1.141 runs hooks without a controlling terminal and writes terminalSequence itself.
jq -nc --arg seq "$SEQS" '{terminalSequence: $seq}'
