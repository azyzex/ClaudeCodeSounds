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
SOUND_DIR="$HOME/.claude/claude-sounds"
TMP="${TMPDIR:-/tmp}"
UID_=$(id -u 2>/dev/null || echo 0)

# Normalise up front, so the per-event option lookups below cannot be fed an
# arbitrary string from the command line.
case "$KIND" in
  mark|done|blocked|limit|error) ;;
  *) KIND="done" ;;
esac

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
QUIET_HOURS=$(cfg QUIET_HOURS "")
MUTE_UNTIL=$(cfg MUTE_UNTIL "")
NTFY_TOPIC=$(cfg NTFY_TOPIC "")
NTFY_SERVER=$(cfg NTFY_SERVER "https://ntfy.sh")
NTFY_ALERTS=$(cfg NTFY_ALERTS "blocked,limit,error")
SOUND_PACK=$(cfg SOUND_PACK "default")
# A pack name is a single directory component, never a path.
case "$SOUND_PACK" in ""|*/*|.*) SOUND_PACK="default" ;; esac

# Per-event options, keyed by the uppercased kind: DONE_VOLUME, BLOCKED_PATTERN
# and so on. Flat keys rather than sections, so the parser above stays a single
# sed expression and a v1.1.0 config keeps working untouched.
KIND_UC=$(printf '%s' "$KIND" | tr 'a-z' 'A-Z')
EV_ENABLED=$(cfg "${KIND_UC}_ENABLED" 1)
EV_VOLUME=$(cfg "${KIND_UC}_VOLUME" 100)
EV_SOUND=$(cfg "${KIND_UC}_SOUND" "")

# How many times to play, and how far apart. "2" means twice at the default
# spacing; "3x120" means three times, 120ms apart. Rhythm carries further than
# pitch when you are not paying attention.
case "$KIND" in
  done) EV_PATTERN=$(cfg "DONE_PATTERN" "1") ;;
  *)    EV_PATTERN=$(cfg "${KIND_UC}_PATTERN" "2") ;;
esac

case "$MIN_SECONDS" in ''|*[!0-9]*) MIN_SECONDS=30 ;; esac
case "$DEBOUNCE_SECONDS" in ''|*[!0-9]*) DEBOUNCE_SECONDS=2 ;; esac
case "$EV_VOLUME" in ''|*[!0-9]*) EV_VOLUME=100 ;; esac
[ "$EV_VOLUME" -gt 100 ] 2>/dev/null && EV_VOLUME=100

# Split "3x120" into count and gap.
REPEAT_COUNT=$(printf '%s' "$EV_PATTERN" | cut -d x -f 1)
REPEAT_GAP=$(printf '%s' "$EV_PATTERN" | cut -s -d x -f 2)
case "$REPEAT_COUNT" in ''|*[!0-9]*) REPEAT_COUNT=1 ;; esac
case "$REPEAT_GAP"   in ''|*[!0-9]*) REPEAT_GAP=220 ;; esac
[ "$REPEAT_COUNT" -lt 1 ] && REPEAT_COUNT=1
[ "$REPEAT_COUNT" -gt 6 ] && REPEAT_COUNT=6

in_list() {  # in_list <needle> <comma,list>
  case ",$(printf '%s' "$2" | tr -d ' ')," in
    *",$1,"*) return 0 ;;
  esac
  return 1
}

LOGFILE="$HOME/.claude/claude-notify.log"
CLAUDE_DIR_ESC="$HOME/.claude"

# Record what was decided. Every exit path goes through this, so the log and the
# debug output can never disagree. It never fails the alert: a log that cannot
# be written is not worth losing a notification over.
record() {
  # Only when the directory is already there. The notifier can be pointed at a
  # HOME that was never installed into, and creating directories under it would
  # be a surprising thing for a notification to do.
  if [ "${CLAUDE_NOTIFY_DRYRUN:-0}" != "1" ] && [ -d "${LOGFILE%/*}" ]; then
    # Trim before appending so the file cannot grow without bound. 64KB is a few
    # thousand alerts, far more than anything ever displays.
    # Guarded on the file existing: an input redirection that cannot open its
    # target is reported by the shell itself, which 2>/dev/null on the command
    # does not suppress.
    if [ -f "$LOGFILE" ]; then
      size=$(wc -c < "$LOGFILE" 2>/dev/null | tr -d ' ')
      case "$size" in
        ''|*[!0-9]*) ;;
        *) if [ "$size" -gt 65536 ]; then
             { tail -n 200 "$LOGFILE" > "$LOGFILE.tmp"; } 2>/dev/null \
               && mv "$LOGFILE.tmp" "$LOGFILE" 2>/dev/null
           fi ;;
      esac
    fi
    # Braces, so the shell's own redirection failure is suppressed too. A
    # redirect that cannot open its target is reported by the shell rather than
    # by the command, and this must never write to stderr.
    { printf '%s|%s\n' "$(date +%s)" "$1" >> "$LOGFILE"; } 2>/dev/null || true
  fi
  if [ "${CLAUDE_NOTIFY_DEBUG:-0}" = "1" ]; then printf '%s\n' "$1"; fi
  return 0
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
  record "kind=mark session=$SESSION"
  exit 0
fi

# CLAUDE_NOTIFY_FORCE=1 plays the alert regardless of every suppression rule
# below. The desktop app uses it for its preview button: you are tuning these
# settings, so the preview must not be silenced by them.
FORCE="${CLAUDE_NOTIFY_FORCE:-0}"

# --- muted? -------------------------------------------------------------------
if [ "$FORCE" != "1" ] && { in_list "$KIND" "$MUTE" || [ "$EV_ENABLED" = "0" ]; }; then
  record "kind=$KIND suppressed=muted"
  exit 0
fi

# --- temporarily muted? -------------------------------------------------------
# MUTE_UNTIL is an epoch second. The app's "quiet for an hour" writes one, and
# it expires by itself, so a mute you forget about cannot silence things
# permanently the way a plain flag would.
if [ "$FORCE" != "1" ]; then
  case "$MUTE_UNTIL" in
    ''|*[!0-9]*) ;;
    *) if [ "$(date +%s)" -lt "$MUTE_UNTIL" ]; then
         record "kind=$KIND suppressed=quiet-until until=$MUTE_UNTIL"
         exit 0
       fi ;;
  esac
fi

# --- quiet hours? -------------------------------------------------------------
# QUIET_HOURS=23:00-08:00, and windows that wrap past midnight are handled.
# This lives in the config rather than in a resident process, so it works
# whether or not anything else is running.
if [ "$FORCE" != "1" ] && [ -n "$QUIET_HOURS" ]; then
  qh_now=$(date +%H%M | sed 's/^0*//'); [ -n "$qh_now" ] || qh_now=0
  qh_from=$(printf '%s' "$QUIET_HOURS" | cut -d- -f1 | tr -d ': ' | sed 's/^0*//')
  qh_to=$(printf '%s'   "$QUIET_HOURS" | cut -s -d- -f2 | tr -d ': ' | sed 's/^0*//')
  [ -n "$qh_from" ] || qh_from=0
  [ -n "$qh_to" ] || qh_to=0
  case "$qh_from$qh_to" in
    *[!0-9]*) ;;   # unparseable, so ignore it rather than silencing everything
    *)
      qh_quiet=0
      if [ "$qh_from" -le "$qh_to" ]; then
        [ "$qh_now" -ge "$qh_from" ] && [ "$qh_now" -lt "$qh_to" ] && qh_quiet=1
      else
        # Wraps midnight, so either side of the boundary counts.
        { [ "$qh_now" -ge "$qh_from" ] || [ "$qh_now" -lt "$qh_to" ]; } && qh_quiet=1
      fi
      if [ "$qh_quiet" = "1" ]; then
        record "kind=$KIND suppressed=quiet-hours window=$QUIET_HOURS"
        exit 0
      fi
      ;;
  esac
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
if [ "$FORCE" != "1" ] && [ "$ALWAYS" = "0" ] && [ "$MIN_SECONDS" -gt 0 ] && [ -n "$ELAPSED" ] \
   && [ "$ELAPSED" -lt "$MIN_SECONDS" ]; then
  record "kind=$KIND suppressed=too-quick elapsed=$ELAPSED min=$MIN_SECONDS"
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

if [ "$FORCE" != "1" ] && [ "$ALWAYS" = "0" ] && [ "$SUPPRESS_WHEN_FOCUSED" = "1" ] && is_focused; then
  record "kind=$KIND suppressed=focused"
  exit 0
fi

# --- debounce -----------------------------------------------------------------
# Several of these events can fire inside the same second. Without this you get
# a stutter of overlapping audio. Namespaced by uid because /tmp is shared.
STAMP="$TMP/claude-notify.$UID_.last"
NOW=$(date +%s)
if [ "$FORCE" != "1" ] && [ -f "$STAMP" ]; then
  LAST=$(cat "$STAMP" 2>/dev/null || echo 0)
  case "$LAST" in ''|*[!0-9]*) LAST=0 ;; esac
  if [ $((NOW - LAST)) -lt "$DEBOUNCE_SECONDS" ]; then
    record "kind=$KIND suppressed=debounced"
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
    BUNDLED_SOUNDS="alert-attention"
    MAC_SOUNDS="Sosumi Ping Funk"
    FD_SOUNDS="dialog-warning message dialog-information bell"
    TITLE="Claude needs you"
    FALLBACK="Waiting on your input or a permission prompt"
    ;;
  limit)
    BUNDLED_SOUNDS="alert-limit"
    MAC_SOUNDS="Basso Bottle Sosumi"
    FD_SOUNDS="suspend-error dialog-warning bell"
    TITLE="Claude hit the usage limit"
    FALLBACK="Rate limited. The turn ended early."
    ;;
  error)
    BUNDLED_SOUNDS="alert-error"
    MAC_SOUNDS="Funk Blow Basso"
    FD_SOUNDS="dialog-error suspend-error dialog-warning bell"
    TITLE="Claude stopped"
    FALLBACK="The turn ended on an API error"
    ;;
  *)
    # Several interchangeable chimes, so PROJECT_PITCH has something to choose
    # between. The first is the default when that option is off.
    BUNDLED_SOUNDS="chime-glass chime-soft chime-bright chime-low chime-warm chime-mid"
    MAC_SOUNDS="Glass Hero Submarine Tink Pop Purr"
    FD_SOUNDS="complete message bell dialog-information"
    TITLE="Claude is done"
    FALLBACK="Turn finished"
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
  BUNDLED_SOUNDS=$(rotate "$BUNDLED_SOUNDS" "$PITCH_IDX")
  MAC_SOUNDS=$(rotate "$MAC_SOUNDS" "$PITCH_IDX")
  FD_SOUNDS=$(rotate "$FD_SOUNDS" "$PITCH_IDX")
fi

find_sound() {
  # Bundled sounds first. They are the same on every machine, which is what
  # makes the alerts consistent and PROJECT_PITCH meaningful. The system themes
  # below stay as a fallback for anyone who deletes them.
  # Selected pack, then default, then the flat layout used before packs existed.
  for d in "$SOUND_DIR/$SOUND_PACK" "$SOUND_DIR/default" "$SOUND_DIR"; do
    for n in $BUNDLED_SOUNDS; do
      [ -f "$d/$n.wav" ] && { printf '%s' "$d/$n.wav"; return 0; }
    done
  done

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
  #
  # Each player spells volume differently, and aplay and canberra cannot set it
  # at all, so those two simply play at the system level.
  for p in afplay paplay pw-play canberra-gtk-play ffplay aplay; do
    command -v "$p" >/dev/null 2>&1 || continue
    case "$p" in
      afplay)            "$p" -v "$(vol_frac)" "$1" >/dev/null 2>&1 ;;
      paplay)            "$p" "--volume=$(( EV_VOLUME * 65536 / 100 ))" "$1" >/dev/null 2>&1 ;;
      pw-play)           "$p" "--volume=$(vol_frac)" "$1" >/dev/null 2>&1 ;;
      canberra-gtk-play) "$p" -f "$1" >/dev/null 2>&1 ;;
      ffplay)            "$p" -nodisp -autoexit -loglevel quiet -volume "$EV_VOLUME" "$1" >/dev/null 2>&1 ;;
      aplay)             case "$1" in *.wav) "$p" -q "$1" >/dev/null 2>&1 ;; *) false ;; esac ;;
    esac
    if [ $? -eq 0 ]; then PLAYER_USED="$p"; return 0; fi
  done
  return 1
}

# Volume as a 0.00-1.00 fraction, for the players that want it that way.
# Done with integer arithmetic, because there is no floating point in POSIX sh.
vol_frac() {
  printf '%d.%02d' $(( EV_VOLUME / 100 )) $(( EV_VOLUME % 100 ))
}

# Play the alert REPEAT_COUNT times, REPEAT_GAP milliseconds apart.
play_pattern() {
  i=1
  while [ "$i" -le "$REPEAT_COUNT" ]; do
    if [ "$i" -gt 1 ]; then
      # Split into whole seconds and milliseconds, so a gap of 1200 is 1.200
      # rather than 0.1200.
      sleep "$(printf '%d.%03d' $(( REPEAT_GAP / 1000 )) $(( REPEAT_GAP % 1000 )))" \
        2>/dev/null || sleep 1
    fi
    "$@" || return 1
    i=$((i + 1))
  done
  return 0
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
if [ "${CLAUDE_NOTIFY_DRYRUN:-0}" = "1" ]; then
  # Resolve everything and report it, but make no sound and raise no
  # notification. Used by the tests, and by anything that wants to know what
  # would happen without actually interrupting the user.
  if [ -n "$EV_SOUND" ] && [ -f "$EV_SOUND" ]; then SOUND="$EV_SOUND"
  else SOUND=$(find_sound || true); fi
  PLAYER_USED="dryrun"
elif [ "$SPEAK" = "1" ]; then
  # Speech is read once regardless of the pattern: repeating a sentence is
  # irritating rather than informative.
  speak "$TITLE. $DETAIL" || bell
else
  # An explicit per-event sound wins over the candidate lists, so someone can
  # point a kind at their own file without editing this script.
  if [ -n "$EV_SOUND" ] && [ -f "$EV_SOUND" ]; then
    SOUND="$EV_SOUND"
  else
    SOUND=$(find_sound || true)
  fi

  if [ -n "$SOUND" ] && play_pattern play_file "$SOUND"; then
    :
  else
    play_pattern bell
  fi
fi

# --- desktop notification ----------------------------------------------------
NOTIFIED=no
if [ "${CLAUDE_NOTIFY_DRYRUN:-0}" = "1" ]; then
  :
elif [ "$KIND" != "done" ] || [ "$TOAST_ON_DONE" = "1" ]; then
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

# --- push to a phone ----------------------------------------------------------
# ntfy.sh needs no account or API key: the topic name is the whole address, and
# also the whole secret, so it is off unless someone sets one.
#
# Backgrounded and time limited, because a notification must never make Claude
# Code wait on the network, and a phone that is unreachable is not a reason to
# lose the local alert that already happened.
PUSHED=no
if [ -n "$NTFY_TOPIC" ] && [ "${CLAUDE_NOTIFY_DRYRUN:-0}" != "1" ]    && in_list "$KIND" "$NTFY_ALERTS" && command -v curl >/dev/null 2>&1; then
  ( curl -fsS -m 8       -H "Title: $TITLE"       -H "Priority: $([ "$KIND" = "done" ] && echo default || echo high)"       -H "Tags: bell"       -d "$DETAIL"       "$NTFY_SERVER/$NTFY_TOPIC" >/dev/null 2>&1 & ) 2>/dev/null
  PUSHED=queued
fi

# --- leave a marker for escalation --------------------------------------------
# A hook exits at once, so it cannot wait to see whether you responded. It just
# records that a prompt is outstanding; the tray app decides whether to nag.
# Anything that is not "blocked" means the session moved on, so the marker goes.
PENDING="$CLAUDE_DIR_ESC/claude-notify-pending"
if [ "${CLAUDE_NOTIFY_DRYRUN:-0}" != "1" ] && [ -d "$CLAUDE_DIR_ESC" ]; then
  if [ "$KIND" = "blocked" ]; then
    { printf '%s|%s
' "$(date +%s)" "$DETAIL" > "$PENDING"; } 2>/dev/null || true
  else
    rm -f "$PENDING" 2>/dev/null || true
  fi
fi

# --- report ------------------------------------------------------------------
# CLAUDE_NOTIFY_DEBUG=1 prints the decision instead of staying silent. Useful
# for working out why nothing is audible, and it is what CI asserts on, since a
# zero exit alone cannot distinguish a played sound from a fallback bell.
record "$(printf 'kind=%s sound=%s player=%s volume=%s pattern=%sx%s notified=%s pushed=%s elapsed=%s detail=%s' \
  "$KIND" "${SOUND:-none}" "${PLAYER_USED:-bell}" "$EV_VOLUME" \
  "$REPEAT_COUNT" "$REPEAT_GAP" "$NOTIFIED" "$PUSHED" "${ELAPSED:-na}" "$DETAIL")"

exit 0
