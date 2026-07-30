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
HOME="$H" NO_TEST_TONE=1 bash "$INSTALLER" >/dev/null 2>&1
check "$?" "0" "installer exits 0"
S="$H/.claude/settings.json"
[ -f "$S" ] && ok "settings.json created" || bad "settings.json created"
[ -f "$H/.claude/claude-notify.sh" ] && ok "notifier created" || bad "notifier created"
[ -x "$H/.claude/claude-notify.sh" ] && ok "notifier is executable" || bad "notifier is executable"
check "$(ours "$S" | tr '\n' ' ')" "Notification=1 Stop=1 StopFailure=2 " "four hook groups across three events"
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
HOME="$H" NO_TEST_TONE=1 bash "$INSTALLER" >/dev/null 2>&1
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
HOME="$H" NO_TEST_TONE=1 bash "$INSTALLER" >/dev/null 2>&1
HOME="$H" NO_TEST_TONE=1 bash "$INSTALLER" >/dev/null 2>&1
check "$(ours "$S" | tr '\n' ' ')" "Notification=1 PostToolUse=0 Stop=1 StopFailure=2 " "still exactly four groups after three runs"
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
HOME="$H" NO_TEST_TONE=1 bash "$INSTALLER" >/dev/null 2>&1
[ "$?" != "0" ] && ok "exits non-zero on malformed settings.json" || bad "exits non-zero on malformed settings.json"
grep -q 'this is not json' "$H/.claude/settings.json" && ok "malformed file left untouched" || bad "malformed file left untouched"
rm -rf "$H"
echo

# --------------------------------------------------------------------------
echo "case 6: the notifier survives every alert kind"
# --------------------------------------------------------------------------
H=$(mktemp -d)
HOME="$H" NO_TEST_TONE=1 bash "$INSTALLER" >/dev/null 2>&1
N="$H/.claude/claude-notify.sh"
for kind in "done" blocked limit error bogus-kind; do
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
printf 'passed %d, failed %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
