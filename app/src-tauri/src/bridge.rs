//! The browser link, without a terminal and without Python.
//!
//! There was already a bridge: a small Python program the browser launches over
//! stdin and stdout. It works, but setting it up meant opening a terminal,
//! copying an extension id out of `chrome://extensions`, and having Python
//! installed. That is a fine ask for someone building this, and no ask at all
//! is the right one for someone using it.
//!
//! So the app is the bridge. It is already installed, it is already a program
//! the browser can launch, and it already knows where the notifier lives.
//!
//! Two halves live here:
//!
//!   * [`install`] and [`uninstall`], which write the small manifest each
//!     browser reads to learn that this program exists
//!   * [`run_host`], the stdin and stdout loop the browser talks to
//!
//! Nothing opens a port and nothing runs in the background. The browser starts
//! this program when it has something to say and it exits when the browser
//! closes.

use std::io::{Read, Write};
use std::path::PathBuf;

/// The name the extension asks for. Both sides must agree on it exactly.
pub const HOST_NAME: &str = "com.azyzex.earshot";

/// The extension is allowed to start this program, and nothing else is.
///
/// The id is fixed because the extension carries its own public key, so it is
/// the same on every machine. That is what removed the copy-and-paste step:
/// before, Chrome derived the id from the folder it was loaded from and every
/// install had a different one.
pub const EXTENSION_ID: &str = "gkinjfdcpheaejgdcdmhocpnfianbmpf";

/// Was this process started by a browser rather than by a person?
///
/// Chrome hands a native messaging host the origin of the extension that wants
/// it. Nothing else on this machine passes an argument that looks like that, so
/// it is a reliable way to tell "be the bridge" from "be the app". The manifest
/// format has no way to pass a flag of our own, which is why this is done by
/// inspecting what the browser passes rather than by asking for it.
pub fn launched_by_browser() -> bool {
    std::env::args().any(|a| a.starts_with("chrome-extension://"))
}

/// The extension origin the browser says it is acting for, if any.
fn calling_origin() -> Option<String> {
    std::env::args().find(|a| a.starts_with("chrome-extension://"))
}

fn claude_dir() -> Option<PathBuf> {
    crate::config::claude_dir()
}

// ---------------------------------------------------------------- manifests --

fn manifest_dirs() -> Vec<(&'static str, PathBuf)> {
    let home = dirs_home();
    let Some(home) = home else {
        return Vec::new();
    };
    if cfg!(target_os = "macos") {
        let base = home.join("Library").join("Application Support");
        return vec![
            ("chrome", base.join("Google/Chrome/NativeMessagingHosts")),
            ("edge", base.join("Microsoft Edge/NativeMessagingHosts")),
            ("chromium", base.join("Chromium/NativeMessagingHosts")),
        ];
    }
    if cfg!(target_os = "windows") {
        // Windows keeps the path in the registry rather than a fixed folder, so
        // the manifest lives beside our own data and is pointed at from there.
        return vec![("windows", home.join(".claude"))];
    }
    let cfg = home.join(".config");
    vec![
        ("chrome", cfg.join("google-chrome/NativeMessagingHosts")),
        ("chromium", cfg.join("chromium/NativeMessagingHosts")),
        ("edge", cfg.join("microsoft-edge/NativeMessagingHosts")),
    ]
}

fn dirs_home() -> Option<PathBuf> {
    std::env::var_os("HOME")
        .or_else(|| std::env::var_os("USERPROFILE"))
        .map(PathBuf::from)
}

fn manifest_json(program: &str) -> String {
    // Written by hand rather than through a serialiser: it is four fields, and
    // seeing the exact shape the browser expects is worth more here than the
    // machinery to generate it.
    format!(
        "{{\n  \"name\": \"{}\",\n  \"description\": \"Earshot Bridge, by Azyzex\",\n  \
         \"path\": {},\n  \"type\": \"stdio\",\n  \
         \"allowed_origins\": [\"chrome-extension://{}/\"]\n}}\n",
        HOST_NAME,
        // The path needs JSON escaping, which on Windows means every backslash.
        serde_json::to_string(program).unwrap_or_else(|_| "\"\"".to_string()),
        trusted_id()
    )
}

/// Tell the browsers on this machine that the bridge exists.
/// Whichever id we were told to trust, falling back to the pinned one.
///
/// The pinned id is right for a fresh install, but Chrome assigns an unpacked
/// extension its id the first time it is loaded and keeps it. An extension
/// loaded before the key existed therefore has a different one, and the
/// allowlist would never match. Rather than telling people to remove and
/// re-add it, the app takes the id it is given.
fn trusted_id() -> String {
    claude_dir()
        .map(|d| d.join("earshot-extension-id"))
        .and_then(|p| std::fs::read_to_string(p).ok())
        .map(|s| s.trim().to_string())
        .filter(|s| s.len() == 32 && s.chars().all(|c| c.is_ascii_lowercase()))
        .unwrap_or_else(|| EXTENSION_ID.to_string())
}

pub fn set_trusted_id(id: &str) -> Result<(), String> {
    let id = id.trim();
    if id.len() != 32 || !id.chars().all(|c| c.is_ascii_lowercase()) {
        return Err("That does not look like an extension id.".to_string());
    }
    let dir = claude_dir().ok_or("no home directory")?;
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    std::fs::write(dir.join("earshot-extension-id"), id).map_err(|e| e.to_string())
}

pub fn install() -> Result<String, String> {
    let exe = std::env::current_exe()
        .map_err(|e| format!("could not find this program on disk: {}", e))?;
    let program = exe.to_string_lossy().to_string();

    let mut written = Vec::new();
    for (_, dir) in manifest_dirs() {
        if std::fs::create_dir_all(&dir).is_err() {
            continue;
        }
        let path = dir.join(format!("{}.json", HOST_NAME));
        if std::fs::write(&path, manifest_json(&program)).is_ok() {
            written.push(path);
        }
    }

    if written.is_empty() {
        return Err("could not write the browser manifest".to_string());
    }

    #[cfg(windows)]
    {
        let path = written[0].to_string_lossy().to_string();
        registry_write(&path)?;
    }

    Ok("Connected. Turn the link on in the extension too.".to_string())
}

pub fn uninstall() -> Result<String, String> {
    for (_, dir) in manifest_dirs() {
        let _ = std::fs::remove_file(dir.join(format!("{}.json", HOST_NAME)));
    }
    #[cfg(windows)]
    {
        registry_remove();
    }
    Ok("Disconnected.".to_string())
}

/// Whether the browsers on this machine currently know about the bridge.
pub fn is_installed() -> bool {
    manifest_dirs()
        .into_iter()
        .any(|(_, dir)| dir.join(format!("{}.json", HOST_NAME)).is_file())
}

#[cfg(windows)]
fn registry_keys() -> [String; 2] {
    [
        format!(r"Software\Google\Chrome\NativeMessagingHosts\{}", HOST_NAME),
        format!(
            r"Software\Microsoft\Edge\NativeMessagingHosts\{}",
            HOST_NAME
        ),
    ]
}

/// Chromium on Windows finds a host through the registry, not a folder.
///
/// Shelling out to `reg` rather than taking a registry crate: two values under
/// the current user is not worth a dependency, and this is the same tool the
/// rest of the app already uses for the start-with-Windows setting.
#[cfg(windows)]
fn registry_write(path: &str) -> Result<(), String> {
    let mut ok = false;
    for key in registry_keys() {
        let status = crate::spawn("reg")
            .args([
                "add",
                &format!(r"HKCU\{}", key),
                "/ve",
                "/t",
                "REG_SZ",
                "/d",
                path,
                "/f",
            ])
            .status();
        if matches!(status, Ok(s) if s.success()) {
            ok = true;
        }
    }
    if ok {
        Ok(())
    } else {
        Err("could not register the bridge with your browser".to_string())
    }
}

#[cfg(windows)]
fn registry_remove() {
    for key in registry_keys() {
        let _ = crate::spawn("reg")
            .args(["delete", &format!(r"HKCU\{}", key), "/f"])
            .status();
    }
}

// --------------------------------------------------------------- the host ---

/// The only things the extension may ask for.
///
/// Deliberately tiny. It cannot name a file, a command, a url, or any text to
/// show. The worst a compromised extension achieves through this is one of
/// three sounds, or a countdown set to a time it claims a window resets.
const ALLOWED: [&str; 3] = ["done", "blocked", "limit"];

fn read_message() -> Option<serde_json::Value> {
    let mut header = [0u8; 4];
    std::io::stdin().read_exact(&mut header).ok()?;
    let length = u32::from_le_bytes(header) as usize;
    // Nothing legitimate comes near this. It stops a malformed header from
    // asking us to allocate a gigabyte.
    if length > 64 * 1024 {
        return None;
    }
    let mut body = vec![0u8; length];
    std::io::stdin().read_exact(&mut body).ok()?;
    serde_json::from_slice(&body).ok()
}

fn write_message(value: &serde_json::Value) -> std::io::Result<()> {
    let data = serde_json::to_vec(value)?;
    let mut out = std::io::stdout();
    out.write_all(&(data.len() as u32).to_le_bytes())?;
    out.write_all(&data)?;
    out.flush()
}

/// Hand an alert to the notifier that is already installed.
///
/// Reusing it rather than making a sound here means a browser alert is
/// identical to a terminal one: same sound, same mute, same quiet hours, same
/// log.
fn notify(kind: &str) {
    let Some(dir) = claude_dir() else { return };
    let (program, args): (&str, Vec<String>) = if cfg!(target_os = "windows") {
        (
            "powershell.exe",
            vec![
                "-NoProfile".into(),
                "-ExecutionPolicy".into(),
                "Bypass".into(),
                "-File".into(),
                dir.join("claude-notify.ps1").to_string_lossy().into(),
                "-Kind".into(),
                kind.into(),
            ],
        )
    } else {
        (
            "bash",
            vec![
                dir.join("claude-notify.sh").to_string_lossy().into(),
                kind.into(),
            ],
        )
    };
    let _ = crate::spawn(program)
        .args(&args)
        .env("CLAUDE_NOTIFY_SOURCE", "web")
        .spawn();
}

fn store_limits(message: &serde_json::Value) -> Result<(), &'static str> {
    let account = message
        .get("account")
        .and_then(|v| v.as_str())
        .unwrap_or("");
    // A hash and nothing else. It is what keeps two signed-in accounts from
    // being reported under each other's name, so it is checked rather than
    // trusted.
    if account.len() < 6
        || account.len() > 32
        || !account
            .chars()
            .all(|c| c.is_ascii_hexdigit() && !c.is_uppercase())
    {
        return Err("bad account");
    }

    let mut lines = vec![
        format!("updated={}", crate::limits::epoch_now()),
        "source=web".to_string(),
        format!("account={}", account),
    ];
    let mut any = false;
    for name in ["five_hour", "seven_day"] {
        let Some(w) = message.get(name) else { continue };
        let used = w.get("utilization").and_then(|v| v.as_f64());
        let at = w.get("resets_at").and_then(|v| v.as_str());
        let (Some(used), Some(at)) = (used, at) else {
            continue;
        };
        if !(0.0..=100.0).contains(&used) {
            continue;
        }
        let Some(epoch) = crate::limits::parse_iso8601(at) else {
            continue;
        };
        // A reset is soon by definition. A bogus far-future time would quietly
        // mean no alert ever, which is worse than refusing it.
        let ahead = epoch - crate::limits::epoch_now();
        if !(-3600..=8 * 24 * 3600).contains(&ahead) {
            continue;
        }
        lines.push(format!("{}_resets_at={}", name, epoch));
        lines.push(format!("{}_used={}", name, used.round() as i64));
        any = true;
    }
    if !any {
        return Err("no usable window");
    }

    let Some(dir) = claude_dir() else {
        return Err("no home directory");
    };
    let target = dir.join("claude-limits.d");
    std::fs::create_dir_all(&target).map_err(|_| "could not save")?;
    let path = target.join("web.conf");
    let tmp = target.join("web.conf.tmp");
    std::fs::write(&tmp, lines.join("\n") + "\n").map_err(|_| "could not save")?;
    std::fs::rename(&tmp, &path).map_err(|_| "could not save")?;
    Ok(())
}

/// Record that the browser was here.
///
/// The app cannot start a conversation with the extension: native messaging is
/// browser-initiated, always. So the app proves the link by reporting when the
/// browser last spoke to it, which is the honest half it can actually observe.
fn stamp_contact(kind: &str) {
    let Some(dir) = claude_dir() else { return };
    let _ = std::fs::create_dir_all(&dir);
    let _ = std::fs::write(
        dir.join("earshot-last-contact"),
        format!(
            "{}
{}
",
            crate::limits::epoch_now(),
            kind
        ),
    );
}

fn handle(message: &serde_json::Value) -> serde_json::Value {
    let kind = message.get("kind").and_then(|v| v.as_str()).unwrap_or("");
    stamp_contact(kind);
    let kind = message.get("kind").and_then(|v| v.as_str()).unwrap_or("");
    // A ping so the extension can prove the link works instead of assuming it.
    // It does nothing and says so, which is the point.
    if kind == "ping" {
        return serde_json::json!({
            "ok": true,
            "app": env!("CARGO_PKG_VERSION"),
            "notifier": claude_dir()
                .map(|d| d.join(if cfg!(target_os = "windows") {
                    "claude-notify.ps1"
                } else {
                    "claude-notify.sh"
                }).is_file())
                .unwrap_or(false),
        });
    }
    if kind == "limits" {
        return match store_limits(message) {
            Ok(()) => serde_json::json!({"ok": true, "stored": true}),
            Err(e) => serde_json::json!({"ok": false, "error": e}),
        };
    }
    if !ALLOWED.contains(&kind) {
        return serde_json::json!({"ok": false, "error": "unknown kind"});
    }
    notify(kind);
    serde_json::json!({"ok": true})
}

/// Where the app leaves a message for the browser.
///
/// The app and the bridge are different processes: Chrome starts the bridge,
/// not us, so the window cannot write to its pipe directly. It leaves a line in
/// this file instead and the bridge, which is holding the pipe, passes it on.
/// That is what makes a test from the app to the browser possible at all.
pub fn outbox_path() -> Option<PathBuf> {
    claude_dir().map(|d| d.join("earshot-outbox"))
}

/// Watch for anything the app wants said to the browser, and say it.
///
/// Only runs while the browser has a port open, so nothing here keeps a process
/// alive on its own.
fn start_outbox_watcher() {
    std::thread::spawn(|| {
        loop {
            std::thread::sleep(std::time::Duration::from_millis(400));
            let Some(path) = outbox_path() else { return };
            let Ok(text) = std::fs::read_to_string(&path) else {
                continue;
            };
            let _ = std::fs::remove_file(&path);
            let kind = text.trim();
            // One word, checked against a list. The file is ours, but a file is
            // still the sort of thing that gets edited.
            if !["test", "done", "blocked", "limit"].contains(&kind) {
                continue;
            }
            if write_message(&serde_json::json!({ "from": "app", "kind": kind })).is_err() {
                return;
            }
        }
    });
}

/// Talk to the browser until it closes the pipe.
pub fn run_host() {
    // The manifest already restricts who may start this, and the browser
    // enforces that before any of this code runs. Checking again costs nothing
    // and means a manifest edited by hand cannot quietly widen the door.
    if let Some(origin) = calling_origin() {
        if !origin.contains(trusted_id().as_str()) {
            return;
        }
    }

    start_outbox_watcher();

    let mut last = std::time::Instant::now() - std::time::Duration::from_secs(60);
    while let Some(message) = read_message() {
        let kind = message.get("kind").and_then(|v| v.as_str()).unwrap_or("");
        // Alerts are rate limited so a misbehaving page cannot become a noise
        // machine. Limit readings are not: they make no sound and arrive on a
        // ten minute timer anyway.
        let reply = if kind != "limits" && last.elapsed() < std::time::Duration::from_secs(3) {
            serde_json::json!({"ok": true, "skipped": "too soon"})
        } else {
            if kind != "limits" {
                last = std::time::Instant::now();
            }
            handle(&message)
        };
        if write_message(&reply).is_err() {
            return;
        }
    }
}

/// Everything worth knowing about whether the link will actually work.
///
/// A switch that reports only "on" is no help when it is on and nothing
/// happens. This says where the manifest went, whether the browser can find it,
/// and whether the notifier it would call even exists.
#[derive(serde::Serialize)]
pub struct Status {
    pub installed: bool,
    pub extension_id: String,
    /// Full paths of every manifest found, so a wrong one can be seen.
    pub manifests: Vec<String>,
    /// Windows only: whether the registry points at us.
    pub registered: Option<bool>,
    /// The program the manifest names, which should be this app.
    pub program: String,
    /// Whether the notifier the bridge would hand alerts to is installed.
    pub notifier: bool,
    /// Where the browser's usage readings land, once any arrive.
    pub last_reading: Option<String>,
    /// When the browser last spoke to us, and what it said.
    pub last_contact: Option<String>,
}

pub fn status() -> Status {
    let manifests: Vec<String> = manifest_dirs()
        .into_iter()
        .map(|(_, dir)| dir.join(format!("{}.json", HOST_NAME)))
        .filter(|p| p.is_file())
        .map(|p| p.display().to_string())
        .collect();

    let program = std::env::current_exe()
        .map(|p| p.display().to_string())
        .unwrap_or_else(|_| "unknown".to_string());

    let notifier = claude_dir()
        .map(|d| {
            d.join(if cfg!(target_os = "windows") {
                "claude-notify.ps1"
            } else {
                "claude-notify.sh"
            })
            .is_file()
        })
        .unwrap_or(false);

    let last_reading = claude_dir()
        .map(|d| d.join("claude-limits.d").join("web.conf"))
        .filter(|p| p.is_file())
        .map(|p| p.display().to_string());

    Status {
        installed: !manifests.is_empty(),
        extension_id: trusted_id(),
        manifests,
        registered: registry_present(),
        program,
        notifier,
        last_reading,
        last_contact: claude_dir()
            .map(|d| d.join("earshot-last-contact"))
            .and_then(|p| std::fs::read_to_string(p).ok())
            .and_then(|text| {
                let mut lines = text.lines();
                let at: i64 = lines.next()?.trim().parse().ok()?;
                let kind = lines.next().unwrap_or("something").trim().to_string();
                let ago = crate::limits::epoch_now() - at;
                Some(format!(
                    "{} ({})",
                    crate::limits::human_gap(ago.max(1)),
                    kind
                ))
            }),
    }
}

#[cfg(windows)]
fn registry_present() -> Option<bool> {
    let key = format!(
        r"HKCU\Software\Google\Chrome\NativeMessagingHosts\{}",
        HOST_NAME
    );
    let out = crate::spawn("reg").args(["query", &key]).output();
    Some(matches!(out, Ok(o) if o.status.success()))
}

#[cfg(not(windows))]
fn registry_present() -> Option<bool> {
    None
}
