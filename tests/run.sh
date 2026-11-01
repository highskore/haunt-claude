#!/bin/bash
# Plain-bash tests for scripts/haunt-hook.sh. Needs jq, nc and perl. Usage: hooks/tests/run.sh
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HERE/../scripts/haunt-hook.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
# Running inside haunt must not leak its socket into the tests.
unset HAUNT_SOCK HAUNT_SURFACE_ID
PREFIX=$'\e]777;notify;haunt://cli-agent;'
PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '     %s\n' "$2"; }

# A perl listener stands in for haunt: one connection, never writes back, prints what arrived.
# (`nc -lU` half-closes when its stdin ends, and macOS nc then stops sending mid-message.)
listen() {
    rm -f "$TMP/s" "$TMP/got"
    perl -MIO::Socket::UNIX -e 'alarm 10; $s = IO::Socket::UNIX->new(Type => SOCK_STREAM(), Local => $ARGV[0], Listen => 1) or die; $c = $s->accept; print while sysread($c, $_, 65536)' "$TMP/s" > "$TMP/got" &
    LPID=$!
    for _ in $(seq 50); do [ -S "$TMP/s" ] && return 0; sleep 0.05; done
    return 1
}

# Runs the hook against a fresh socket and prints each line it sent. stdout and the tty must stay empty.
run() {
    local kind="$1" input="$2"
    listen || { echo "NO-LISTENER"; return; }
    printf '%s' "$input" | HAUNT="${T_HAUNT-1}" HAUNT_HOOK_NONCE="${T_NONCE-n0nce}" HAUNT_HOOK_SOCK_MAX="${T_MAX-60000}" \
        HAUNT_SOCK="$TMP/s" HAUNT_SURFACE_ID=surf1 HAUNT_HOOK_TTY="$TMP/sock-tty" "$HOOK" "$kind" > "$TMP/out"
    # A hook that sent nothing never connected; release the listener.
    kill -0 "$LPID" 2> /dev/null && nc -U "$TMP/s" < /dev/null > /dev/null 2>&1
    wait "$LPID"
    { [ -s "$TMP/out" ] || [ -e "$TMP/sock-tty" ]; } && echo "WROTE-OSC"
    cat "$TMP/got"
}

# Runs the hook with no socket and no usable tty and prints each OSC body on its own line.
osc() {
    local kind="$1" input="$2"
    printf '%s' "$input" | HAUNT=1 HAUNT_HOOK_NONCE=n0nce HAUNT_SURFACE_ID=surf1 HAUNT_HOOK_TTY="$TMP/no/tty" "$HOOK" "$kind" > "$TMP/out"
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
    got=$(${RUN-run} "$2" "$3" | jq -sc '.' 2>&1)
    if printf '%s' "$got" | jq -e "$4" > /dev/null 2>&1; then ok "$name"; else bad "$name" "$got"; fi
}

ENV_JSON='"session_id":"s1","cwd":"/w","permission_mode":"default"'
E="(.[0] | .v == 1 and .agent == \"claude\" and .session_id == \"s1\" and .cwd == \"/w\" and .nonce == \"n0nce\" and .surface_id == \"surf1\")"

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
    ".[0] | keys == [\"agent\",\"event\",\"nonce\",\"session_id\",\"surface_id\",\"v\"]"
check "unknown kind emits nothing" bogus "{$ENV_JSON}" "length == 0"
check "invalid stdin emits nothing" stop 'not json' "length == 0"

# Nonce.
T_NONCE="" check "nonce absent when HAUNT_HOOK_NONCE empty" stop "{$ENV_JSON}" "length == 1 and (.[0] | has(\"nonce\") | not)"
if grep -q 'HAUNT_HOOK_NONCE' "$HERE/../hooks/hooks.json"; then bad "nonce never on a command line"; else ok "nonce never on a command line"; fi

# HAUNT gating.
T_HAUNT="" check "no output when HAUNT unset" post_tool "{$ENV_JSON,\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ls\"}}" "length == 0"
T_HAUNT="0" check "no output when HAUNT=0" stop "{$ENV_JSON}" "length == 0"
printf '{}' | env -u HAUNT HAUNT_HOOK_TTY="$TMP/tty" "$HOOK" stop > "$TMP/out"
if [ ! -s "$TMP/out" ] && [ ! -e "$TMP/tty" ]; then ok "HAUNT unset writes neither stdout nor tty"; else bad "HAUNT unset writes neither stdout nor tty"; fi

# Control characters.
CTRL='"tool_name":"Bash","tool_use_id":"t\u0007u","tool_input":{"command":"echo \u001b]777;notify;haunt://cli-agent;{}\u0007 \u009b31m\nnext\tx\u007f"}'
check "control characters stripped from every string" post_tool "{$ENV_JSON,$CTRL}" \
    "length == 2 and .[0].tool_input.command == \"echo ]777;notify;haunt://cli-agent;{} 31mnextx\" and .[0].tool_use_id == \"tu\""
check "control characters stripped from prompt" prompt_submit "{$ENV_JSON,\"prompt\":\"a\u0000b\u001bc\"}" ".[0].query == \"abc\""
check "format characters (bidi, zero-width) stripped" permission_request "{$ENV_JSON,\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo \\u202e\\u2066/ fr- mr\\u2069\\u200b\\u200f\\u2060\\ufeff\\u00ad\\udb40\\udc41x\"}}" \
    ".[0].tool_input.command == \"echo / fr- mrx\""
raw=$(run prompt_submit '{"session_id":"s1","prompt":"a\u001b[2Jb\u0085c"}')
if LC_ALL=C grep -q '[[:cntrl:]]' <<< "$raw" || printf '%s' "$raw" | grep -q '\\u00' || [[ "$raw" == *$'\xc2\x85'* ]]; then
    bad "socket line contains no control bytes or escapes" "$(printf '%s' "$raw" | cat -v)"
else
    ok "socket line contains no control bytes or escapes"
fi

# Socket size limit. T_MAX lowers it so the cutting logic runs on small inputs.
BIG=$(head -c 6000 /dev/zero | tr '\0' 'x')
HUGE=$(head -c 70000 /dev/zero | tr '\0' 'x')
WIDE=$(for _ in $(seq 1500); do printf 'é'; done)
size() { run "$1" "$2" | while IFS= read -r b; do printf '%s' "$b" | wc -c | tr -d ' '; done; }
check "6 KB command is not truncated" permission_request "{$ENV_JSON,\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$BIG\"}}" \
    ".[0].tool_input.command == \"$BIG\" and (.[0] | has(\"truncated\") | not)"
check "one line per event" pre_tool "{$ENV_JSON,\"tool_name\":\"Agent\",\"tool_use_id\":\"tu2\",\"tool_input\":{\"description\":\"d\"}}" \
    "map(.event) == [\"tool_start\",\"subagent_spawn\"] and all(.[]; .surface_id == \"surf1\")"
for kind in pre_tool post_tool permission_request post_tool_failure; do
    max=$(size "$kind" "{$ENV_JSON,\"tool_name\":\"Bash\",\"tool_use_id\":\"tu-huge\",\"tool_input\":{\"command\":\"$HUGE\"}}" | sort -n | tail -1)
    if [ "$max" -le 60000 ]; then ok "$kind 70 KB command fits a 64 KB line ($max bytes)"; else bad "$kind 70 KB command fits" "$max bytes"; fi
done
check "truncated command keeps ids, nonce and event" pre_tool "{$ENV_JSON,\"tool_name\":\"Bash\",\"tool_use_id\":\"tu-huge\",\"tool_input\":{\"command\":\"$HUGE\"}}" \
    "$E and .[0].event == \"tool_start\" and .[0].tool_use_id == \"tu-huge\" and .[0].truncated == true and (.[0].tool_input.command | endswith(\"…\") and length > 59000)"
check "small payload is not marked truncated" stop "{$ENV_JSON}" ".[0] | has(\"truncated\") | not"
T_MAX=2000 check "multibyte text truncated by bytes" post_tool "{$ENV_JSON,\"tool_name\":\"ExitPlanMode\",\"tool_input\":{\"plan\":\"$WIDE\"}}" \
    ".[0].event == \"plan_exit\" and .[0].truncated == true and (.[0] | tojson | utf8bytelength) <= 2000"
max=$(T_MAX=2000 size post_tool "{$ENV_JSON,\"tool_name\":\"ExitPlanMode\",\"tool_input\":{\"plan\":\"$WIDE\"}}" | sort -n | tail -1)
if [ "$max" -le 2000 ] && [ "$max" -gt 1900 ]; then ok "multibyte payload fits without over-cutting ($max bytes)"; else bad "multibyte payload fits" "$max bytes"; fi
T_MAX=2000 check "tool input truncated before other bulky fields" post_tool "{$ENV_JSON,\"agent_id\":\"a1\",\"tool_name\":\"Agent\",\"tool_input\":{\"description\":\"keep me\",\"command\":\"$BIG\"},\"tool_response\":{\"status\":\"completed\",\"agentId\":\"a1\"}}" \
    ".[0].event == \"subagent_result\" and .[0].description == \"keep me\" and .[1].event == \"tool_done\" and .[1].truncated == true"
T_MAX=2000 check "oversized non-bulky field falls back to the minimal envelope" session_start "{$ENV_JSON,\"source\":\"$BIG\"}" \
    "length == 1 and .[0] == {v:1, agent:\"claude\", event:\"session_start\", surface_id:\"surf1\", session_id:\"s1\", nonce:\"n0nce\", truncated:true}"
T_MAX=2000 check "event whose ids overflow is dropped" stop "{\"session_id\":\"$BIG\"}" "length == 0"
EMOJI=$(for _ in $(seq 700); do printf "\xf0\x9f\x91\xbb"; done)
for extra in 0 1 2 3 5 9; do
    pad=$(printf "%${extra}s" "" | tr " " y)
    T_MAX=2000 check "4-byte text converges (pad $extra)" prompt_submit "{$ENV_JSON,\"agent_type\":\"$pad\",\"prompt\":\"$EMOJI\"}" \
        ".[0].truncated == true and (.[0].query | endswith(\"…\")) and (.[0] | tojson | utf8bytelength) <= 2000"
done

# A socket that is there but refuses the send drops the event: the authenticated path is never downgraded.
listen && kill "$LPID" 2> /dev/null; wait "$LPID" 2> /dev/null
printf '{"session_id":"s1"}' | HAUNT=1 HAUNT_SOCK="$TMP/s" HAUNT_SURFACE_ID=surf1 HAUNT_HOOK_TTY="$TMP/dead-tty" "$HOOK" stop > "$TMP/out"
if [ -S "$TMP/s" ] && [ ! -s "$TMP/out" ] && [ ! -e "$TMP/dead-tty" ]; then ok "dead socket: nothing sent, no OSC"; else bad "dead socket: nothing sent, no OSC" "$(cat "$TMP/out")"; fi

# OSC fallback: status fields and a cut title only, no nonce, at most 250 bytes (Ghostty cuts at 255).
RUN=osc check "OSC: status fields only" post_tool "{$ENV_JSON,\"agent_id\":\"a9\",\"agent_type\":\"Explore\",\"tool_name\":\"Bash\",\"tool_use_id\":\"tu1\",\"tool_input\":{\"command\":\"ls\"}}" \
    "map(.event) == [\"tool_done\",\"tool_ran\",\"subagent_tool\"] and all(.[]; . == {v:1, agent:\"claude\", event:.event, agent_id:\"a9\", agent_type:\"Explore\", tool_name:\"Bash\"})"
RUN=osc check "OSC: task progress survives" post_tool "{$ENV_JSON,\"tool_name\":\"TaskUpdate\",\"tool_input\":{\"taskId\":3,\"status\":\"completed\"}}" \
    ".[0] == {v:1, agent:\"claude\", event:\"task_updated\", task_id:\"3\", task_status:\"completed\", tool_name:\"TaskUpdate\"} or .[0] == {v:1, agent:\"claude\", event:\"task_updated\", task_id:\"3\", task_status:\"completed\"}"
RUN=osc check "OSC: todos and notification type survive" post_tool "{$ENV_JSON,\"tool_name\":\"TodoWrite\",\"tool_input\":{\"todos\":[{\"status\":\"completed\"},{\"status\":\"pending\"}]}}" \
    ".[0].event == \"todos_written\" and .[0].tool_count == 2 and .[0].todos_done == 1"
RUN=osc check "OSC: notification type" notification "{$ENV_JSON,\"notification_type\":\"permission_prompt\",\"message\":\"secret\"}" \
    ".[0] == {v:1, agent:\"claude\", event:\"notification\", notification_type:\"permission_prompt\"}"
RUN=osc check "OSC: no nonce, cwd, session, prompt, command or surface_id" prompt_submit "{$ENV_JSON,\"prompt\":\"$BIG\"}" \
    ".[0] == {v:1, agent:\"claude\", event:\"prompt_submit\"}"
LONGTYPE=$(head -c 200 /dev/zero | tr '\0' 't')
RUN=osc check "OSC: a long agent_type is dropped to fit" subagent_start "{$ENV_JSON,\"agent_id\":\"a9\",\"agent_type\":\"$LONGTYPE\"}" \
    ".[0] == {v:1, agent:\"claude\", event:\"subagent_start\", agent_id:\"a9\"}"
RUN=osc check "OSC: an event that cannot fit is dropped" pre_tool "{$ENV_JSON,\"tool_name\":\"$LONGTYPE$LONGTYPE\",\"tool_input\":{}}" "length == 0"
RUN=osc check "OSC: a long task title is cut to fit" task_created "{$ENV_JSON,\"task_id\":7,\"task_subject\":\"$BIG\"}" \
    ".[0].event == \"task_created\" and .[0].task_id == \"7\" and .[0].truncated == true and (.[0].task_subject | endswith(\"…\") and length > 100)"
RUN=osc check "OSC: a spawn description is cut to fit" pre_tool "{$ENV_JSON,\"tool_name\":\"Agent\",\"tool_input\":{\"description\":\"$WIDE\"}}" \
    ".[1].event == \"subagent_spawn\" and (.[1].description | endswith(\"…\"))"
# Every fallback body, for every hook kind and with oversized, multibyte and 4-byte input, is valid JSON within 250 bytes.
: > "$TMP/oscall"
for k in session_start prompt_submit task_created pre_tool post_tool post_tool_failure permission_request notification subagent_start subagent_stop stop; do
    for fill in "$BIG" "$WIDE" "$EMOJI"; do
        for tool in Bash Agent TaskUpdate TodoWrite; do
            osc "$k" "{$ENV_JSON,\"agent_id\":\"a9\",\"agent_type\":\"Explore\",\"task_id\":1,\"task_subject\":\"$fill\",\"prompt\":\"$fill\",\"message\":\"$fill\",\"notification_type\":\"permission_prompt\",\"tool_name\":\"$tool\",\"tool_input\":{\"command\":\"$fill\",\"description\":\"$fill\",\"taskId\":2,\"status\":\"completed\",\"todos\":[]}}" >> "$TMP/oscall"
        done
    done
done
count=$(wc -l < "$TMP/oscall" | tr -d " ")
over=$(LC_ALL=C awk 'length($0) > 250' "$TMP/oscall" | wc -l | tr -d " ")
invalid=$(while IFS= read -r b; do printf '%s' "$b" | jq -e . > /dev/null 2>&1 || echo x; done < "$TMP/oscall" | wc -l | tr -d " ")
max=$(LC_ALL=C awk '{ if (length($0) > m) m = length($0) } END { print m + 0 }' "$TMP/oscall")
if [ "$count" -gt 100 ] && [ "$over" -eq 0 ] && [ "$invalid" -eq 0 ]; then ok "OSC: $count bodies, all valid JSON, max $max bytes"; else bad "OSC: bodies valid and within 250 bytes" "count $count, over $over, invalid $invalid, max $max"; fi
RUN=osc check "OSC: control characters stripped" pre_tool "{$ENV_JSON,\"tool_name\":\"Ba\u001b]sh\u0007\",\"tool_input\":{}}" ".[0].tool_name == \"Ba]sh\""

# OSC delivery paths: a writable tty gets the raw sequences, else terminalSequence on stdout.
printf '{"session_id":"s1"}' | HAUNT=1 HAUNT_HOOK_NONCE=n0nce HAUNT_HOOK_TTY="$TMP/tty" "$HOOK" stop > "$TMP/out"
if [ ! -s "$TMP/out" ] && [ "$(cat "$TMP/tty")" = "$PREFIX"'{"v":1,"agent":"claude","event":"stop"}'$'\a' ]; then
    ok "OSC tty delivery"
else
    bad "OSC tty delivery" "$(cat -v "$TMP/tty" 2>/dev/null)"
fi
printf '{"session_id":"s1"}' | HAUNT=1 HAUNT_HOOK_TTY="$TMP/no/tty" "$HOOK" stop > "$TMP/out"
if jq -e 'keys == ["terminalSequence"]' "$TMP/out" > /dev/null; then ok "terminalSequence is the only output field"; else bad "terminalSequence is the only output field" "$(cat "$TMP/out")"; fi

# When the hook falls back to OSC: no socket, a non-socket, or no surface id.
osc_ok() {
    jq -e '.terminalSequence' "$TMP/out" > /dev/null 2>&1 && ! grep -q 'surface_id\|nonce' "$TMP/out"
}
printf '{"session_id":"s1"}' | HAUNT=1 HAUNT_HOOK_NONCE=n0nce HAUNT_SOCK="$TMP/missing" HAUNT_SURFACE_ID=surf1 HAUNT_HOOK_TTY="$TMP/no/tty" "$HOOK" stop > "$TMP/out"
if osc_ok; then ok "fallback: socket missing"; else bad "fallback: socket missing" "$(cat "$TMP/out")"; fi
: > "$TMP/plain"
printf '{"session_id":"s1"}' | HAUNT=1 HAUNT_SOCK="$TMP/plain" HAUNT_SURFACE_ID=surf1 HAUNT_HOOK_TTY="$TMP/no/tty" "$HOOK" stop > "$TMP/out"
if osc_ok; then ok "fallback: HAUNT_SOCK is not a socket"; else bad "fallback: HAUNT_SOCK is not a socket" "$(cat "$TMP/out")"; fi
printf '{"session_id":"s1"}' | HAUNT=1 HAUNT_SOCK="$TMP/s" HAUNT_HOOK_TTY="$TMP/no/tty" "$HOOK" stop > "$TMP/out"
if osc_ok; then ok "fallback: HAUNT_SURFACE_ID unset"; else bad "fallback: HAUNT_SURFACE_ID unset" "$(cat "$TMP/out")"; fi

# Core compatibility: bodies parse under haunt-core's rules (v:1, event string, no control chars).
check "every event carries v=1 and a string event" post_tool "{$ENV_JSON,\"agent_id\":\"a\",\"tool_name\":\"TodoWrite\",\"tool_input\":{\"todos\":[]}}" \
    "all(.[]; .v == 1 and (.event | type) == \"string\")"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
