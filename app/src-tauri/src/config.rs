//! Reading and writing ~/.claude/claude-notify.conf.
//!
//! The notifier scripts are the authority on what these options mean. This
//! module only has to agree with them on the file format, which is deliberately
//! dull: `KEY=value`, one per line, `#` comments, last occurrence wins.
//!
//! The file is parsed, never executed, exactly as the shell and PowerShell
//! notifiers do. Editing here must preserve comments and unknown keys, because
//! people hand-edit this file and a round trip through the app should not
//! silently drop anything it did not recognise.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

/// Every option the app knows about, with the default the notifiers assume when
/// a key is absent. Keys not in this list still round-trip; they are simply not
/// shown in the UI.
pub const DEFAULTS: &[(&str, &str)] = &[
    ("MIN_SECONDS", "30"),
    ("SUPPRESS_WHEN_FOCUSED", "1"),
    ("PROJECT_PITCH", "1"),
    ("SPEAK", "0"),
    ("TOAST_ON_DONE", "0"),
    ("DEBOUNCE_SECONDS", "2"),
    ("ALWAYS_ALERT", "blocked,limit,error"),
    ("MUTE", ""),
    ("QUIET_HOURS", ""),
    ("SOUND_PACK", "default"),
    ("DONE_ENABLED", "1"),
    ("DONE_VOLUME", "70"),
    ("DONE_PATTERN", "1"),
    ("DONE_SOUND", ""),
    ("BLOCKED_ENABLED", "1"),
    ("BLOCKED_VOLUME", "100"),
    ("BLOCKED_PATTERN", "2"),
    ("BLOCKED_SOUND", ""),
    ("LIMIT_ENABLED", "1"),
    ("LIMIT_VOLUME", "100"),
    ("LIMIT_PATTERN", "3x140"),
    ("LIMIT_SOUND", ""),
    ("ERROR_ENABLED", "1"),
    ("ERROR_VOLUME", "100"),
    ("ERROR_PATTERN", "2"),
    ("ERROR_SOUND", ""),
];

pub fn claude_dir() -> Option<PathBuf> {
    // No dirs crate: HOME on Unix, USERPROFILE on Windows is all this needs,
    // and it matches what the notifiers themselves use.
    let home = std::env::var_os("HOME")
        .or_else(|| std::env::var_os("USERPROFILE"))
        .map(PathBuf::from)?;
    Some(home.join(".claude"))
}

pub fn conf_path() -> Option<PathBuf> {
    claude_dir().map(|d| d.join("claude-notify.conf"))
}

pub fn sounds_dir() -> Option<PathBuf> {
    claude_dir().map(|d| d.join("claude-sounds"))
}

/// Split a config line into key and value, or None for blanks and comments.
fn split_line(line: &str) -> Option<(String, String)> {
    let trimmed = line.trim_start();
    if trimmed.is_empty() || trimmed.starts_with('#') {
        return None;
    }
    let eq = trimmed.find('=')?;
    let key = trimmed[..eq].trim();
    if key.is_empty() || !key.chars().all(|c| c.is_ascii_uppercase() || c == '_' || c.is_ascii_digit()) {
        return None;
    }
    // Strip a trailing carriage return, so a file edited on Windows and read on
    // Linux does not produce values with \r stuck on the end.
    let value = trimmed[eq + 1..].trim_end_matches(['\r', '\n']).trim();
    Some((key.to_string(), value.to_string()))
}

/// Every key present in the file. Later lines win, matching the notifiers,
/// which take the last match.
pub fn parse(text: &str) -> BTreeMap<String, String> {
    let mut out = BTreeMap::new();
    for line in text.lines() {
        if let Some((k, v)) = split_line(line) {
            out.insert(k, v);
        }
    }
    out
}

/// The effective settings: defaults, overlaid with whatever the file sets.
pub fn effective(text: &str) -> BTreeMap<String, String> {
    let mut out: BTreeMap<String, String> = DEFAULTS
        .iter()
        .map(|(k, v)| (k.to_string(), v.to_string()))
        .collect();
    out.extend(parse(text));
    out
}

/// Apply changes to the file's text, editing in place.
///
/// Existing lines are rewritten where they sit, so comments, ordering and any
/// key this app does not know about all survive. Genuinely new keys are
/// appended. This matters because the file is meant to be hand-editable, and an
/// app that reformatted it on every save would be hostile.
pub fn apply(original: &str, changes: &BTreeMap<String, String>) -> String {
    let mut seen: Vec<String> = Vec::new();
    let mut lines: Vec<String> = Vec::new();

    for line in original.lines() {
        match split_line(line) {
            Some((k, _)) if changes.contains_key(&k) => {
                lines.push(format!("{}={}", k, changes[&k]));
                seen.push(k);
            }
            _ => lines.push(line.to_string()),
        }
    }

    let missing: Vec<&String> = changes.keys().filter(|k| !seen.contains(k)).collect();
    if !missing.is_empty() {
        if !lines.is_empty() && !lines.last().map(|l| l.trim().is_empty()).unwrap_or(false) {
            lines.push(String::new());
        }
        for k in missing {
            lines.push(format!("{}={}", k, changes[k]));
        }
    }

    let mut out = lines.join("\n");
    out.push('\n');
    out
}

/// Sound packs, as folder names under claude-sounds/. "default" first, then
/// the rest alphabetically, which is the order the UI wants to show them in.
pub fn list_packs(dir: &Path) -> Vec<String> {
    let mut packs: Vec<String> = Vec::new();
    if let Ok(entries) = std::fs::read_dir(dir) {
        for entry in entries.flatten() {
            if entry.file_type().map(|t| t.is_dir()).unwrap_or(false) {
                if let Some(name) = entry.file_name().to_str() {
                    packs.push(name.to_string());
                }
            }
        }
    }
    packs.sort();
    if let Some(i) = packs.iter().position(|p| p == "default") {
        let d = packs.remove(i);
        packs.insert(0, d);
    }
    packs
}

/// The .wav files in a pack, without the extension, which is how the config
/// and the notifiers refer to them.
pub fn list_sounds(dir: &Path, pack: &str) -> Vec<String> {
    let mut names: Vec<String> = Vec::new();
    if !is_safe_pack(pack) {
        return names;
    }
    if let Ok(entries) = std::fs::read_dir(dir.join(pack)) {
        for entry in entries.flatten() {
            let path = entry.path();
            if path.extension().and_then(|e| e.to_str()) == Some("wav") {
                if let Some(stem) = path.file_stem().and_then(|s| s.to_str()) {
                    names.push(stem.to_string());
                }
            }
        }
    }
    names.sort();
    names
}

/// A pack name is one directory component, never a path. Same rule the
/// notifiers apply, so the app cannot write a config the notifier would reject.
pub fn is_safe_pack(pack: &str) -> bool {
    !pack.is_empty()
        && !pack.starts_with('.')
        && !pack.contains('/')
        && !pack.contains('\\')
        && !pack.contains(':')
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_simple_keys() {
        let c = parse("MIN_SECONDS=45\nSPEAK=1\n");
        assert_eq!(c["MIN_SECONDS"], "45");
        assert_eq!(c["SPEAK"], "1");
    }

    #[test]
    fn ignores_comments_and_blanks() {
        let c = parse("# a comment\n\n  # indented\nMUTE=done\n");
        assert_eq!(c.len(), 1);
        assert_eq!(c["MUTE"], "done");
    }

    #[test]
    fn last_occurrence_wins_like_the_notifiers() {
        let c = parse("MIN_SECONDS=10\nMIN_SECONDS=99\n");
        assert_eq!(c["MIN_SECONDS"], "99");
    }

    #[test]
    fn tolerates_whitespace_and_crlf() {
        let c = parse("  MIN_SECONDS  =  45  \r\nSPEAK=1\r\n");
        assert_eq!(c["MIN_SECONDS"], "45");
        assert_eq!(c["SPEAK"], "1");
    }

    #[test]
    fn empty_values_are_kept() {
        let c = parse("MUTE=\n");
        assert_eq!(c["MUTE"], "");
    }

    #[test]
    fn effective_fills_in_defaults() {
        let c = effective("MIN_SECONDS=5\n");
        assert_eq!(c["MIN_SECONDS"], "5");
        assert_eq!(c["SOUND_PACK"], "default");
        assert_eq!(c["LIMIT_PATTERN"], "3x140");
    }

    #[test]
    fn apply_edits_in_place_and_keeps_comments() {
        let original = "# keep me\nMIN_SECONDS=30\n\n# and me\nSPEAK=0\n";
        let mut changes = BTreeMap::new();
        changes.insert("SPEAK".to_string(), "1".to_string());
        let out = apply(original, &changes);
        assert!(out.contains("# keep me"));
        assert!(out.contains("# and me"));
        assert!(out.contains("SPEAK=1"));
        assert!(out.contains("MIN_SECONDS=30"));
        assert!(!out.contains("SPEAK=0"));
    }

    #[test]
    fn apply_preserves_unknown_keys() {
        let original = "SOMETHING_ELSE=hello\nSPEAK=0\n";
        let mut changes = BTreeMap::new();
        changes.insert("SPEAK".to_string(), "1".to_string());
        let out = apply(original, &changes);
        assert!(out.contains("SOMETHING_ELSE=hello"));
    }

    #[test]
    fn apply_appends_keys_that_were_absent() {
        let mut changes = BTreeMap::new();
        changes.insert("QUIET_HOURS".to_string(), "23:00-08:00".to_string());
        let out = apply("SPEAK=0\n", &changes);
        assert!(out.contains("QUIET_HOURS=23:00-08:00"));
        assert!(out.contains("SPEAK=0"));
    }

    #[test]
    fn apply_round_trips_through_parse() {
        let mut changes = BTreeMap::new();
        changes.insert("MIN_SECONDS".to_string(), "12".to_string());
        changes.insert("MUTE".to_string(), "done,error".to_string());
        let out = apply("# header\nMIN_SECONDS=30\n", &changes);
        let back = parse(&out);
        assert_eq!(back["MIN_SECONDS"], "12");
        assert_eq!(back["MUTE"], "done,error");
    }

    #[test]
    fn apply_always_ends_with_one_newline() {
        let out = apply("SPEAK=0", &BTreeMap::new());
        assert!(out.ends_with('\n'));
        assert!(!out.ends_with("\n\n"));
    }

    #[test]
    fn rejects_unsafe_pack_names() {
        assert!(is_safe_pack("default"));
        assert!(is_safe_pack("retro-2"));
        assert!(!is_safe_pack(""));
        assert!(!is_safe_pack(".."));
        assert!(!is_safe_pack("../etc"));
        assert!(!is_safe_pack("a/b"));
        assert!(!is_safe_pack("a\\b"));
        assert!(!is_safe_pack("C:"));
    }

    #[test]
    fn lowercase_keys_are_not_config() {
        // The notifiers only match uppercase keys, so neither should this, or
        // the app would show settings that have no effect.
        let c = parse("min_seconds=5\nMIN_SECONDS=9\n");
        assert_eq!(c.len(), 1);
        assert_eq!(c["MIN_SECONDS"], "9");
    }
}
