//! Re-alerting on a prompt you never answered.
//!
//! This is the one thing a hook genuinely cannot do. A hook runs and exits, so
//! it can announce that Claude is waiting but it can never notice that you
//! still have not responded five minutes later. The notifier writes a marker
//! when it alerts for a blocked prompt and deletes it on any other event; a
//! resident process is what turns that into a nudge.
//!
//! The rules are deliberately timid, because a notifier that nags wrongly gets
//! uninstalled faster than one that stays quiet:
//!
//!   * off unless `ESCALATE_AFTER` is a positive number of seconds
//!   * at most one nudge per outstanding prompt
//!   * never while a mute or quiet hours is in force
//!   * never while the marker is younger than the threshold

use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

pub fn pending_path(claude_dir: &Path) -> PathBuf {
    claude_dir.join("claude-notify-pending")
}

pub fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// `epoch|message`, as the notifier writes it.
pub fn parse_marker(text: &str) -> Option<(u64, String)> {
    let (stamp, rest) = text.trim().split_once('|')?;
    let at: u64 = stamp.trim().parse().ok()?;
    Some((at, rest.trim().to_string()))
}

/// What the watcher should do this tick.
#[derive(Debug, PartialEq)]
pub enum Action {
    Nothing,
    /// A prompt has been outstanding this long, in seconds.
    Nudge(u64, String),
}

/// Decide, given everything relevant. Pure, so the rules are testable without a
/// filesystem, a clock or a notification daemon.
#[allow(clippy::too_many_arguments)]
pub fn decide(
    marker: Option<&str>,
    now: u64,
    escalate_after: u64,
    already_nudged_at: Option<u64>,
    muted_until: Option<u64>,
    in_quiet_hours: bool,
) -> Action {
    if escalate_after == 0 {
        return Action::Nothing;
    }
    let Some((at, message)) = marker.and_then(parse_marker) else {
        return Action::Nothing;
    };
    let waited = now.saturating_sub(at);
    if waited < escalate_after {
        return Action::Nothing;
    }
    // One nudge per prompt. The marker's own timestamp identifies the prompt,
    // so a nudge already sent for this one is not sent again.
    if already_nudged_at == Some(at) {
        return Action::Nothing;
    }
    if muted_until.map(|u| u > now).unwrap_or(false) || in_quiet_hours {
        return Action::Nothing;
    }
    Action::Nudge(waited, message)
}

/// `HH:MM-HH:MM`, wrapping past midnight, matching both notifiers.
pub fn in_quiet_hours(window: &str, hour: u32, minute: u32) -> bool {
    let parts: Vec<&str> = window.split('-').collect();
    if parts.len() != 2 {
        return false;
    }
    let parse = |s: &str| -> Option<u32> {
        let s = s.trim().replace(':', "");
        if s.len() < 3 || !s.chars().all(|c| c.is_ascii_digit()) {
            return None;
        }
        let (h, m) = s.split_at(s.len() - 2);
        Some(h.parse::<u32>().ok()? * 60 + m.parse::<u32>().ok()?)
    };
    let (Some(from), Some(to)) = (parse(parts[0]), parse(parts[1])) else {
        return false;
    };
    let now = hour * 60 + minute;
    if from <= to {
        now >= from && now < to
    } else {
        now >= from || now < to
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const MARKER: &str = "1000|Approve this edit";

    #[test]
    fn off_unless_configured() {
        assert_eq!(
            decide(Some(MARKER), 9999, 0, None, None, false),
            Action::Nothing
        );
    }

    #[test]
    fn nothing_without_a_marker() {
        assert_eq!(decide(None, 9999, 60, None, None, false), Action::Nothing);
    }

    #[test]
    fn waits_for_the_threshold() {
        assert_eq!(
            decide(Some(MARKER), 1030, 60, None, None, false),
            Action::Nothing
        );
        assert_eq!(
            decide(Some(MARKER), 1060, 60, None, None, false),
            Action::Nudge(60, "Approve this edit".into())
        );
    }

    #[test]
    fn only_nudges_once_per_prompt() {
        assert_eq!(
            decide(Some(MARKER), 2000, 60, Some(1000), None, false),
            Action::Nothing
        );
        // A different prompt, so a fresh nudge is allowed.
        assert_eq!(
            decide(Some("1500|Another"), 2000, 60, Some(1000), None, false),
            Action::Nudge(500, "Another".into())
        );
    }

    #[test]
    fn respects_a_mute_and_quiet_hours() {
        assert_eq!(
            decide(Some(MARKER), 1100, 60, None, Some(9999), false),
            Action::Nothing
        );
        assert_eq!(
            decide(Some(MARKER), 1100, 60, None, None, true),
            Action::Nothing
        );
        // An expired mute does not suppress.
        assert_eq!(
            decide(Some(MARKER), 1100, 60, None, Some(1050), false),
            Action::Nudge(100, "Approve this edit".into())
        );
    }

    #[test]
    fn malformed_markers_are_ignored() {
        for bad in ["", "no pipe", "abc|x", "|"] {
            assert_eq!(
                decide(Some(bad), 9999, 60, None, None, false),
                Action::Nothing,
                "{bad:?}"
            );
        }
    }

    #[test]
    fn quiet_hours_matches_the_notifiers() {
        assert!(in_quiet_hours("09:00-17:00", 12, 0));
        assert!(!in_quiet_hours("09:00-17:00", 8, 0));
        assert!(!in_quiet_hours("09:00-17:00", 17, 0)); // exclusive end
                                                        // Wrapping past midnight.
        assert!(in_quiet_hours("23:00-08:00", 23, 30));
        assert!(in_quiet_hours("23:00-08:00", 2, 0));
        assert!(!in_quiet_hours("23:00-08:00", 12, 0));
        // Unparseable windows must not silence everything.
        assert!(!in_quiet_hours("", 12, 0));
        assert!(!in_quiet_hours("nonsense", 12, 0));
    }
}
