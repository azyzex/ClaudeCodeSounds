#!/usr/bin/env bash
# =============================================================================
#  Claude Code sound alerts - status line
# =============================================================================
#
#  Claude Code runs this to draw the bar at the bottom of the terminal, handing
#  it session data on stdin. That data includes the one thing this project could
#  not otherwise know:
#
#      "rate_limits": {
#        "five_hour": { "used_percentage": 23.5, "resets_at": 1738425600 },
#        "seven_day": { "used_percentage": 41.2, "resets_at": 1738857600 }
#      }
#
#  Those numbers come from Anthropic, so they already account for every surface
#  you use: this terminal, the web, the phone, another machine. Reading them
#  costs nothing, because Claude Code draws this bar regardless.
#
#  So this script does two jobs:
#
#    1. print a status line, which is what Claude Code asked for
#    2. save the reset times, so the notifier can alert when they pass
#
#  It must stay quick and it must never fail loudly: it runs constantly, and a
#  broken status line is a broken looking editor.
# =============================================================================

LIMITS="$HOME/.claude/claude-limits.json"
NOTIFIER="$HOME/.claude/claude-notify.sh"

payload=$(cat 2>/dev/null)
[ -n "$payload" ] || exit 0

# Pulled out with grep rather than a JSON parser on purpose. This runs on every
# redraw, so starting an interpreter each time would be felt. The shape here is
# flat and known, and anything unexpected simply yields an empty string.
field() {  # field <window> <key>
  printf '%s' "$payload" \
    | grep -o "\"$1\"[[:space:]]*:[[:space:]]*{[^}]*}" \
    | grep -o "\"$2\"[[:space:]]*:[[:space:]]*[0-9.]*" \
    | grep -o '[0-9.]*$' \
    | head -1
}

five_pct=$(field five_hour used_percentage)
five_at=$(field five_hour resets_at)
week_pct=$(field seven_day used_percentage)
week_at=$(field seven_day resets_at)

# --- save what was learned ----------------------------------------------------
# Written whenever a reset time is present, so the notifier has something to
# watch even after Claude Code closes. A plain file of key=value, for the same
# reason the config is: anything can read it without a parser.
if [ -n "$five_at" ] && [ -d "$HOME/.claude" ]; then
  {
    printf 'updated=%s\n' "$(date +%s)"
    printf 'five_hour_resets_at=%s\n' "$five_at"
    [ -n "$five_pct" ]  && printf 'five_hour_used=%s\n' "$five_pct"
    [ -n "$week_at" ]   && printf 'seven_day_resets_at=%s\n' "$week_at"
    [ -n "$week_pct" ]  && printf 'seven_day_used=%s\n' "$week_pct"
  } > "$LIMITS.tmp" 2>/dev/null && mv "$LIMITS.tmp" "$LIMITS" 2>/dev/null

  # Make sure something is watching the clock. The notifier's watcher exits once
  # nothing is pending, so it needs starting again whenever a new reset appears.
  if [ -x "$NOTIFIER" ]; then
    alive="$HOME/.claude/claude-watch-alive"
    running=0
    if [ -f "$alive" ]; then
      last=$(cat "$alive" 2>/dev/null)
      case "$last" in
        ''|*[!0-9]*) ;;
        *) [ $(( $(date +%s) - last )) -lt 150 ] && running=1 ;;
      esac
    fi
    [ "$running" = "0" ] && ( nohup "$NOTIFIER" watch >/dev/null 2>&1 & ) 2>/dev/null
  fi
fi

# --- draw the bar -------------------------------------------------------------
# Only installed when there was no status line already, so it has to be useful
# on its own rather than assuming someone will style it.
model=$(printf '%s' "$payload" \
  | grep -o '"display_name"[[:space:]]*:[[:space:]]*"[^"]*"' \
  | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
dir=$(printf '%s' "$payload" \
  | grep -o '"current_dir"[[:space:]]*:[[:space:]]*"[^"]*"' \
  | head -1 | sed 's/.*"\(.*\)"$/\1/')
dir=${dir##*[\\/]}

# Local clock time from an epoch, on either GNU or BSD date.
clock() {
  date -d "@$1" +%H:%M 2>/dev/null || date -r "$1" +%H:%M 2>/dev/null
}

out=""
[ -n "$model" ] && out="$model"
[ -n "$dir" ] && out="${out:+$out · }$dir"

if [ -n "$five_pct" ] && [ -n "$five_at" ]; then
  # Rounded to whole percent: the decimal is noise at a glance.
  pct=${five_pct%%.*}
  at=$(clock "$five_at")
  out="${out:+$out · }${pct}% used${at:+, resets $at}"
fi

printf '%s\n' "$out"
