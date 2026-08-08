#!/usr/bin/env bash
# Claude Code notifier. Called by the hooks in ~/.claude/settings.json.
#
#   mark     a turn started            records the time, plays nothing
#   done     turn finished             sound
#   blocked  waiting on you            sound + desktop notification
#   limit    usage limit hit           sound + desktop notification
#   error    other API error           sound + desktop notification
#
# Options live in ~/.claude/claude-notify.conf and are re-read on every call,
# so edits take effect immediately. CLAUDE_NOTIFY_DEBUG=1 prints the decision.

KIND="${1:-done}"
CONF="$HOME/.claude/claude-notify.conf"
TMP="${TMPDIR:-/tmp}"
UID_=$(id -u 2>/dev/null || echo 0)

# --- options ------------------------------------------------------------------
# Read, never sourced, so nothing in the config file can be executed.
cfg() {
  local v=""
  if [ -f "$CONF" ]; then
    v=$(sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$CONF" \
        | tail -1 | tr -d '\r' | sed 's/[[:space:]]*$//')
  fi
  if [ -n "$v" ]; then printf '%s' "$v"; else printf '%s' "$2"; fi
}

MIN_SECONDS=$(cfg MIN_SECONDS 30)
SUPPRESS_WHEN_FOCUSED=$(cfg SUPPRESS_WHEN_FOCUSED 1)
PROJECT_PITCH=$(cfg PROJECT_PITCH 1)
SPEAK=$(cfg SPEAK 0)
TOAST_ON_DONE=$(cfg TOAST_ON_DONE 0)
DEBOUNCE_SECONDS=$(cfg DEBOUNCE_SECONDS 2)
ALWAYS_ALERT=$(cfg ALWAYS_ALERT "blocked,limit,error")
MUTE=$(cfg MUTE "")

case "$MIN_SECONDS" in ''|*[!0-9]*) MIN_SECONDS=30 ;; esac
case "$DEBOUNCE_SECONDS" in ''|*[!0-9]*) DEBOUNCE_SECONDS=2 ;; esac

in_list() {  # in_list <needle> <comma,list>
  case ",$(printf '%s' "$2" | tr -d ' ')," in
    *",$1,"*) return 0 ;;
  esac
  return 1
}

# --- read the hook payload ----------------------------------------------------
# Claude Code sends the event JSON on stdin. Every event carries session_id and
# cwd; Notification carries message.
PY=""
for c in python3 python; do
  command -v "$c" >/dev/null 2>&1 && { PY="$c"; break; }
done

DETAIL=""; SESSION=""; CWD=""
if [ ! -t 0 ]; then
  PAYLOAD=$(cat 2>/dev/null || true)
  if [ -n "$PAYLOAD" ] && [ -n "$PY" ]; then
    parsed=$(printf '%s' "$PAYLOAD" | "$PY" -c '
import json, sys
try:
    o = json.load(sys.stdin)
except Exception:
    raise SystemExit(0)
if not isinstance(o, dict):
    raise SystemExit(0)
detail = ""
for f in ("message", "reason", "error_type", "last_assistant_message"):
    v = o.get(f)
    if v:
        detail = str(v).replace("\n", " ")[:180]
        break
print(detail)
print(o.get("session_id", ""))
print(o.get("cwd", ""))
' 2>/dev/null || true)
    DETAIL=$(printf '%s' "$parsed" | sed -n 1p)
    SESSION=$(printf '%s' "$parsed" | sed -n 2p)
    CWD=$(printf '%s' "$parsed" | sed -n 3p)
  fi
fi
[ -n "$SESSION" ] || SESSION="nosession"
STARTFILE="$TMP/claude-notify-start.$UID_.$(printf '%s' "$SESSION" | tr -c 'a-zA-Z0-9_-' '_')"

# --- mark: a turn began -------------------------------------------------------
# This is the whole job of the UserPromptSubmit hook. No sound, no notification.
if [ "$KIND" = "mark" ]; then
  date +%s > "$STARTFILE" 2>/dev/null || true
  [ "${CLAUDE_NOTIFY_DEBUG:-0}" = "1" ] && printf 'kind=mark session=%s\n' "$SESSION"
  exit 0
fi

# --- muted? -------------------------------------------------------------------
if in_list "$KIND" "$MUTE"; then
  [ "${CLAUDE_NOTIFY_DEBUG:-0}" = "1" ] && printf 'kind=%s suppressed=muted\n' "$KIND"
  exit 0
fi

# Kinds you always want to hear about ignore the elapsed and focus checks.
ALWAYS=0
in_list "$KIND" "$ALWAYS_ALERT" && ALWAYS=1

# --- too quick to care? -------------------------------------------------------
ELAPSED=""
if [ -f "$STARTFILE" ]; then
  started=$(cat "$STARTFILE" 2>/dev/null || echo "")
  case "$started" in
    ''|*[!0-9]*) ;;
    *) ELAPSED=$(( $(date +%s) - started )) ;;
  esac
  rm -f "$STARTFILE" 2>/dev/null || true
fi
if [ "$ALWAYS" = "0" ] && [ "$MIN_SECONDS" -gt 0 ] && [ -n "$ELAPSED" ] \
   && [ "$ELAPSED" -lt "$MIN_SECONDS" ]; then
  [ "${CLAUDE_NOTIFY_DEBUG:-0}" = "1" ] \
    && printf 'kind=%s suppressed=too-quick elapsed=%s min=%s\n' "$KIND" "$ELAPSED" "$MIN_SECONDS"
  exit 0
fi

# --- already looking at it? ---------------------------------------------------
# Best effort. Any uncertainty resolves to "not focused", so the failure mode is
# an alert you did not strictly need rather than a missed one.
is_focused() {
  if [ "$(uname -s)" = "Darwin" ]; then
    command -v osascript >/dev/null 2>&1 || return 1
    front=$(osascript -e 'tell application "System Events" to get name of first application process whose frontmost is true' 2>/dev/null || true)
    case "$front" in
      Terminal|iTerm2|WezTerm|Alacritty|kitty|Ghostty|Hyper|Warp|Code|"Visual Studio Code"|Cursor|tmux) return 0 ;;
      *) return 1 ;;
    esac
  fi
  # X11. Wayland has no portable equivalent, so this simply finds no tool and
  # reports "not focused".
  command -v xdotool >/dev/null 2>&1 || return 1
  [ -n "${DISPLAY:-}" ] || return 1
  fg_pid=$(xdotool getactivewindow getwindowpid 2>/dev/null || true)
  case "$fg_pid" in ''|*[!0-9]*) return 1 ;; esac
  # Walk our own ancestry: the notifier's grandparent chain reaches the terminal.
  pid=$$
  for _ in 1 2 3 4 5 6 7 8; do
    [ "$pid" = "$fg_pid" ] && return 0
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    case "$pid" in ''|0|1) break ;; esac
  done
  return 1
}

if [ "$ALWAYS" = "0" ] && [ "$SUPPRESS_WHEN_FOCUSED" = "1" ] && is_focused; then
  [ "${CLAUDE_NOTIFY_DEBUG:-0}" = "1" ] && printf 'kind=%s suppressed=focused\n' "$KIND"
  exit 0
fi

# --- debounce -----------------------------------------------------------------
# Several of these events can fire inside the same second. Without this you get
# a stutter of overlapping audio. Namespaced by uid because /tmp is shared.
STAMP="$TMP/claude-notify.$UID_.last"
NOW=$(date +%s)
if [ -f "$STAMP" ]; then
  LAST=$(cat "$STAMP" 2>/dev/null || echo 0)
  case "$LAST" in ''|*[!0-9]*) LAST=0 ;; esac
  if [ $((NOW - LAST)) -lt "$DEBOUNCE_SECONDS" ]; then
    [ "${CLAUDE_NOTIFY_DEBUG:-0}" = "1" ] && printf 'kind=%s suppressed=debounced\n' "$KIND"
    exit 0
  fi
fi
printf '%s' "$NOW" > "$STAMP" 2>/dev/null || true

# --- pick sound and text ------------------------------------------------------
# Two candidate lists per kind: macOS system sounds, then the freedesktop theme
# most Linux desktops ship. First file that exists wins.
#
# 'limit' and 'error' must not share a first choice, or splitting rate_limit out
# of StopFailure buys nothing audible.
case "$KIND" in
  blocked)
    MAC_SOUNDS="Sosumi Ping Funk"
    FD_SOUNDS="dialog-warning message dialog-information bell"
    TITLE="Claude needs you"
    FALLBACK="Waiting on your input or a permission prompt"
    REPEAT=1
    ;;
  limit)
    MAC_SOUNDS="Basso Bottle Sosumi"
    FD_SOUNDS="suspend-error dialog-warning bell"
    TITLE="Claude hit the usage limit"
    FALLBACK="Rate limited. The turn ended early."
    REPEAT=1
    ;;
  error)
    MAC_SOUNDS="Funk Blow Basso"
    FD_SOUNDS="dialog-error suspend-error dialog-warning bell"
    TITLE="Claude stopped"
    FALLBACK="The turn ended on an API error"
    REPEAT=1
    ;;
  *)
    KIND="done"
    # Several interchangeable chimes, so PROJECT_PITCH has something to choose
    # between. The first is the default when that option is off.
    MAC_SOUNDS="Glass Hero Submarine Tink Pop Purr"
    FD_SOUNDS="complete message bell dialog-information"
    TITLE="Claude is done"
    FALLBACK="Turn finished"
    REPEAT=0
    ;;
esac
[ -n "$DETAIL" ] || DETAIL="$FALLBACK"

# --- play --------------------------------------------------------------------
PLAYER_USED=""   # set by play_file on success; empty means we fell back
PITCH_IDX=0

# Turn the project directory into a stable index, so the same project always
# gets the same chime.
if [ "$PROJECT_PITCH" = "1" ] && [ "$KIND" = "done" ] && [ -n "$CWD" ]; then
  h=$(printf '%s' "$CWD" | cksum 2>/dev/null | tr -d ' ' | sed 's/[^0-9].*$//')
  case "$h" in ''|*[!0-9]*) h=0 ;; esac
  PITCH_IDX=$h
fi

# Rotate a space separated list left by N, so entry N becomes the first choice
# and the rest stay as fallbacks.
rotate() {
  local list="$1" n="$2" count i out=""
  set -- $list
  count=$#
  [ "$count" -gt 0 ] || return 0
  n=$(( n % count ))
  i=0
  for item in "$@"; do
    i=$((i+1))
    [ "$i" -gt "$n" ] && out="$out $item"
  done
  i=0
  for item in "$@"; do
    i=$((i+1))
    [ "$i" -le "$n" ] && out="$out $item"
  done
  printf '%s' "${out# }"
}

if [ "$PITCH_IDX" -gt 0 ]; then
  MAC_SOUNDS=$(rotate "$MAC_SOUNDS" "$PITCH_IDX")
  FD_SOUNDS=$(rotate "$FD_SOUNDS" "$PITCH_IDX")
fi

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

speak() {
  for s in say spd-say espeak espeak-ng; do
    command -v "$s" >/dev/null 2>&1 || continue
    case "$s" in
      say)     "$s" "$1" >/dev/null 2>&1 ;;
      spd-say) "$s" -w "$1" >/dev/null 2>&1 ;;
      *)       "$s" "$1" >/dev/null 2>&1 ;;
    esac
    if [ $? -eq 0 ]; then PLAYER_USED="$s"; return 0; fi
  done
  return 1
}

bell() {
  # Last resort. Goes to the controlling terminal if we have one, otherwise
  # stdout. Hooks often run detached, where opening /dev/tty fails outright.
  { printf '\a' > /dev/tty; } 2>/dev/null || printf '\a'
}

SOUND=""
if [ "$SPEAK" = "1" ]; then
  speak "$TITLE. $DETAIL" || bell
else
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
# CLAUDE_NOTIFY_DEBUG=1 prints the decision instead of staying silent. Useful
# for working out why nothing is audible, and it is what CI asserts on, since a
# zero exit alone cannot distinguish a played sound from a fallback bell.
if [ "${CLAUDE_NOTIFY_DEBUG:-0}" = "1" ]; then
  printf 'kind=%s sound=%s player=%s notified=%s elapsed=%s detail=%s\n' \
    "$KIND" "${SOUND:-none}" "${PLAYER_USED:-bell}" "$NOTIFIED" "${ELAPSED:-na}" "$DETAIL"
fi

exit 0
