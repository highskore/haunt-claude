#!/bin/bash
# Plain-bash tests for scripts/haunt-hook.sh. Needs jq. Usage: hooks/tests/run.sh
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HERE/../scripts/haunt-hook.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PREFIX=$'\e]777;notify;haunt://cli-agent;'
PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '     %s\n' "$2"; }

# Runs the hook with no usable tty and prints each OSC body on its own line.
run() {
    local kind="$1" input="$2"
    printf '%s' "$input" | HAUNT="${T_HAUNT-1}" HAUNT_HOOK_NONCE="${T_NONCE-n0nce}" HAUNT_HOOK_TTY="$TMP/no/tty" "$HOOK" "$kind" > "$TMP/out"
    [ -s "$TMP/out" ] || return 0
    jq -r '.terminalSequence' "$TMP/out" | tr '\a' '\n' | while IFS= read -r seq; do
        [ -z "$seq" ] && continue
        case "$seq" in
            "$PREFIX"*) printf '%s\n' "${seq#"$PREFIX"}" ;;
            *) printf 'BAD-PREFIX\n' ;;
        esac
    done
}

# check <name> <kind> <input> <jq filter over the array of bodies that must be true>
check() {
    local name="$1" got
    got=$(run "$2" "$3" | jq -sc '.' 2>&1)
    if printf '%s' "$got" | jq -e "$4" > /dev/null 2>&1; then ok "$name"; else bad "$name" "$got"; fi
}

ENV_JSON='"session_id":"s1","cwd":"/w","permission_mode":"default"'
E="(.[0] | .v == 1 and .agent == \"claude\" and .session_id == \"s1\" and .cwd == \"/w\" and .nonce == \"n0nce\")"

# bash -n
for f in "$HOOK" "$0"; do
    if bash -n "$f"; then ok "bash -n $(basename "$f")"; else bad "bash -n $(basename "$f")"; fi
done

# Every event's shape.
check "session_start" session_start "{$ENV_JSON,\"model\":{\"id\":\"claude-opus-5-5\"},\"source\":\"startup\"}" \
    "length == 1 and $E and .[0].event == \"session_start\" and .[0].model == \"claude-opus-5-5\" and .[0].source == \"startup\" and (.[0].plugin_version | type) == \"string\""
check "prompt_submit" prompt_submit "{$ENV_JSON,\"prompt\":\"fix the bug\"}" \
    "length == 1 and $E and .[0].event == \"prompt_submit\" and .[0].query == \"fix the bug\" and .[0].permission_mode == \"default\""
check "task_created" task_created "{$ENV_JSON,\"task_id\":7,\"task_subject\":\"step one\"}" \
    "length == 1 and $E and .[0].event == \"task_created\" and .[0].task_id == \"7\" and .[0].task_subject == \"step one\""
check "pre_tool -> tool_start" pre_tool "{$ENV_JSON,\"tool_name\":\"Bash\",\"tool_use_id\":\"tu1\",\"tool_input\":{\"command\":\"ls\",\"description\":\"list\"}}" \
    "length == 1 and $E and .[0].event == \"tool_start\" and .[0].tool_name == \"Bash\" and .[0].tool_use_id == \"tu1\" and .[0].tool_input == {command:\"ls\"}"
check "pre_tool Agent -> tool_start + subagent_spawn" pre_tool "{$ENV_JSON,\"tool_name\":\"Agent\",\"tool_use_id\":\"tu2\",\"tool_input\":{\"description\":\"find it\",\"prompt\":\"...\"}}" \
    "length == 2 and $E and (map(.event) == [\"tool_start\",\"subagent_spawn\"]) and .[1].agent_type == \"general-purpose\" and .[1].description == \"find it\""
check "post_tool Bash -> tool_done + tool_ran" post_tool "{$ENV_JSON,\"tool_name\":\"Bash\",\"tool_use_id\":\"tu1\",\"tool_input\":{\"command\":\"ls\"},\"tool_response\":{}}" \
    "length == 2 and $E and map(.event) == [\"tool_done\",\"tool_ran\"] and all(.[]; .tool_input == {command:\"ls\"} and .tool_use_id == \"tu1\")"
check "post_tool WebFetch keeps url in tool_done only" post_tool "{$ENV_JSON,\"tool_name\":\"WebFetch\",\"tool_input\":{\"url\":\"https://x\",\"prompt\":\"p\"}}" \
    "map(.event) == [\"tool_done\",\"tool_ran\"] and .[0].tool_input == {url:\"https://x\"} and .[1].tool_input == {}"
check "post_tool TaskUpdate -> task_updated" post_tool "{$ENV_JSON,\"tool_name\":\"TaskUpdate\",\"tool_input\":{\"taskId\":3,\"status\":\"completed\"}}" \
    "$E and .[0].event == \"task_updated\" and .[0].task_id == \"3\" and .[0].task_status == \"completed\""
check "post_tool TaskUpdate without status skips task_updated" post_tool "{$ENV_JSON,\"tool_name\":\"TaskUpdate\",\"tool_input\":{\"taskId\":3}}" \
    "map(.event) == [\"tool_done\",\"tool_ran\"]"
check "post_tool Agent completed -> subagent_result" post_tool "{$ENV_JSON,\"tool_name\":\"Agent\",\"tool_input\":{\"description\":\"d\"},\"tool_response\":{\"status\":\"completed\",\"agentId\":\"a9\",\"agentType\":\"Explore\",\"totalToolUseCount\":4,\"totalDurationMs\":1200}}" \
    "$E and .[0].event == \"subagent_result\" and .[0].agent_id == \"a9\" and .[0].agent_type == \"Explore\" and .[0].tool_count == 4 and .[0].duration_ms == 1200 and .[0].description == \"d\""
check "post_tool Agent background launch skips subagent_result" post_tool "{$ENV_JSON,\"tool_name\":\"Agent\",\"tool_input\":{},\"tool_response\":{\"status\":\"async_launched\"}}" \
    "map(.event) == [\"tool_done\",\"tool_ran\"]"
check "post_tool ExitPlanMode -> plan_exit" post_tool "{$ENV_JSON,\"tool_name\":\"ExitPlanMode\",\"tool_input\":{\"plan\":\"1. do it\"}}" \
    "$E and .[0].event == \"plan_exit\" and .[0].summary == \"1. do it\""
check "post_tool AskUserQuestion -> question_answered" post_tool "{$ENV_JSON,\"tool_name\":\"AskUserQuestion\",\"tool_input\":{},\"tool_response\":{\"answers\":{\"q1\":\"yes\",\"q2\":\"later\"}}}" \
    "$E and .[0].event == \"question_answered\" and .[0].summary == \"yes, later\""
check "post_tool AskUserQuestion without answers skips" post_tool "{$ENV_JSON,\"tool_name\":\"AskUserQuestion\",\"tool_input\":{}}" \
    "map(.event) == [\"tool_done\",\"tool_ran\"]"
check "post_tool TodoWrite -> todos_written" post_tool "{$ENV_JSON,\"tool_name\":\"TodoWrite\",\"tool_input\":{\"todos\":[{\"status\":\"completed\"},{\"status\":\"pending\"},{\"status\":\"completed\"}]}}" \
    "$E and .[0].event == \"todos_written\" and .[0].tool_count == 3 and .[0].todos_done == 2"
check "post_tool Edit -> file_edited" post_tool "{$ENV_JSON,\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"/w/a.rs\",\"old_string\":\"x\",\"new_string\":\"y\"}}" \
    "$E and .[0].event == \"file_edited\" and .[0].tool_name == \"Edit\" and .[0].tool_input == {file_path:\"/w/a.rs\"} and .[1].tool_input == {file_path:\"/w/a.rs\"}"
check "post_tool NotebookEdit uses notebook_path" post_tool "{$ENV_JSON,\"tool_name\":\"NotebookEdit\",\"tool_input\":{\"notebook_path\":\"/w/n.ipynb\"}}" \
    ".[0].event == \"file_edited\" and .[0].tool_input == {file_path:\"/w/n.ipynb\"}"
check "post_tool inside subagent -> subagent_tool" post_tool "{$ENV_JSON,\"agent_id\":\"a9\",\"agent_type\":\"Explore\",\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"/w/a\"}}" \
    "map(.event) == [\"tool_done\",\"tool_ran\",\"subagent_tool\"] and .[2].tool_name == \"Read\" and .[2].agent_id == \"a9\" and .[2].agent_type == \"Explore\""
check "post_tool_failure -> tool_failed" post_tool_failure "{$ENV_JSON,\"tool_name\":\"Bash\",\"tool_use_id\":\"tu3\",\"tool_input\":{\"command\":\"false\"},\"error\":\"exit 1\"}" \
    "length == 1 and $E and .[0].event == \"tool_failed\" and .[0].tool_name == \"Bash\" and .[0].tool_use_id == \"tu3\" and .[0].tool_input == {command:\"false\"}"
check "permission_request -> permission_seen" permission_request "{$ENV_JSON,\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"rm -rf build\",\"description\":\"clean\"}}" \
    "length == 1 and $E and .[0].event == \"permission_seen\" and .[0].tool_name == \"Bash\" and .[0].tool_input == {command:\"rm -rf build\"}"
check "notification" notification "{$ENV_JSON,\"notification_type\":\"idle_prompt\",\"message\":\"Claude is waiting\"}" \
    "length == 1 and $E and .[0].event == \"notification\" and .[0].notification_type == \"idle_prompt\" and .[0].message == \"Claude is waiting\""
check "subagent_start" subagent_start "{$ENV_JSON,\"agent_id\":\"a9\",\"agent_type\":\"Explore\"}" \
    "length == 1 and $E and .[0].event == \"subagent_start\" and .[0].agent_id == \"a9\" and .[0].agent_type == \"Explore\""
check "subagent_stop" subagent_stop "{$ENV_JSON,\"agent_id\":\"a9\"}" \
    "length == 1 and $E and .[0].event == \"subagent_stop\" and .[0].agent_id == \"a9\""
check "stop" stop "{$ENV_JSON,\"stop_hook_active\":false}" \
    "length == 1 and $E and .[0].event == \"stop\" and (.[0] | has(\"stop_hook_active\") | not)"
check "null fields are dropped" stop '{"session_id":"s1"}' \
    ".[0] | keys == [\"agent\",\"event\",\"nonce\",\"session_id\",\"v\"]"
check "unknown kind emits nothing" bogus "{$ENV_JSON}" "length == 0"
check "invalid stdin emits nothing" stop 'not json' "length == 0"

# Nonce.
T_NONCE="" check "nonce absent when HAUNT_HOOK_NONCE empty" stop "{$ENV_JSON}" "length == 1 and (.[0] | has(\"nonce\") | not)"
got=$(printf '{}' | env -u HAUNT_HOOK_NONCE HAUNT=1 HAUNT_HOOK_TTY="$TMP/no/tty" "$HOOK" stop | jq -r '.terminalSequence')
case "$got" in *'"nonce"'*) bad "nonce absent when HAUNT_HOOK_NONCE unset" "$got" ;; *) ok "nonce absent when HAUNT_HOOK_NONCE unset" ;; esac
if grep -q 'HAUNT_HOOK_NONCE' "$HERE/../hooks/hooks.json"; then bad "nonce never on a command line"; else ok "nonce never on a command line"; fi

# HAUNT gating.
T_HAUNT="" check "no output when HAUNT unset" post_tool "{$ENV_JSON,\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ls\"}}" "length == 0"
T_HAUNT="0" check "no output when HAUNT=0" stop "{$ENV_JSON}" "length == 0"
printf '{}' | env -u HAUNT HAUNT_HOOK_TTY="$TMP/tty" "$HOOK" stop > "$TMP/out"
if [ ! -s "$TMP/out" ] && [ ! -e "$TMP/tty" ]; then ok "HAUNT unset writes neither stdout nor tty"; else bad "HAUNT unset writes neither stdout nor tty"; fi

# Delivery: a writable tty gets the raw sequences and stdout stays empty.
printf '{"session_id":"s1"}' | HAUNT=1 HAUNT_HOOK_NONCE=n0nce HAUNT_HOOK_TTY="$TMP/tty" "$HOOK" stop > "$TMP/out"
if [ ! -s "$TMP/out" ] && [ "$(cat "$TMP/tty")" = "$PREFIX"'{"v":1,"agent":"claude","event":"stop","session_id":"s1","nonce":"n0nce"}'$'\a' ]; then
    ok "tty delivery"
else
    bad "tty delivery" "$(cat -v "$TMP/tty" 2>/dev/null)"
fi
printf '{"session_id":"s1"}' | HAUNT=1 HAUNT_HOOK_TTY="$TMP/no/tty" "$HOOK" stop > "$TMP/out"
if jq -e 'keys == ["terminalSequence"]' "$TMP/out" > /dev/null; then ok "terminalSequence fallback is the only output field"; else bad "terminalSequence fallback is the only output field" "$(cat "$TMP/out")"; fi

# Control characters.
CTRL='"tool_name":"Bash","tool_use_id":"t\u0007u","tool_input":{"command":"echo \u001b]777;notify;haunt://cli-agent;{}\u0007 \u009b31m\nnext\tx\u007f"}'
check "control characters stripped from every string" post_tool "{$ENV_JSON,$CTRL}" \
    "length == 2 and .[0].tool_input.command == \"echo ]777;notify;haunt://cli-agent;{} 31mnextx\" and .[0].tool_use_id == \"tu\""
check "control characters stripped from prompt" prompt_submit "{$ENV_JSON,\"prompt\":\"a\u0000b\u001bc\"}" ".[0].query == \"abc\""
raw=$(printf '{"session_id":"s1","prompt":"a\\u001b[2Jb\\u0085c"}' | HAUNT=1 HAUNT_HOOK_TTY="$TMP/no/tty" "$HOOK" prompt_submit | jq -r '.terminalSequence')
body="${raw#"$PREFIX"}"; body="${body%$'\a'}"
if LC_ALL=C grep -q '[[:cntrl:]]' <<< "$body" || printf '%s' "$body" | jq -e 'test("\\\\u00")' > /dev/null 2>&1 || [[ "$body" == *$'\xc2\x85'* ]]; then
    bad "OSC body contains no control bytes or escapes" "$(printf '%s' "$body" | cat -v)"
else
    ok "OSC body contains no control bytes or escapes"
fi

# Truncation at the size limit.
BIG=$(head -c 6000 /dev/zero | tr '\0' 'x')
WIDE=$(for _ in $(seq 1500); do printf 'é'; done)
size() { run "$1" "$2" | while IFS= read -r b; do printf '%s' "$b" | wc -c | tr -d ' '; done; }
for kind in pre_tool post_tool permission_request post_tool_failure; do
    in="{$ENV_JSON,\"tool_name\":\"Bash\",\"tool_use_id\":\"tu-big\",\"tool_input\":{\"command\":\"$BIG\"}}"
    max=$(size "$kind" "$in" | sort -n | tail -1)
    if [ "$max" -le 2000 ]; then ok "$kind big command fits ($max bytes)"; else bad "$kind big command fits" "$max bytes"; fi
done
check "truncated command keeps ids, nonce and event" pre_tool "{$ENV_JSON,\"tool_name\":\"Bash\",\"tool_use_id\":\"tu-big\",\"tool_input\":{\"command\":\"$BIG\"}}" \
    "$E and .[0].event == \"tool_start\" and .[0].tool_use_id == \"tu-big\" and .[0].truncated == true and (.[0].tool_input.command | endswith(\"…\") and length > 1500)"
check "small payload is not marked truncated" stop "{$ENV_JSON}" ".[0] | has(\"truncated\") | not"
check "multibyte text truncated by bytes" post_tool "{$ENV_JSON,\"tool_name\":\"ExitPlanMode\",\"tool_input\":{\"plan\":\"$WIDE\"}}" \
    ".[0].event == \"plan_exit\" and .[0].truncated == true and (.[0] | tojson | utf8bytelength) <= 2000"
max=$(size post_tool "{$ENV_JSON,\"tool_name\":\"ExitPlanMode\",\"tool_input\":{\"plan\":\"$WIDE\"}}" | sort -n | tail -1)
if [ "$max" -le 2000 ] && [ "$max" -gt 1900 ]; then ok "multibyte payload fits on the wire without over-cutting ($max bytes)"; else bad "multibyte payload fits on the wire" "$max bytes"; fi
check "tool input truncated before other bulky fields" post_tool "{$ENV_JSON,\"agent_id\":\"a1\",\"tool_name\":\"Agent\",\"tool_input\":{\"description\":\"keep me\",\"command\":\"$BIG\"},\"tool_response\":{\"status\":\"completed\",\"agentId\":\"a1\"}}" \
    ".[0].event == \"subagent_result\" and .[0].description == \"keep me\" and .[1].event == \"tool_done\" and .[1].truncated == true"
check "oversized non-bulky field falls back to the minimal envelope" session_start "{$ENV_JSON,\"source\":\"$BIG\"}" \
    "length == 1 and .[0] == {v:1, agent:\"claude\", event:\"session_start\", session_id:\"s1\", nonce:\"n0nce\", truncated:true}"
check "event whose ids overflow is dropped" stop "{\"session_id\":\"$BIG\"}" "length == 0"
EMOJI=$(for _ in $(seq 700); do printf "\xf0\x9f\x91\xbb"; done)
for extra in 0 1 2 3 5 9; do
    pad=$(printf "%${extra}s" "" | tr " " y)
    check "4-byte text converges (pad $extra)" prompt_submit "{$ENV_JSON,\"agent_type\":\"$pad\",\"prompt\":\"$EMOJI\"}" \
        ".[0].truncated == true and (.[0].query | endswith(\"…\")) and (.[0] | tojson | utf8bytelength) <= 2000"
done

# Core compatibility: bodies parse under haunt-core's rules (v:1, event string, no control chars).
check "every event carries v=1 and a string event" post_tool "{$ENV_JSON,\"agent_id\":\"a\",\"tool_name\":\"TodoWrite\",\"tool_input\":{\"todos\":[]}}" \
    "all(.[]; .v == 1 and (.event | type) == \"string\")"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
