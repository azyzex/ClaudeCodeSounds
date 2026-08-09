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

# Wait for something to actually happen rather than sleeping a fixed time. CI
# machines have real audio, so a notifier call takes noticeably longer there
# than on a box where playback falls straight through to a bell.
wait_for() {  # wait_for <seconds> <shell test>
  _deadline=$(( $(date +%s) + $1 ))
  shift
  while [ "$(date +%s)" -lt "$_deadline" ]; do
    if eval "$*"; then return 0; fi
    sleep 1
  done
  return 1
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

# The focus check would otherwise suppress every 'done' when these tests run
# from a focused terminal, and not on CI, which has no foreground window. Off,
# so the results do not depend on where the test happens to run.
setconf SUPPRESS_WHEN_FOCUSED 0

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

echo "  (phone push is off unless a topic is set)"
# Not dry run: the push is deliberately skipped there, so it has to be checked
# on the real path. There is no topic, so nothing leaves the machine.
pushfield() {
  rm -f "${TMPDIR:-/tmp}"/claude-notify.*.last
  # CLAUDE_NOTIFY_DRYRUN=0 overrides the export this case sets: the push is
  # deliberately skipped in a dry run and would never be exercised otherwise.
  out=$(printf '{}' | HOME="$H" CLAUDE_NOTIFY_DRYRUN=0 CLAUDE_NOTIFY_FORCE=1 \
    CLAUDE_NOTIFY_DEBUG=1 bash "$N" "$1" 2>/dev/null | tr -d '\r')
  field "$out" pushed
}
check "$(pushfield blocked)" "no" "no topic means no push"
# A topic pointed at a port nothing is listening on: queued, but the alert still
# completes, because an unreachable phone must not cost you the local alert.
setconf NTFY_TOPIC "test-topic"
setconf NTFY_SERVER "http://127.0.0.1:9"
check "$(pushfield blocked)" "queued" "a topic queues a push"
check "$(pushfield "done")" "no" "finished turns are not pushed by default"
setconf NTFY_ALERTS "done,blocked,limit,error"
check "$(pushfield "done")" "queued" "NTFY_ALERTS controls which kinds push"
setconf NTFY_TOPIC ""
setconf NTFY_ALERTS "blocked,limit,error"

echo "  (a temporary mute expires by itself)"
setconf MUTE_UNTIL "$(( $(date +%s) + 3600 ))"
r=$(decide blocked)
case "$r" in *suppressed=quiet-until*) ok "a future MUTE_UNTIL silences everything" ;; *) bad "expected quiet-until, got: $r" ;; esac
setconf MUTE_UNTIL "1"
r=$(decide blocked)
case "$r" in *suppressed=quiet-until*) bad "an expired mute still silenced: $r" ;; *) ok "an expired MUTE_UNTIL is ignored" ;; esac
setconf MUTE_UNTIL "not-a-time"
r=$(decide blocked)
case "$r" in *suppressed=quiet-until*) bad "garbage silenced everything: $r" ;; *) ok "an unparseable MUTE_UNTIL is ignored" ;; esac
setconf MUTE_UNTIL ""

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
echo "  (bundled sounds)"
setconf DONE_SOUND ""   # the previous case pointed this at a custom file
n_sounds=$(find "$H/.claude/claude-sounds" -name '*.wav' 2>/dev/null | wc -l | tr -d ' ')
[ "$n_sounds" -ge 9 ] && ok "the installer wrote $n_sounds sounds" || bad "expected 9 bundled sounds, found $n_sounds"
"$PY" - "$H/.claude/claude-sounds" <<'PYEOF' && ok "every bundled sound is a valid WAV" || bad "a bundled sound is not valid"
import glob, os, sys, wave
for f in sorted(glob.glob(os.path.join(sys.argv[1], '*', '*.wav'))):
    w = wave.open(f)
    assert w.getnchannels() == 1 and w.getsampwidth() == 2 and w.getnframes() > 1000, f
    w.close()
PYEOF

# The whole point of bundling: no system sound theme, still real audio. Every
# kind must resolve to a bundled file rather than falling through to the bell.
for k in "done" blocked limit error; do
  got=$(field "$(decide "$k")" sound)
  case "$got" in
    */claude-sounds/*.wav) ok "$k resolves to a bundled sound" ;;
    *) bad "$k did not use a bundled sound (got '$got')" ;;
  esac
done

# Distinct sounds are what make four events worth having.
# tr strips the padding BSD wc adds, which GNU wc does not.
sounds=$(for k in "done" blocked limit error; do basename "$(field "$(decide "$k")" sound)"; done \
         | sort -u | wc -l | tr -d ' ')
check "$sounds" "4" "the four kinds resolve to four different sounds"

echo "  (sound packs)"
[ -d "$H/.claude/claude-sounds/default" ] && ok "the default pack is a folder" || bad "expected claude-sounds/default/"
got=$(field "$(decide "done")" sound)
case "$got" in
  */claude-sounds/default/*) ok "sounds resolve from the default pack" ;;
  *) bad "expected the default pack (got '$got')" ;;
esac

# A pack is just a folder, so one file is enough to override that one sound.
mkdir -p "$H/.claude/claude-sounds/retro"
cp "$H/.claude/claude-sounds/default/alert-limit.wav" "$H/.claude/claude-sounds/retro/chime-glass.wav"
setconf SOUND_PACK retro
got=$(field "$(decide "done")" sound)
case "$got" in
  */retro/chime-glass.wav) ok "the selected pack takes precedence" ;;
  *) bad "pack not used (got '$got')" ;;
esac
# The pack has no alert-attention, so that one must fall back rather than vanish.
got=$(field "$(decide blocked)" sound)
case "$got" in
  */default/alert-attention.wav) ok "a partial pack falls back to default per sound" ;;
  *) bad "expected a default fallback (got '$got')" ;;
esac

# A pack name is a directory component, never a path.
setconf SOUND_PACK "../../../etc"
got=$(field "$(decide "done")" sound)
case "$got" in
  */claude-sounds/default/*) ok "a traversal in the pack name is refused" ;;
  *) bad "traversal not refused (got '$got')" ;;
esac
setconf SOUND_PACK default

unset CLAUDE_NOTIFY_DRYRUN
rm -rf "$H"
echo

# --------------------------------------------------------------------------
echo "case 9: the claude-sounds command"
# --------------------------------------------------------------------------
H=$(mktemp -d)
HOME="$H" NO_TEST_TONE=1 NONINTERACTIVE=1 bash "$INSTALLER" >/dev/null 2>&1
CLI="$H/.claude/claude-sounds-cli"
[ -x "$CLI" ] && ok "the installer wrote an executable cli" || bad "cli missing or not executable"

out=$(HOME="$H" bash "$CLI" status 2>&1)
check "$?" "0" "status exits 0"
case "$out" in *"5 hooks registered"*) ok "status sees the hooks" ;; *) bad "status did not report hooks: $out" ;; esac
case "$out" in *"9 sounds installed"*) ok "status sees the sounds" ;; *) bad "status did not report sounds" ;; esac

# The question status exists to answer is "why is nothing happening", so the
# things that silence alerts have to show up in it.
HOME="$H" bash "$CLI" mute 45m >/dev/null 2>&1
check "$?" "0" "mute exits 0"
out=$(HOME="$H" bash "$CLI" status 2>&1)
case "$out" in *"temporarily muted"*) ok "status reports an active mute" ;; *) bad "an active mute was not reported" ;; esac
HOME="$H" bash "$CLI" mute off >/dev/null 2>&1
out=$(HOME="$H" bash "$CLI" status 2>&1)
case "$out" in *"temporarily muted"*) bad "the mute was not cleared" ;; *) ok "mute off clears it" ;; esac

# A mute written by the cli must be one the notifier honours: the two agree on
# the file, or the command is lying to you.
HOME="$H" bash "$CLI" mute 30m >/dev/null 2>&1
rm -f "${TMPDIR:-/tmp}"/claude-notify.*.last
r=$(printf '{}' | HOME="$H" CLAUDE_NOTIFY_DEBUG=1 bash "$H/.claude/claude-notify.sh" blocked 2>/dev/null | tr -d '\r')
case "$r" in *suppressed=quiet-until*) ok "the notifier honours a mute set by the cli" ;; *) bad "notifier ignored the cli mute: $r" ;; esac
HOME="$H" bash "$CLI" mute off >/dev/null 2>&1

HOME="$H" bash "$CLI" stats >/dev/null 2>&1
check "$?" "0" "stats exits 0"
HOME="$H" bash "$CLI" log >/dev/null 2>&1
check "$?" "0" "log exits 0"
HOME="$H" bash "$CLI" nonsense >/dev/null 2>&1
[ "$?" = "2" ] && ok "an unknown command exits 2" || bad "an unknown command should exit 2"
rm -rf "$H"
echo

# --------------------------------------------------------------------------
echo "case 10: limit resets, from the figures Claude Code reports"
# --------------------------------------------------------------------------
H=$(mktemp -d)
HOME="$H" NO_TEST_TONE=1 NONINTERACTIVE=1 bash "$INSTALLER" >/dev/null 2>&1
N="$H/.claude/claude-notify.sh"
C="$H/.claude/claude-notify.conf"
SL="$H/.claude/claude-sounds-statusline.sh"
export CLAUDE_NOTIFY_DRYRUN=0

echo "  (the status line is installed and registered)"
[ -x "$SL" ] && ok "the status line script was written" || bad "no status line script"
grep -q 'claude-sounds-statusline' "$H/.claude/settings.json" \
  && ok "registered in settings.json" || bad "not registered"

echo "  (it reads the real reset times out of the session data)"
future=$(( $(date +%s) + 4000 ))
printf '{"model":{"display_name":"Opus"},"workspace":{"current_dir":"/x/proj"},"rate_limits":{"five_hour":{"used_percentage":43.5,"resets_at":%s},"seven_day":{"used_percentage":12,"resets_at":%s}}}' \
  "$future" "$(( future + 90000 ))" | HOME="$H" bash "$SL" > "$H/bar.txt" 2>/dev/null
[ -f "$H/.claude/claude-limits.json" ] && ok "the reset times were saved" || bad "nothing was saved"
check "$(sed -n 's/^five_hour_resets_at=//p' "$H/.claude/claude-limits.json")" "$future" "the five hour reset was recorded"
check "$(sed -n 's/^five_hour_used=//p' "$H/.claude/claude-limits.json")" "43.5" "usage was recorded too"
grep -q '43% used' "$H/bar.txt" && ok "the bar shows usage" || bad "the bar is missing usage: $(cat "$H/bar.txt")"

echo "  (nothing fires while the reset is still ahead)"
before=$(cat "$H/.claude/claude-notify.log" 2>/dev/null | wc -l | tr -d " ")
rm -f "$H/.claude/claude-watch-alive"
HOME="$H" timeout 5 bash "$N" watch >/dev/null 2>&1 || true
after=$(cat "$H/.claude/claude-notify.log" 2>/dev/null | wc -l | tr -d " ")
check "$after" "$before" "silent until the time arrives"

echo "  (it fires when the reset time passes, with no limit ever hit)"
past=$(( $(date +%s) - 5 ))
printf 'updated=%s\nfive_hour_resets_at=%s\nseven_day_resets_at=%s\n' "$(date +%s)" "$past" "$past" \
  > "$H/.claude/claude-limits.json"
rm -f "$H/.claude/claude-watch-alive" "${TMPDIR:-/tmp}"/claude-notify.*.last
HOME="$H" bash "$N" watch >/dev/null 2>&1
grep -q 'kind=limit-reset' "$H/.claude/claude-notify.log" && ok "the five hour reset fired" || bad "no limit-reset"
grep -q 'kind=weekly-reset' "$H/.claude/claude-notify.log" && ok "the seven day reset fired too" || bad "no weekly-reset"
grep -q 'has reset' "$H/.claude/claude-notify.log" && ok "worded as fact, not an estimate" || bad "still worded as an estimate"

echo "  (each reset is announced once and only once)"
n1=$(wc -l < "$H/.claude/claude-notify.log")
rm -f "$H/.claude/claude-watch-alive" "${TMPDIR:-/tmp}"/claude-notify.*.last
HOME="$H" bash "$N" watch >/dev/null 2>&1
check "$(wc -l < "$H/.claude/claude-notify.log")" "$n1" "a second pass stays silent"

echo "  (a new reset time is a new announcement)"
newer=$(( $(date +%s) - 1 ))
printf 'updated=%s\nfive_hour_resets_at=%s\n' "$(date +%s)" "$newer" > "$H/.claude/claude-limits.json"
rm -f "$H/.claude/claude-watch-alive" "${TMPDIR:-/tmp}"/claude-notify.*.last
HOME="$H" bash "$N" watch >/dev/null 2>&1
[ "$(wc -l < "$H/.claude/claude-notify.log")" -gt "$n1" ] && ok "the next window is announced" || bad "a new reset was missed"

echo "  (a status line you already had is never overwritten)"
"$PY" - "$H/.claude/settings.json" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1], encoding='utf-8-sig'))
d['statusLine'] = {'type': 'command', 'command': 'my-own-bar.sh'}
json.dump(d, open(sys.argv[1], 'w', encoding='utf-8'), indent=2)
PYEOF
HOME="$H" NO_TEST_TONE=1 NONINTERACTIVE=1 bash "$INSTALLER" >/dev/null 2>&1
grep -q 'my-own-bar.sh' "$H/.claude/settings.json" && ok "yours is left alone" || bad "yours was overwritten"
HOME="$H" bash "$INSTALLER" --uninstall >/dev/null 2>&1
grep -q 'my-own-bar.sh' "$H/.claude/settings.json" && ok "and survives uninstall" || bad "uninstall removed yours"

unset CLAUDE_NOTIFY_DRYRUN
rm -rf "$H"
echo

# --------------------------------------------------------------------------
printf 'passed %d, failed %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
