// Hide the console window on Windows release builds.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod config;
mod hooks;

use serde::Serialize;
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::process::Command;

/// Everything the UI needs to draw itself, fetched in one call so the window
/// does not flash through half-populated states.
#[derive(Serialize)]
struct AppState {
    /// Effective settings: defaults overlaid with the config file.
    settings: BTreeMap<String, String>,
    /// Hook groups currently in settings.json. 5 means fully installed.
    installed: usize,
    /// Whether ~/.claude exists at all, ie. whether Claude Code has ever run.
    claude_dir_exists: bool,
    packs: Vec<String>,
    sounds: Vec<String>,
    conf_path: String,
    platform: &'static str,
}

fn is_unix() -> bool {
    cfg!(not(target_os = "windows"))
}

fn read_conf_text() -> String {
    config::conf_path()
        .and_then(|p| std::fs::read_to_string(p).ok())
        .unwrap_or_default()
}

#[tauri::command]
fn load_state() -> Result<AppState, String> {
    let dir = config::claude_dir().ok_or("could not work out your home directory")?;
    let text = read_conf_text();
    let settings = config::effective(&text);

    let sounds_dir = config::sounds_dir().unwrap_or_default();
    let packs = config::list_packs(&sounds_dir);
    let pack = settings
        .get("SOUND_PACK")
        .cloned()
        .unwrap_or_else(|| "default".to_string());
    let sounds = config::list_sounds(&sounds_dir, &pack);

    let installed = std::fs::read_to_string(hooks::settings_path(&dir))
        .ok()
        .and_then(|s| serde_json::from_str::<serde_json::Value>(&s).ok())
        .map(|v| hooks::installed_count(&v))
        .unwrap_or(0);

    Ok(AppState {
        settings,
        installed,
        claude_dir_exists: dir.exists(),
        packs,
        sounds,
        conf_path: config::conf_path()
            .map(|p| p.display().to_string())
            .unwrap_or_default(),
        platform: if is_unix() { "unix" } else { "windows" },
    })
}

/// Write changed keys back, editing the file in place so comments and any keys
/// this app does not know about survive.
#[tauri::command]
fn save_settings(changes: BTreeMap<String, String>) -> Result<(), String> {
    if let Some(pack) = changes.get("SOUND_PACK") {
        if !config::is_safe_pack(pack) {
            return Err(format!("{:?} is not a valid pack name", pack));
        }
    }

    let path = config::conf_path().ok_or("could not work out your home directory")?;
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    }
    let original = std::fs::read_to_string(&path).unwrap_or_default();
    let updated = config::apply(&original, &changes);
    std::fs::write(&path, updated).map_err(|e| e.to_string())
}

/// Play one alert exactly as it would fire, so the settings can be heard rather
/// than guessed at. This runs the real notifier, not a reimplementation of it,
/// so what you hear is what you will get.
#[tauri::command]
fn preview(kind: String) -> Result<String, String> {
    if !["done", "blocked", "limit", "error"].contains(&kind.as_str()) {
        return Err(format!("unknown alert kind {:?}", kind));
    }
    let dir = config::claude_dir().ok_or("could not work out your home directory")?;

    // Clearing the debounce stamp first: two previews in a row should both be
    // audible, where in normal use the second would be suppressed.
    if let Some(stamp) = debounce_stamp() {
        let _ = std::fs::remove_file(stamp);
    }

    let output = if is_unix() {
        Command::new("bash")
            .arg(dir.join("claude-notify.sh"))
            .arg(&kind)
            .env("CLAUDE_NOTIFY_DEBUG", "1")
            // Preview must not be silenced by the very settings being tuned.
            .env("CLAUDE_NOTIFY_FORCE", "1")
            .output()
    } else {
        Command::new("powershell.exe")
            .args(["-NoProfile", "-ExecutionPolicy", "Bypass", "-File"])
            .arg(dir.join("claude-notify.ps1"))
            .args(["-Kind", &kind])
            .env("CLAUDE_NOTIFY_DEBUG", "1")
            .env("CLAUDE_NOTIFY_FORCE", "1")
            .output()
    }
    .map_err(|e| format!("could not run the notifier: {}", e))?;

    Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
}

fn debounce_stamp() -> Option<PathBuf> {
    let tmp = std::env::temp_dir();
    if is_unix() {
        // Namespaced by uid, matching the shell notifier.
        let uid = Command::new("id")
            .arg("-u")
            .output()
            .ok()
            .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
            .unwrap_or_else(|| "0".to_string());
        Some(tmp.join(format!("claude-notify.{}.last", uid)))
    } else {
        Some(tmp.join("claude-notify.last"))
    }
}

/// Copy the notifier and the bundled sounds out of the app into ~/.claude.
///
/// This is what lets the app set up a machine that has never run the shell
/// installer, which is most of the reason for having an app at all. The files
/// are the very ones the installers embed, shipped as Tauri resources, so both
/// front doors put the same thing on disk.
fn write_payload(app: &tauri::AppHandle, dir: &Path) -> Result<(), String> {
    use tauri::Manager;

    let res = app
        .path()
        .resource_dir()
        .map_err(|e| format!("could not find the bundled files: {}", e))?;

    let notifier = if is_unix() {
        "claude-notify.sh"
    } else {
        "claude-notify.ps1"
    };
    let src = res.join("notifier").join(notifier);
    let dst = dir.join(notifier);
    std::fs::copy(&src, &dst).map_err(|e| format!("could not write {}: {}", dst.display(), e))?;

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&dst, std::fs::Permissions::from_mode(0o755));
    }

    // Sounds are only ever added, never replaced: someone may have edited or
    // replaced a file in the default pack and an install should not undo that.
    let sound_src = res.join("sounds").join("default");
    let sound_dst = dir.join("claude-sounds").join("default");
    std::fs::create_dir_all(&sound_dst).map_err(|e| e.to_string())?;
    if let Ok(entries) = std::fs::read_dir(&sound_src) {
        for entry in entries.flatten() {
            let from = entry.path();
            if from.extension().and_then(|e| e.to_str()) != Some("wav") {
                continue;
            }
            let to = sound_dst.join(entry.file_name());
            if !to.exists() {
                let _ = std::fs::copy(&from, &to);
            }
        }
    }

    // The config file is created only if absent, so re-installing never
    // discards options someone has already chosen.
    let conf = dir.join("claude-notify.conf");
    if !conf.exists() {
        let mut text = String::from(
            "# Claude Code sound alerts - options\n\
             #\n\
             # Written by the desktop app. The notifier re-reads this file on every\n\
             # alert, so changes take effect immediately with no restart.\n\n",
        );
        for (k, v) in config::DEFAULTS {
            text.push_str(&format!("{}={}\n", k, v));
        }
        std::fs::write(&conf, text).map_err(|e| e.to_string())?;
    }

    Ok(())
}

#[tauri::command]
fn set_hooks(app: tauri::AppHandle, install: bool) -> Result<usize, String> {
    let dir = config::claude_dir().ok_or("could not work out your home directory")?;
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let path = hooks::settings_path(&dir);

    if install {
        write_payload(&app, &dir)?;
    }

    let mut settings: serde_json::Value = match std::fs::read_to_string(&path) {
        Ok(text) if !text.trim().is_empty() => serde_json::from_str(&text).map_err(|e| {
            format!(
                "settings.json is not valid JSON, so it has been left alone: {}",
                e
            )
        })?,
        _ => serde_json::json!({}),
    };

    // Back up before touching it, same as the installer scripts.
    if path.exists() {
        let stamp = timestamp();
        let backup = dir.join(hooks::backup_name(&stamp));
        std::fs::copy(&path, &backup).map_err(|e| e.to_string())?;
    }

    if install {
        hooks::install(&mut settings, is_unix());
    } else {
        hooks::uninstall(&mut settings);
    }

    // Two-space indent and no BOM, matching what the scripts write.
    let text = serde_json::to_string_pretty(&settings).map_err(|e| e.to_string())?;
    std::fs::write(&path, format!("{}\n", text)).map_err(|e| e.to_string())?;

    Ok(hooks::installed_count(&settings))
}

fn timestamp() -> String {
    // Deliberately not pulling in a date crate for one filename. Seconds since
    // the epoch sorts correctly and is unambiguous, which is all a backup name
    // needs to be.
    let secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    format!("{}", secs)
}

fn main() {
    tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![
            load_state,
            save_settings,
            preview,
            set_hooks
        ])
        .run(tauri::generate_context!())
        .expect("error while running the app");
}
