#!/usr/bin/env bash
# =============================================================================
#  Claude Code sound alerts - one-shot installer (Linux / macOS)
# =============================================================================
#
#  WHAT IT DOES
#    Makes Claude Code play a sound when it:
#      - finishes a turn                  (soft chime)
#      - needs your input or permission   (alert + desktop notification)
#      - hits your usage limit            (alarm + desktop notification)
#      - dies on any other API error      (alarm + desktop notification)
#
#  HOW TO RUN
#    Read it first, then run it:
#
#      curl -fsSL https://raw.githubusercontent.com/azyzex/ClaudeCodeSounds/main/install-claude-sound-alerts.sh -o install.sh
#      less install.sh
#      bash install.sh
#
#  WHAT IT TOUCHES
#    ~/.claude/claude-notify.sh   created / overwritten
#    ~/.claude/settings.json      backed up, then four hook entries added
#
#  SAFE TO RE-RUN. It replaces its own hook entries and leaves everything
#  else in settings.json alone.
#
#  UNINSTALL
#    bash install.sh --uninstall
# =============================================================================

set -euo pipefail

CLAUDE_DIR="$HOME/.claude"
NOTIFY_SCRIPT="$CLAUDE_DIR/claude-notify.sh"
SETTINGS="$CLAUDE_DIR/settings.json"
MARKER="claude-notify.sh"    # how we recognise our own hook entries

UNINSTALL=0
case "${1:-}" in
  --uninstall|-u) UNINSTALL=1 ;;
  '') ;;
  *) printf 'unknown option: %s\nusage: bash %s [--uninstall]\n' "$1" "$(basename "$0")" >&2; exit 2 ;;
esac

step() { printf '  \033[36m%s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m%s\033[0m\n' "$1"; }
dim()  { printf '  \033[90m%s\033[0m\n' "$1"; }
die()  { printf '  \033[31m%s\033[0m\n' "$1" >&2; exit 1; }

printf '\nClaude Code sound alerts\n------------------------\n'

# The merge below needs a real JSON parser. python3 is the one thing present on
# effectively every Linux distro and every macOS with the developer tools.
PY=""
for c in python3 python; do
  if command -v "$c" >/dev/null 2>&1; then PY="$c"; break; fi
done
[ -n "$PY" ] || die "python3 not found. Install it (it is only needed for this installer, not for the alerts)."

mkdir -p "$CLAUDE_DIR"

if [ -f "$SETTINGS" ]; then
  BACKUP="$SETTINGS.bak-$(date +%Y%m%d-%H%M%S)"
  cp "$SETTINGS" "$BACKUP"
  step "backed up settings.json -> $(basename "$BACKUP")"
fi

# ------------------------------------------------------------ settings.json ---
# Merge rather than replace: any hooks you already have survive. Our own entries
# are stripped first (recognised by the marker), so re-running never stacks
# duplicates and gives you four overlapping chimes.

CLAUDE_SETTINGS="$SETTINGS" \
CLAUDE_MARKER="$MARKER" \
CLAUDE_NOTIFY="$NOTIFY_SCRIPT" \
CLAUDE_UNINSTALL="$UNINSTALL" \
"$PY" <<'PYEOF'
import json, os, sys

settings_path = os.environ['CLAUDE_SETTINGS']
marker        = os.environ['CLAUDE_MARKER']
uninstall     = os.environ['CLAUDE_UNINSTALL'] == '1'

settings = {}
if os.path.exists(settings_path):
    with open(settings_path, encoding='utf-8-sig') as f:
        raw = f.read().strip()
    if raw:
        try:
            settings = json.loads(raw)
        except ValueError as e:
            sys.exit("settings.json is not valid JSON. Fix or move it, then re-run. (%s)" % e)

if not isinstance(settings, dict):
    settings = {}
hooks = settings.get('hooks')
if not isinstance(hooks, dict):
    hooks = settings['hooks'] = {}

# Four lifecycle events. Matcher values come from the hooks reference:
# https://code.claude.com/docs/en/hooks
#
# Stop          has no matcher, it fires on every turn end.
# Notification  filters on notification type.
# StopFailure   filters on error type, which is what lets rate_limit have its
#               own sound instead of being lumped in with every other failure.
WIRING = [
    ('Stop',         'done',    None),
    ('Notification', 'blocked', 'permission_prompt|idle_prompt|agent_needs_input|elicitation_dialog'),
    ('StopFailure',  'limit',   'rate_limit'),
    ('StopFailure',  'error',   'overloaded|authentication_failed|oauth_org_not_allowed|billing_error|'
                                'invalid_request|model_not_found|server_error|max_output_tokens|unknown'),
]

# Elicitation is listed only so the cleanup pass removes it. Notification
# already covers it through the elicitation_dialog matcher.
OUR_EVENTS = ['Stop', 'Notification', 'StopFailure', 'Elicitation']

def is_ours(group):
    return marker in json.dumps(group)

for event in OUR_EVENTS:
    if event in hooks:
        kept = [g for g in hooks[event] if not is_ours(g)]
        if kept:
            hooks[event] = kept
        else:
            del hooks[event]

if not uninstall:
    for event, kind, matcher in WIRING:
        group = {
            'hooks': [{
                'type': 'command',
                # Shell form (no "args"), so sh -c expands $HOME. async keeps
                # Claude from blocking for the length of the audio clip.
                'command': '"$HOME/.claude/claude-notify.sh" %s' % kind,
                'async': True,
                'timeout': 30,
            }]
        }
        if matcher:
            group['matcher'] = matcher
        hooks.setdefault(event, []).append(group)

if not hooks:
    settings.pop('hooks', None)

with open(settings_path, 'w', encoding='utf-8') as f:
    json.dump(settings, f, indent=2)
    f.write('\n')
PYEOF

if [ "$UNINSTALL" = "1" ]; then
  rm -f "$NOTIFY_SCRIPT"
  ok "removed. restart Claude Code."
  printf '\n'
  exit 0
fi

ok "wired 4 hooks into settings.json"

# ----------------------------------------------------- the notifier script ---

cat > "$NOTIFY_SCRIPT" <<'NOTIFYEOF'
#!/usr/bin/env bash
# Claude Code notifier. Called by the hooks in ~/.claude/settings.json.
#
#   done     turn finished          sound only
#   blocked  waiting on you        sound + desktop notification
#   limit    usage limit hit       sound + desktop notification
#   error    other API error       sound + desktop notification
#
# Set TOAST_ON_DONE=1 if you want a notification on every finish too.

KIND="${1:-done}"
TOAST_ON_DONE="${TOAST_ON_DONE:-0}"

# --- debounce ----------------------------------------------------------------
# Several of these events can fire inside the same second. Without this you get
# a stutter of overlapping audio.
# Namespaced by uid: on a shared box /tmp is world-writable and a single shared
# stamp file would let one user's alerts silence another's.
STAMP="${TMPDIR:-/tmp}/claude-notify.$(id -u 2>/dev/null || echo 0).last"
NOW=$(date +%s)
if [ -f "$STAMP" ]; then
  LAST=$(cat "$STAMP" 2>/dev/null || echo 0)
  case "$LAST" in
    ''|*[!0-9]*) LAST=0 ;;
  esac
  [ $((NOW - LAST)) -lt 2 ] && exit 0
fi
printf '%s' "$NOW" > "$STAMP" 2>/dev/null || true

# --- read the hook payload ---------------------------------------------------
# Claude Code sends the event JSON on stdin. Notification events carry .message
DETAIL=""
PY=""
for c in python3 python; do
  command -v "$c" >/dev/null 2>&1 && { PY="$c"; break; }
done
if [ ! -t 0 ]; then
  PAYLOAD=$(cat 2>/dev/null || true)
  # No interpreter is not an error, you just get the generic text for this kind.
  if [ -n "$PAYLOAD" ] && [ -n "$PY" ]; then
    DETAIL=$(printf '%s' "$PAYLOAD" | "$PY" -c '
import json, sys
try:
    o = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for f in ("message", "reason", "error_type", "last_assistant_message"):
    v = o.get(f) if isinstance(o, dict) else None
    if v:
        print(str(v).replace("\n", " ")[:180])
        break
' 2>/dev/null || true)
  fi
fi

# --- pick sound and text -----------------------------------------------------
# Two candidate lists per kind: macOS system sounds, then the freedesktop sound
# theme used by most Linux desktops. First file that exists wins.
case "$KIND" in
  blocked)
    MAC_SOUNDS="Sosumi Ping Funk"
    FD_SOUNDS="dialog-warning message dialog-information bell"
    TITLE="Claude needs you"
    FALLBACK="Waiting on your input or a permission prompt"
    REPEAT=1
    ;;
  limit)
    MAC_SOUNDS="Basso Sosumi Funk"
    FD_SOUNDS="suspend-error dialog-error dialog-warning bell"
    TITLE="Claude hit the usage limit"
    FALLBACK="Rate limited. The turn ended early."
    REPEAT=1
    ;;
  error)
    MAC_SOUNDS="Basso Funk Sosumi"
    FD_SOUNDS="dialog-error suspend-error dialog-warning bell"
    TITLE="Claude stopped"
    FALLBACK="The turn ended on an API error"
    REPEAT=1
    ;;
  *)
    KIND="done"
    MAC_SOUNDS="Glass Ping Hero Submarine"
    FD_SOUNDS="complete message dialog-information bell"
    TITLE="Claude is done"
    FALLBACK="Turn finished"
    REPEAT=0
    ;;
esac
[ -n "$DETAIL" ] || DETAIL="$FALLBACK"

# --- play --------------------------------------------------------------------
PLAYER_USED=""   # set by play_file on success; stays empty if we fell back to the bell

find_sound() {
  if [ "$(uname -s)" = "Darwin" ]; then
    for n in $MAC_SOUNDS; do
      for d in "$HOME/Library/Sounds" /System/Library/Sounds; do
        [ -f "$d/$n.aiff" ] && { printf '%s' "$d/$n.aiff"; return 0; }
      done
    done
  fi
  for n in $FD_SOUNDS; do
    for d in /usr/share/sounds/freedesktop/stereo \
             /usr/share/sounds/gnome/default/alerts \
             /usr/share/sounds/ubuntu/stereo \
             /usr/share/sounds; do
      for ext in oga ogg wav; do
        [ -f "$d/$n.$ext" ] && { printf '%s' "$d/$n.$ext"; return 0; }
      done
    done
  done
  return 1
}

play_file() {
  # afplay on macOS; on Linux prefer the players that handle .oga.
  #
  # A player being installed does not mean it works. paplay ships on plenty of
  # ALSA-only and headless boxes and just fails, and pw-play fails wherever
  # PipeWire is not the running server. So a failure has to fall through to the
  # next candidate rather than give up on the whole chain.
  for p in afplay paplay pw-play canberra-gtk-play ffplay aplay; do
    command -v "$p" >/dev/null 2>&1 || continue
    case "$p" in
      canberra-gtk-play) "$p" -f "$1" >/dev/null 2>&1 ;;
      ffplay)            "$p" -nodisp -autoexit -loglevel quiet "$1" >/dev/null 2>&1 ;;
      aplay)             case "$1" in *.wav) "$p" -q "$1" >/dev/null 2>&1 ;; *) false ;; esac ;;
      *)                 "$p" "$1" >/dev/null 2>&1 ;;
    esac
    if [ $? -eq 0 ]; then PLAYER_USED="$p"; return 0; fi
  done
  return 1
}

bell() {
  # Last resort. Goes to the controlling terminal if we have one, otherwise
  # stdout. Hooks often run detached, where opening /dev/tty fails outright.
  { printf '\a' > /dev/tty; } 2>/dev/null || printf '\a'
}

SOUND=$(find_sound || true)
if [ -n "$SOUND" ] && play_file "$SOUND"; then
  if [ "$REPEAT" = "1" ]; then
    sleep 0.22
    play_file "$SOUND" || true
  fi
else
  bell
  if [ "$REPEAT" = "1" ]; then sleep 0.12; bell; fi
fi

# --- desktop notification ----------------------------------------------------
NOTIFIED=no
if [ "$KIND" != "done" ] || [ "$TOAST_ON_DONE" = "1" ]; then
  if [ "$(uname -s)" = "Darwin" ]; then
    if command -v terminal-notifier >/dev/null 2>&1; then
      terminal-notifier -title "$TITLE" -message "$DETAIL" >/dev/null 2>&1 && NOTIFIED=terminal-notifier
    elif command -v osascript >/dev/null 2>&1; then
      # Escape backslashes and double quotes for AppleScript.
      esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
      osascript -e "display notification \"$(esc "$DETAIL")\" with title \"$(esc "$TITLE")\"" \
        >/dev/null 2>&1 && NOTIFIED=osascript
    fi
  elif command -v notify-send >/dev/null 2>&1; then
    case "$KIND" in
      done) URGENCY=low ;;
      *)    URGENCY=critical ;;
    esac
    # -t is ignored by some daemons; harmless where it is.
    notify-send -a "Claude Code" -u "$URGENCY" -t 8000 "$TITLE" "$DETAIL" >/dev/null 2>&1 \
      && NOTIFIED=notify-send
  fi
fi

# --- report ------------------------------------------------------------------
# CLAUDE_NOTIFY_DEBUG=1 prints the decision it reached instead of staying silent.
# Useful for working out why nothing is audible, and it is what CI asserts on,
# since a zero exit alone cannot distinguish a played sound from a fallback bell.
if [ "${CLAUDE_NOTIFY_DEBUG:-0}" = "1" ]; then
  printf 'kind=%s sound=%s player=%s notified=%s detail=%s\n' \
    "$KIND" "${SOUND:-none}" "${PLAYER_USED:-bell}" "$NOTIFIED" "$DETAIL"
fi

exit 0
NOTIFYEOF

chmod +x "$NOTIFY_SCRIPT"
ok "wrote $NOTIFY_SCRIPT"

# --------------------------------------------------------------------- test ---

printf '\n'
# NO_TEST_TONE=1 skips this, for unattended installs and CI.
if [ "${NO_TEST_TONE:-0}" = "1" ]; then
  step "test tone skipped (NO_TEST_TONE=1)"
else
  step "test tone..."
  rm -f "${TMPDIR:-/tmp}/claude-notify.$(id -u 2>/dev/null || echo 0).last"
  # "done" is quoted so it does not read as the shell keyword (shellcheck SC1010).
  "$NOTIFY_SCRIPT" "done" </dev/null || true
fi

printf '\n'
ok "Done. Restart Claude Code, then run /hooks to confirm all four are listed."
dim 'Silence everything:  set "disableAllHooks": true in settings.json'
dim 'Nothing firing?      run claude --debug and watch the hook lines'
dim 'No sound on Linux?   install the sound theme: sudo apt install sound-theme-freedesktop libcanberra-gtk-module'
printf '\n'
