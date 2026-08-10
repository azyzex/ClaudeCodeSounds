//! Reading the usage windows, for the app to show.
//!
//! Nothing here asks anyone anything. It reads files that other parts of the
//! system have already written: `claude-limits.json` from the Claude Code
//! status line, and one file per other surface under `claude-limits.d/`.
//!
//! That is the whole trick, and it is why a "check usage" button costs nothing.
//! The figures arrive as a side effect of using Claude at all, so refreshing is
//! re-reading a file rather than asking for anything.
//!
//! Sources are deliberately **not** merged. The window is per account, so
//! folding two together would report one account's reset time under the other's
//! name. Each is reported separately and labelled.

use serde::Serialize;
use std::path::{Path, PathBuf};

#[derive(Serialize, Debug, Default, PartialEq)]
pub struct Window {
    pub used: Option<u32>,
    /// Unix seconds. The status line is handed a number and the bridge converts
    /// what the web returns, so everything downstream sees the same shape.
    pub resets_at: Option<i64>,
}

#[derive(Serialize, Debug, PartialEq)]
pub struct Source {
    /// "claude code", "web", and so on. Shown only when there is more than one.
    pub source: String,
    /// A short hash, never the organisation id itself.
    pub account: Option<String>,
    pub updated: Option<i64>,
    pub five_hour: Window,
    pub seven_day: Window,
}

/// One `key=value` line, last occurrence winning, as the notifier reads it.
fn field(text: &str, key: &str) -> Option<String> {
    let prefix = format!("{}=", key);
    // next_back, not last: the lines iterator runs both ways, so there is no
    // need to walk the whole file to reach the final match.
    text.lines()
        .filter_map(|l| l.strip_prefix(prefix.as_str()))
        .next_back()
        .map(|v| v.trim().to_string())
        .filter(|v| !v.is_empty())
}

fn number(text: &str, key: &str) -> Option<i64> {
    field(text, key).and_then(|v| v.parse::<i64>().ok())
}

fn window(text: &str, name: &str) -> Window {
    Window {
        // A percentage may be fractional in the status line payload, so it is
        // parsed as a float and shown whole.
        used: field(text, &format!("{}_used", name))
            .and_then(|v| v.parse::<f64>().ok())
            .map(|v| v.round() as u32),
        resets_at: number(text, &format!("{}_resets_at", name)),
    }
}

pub fn parse_source(text: &str, fallback: &str) -> Source {
    Source {
        source: field(text, "source").unwrap_or_else(|| fallback.to_string()),
        account: field(text, "account"),
        updated: number(text, "updated"),
        five_hour: window(text, "five_hour"),
        seven_day: window(text, "seven_day"),
    }
}

/// Every file that might hold a reset time. A missing file and an empty
/// directory are both perfectly normal.
pub fn source_paths(dir: &Path) -> Vec<PathBuf> {
    let mut found = Vec::new();
    let shared = dir.join("claude-limits.json");
    if shared.is_file() {
        found.push(shared);
    }
    if let Ok(entries) = std::fs::read_dir(dir.join("claude-limits.d")) {
        let mut extra: Vec<PathBuf> = entries
            .flatten()
            .map(|e| e.path())
            .filter(|p| p.is_file() && p.extension().is_some_and(|e| e == "conf"))
            .collect();
        // Directory order is not defined, and a list that reshuffles itself
        // between refreshes looks broken even when it is not.
        extra.sort();
        found.extend(extra);
    }
    found
}

pub fn read_all(dir: &Path) -> Vec<Source> {
    source_paths(dir)
        .into_iter()
        .filter_map(|p| {
            let text = std::fs::read_to_string(&p).ok()?;
            let fallback = if p.ends_with("claude-limits.json") {
                "claude code"
            } else {
                "another surface"
            };
            let parsed = parse_source(&text, fallback);
            // A file with neither window is not worth a row.
            if parsed.five_hour.resets_at.is_none() && parsed.seven_day.resets_at.is_none() {
                None
            } else {
                Some(parsed)
            }
        })
        .collect()
}

/// Seconds since the epoch, or 0 if the clock is before 1970.
pub fn epoch_now() -> i64 {
    now()
}

fn now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// "2h 10m", "45m", "any moment".
///
/// Floors rather than rounds. A countdown that says two hours when there is one
/// hour fifty-nine left is the kind of small lie that gets noticed.
pub fn human_gap(seconds: i64) -> String {
    if seconds <= 0 {
        return "any moment".to_string();
    }
    let mins = seconds / 60;
    if mins < 60 {
        return format!("{}m", mins.max(1));
    }
    let hours = mins / 60;
    if hours < 24 {
        return format!("{}h {}m", hours, mins % 60);
    }
    format!("{} days", hours / 24)
}

/// What the tray icon says when you hover it.
///
/// The soonest reset across every source and both windows, because the only
/// question a tray tooltip can usefully answer is "how long until I can work
/// again". Which account it belongs to is left to the window: there is no room
/// here, and with one account it would be noise.
pub fn tooltip(dir: &Path) -> String {
    const NAME: &str = "Claude Code Sounds";
    let at = now();
    let soonest = read_all(dir)
        .into_iter()
        .flat_map(|s| {
            [
                ("5 hour", s.five_hour.resets_at),
                ("7 day", s.seven_day.resets_at),
            ]
        })
        .filter_map(|(label, resets)| resets.map(|r| (label, r)))
        // Times already past belong to a window that has rolled over, and the
        // next reading will replace them. Counting down to them would be wrong.
        .filter(|(_, r)| *r > at)
        .min_by_key(|(_, r)| *r);

    match soonest {
        Some((label, r)) => format!("{}\n{} resets in {}", NAME, label, human_gap(r - at)),
        None => NAME.to_string(),
    }
}

/// An ISO 8601 instant as a unix second, or None.
///
/// Written out rather than pulling in a date crate, because exactly one shape
/// arrives here: what claude.ai puts in `resets_at`, which is
/// `2026-08-09T22:00:00.000000+00:00` or the same with a `Z`. Anything else is
/// refused rather than guessed at.
pub fn parse_iso8601(text: &str) -> Option<i64> {
    let bytes = text.as_bytes();
    if bytes.len() < 19 {
        return None;
    }
    let num = |a: usize, b: usize| text.get(a..b)?.parse::<i64>().ok();
    let (y, mo, d) = (num(0, 4)?, num(5, 7)?, num(8, 10)?);
    let (h, mi, s) = (num(11, 13)?, num(14, 16)?, num(17, 19)?);
    if !(1..=12).contains(&mo) || !(1..=31).contains(&d) {
        return None;
    }
    if h > 23 || mi > 59 || s > 60 {
        return None;
    }

    // Days since the epoch, by the civil-from-days algorithm. Leap years and
    // century rules included, which is the whole reason not to do this by hand
    // twice.
    let yy = if mo <= 2 { y - 1 } else { y };
    let era = if yy >= 0 { yy } else { yy - 399 } / 400;
    let yoe = yy - era * 400;
    let mp = (mo + 9) % 12;
    let doy = (153 * mp + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146097 + doe - 719468;

    let mut secs = days * 86400 + h * 3600 + mi * 60 + s;

    // The offset, if one is given. A time with no offset is taken as UTC, which
    // is what this endpoint sends.
    let tail = &text[19..];
    let sign_at = tail.find(['+', '-']);
    if let Some(i) = sign_at {
        let sign = if tail.as_bytes()[i] == b'-' { -1 } else { 1 };
        let rest = &tail[i + 1..];
        let oh: i64 = rest.get(0..2)?.parse().ok()?;
        let om: i64 = rest
            .get(3..5)
            .or_else(|| rest.get(2..4))
            .and_then(|v| v.parse().ok())
            .unwrap_or(0);
        secs -= sign * (oh * 3600 + om * 60);
    }
    Some(secs)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A directory of its own for each test that needs one.
    ///
    /// Tests in one binary share a process id, so naming a scratch directory
    /// after it alone would hand the same path to every caller and let one
    /// test's files decide another's result.
    fn tempdir() -> PathBuf {
        use std::sync::atomic::{AtomicU32, Ordering};
        static N: AtomicU32 = AtomicU32::new(0);
        let dir = std::env::temp_dir().join(format!(
            "earshot-tip-{}-{}",
            std::process::id(),
            N.fetch_add(1, Ordering::Relaxed)
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn iso_timestamps_become_the_right_instant() {
        // Checked against known epochs rather than against itself: hand-rolled
        // calendar maths that only agrees with its own assumptions is worth
        // nothing.
        assert_eq!(parse_iso8601("1970-01-01T00:00:00Z"), Some(0));
        assert_eq!(parse_iso8601("2000-01-01T00:00:00Z"), Some(946_684_800));
        assert_eq!(parse_iso8601("2026-08-09T22:00:00Z"), Some(1_786_312_800));
        // Leap day, and the century rule that makes 2000 a leap year.
        assert_eq!(parse_iso8601("2024-02-29T12:00:00Z"), Some(1_709_208_000));
        // No offset means UTC, which is what the endpoint sends.
        assert_eq!(
            parse_iso8601("2026-08-09T22:00:00.000000"),
            parse_iso8601("2026-08-09T22:00:00Z")
        );
        // An offset moves the instant, and both spellings are accepted.
        assert_eq!(
            parse_iso8601("2026-08-09T23:00:00+01:00"),
            parse_iso8601("2026-08-09T22:00:00Z")
        );
        assert_eq!(
            parse_iso8601("2026-08-09T21:00:00-0100"),
            parse_iso8601("2026-08-09T22:00:00Z")
        );
    }

    #[test]
    fn nonsense_timestamps_are_refused_not_guessed_at() {
        for bad in [
            "",
            "tomorrow",
            "2026-08-09",
            "2026-13-45T99:99:99Z",
            "2026-00-09T00:00:00Z",
            "2026-08-09T24:00:00Z",
            "not-a-date-at-all!!",
        ] {
            assert_eq!(parse_iso8601(bad), None, "{:?} should be refused", bad);
        }
    }

    #[test]
    fn a_gap_is_floored_not_rounded() {
        // 1h59m40s must never read as two hours. A countdown that rounds up is
        // the kind of small lie that gets noticed.
        assert_eq!(human_gap(7180), "1h 59m");
        assert_eq!(human_gap(7200), "2h 0m");
        assert_eq!(human_gap(59), "1m");
        assert_eq!(human_gap(3599), "59m");
        assert_eq!(human_gap(0), "any moment");
        assert_eq!(human_gap(-5), "any moment");
        assert_eq!(human_gap(90000), "1 days");
    }

    #[test]
    fn the_tooltip_counts_down_to_the_soonest_reset() {
        let dir = tempdir();
        let now = now();
        // Two sources, two accounts. The nearer one wins regardless of which
        // file it came from, because the only useful question is "how long".
        std::fs::write(
            dir.join("claude-limits.json"),
            format!("updated={}\nfive_hour_resets_at={}\n", now, now + 7200),
        )
        .unwrap();
        std::fs::create_dir_all(dir.join("claude-limits.d")).unwrap();
        std::fs::write(
            dir.join("claude-limits.d").join("web.conf"),
            format!(
                "updated={}\nsource=web\naccount=a1b2c3\nfive_hour_resets_at={}\n",
                now,
                now + 600
            ),
        )
        .unwrap();

        let text = tooltip(&dir);
        assert!(
            text.starts_with(
                "Claude Code Sounds
"
            ),
            "{}",
            text
        );
        assert!(
            text.contains("10m"),
            "should pick the nearer reset: {}",
            text
        );
        assert!(
            !text.contains("2h"),
            "should not show the later one: {}",
            text
        );
    }

    #[test]
    fn a_reset_already_past_is_not_counted_down_to() {
        let dir = tempdir();
        let now = now();
        // The window has rolled over and the next reading will replace this.
        // Counting down to a moment that has gone would show nonsense.
        std::fs::write(
            dir.join("claude-limits.json"),
            format!("updated={}\nfive_hour_resets_at={}\n", now, now - 60),
        )
        .unwrap();
        assert_eq!(tooltip(&dir), "Claude Code Sounds");
    }

    #[test]
    fn the_tooltip_is_just_the_name_when_nothing_is_known() {
        assert_eq!(tooltip(&tempdir()), "Claude Code Sounds");
    }

    const CC: &str = "updated=1786300000\nfive_hour_used=43.5\nfive_hour_resets_at=1786322194\n";
    const WEB: &str = "updated=1786300000\nsource=web\naccount=a1b2c3\n\
                       five_hour_used=93\nfive_hour_resets_at=1786322194\n\
                       seven_day_used=35\nseven_day_resets_at=1786900000\n";

    #[test]
    fn reads_the_status_line_file() {
        let s = parse_source(CC, "claude code");
        assert_eq!(s.source, "claude code");
        assert_eq!(s.account, None);
        // Fractional percentages appear in the status line payload.
        assert_eq!(s.five_hour.used, Some(44));
        assert_eq!(s.five_hour.resets_at, Some(1786322194));
        assert_eq!(s.seven_day.resets_at, None);
    }

    #[test]
    fn reads_a_surface_that_named_its_account() {
        let s = parse_source(WEB, "another surface");
        assert_eq!(s.source, "web");
        assert_eq!(s.account.as_deref(), Some("a1b2c3"));
        assert_eq!(s.five_hour.used, Some(93));
        assert_eq!(s.seven_day.used, Some(35));
    }

    #[test]
    fn a_later_line_wins_over_an_earlier_one() {
        let s = parse_source("five_hour_used=1\nfive_hour_used=2\n", "x");
        assert_eq!(s.five_hour.used, Some(2));
    }

    #[test]
    fn rubbish_is_ignored_rather_than_guessed_at() {
        let s = parse_source("five_hour_resets_at=tomorrow\nfive_hour_used=\n", "x");
        assert_eq!(s.five_hour.resets_at, None);
        assert_eq!(s.five_hour.used, None);
    }

    #[test]
    fn two_accounts_stay_two_rows() {
        let dir = std::env::temp_dir().join(format!("earshot-limits-{}", std::process::id()));
        let d = dir.join("claude-limits.d");
        std::fs::create_dir_all(&d).unwrap();
        std::fs::write(dir.join("claude-limits.json"), CC).unwrap();
        std::fs::write(d.join("web.conf"), WEB).unwrap();
        std::fs::write(
            d.join("other.conf"),
            WEB.replace("account=a1b2c3", "account=ddeeff"),
        )
        .unwrap();

        let all = read_all(&dir);
        assert_eq!(all.len(), 3, "nothing may be merged away");
        let accounts: Vec<_> = all.iter().map(|s| s.account.clone()).collect();
        assert!(accounts.contains(&Some("a1b2c3".into())));
        assert!(accounts.contains(&Some("ddeeff".into())));

        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn a_file_with_no_window_is_left_out() {
        let dir = std::env::temp_dir().join(format!("earshot-empty-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("claude-limits.json"), "updated=1786300000\n").unwrap();
        assert!(read_all(&dir).is_empty());
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn nothing_installed_is_not_an_error() {
        assert!(read_all(Path::new("/nowhere/at/all")).is_empty());
    }
}
