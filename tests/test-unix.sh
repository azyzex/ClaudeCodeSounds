#!/usr/bin/env bash
# Integration tests for install-claude-sound-alerts.sh.
#
# Runs the real installer against a throwaway HOME, so nothing here touches the
# machine's actual ~/.claude. Usage:
#
#   bash tests/test-unix.sh [path/to/install-claude-sound-alerts.sh]

set -uo pipefail

INSTALLER="${1:-$(cd "$(dirname "$0")/.." && pwd)/install-claude-sound-alerts.sh}"
PASS=0
FAIL=0

PY=""
for c in python3 python; do command -v "$c" >/dev/null 2>&1 && { PY="$c"; break; }; done
if [ -z "$PY" ]; then echo "FATAL: no python found, cannot verify JSON"; exit 1; fi

ok()   { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }
check() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (expected '$2', got '$1')"; fi; }

# Count hook groups belonging to us, per event, in a settings file.
# Prints "Event=count" per line. Piped through tr because Python on Windows
# emits CRLF, which would otherwise end up embedded mid-string.
ours() {
  _ours "$1" | tr -d '\r'
}
_ours() {
  "$PY" - "$1" <<'PYEOF'
import json, sys
try:
    h = json.load(open(sys.argv[1], encoding='utf-8-sig')).get('hooks', {})
except Exception as e:
    print("PARSE_ERROR", e); raise SystemExit(0)
for event in sorted(h):
    n = sum(1 for g in h[event] if 'claude-notify.sh' in json.dumps(g))
    print("%s=%d" % (event, n))
PYEOF
}

# Read an arbitrary dotted key out of the settings file, or the literal
# string MISSING.
getkey() {
  _getkey "$1" "$2" | tr -d '\r'
}
_getkey() {
  "$PY" - "$1" "$2" <<'PYEOF'
import json, sys
cur = json.load(open(sys.argv[1], encoding='utf-8-sig'))
for part in sys.argv[2].split('.'):
    if isinstance(cur, dict) and part in cur:
        cur = cur[part]
    elif isinstance(cur, list) and part.isdigit() and int(part) < len(cur):
        cur = cur[int(part)]
    else:
        print("MISSING"); raise SystemExit(0)
print(json.dumps(cur) if isinstance(cur, (dict, list)) else cur)
PYEOF
}

echo "installer: $INSTALLER"
echo "python:    $PY"
echo "platform:  $(uname -s)"
echo

# --------------------------------------------------------------------------
echo "case 1: fresh install into an empty HOME"
# --------------------------------------------------------------------------
H=$(mktemp -d)
HOME="$H" NO_TEST_TONE=1 NONINTERACTIVE=1 bash "$INSTALLER" >/dev/null 2>&1
check "$?" "0" "installer exits 0"
S="$H/.claude/settings.json"
[ -f "$S" ] && ok "settings.json created" || bad "settings.json created"
[ -f "$H/.claude/claude-notify.sh" ] && ok "notifier created" || bad "notifier created"
[ -x "$H/.claude/claude-notify.sh" ] && ok "notifier is executable" || bad "notifier is executable"
check "$(ours "$S" | tr '\n' ' ')" "Notification=1 Stop=1 StopFailure=2 UserPromptSubmit=1 " "five hook groups across four events"
"$PY" -c "import json,sys; json.load(open(sys.argv[1],encoding='utf-8-sig'))" "$S" 2>/dev/null \
  && ok "settings.json parses as JSON" || bad "settings.json parses as JSON"
# A BOM would break strict parsers, so assert the first byte is '{'.
check "$(head -c1 "$S")" "{" "written without a UTF-8 BOM"
check "$(getkey "$S" hooks.Stop.0.hooks.0.async)" "True" "async is set on the Stop hook"
rm -rf "$H"
echo

# --------------------------------------------------------------------------
echo "case 2: merge into existing settings, leaving them intact"
# --------------------------------------------------------------------------
H=$(mktemp -d); mkdir -p "$H/.claude"
cat > "$H/.claude/settings.json" <<'EOF'
{
  "model": "opus",
  "theme": "dark",
  "hooks": {
    "PostToolUse": [
      { "hooks": [ { "type": "command", "command": "echo somebody-elses-hook" } ] }
    ],
    "Stop": [
      { "hooks": [ { "type": "command", "command": "echo pre-existing-stop-hook" } ] }
    ]
  }
}
EOF
HOME="$H" NO_TEST_TONE=1 NONINTERACTIVE=1 bash "$INSTALLER" >/dev/null 2>&1
check "$?" "0" "installer exits 0 over existing settings"
S="$H/.claude/settings.json"
check "$(getkey "$S" model)" "opus" "unrelated key 'model' preserved"
check "$(getkey "$S" theme)" "dark" "unrelated key 'theme' preserved"
grep -q 'somebody-elses-hook'   "$S" && ok "unrelated PostToolUse hook preserved" || bad "unrelated PostToolUse hook preserved"
grep -q 'pre-existing-stop-hook' "$S" && ok "pre-existing Stop hook preserved"   || bad "pre-existing Stop hook preserved"
check "$(ours "$S" | grep '^Stop=')" "Stop=1" "exactly one of our Stop groups added"
ls "$H/.claude"/settings.json.bak-* >/dev/null 2>&1 && ok "timestamped backup written" || bad "timestamped backup written"
echo

# --------------------------------------------------------------------------
echo "case 3: re-running is idempotent"
# --------------------------------------------------------------------------
# Assert the exit codes, not just the end state. A re-run that dies early leaves
# the correct JSON behind from the previous run, so without these the whole case
# passes while the installer is in fact broken.
HOME="$H" NO_TEST_TONE=1 NONINTERACTIVE=1 bash "$INSTALLER" >/dev/null 2>&1
check "$?" "0" "second run exits 0"
HOME="$H" NO_TEST_TONE=1 NONINTERACTIVE=1 bash "$INSTALLER" >/dev/null 2>&1
check "$?" "0" "third run exits 0"
check "$(ours "$S" | tr '\n' ' ')" "Notification=1 PostToolUse=0 Stop=1 StopFailure=2 UserPromptSubmit=1 " "still exactly five groups after three runs"
grep -q 'somebody-elses-hook' "$S" && ok "other hooks still intact" || bad "other hooks still intact"
echo

# --------------------------------------------------------------------------
echo "case 4: uninstall removes only our entries"
# --------------------------------------------------------------------------
HOME="$H" bash "$INSTALLER" --uninstall >/dev/null 2>&1
check "$?" "0" "uninstall exits 0"
check "$(ours "$S" | tr '\n' ' ')" "PostToolUse=0 Stop=0 " "none of our groups remain"
check "$(getkey "$S" model)" "opus" "unrelated key survived uninstall"
grep -q 'somebody-elses-hook'   "$S" && ok "unrelated hook survived uninstall" || bad "unrelated hook survived uninstall"
grep -q 'pre-existing-stop-hook' "$S" && ok "pre-existing Stop hook survived"  || bad "pre-existing Stop hook survived"
[ -f "$H/.claude/claude-notify.sh" ] && bad "notifier removed" || ok "notifier removed"
rm -rf "$H"
echo

# --------------------------------------------------------------------------
echo "case 5: refuses to clobber invalid JSON"
# --------------------------------------------------------------------------
H=$(mktemp -d); mkdir -p "$H/.claude"
printf '{ this is not json' > "$H/.claude/settings.json"
HOME="$H" NO_TEST_TONE=1 NONINTERACTIVE=1 bash "$INSTALLER" >/dev/null 2>&1
[ "$?" != "0" ] && ok "exits non-zero on malformed settings.json" || bad "exits non-zero on malformed settings.json"
grep -q 'this is not json' "$H/.claude/settings.json" && ok "malformed file left untouched" || bad "malformed file left untouched"
rm -rf "$H"
echo

# --------------------------------------------------------------------------
echo "case 6: the notifier survives every alert kind"
# --------------------------------------------------------------------------
H=$(mktemp -d)
HOME="$H" NO_TEST_TONE=1 NONINTERACTIVE=1 bash "$INSTALLER" >/dev/null 2>&1
N="$H/.claude/claude-notify.sh"
for kind in mark "done" blocked limit error bogus-kind; do
  rm -f "${TMPDIR:-/tmp}"/claude-notify.*.last
  err=$(echo '{"message":"test payload","session_id":"s1","cwd":"/tmp/proj"}' \
        | HOME="$H" bash "$N" "$kind" 2>&1 >/dev/null)
  rc=$?
  check "$rc" "0" "kind '$kind' exits 0"
  if [ -z "$err" ]; then ok "kind '$kind' writes nothing to stderr"
  else bad "kind '$kind' stderr: $err"; fi
done

echo "  (no stdin at all)"
rm -f "${TMPDIR:-/tmp}"/claude-notify.*.last
HOME="$H" bash "$N" "done" </dev/null >/dev/null 2>&1
check "$?" "0" "runs with empty stdin"

echo "  (debounce)"
rm -f "${TMPDIR:-/tmp}"/claude-notify.*.last
HOME="$H" bash "$N" "done" </dev/null >/dev/null 2>&1
HOME="$H" bash "$N" "done" </dev/null >/dev/null 2>&1
check "$?" "0" "second immediate call still exits 0"
ls "${TMPDIR:-/tmp}"/claude-notify.*.last >/dev/null 2>&1 && ok "debounce stamp is uid-namespaced" || bad "debounce stamp written"
rm -rf "$H"
echo

# --------------------------------------------------------------------------
echo "case 7: the config file drives behaviour"
# --------------------------------------------------------------------------
H=$(mktemp -d)
HOME="$H" NO_TEST_TONE=1 NONINTERACTIVE=1 bash "$INSTALLER" >/dev/null 2>&1
N="$H/.claude/claude-notify.sh"
C="$H/.claude/claude-notify.conf"
[ -f "$C" ] && ok "config file created" || bad "config file created"

# Ask the notifier what it decided rather than inferring from a zero exit.
# $H, $N and $C are set by whichever case is running.
decide() {  # decide <kind> [payload]
  rm -f "${TMPDIR:-/tmp}"/claude-notify.*.last
  printf '%s' "${2:-\{\}}" \
    | HOME="$H" CLAUDE_NOTIFY_DEBUG=1 bash "$N" "$1" 2>/dev/null | tr -d '\r'
}

# Set a key via python rather than sed: some values are absolute paths, and a
# slash in the replacement would collide with the s/// delimiter.
setconf() {  # setconf KEY VALUE
  CONF_PATH="$C" CONF_KEY="$1" CONF_VAL="$2" "$PY" - <<'SETCONFEOF'
import io, os, re
path = os.environ['CONF_PATH']; key = os.environ['CONF_KEY']; val = os.environ['CONF_VAL']
lines = io.open(path, encoding='utf-8').read().split('\n')
out, seen = [], False
for line in lines:
    if re.match(r'^%s\s*=' % re.escape(key), line):
        out.append('%s=%s' % (key, val)); seen = True
    else:
        out.append(line)
if not seen:
    out.append('%s=%s' % (key, val))
io.open(path, 'w', encoding='utf-8', newline='\n').write('\n'.join(out))
SETCONFEOF
}

# Pull one "name=value" field out of a decision line.
field() { printf '%s' "$1" | sed -n "s/.*[ ]$2=\([^ ]*\).*/\1/p"; }

echo "  (mute)"
setconf MUTE "done"
r=$(decide "done")
case "$r" in *suppressed=muted*) ok "MUTE=done silences the finish alert" ;; *) bad "MUTE ignored: $r" ;; esac
r=$(decide blocked)
case "$r" in *suppressed=muted*) bad "MUTE=done wrongly silenced blocked" ;; *) ok "MUTE=done leaves blocked alone" ;; esac
setconf MUTE ""

echo "  (elapsed-time threshold)"
setconf MIN_SECONDS 30
# 'mark' records a start time; an immediate 'done' is therefore far too quick.
printf '{"session_id":"t7"}' | HOME="$H" bash "$N" mark >/dev/null 2>&1
r=$(printf '{"session_id":"t7"}' | HOME="$H" CLAUDE_NOTIFY_DEBUG=1 bash "$N" "done" 2>/dev/null | tr -d '\r')
case "$r" in *suppressed=too-quick*) ok "a turn under MIN_SECONDS stays silent" ;; *) bad "expected too-quick, got: $r" ;; esac
# blocked is in ALWAYS_ALERT, so the same short turn must still alert.
printf '{"session_id":"t7"}' | HOME="$H" bash "$N" mark >/dev/null 2>&1
r=$(printf '{"session_id":"t7"}' | HOME="$H" CLAUDE_NOTIFY_DEBUG=1 bash "$N" blocked 2>/dev/null | tr -d '\r')
case "$r" in *suppressed=*) bad "ALWAYS_ALERT did not bypass the threshold: $r" ;; *) ok "ALWAYS_ALERT bypasses the threshold" ;; esac
# MIN_SECONDS=0 disables the check entirely.
setconf MIN_SECONDS 0
printf '{"session_id":"t7"}' | HOME="$H" bash "$N" mark >/dev/null 2>&1
r=$(printf '{"session_id":"t7"}' | HOME="$H" CLAUDE_NOTIFY_DEBUG=1 bash "$N" "done" 2>/dev/null | tr -d '\r')
case "$r" in *too-quick*) bad "MIN_SECONDS=0 should disable the check: $r" ;; *) ok "MIN_SECONDS=0 disables the check" ;; esac
setconf MIN_SECONDS 30

echo "  (mark plays nothing)"
r=$(decide mark)
case "$r" in *kind=mark*) ok "mark reports itself and exits" ;; *) bad "mark: $r" ;; esac
case "$r" in *player=*) bad "mark must not choose a player" ;; *) ok "mark chooses no player" ;; esac

echo "  (debounce is configurable)"
setconf DEBOUNCE_SECONDS 9
setconf MIN_SECONDS 0
printf '{}' | HOME="$H" bash "$N" blocked >/dev/null 2>&1
r=$(printf '{}' | HOME="$H" CLAUDE_NOTIFY_DEBUG=1 bash "$N" blocked 2>/dev/null | tr -d '\r')
case "$r" in *suppressed=debounced*) ok "DEBOUNCE_SECONDS suppresses a repeat" ;; *) bad "expected debounced, got: $r" ;; esac
setconf DEBOUNCE_SECONDS 2

echo "  (speak instead of chime)"
FAKE="$H/fakebin"; mkdir -p "$FAKE"
printf '#!/bin/sh\nexit 0\n' > "$FAKE/spd-say"; chmod +x "$FAKE/spd-say"
setconf SPEAK 1
rm -f "${TMPDIR:-/tmp}"/claude-notify.*.last
r=$(printf '{}' | HOME="$H" PATH="$FAKE:$PATH" CLAUDE_NOTIFY_DEBUG=1 bash "$N" blocked 2>/dev/null | tr -d '\r')
# Any synthesiser counts. macOS has a real `say`, which the notifier tries ahead
# of the spd-say stub, so pinning this to spd-say would only pass on Linux.
case "$r" in
  *player=say*|*player=spd-say*|*player=espeak*)
    ok "SPEAK=1 routes through a speech synthesiser" ;;
  *) bad "expected a speech synthesiser, got: $r" ;;
esac
setconf SPEAK 0

echo "  (a malicious config cannot execute anything)"
printf 'MIN_SECONDS=0\nMUTE=`touch %s/pwned`\n' "$H" >> "$C"
rm -f "${TMPDIR:-/tmp}"/claude-notify.*.last
printf '{}' | HOME="$H" bash "$N" blocked >/dev/null 2>&1 || true
[ -f "$H/pwned" ] && bad "config file contents were executed" || ok "config is parsed, never sourced"

echo "  (config survives a reinstall)"
HOME="$H" NO_TEST_TONE=1 NONINTERACTIVE=1 bash "$INSTALLER" >/dev/null 2>&1
grep -q 'pwned' "$C" && ok "existing config left untouched by reinstall" || bad "reinstall overwrote the config"
rm -rf "$H"
echo

# --------------------------------------------------------------------------
echo "case 8: per-event options"
# --------------------------------------------------------------------------
H=$(mktemp -d)
HOME="$H" NO_TEST_TONE=1 NONINTERACTIVE=1 bash "$INSTALLER" >/dev/null 2>&1
N="$H/.claude/claude-notify.sh"
C="$H/.claude/claude-notify.conf"

# These checks only care what the notifier decided, not about hearing it. Dry
# run resolves everything and reports it without playing or notifying.
export CLAUDE_NOTIFY_DRYRUN=1

echo "  (each kind gets its own defaults)"
check "$(field "$(decide "done")" pattern)"  "1x220" "done defaults to a single pulse"
check "$(field "$(decide blocked)" pattern)" "2x220" "blocked defaults to two"
check "$(field "$(decide limit)" pattern)"   "3x140" "limit defaults to three, tighter"
check "$(field "$(decide "done")" volume)"   "70"    "done is quieter than the alerts"
check "$(field "$(decide blocked)" volume)"  "100"   "blocked is at full volume"

echo "  (patterns are configurable)"
setconf DONE_PATTERN "4x90"
check "$(field "$(decide "done")" pattern)" "4x90"  "DONE_PATTERN is honoured"
setconf DONE_PATTERN "nonsense"
check "$(field "$(decide "done")" pattern)" "1x220" "a malformed pattern falls back to one pulse"
setconf DONE_PATTERN "99"
check "$(field "$(decide "done")" pattern)" "6x220" "an absurd repeat count is capped"
setconf DONE_PATTERN "1"

echo "  (volume is clamped)"
setconf DONE_VOLUME "500"
check "$(field "$(decide "done")" volume)" "100" "volume above 100 is clamped"
setconf DONE_VOLUME "abc"
check "$(field "$(decide "done")" volume)" "100" "a non-numeric volume falls back"
setconf DONE_VOLUME "70"

echo "  (per-event disable)"
setconf DONE_ENABLED 0
r=$(decide "done")
case "$r" in *suppressed=muted*) ok "DONE_ENABLED=0 silences just that kind" ;; *) bad "expected muted, got: $r" ;; esac
r=$(decide blocked)
case "$r" in *suppressed=*) bad "DONE_ENABLED=0 leaked to blocked" ;; *) ok "other kinds unaffected" ;; esac
setconf DONE_ENABLED 1

echo "  (quiet hours)"
# A window covering the whole day must silence everything, even ALWAYS_ALERT.
setconf QUIET_HOURS "00:00-23:59"
r=$(decide blocked)
case "$r" in *suppressed=quiet-hours*) ok "an all-day window silences even ALWAYS_ALERT kinds" ;; *) bad "expected quiet-hours, got: $r" ;; esac
# A window that has already closed must not.
setconf QUIET_HOURS "00:00-00:01"
r=$(decide blocked)
case "$r" in *suppressed=quiet-hours*) bad "silenced outside the window: $r" ;; *) ok "outside the window it alerts normally" ;; esac
# Garbage must not silence everything.
setconf QUIET_HOURS "not-a-window"
r=$(decide blocked)
case "$r" in *suppressed=quiet-hours*) bad "unparseable window silenced everything" ;; *) ok "an unparseable window is ignored" ;; esac
setconf QUIET_HOURS ""

echo "  (a per-event sound file overrides the built-in choice)"
custom="$H/custom.wav"; : > "$custom"
setconf DONE_SOUND "$custom"
# Compared by basename: under Git Bash the path is rewritten to its native form
# in transit, which is a harness artifact rather than anything the notifier did.
got=$(field "$(decide "done")" sound)
case "$got" in
  */custom.wav) ok "DONE_SOUND takes precedence" ;;
  *) bad "DONE_SOUND takes precedence (got '$got')" ;;
esac
unset CLAUDE_NOTIFY_DRYRUN
rm -rf "$H"
echo

# --------------------------------------------------------------------------
printf 'passed %d, failed %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
