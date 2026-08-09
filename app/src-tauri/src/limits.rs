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

#[cfg(test)]
mod tests {
    use super::*;

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
