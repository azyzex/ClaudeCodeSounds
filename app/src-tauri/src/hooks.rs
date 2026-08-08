//! Reading and writing the hook entries in ~/.claude/settings.json.
//!
//! This has to behave exactly like the installer scripts, because the two are
//! front doors to the same thing and a user may well have used both. The rules
//! that matter:
//!
//!   * merge, never replace: other people's hooks survive
//!   * back up first, with a timestamp
//!   * idempotent: strip our own entries, recognised by the notifier filename,
//!     before adding them, so installing twice does not double every chime
//!   * no BOM, because strict JSON parsers reject it

use serde_json::{json, Map, Value};
use std::path::{Path, PathBuf};

/// How our own hook entries are recognised, in both directions.
const MARKERS: [&str; 2] = ["claude-notify.sh", "claude-notify.ps1"];

/// Every event we own. Elicitation is here only so it gets cleaned up: early
/// versions wired it directly, but Notification covers it via the
/// elicitation_dialog matcher.
const OUR_EVENTS: [&str; 5] = [
    "UserPromptSubmit",
    "Stop",
    "Notification",
    "StopFailure",
    "Elicitation",
];

const NOTIFICATION_MATCHER: &str =
    "permission_prompt|idle_prompt|agent_needs_input|elicitation_dialog";
const ERROR_MATCHER: &str = "overloaded|authentication_failed|oauth_org_not_allowed|billing_error|invalid_request|model_not_found|server_error|max_output_tokens|unknown";

/// (event, kind, matcher)
fn wiring() -> Vec<(&'static str, &'static str, Option<&'static str>)> {
    vec![
        ("UserPromptSubmit", "mark", None),
        ("Stop", "done", None),
        ("Notification", "blocked", Some(NOTIFICATION_MATCHER)),
        ("StopFailure", "limit", Some("rate_limit")),
        ("StopFailure", "error", Some(ERROR_MATCHER)),
    ]
}

pub fn settings_path(claude_dir: &Path) -> PathBuf {
    claude_dir.join("settings.json")
}

fn is_ours(group: &Value) -> bool {
    let text = group.to_string();
    MARKERS.iter().any(|m| text.contains(m))
}

/// How many of our hook groups are currently installed.
pub fn installed_count(settings: &Value) -> usize {
    let Some(hooks) = settings.get("hooks").and_then(|h| h.as_object()) else {
        return 0;
    };
    hooks
        .values()
        .filter_map(|v| v.as_array())
        .flatten()
        .filter(|g| is_ours(g))
        .count()
}

fn hook_group(kind: &str, matcher: Option<&str>, unix: bool) -> Value {
    let handler = if unix {
        json!({
            "type": "command",
            // Shell form, so sh -c expands $HOME. async keeps Claude Code from
            // blocking for the length of the audio clip on every turn.
            "command": format!("\"$HOME/.claude/claude-notify.sh\" {}", kind),
            "async": true,
            "timeout": 30
        })
    } else {
        json!({
            "type": "command",
            "command": "powershell.exe",
            "args": [
                "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command",
                format!("& \"$env:USERPROFILE\\.claude\\claude-notify.ps1\" -Kind {}", kind)
            ],
            "async": true,
            "timeout": 30
        })
    };

    let mut group = Map::new();
    group.insert("hooks".to_string(), json!([handler]));
    if let Some(m) = matcher {
        group.insert("matcher".to_string(), json!(m));
    }
    Value::Object(group)
}

/// Strip our entries from every event we own, dropping events left empty.
fn strip_ours(settings: &mut Value) {
    let Some(hooks) = settings
        .get_mut("hooks")
        .and_then(|h| h.as_object_mut())
    else {
        return;
    };

    for event in OUR_EVENTS {
        let Some(list) = hooks.get_mut(event).and_then(|v| v.as_array_mut()) else {
            continue;
        };
        list.retain(|g| !is_ours(g));
        if list.is_empty() {
            hooks.remove(event);
        }
    }
}

/// Add our hooks, having removed any previous copy first.
pub fn install(settings: &mut Value, unix: bool) {
    if !settings.is_object() {
        *settings = json!({});
    }
    if settings.get("hooks").map(|h| !h.is_object()).unwrap_or(true) {
        settings["hooks"] = json!({});
    }

    strip_ours(settings);

    let hooks = settings["hooks"].as_object_mut().expect("hooks is an object");
    for (event, kind, matcher) in wiring() {
        let entry = hooks.entry(event.to_string()).or_insert_with(|| json!([]));
        if !entry.is_array() {
            *entry = json!([]);
        }
        entry
            .as_array_mut()
            .expect("entry is an array")
            .push(hook_group(kind, matcher, unix));
    }
}

/// Remove our hooks and nothing else.
pub fn uninstall(settings: &mut Value) {
    strip_ours(settings);
    let empty = settings
        .get("hooks")
        .and_then(|h| h.as_object())
        .map(|h| h.is_empty())
        .unwrap_or(false);
    if empty {
        if let Some(obj) = settings.as_object_mut() {
            obj.remove("hooks");
        }
    }
}

pub fn backup_name(now: &str) -> String {
    format!("settings.json.bak-{}", now)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample_with_other_hooks() -> Value {
        json!({
            "model": "opus",
            "hooks": {
                "PostToolUse": [
                    { "hooks": [ { "type": "command", "command": "echo somebody-elses-hook" } ] }
                ],
                "Stop": [
                    { "hooks": [ { "type": "command", "command": "echo pre-existing" } ] }
                ]
            }
        })
    }

    #[test]
    fn install_adds_five_groups() {
        let mut s = json!({});
        install(&mut s, true);
        assert_eq!(installed_count(&s), 5);
    }

    #[test]
    fn install_is_idempotent() {
        let mut s = json!({});
        install(&mut s, true);
        install(&mut s, true);
        install(&mut s, true);
        assert_eq!(installed_count(&s), 5);
    }

    #[test]
    fn install_preserves_other_hooks_and_keys() {
        let mut s = sample_with_other_hooks();
        install(&mut s, true);
        assert_eq!(s["model"], "opus");
        let text = s.to_string();
        assert!(text.contains("somebody-elses-hook"));
        assert!(text.contains("pre-existing"));
        // Our Stop group sits alongside the one that was already there.
        assert_eq!(s["hooks"]["Stop"].as_array().unwrap().len(), 2);
    }

    #[test]
    fn uninstall_removes_only_ours() {
        let mut s = sample_with_other_hooks();
        install(&mut s, true);
        uninstall(&mut s);
        assert_eq!(installed_count(&s), 0);
        let text = s.to_string();
        assert!(text.contains("somebody-elses-hook"));
        assert!(text.contains("pre-existing"));
        assert_eq!(s["model"], "opus");
    }

    #[test]
    fn uninstall_drops_the_hooks_key_when_it_empties() {
        let mut s = json!({ "model": "opus" });
        install(&mut s, true);
        uninstall(&mut s);
        assert!(s.get("hooks").is_none());
        assert_eq!(s["model"], "opus");
    }

    #[test]
    fn uninstall_cleans_up_a_legacy_elicitation_hook() {
        let mut s = json!({
            "hooks": {
                "Elicitation": [
                    { "hooks": [ { "type": "command", "command": "powershell.exe",
                                   "args": ["-Command", "& \"$env:USERPROFILE\\.claude\\claude-notify.ps1\" -Kind blocked"] } ] }
                ]
            }
        });
        assert_eq!(installed_count(&s), 1);
        uninstall(&mut s);
        assert_eq!(installed_count(&s), 0);
    }

    #[test]
    fn windows_and_unix_entries_are_both_recognised_as_ours() {
        let mut unix = json!({});
        install(&mut unix, true);
        let mut win = json!({});
        install(&mut win, false);
        assert_eq!(installed_count(&unix), 5);
        assert_eq!(installed_count(&win), 5);
        // Installing over the other platform's entries replaces them rather
        // than stacking, which is what a shared home directory needs.
        install(&mut unix, false);
        assert_eq!(installed_count(&unix), 5);
    }

    #[test]
    fn rate_limit_gets_its_own_group() {
        let mut s = json!({});
        install(&mut s, true);
        let failures = s["hooks"]["StopFailure"].as_array().unwrap();
        assert_eq!(failures.len(), 2);
        assert_eq!(failures[0]["matcher"], "rate_limit");
        assert_ne!(failures[1]["matcher"], "rate_limit");
    }

    #[test]
    fn every_hook_is_async() {
        let mut s = json!({});
        install(&mut s, true);
        for list in s["hooks"].as_object().unwrap().values() {
            for group in list.as_array().unwrap() {
                for h in group["hooks"].as_array().unwrap() {
                    assert_eq!(h["async"], true, "async keeps Claude Code from blocking");
                }
            }
        }
    }

    #[test]
    fn survives_a_non_object_hooks_value() {
        let mut s = json!({ "hooks": "nonsense" });
        install(&mut s, true);
        assert_eq!(installed_count(&s), 5);
    }
}
