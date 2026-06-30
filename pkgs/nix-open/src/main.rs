use clap::Parser;
use std::fs;
use std::path::PathBuf;
use std::process::{Command, Stdio};

#[derive(Parser)]
#[command(name = "nix-open")]
#[command(about = "Nix-aware macOS application launcher")]
#[command(long_about = "Open macOS applications installed via Nix (home-manager, nix-darwin, nix-casks).\n\n\
Searches Nix app directories first, then system directories, so the version\n\
installed by `decknix switch` or `nix profile install` is always preferred.\n\n\
Search order:\n  \
~/Applications/Home Manager Apps/\n  \
~/Applications/Nix Apps/\n  \
/Applications/\n  \
~/Applications/")]
struct Cli {
    /// Restart the app: quit the running instance then reopen.
    /// Useful after `decknix switch` to pick up a new Nix store version.
    #[arg(short, long)]
    restart: bool,

    /// Open a new instance even if already running.
    #[arg(short, long)]
    new: bool,

    /// Restart all running Nix-managed apps that have stale store paths.
    /// Requires --restart (-r). Discovers apps in Home Manager Apps and
    /// Nix Apps directories, checks which are running from an old store
    /// path, and restarts only those.
    #[arg(short, long, requires = "restart")]
    all: bool,

    /// Application name(s) (without .app suffix).
    /// Not required when --all is used.
    #[arg(required_unless_present = "all")]
    apps: Vec<String>,
}

// ---------------------------------------------------------------------------
// App search
// ---------------------------------------------------------------------------

/// App search directories, in priority order.
fn app_search_dirs() -> Vec<PathBuf> {
    let home = dirs::home_dir().unwrap_or_default();
    vec![
        home.join("Applications/Home Manager Apps"),
        home.join("Applications/Nix Apps"),
        PathBuf::from("/Applications"),
        home.join("Applications"),
    ]
}

/// Nix-only app directories (for --all scanning).
fn nix_app_dirs() -> Vec<PathBuf> {
    let home = dirs::home_dir().unwrap_or_default();
    vec![
        home.join("Applications/Home Manager Apps"),
        home.join("Applications/Nix Apps"),
    ]
}

/// Extract the nix store hash (first 32 chars after /nix/store/) from a path.
fn nix_store_hash(path: &str) -> Option<&str> {
    let rest = path.strip_prefix("/nix/store/")?;
    rest.get(..32)
}

/// Find all running Nix-managed apps whose store hash differs from the
/// currently installed version. Deduplicates by app name (Home Manager
/// Apps takes priority over Nix Apps).
fn find_stale_nix_apps() -> Vec<(String, PathBuf)> {
    let mut seen = std::collections::HashSet::new();
    let mut stale = Vec::new();
    for dir in nix_app_dirs() {
        if !dir.is_dir() {
            continue;
        }
        let entries = match fs::read_dir(&dir) {
            Ok(e) => e,
            Err(_) => continue,
        };
        for entry in entries.flatten() {
            let path = entry.path();
            let name = match path.file_name() {
                Some(n) => n.to_string_lossy().replace(".app", ""),
                None => continue,
            };
            // Deduplicate: same app may appear in both directories
            if !seen.insert(name.clone()) {
                continue;
            }
            // Is this app running?
            let (_, exe_path) = match running_app_exe(&name) {
                Some(pair) => pair,
                None => continue,
            };
            // What store path does the symlink/bundle point to now?
            let installed = match resolved_app_store_path(&path) {
                Some(p) => p,
                None => continue,
            };
            // Compare store *hashes* — more reliable than derivation names
            // (e.g. "emacs-30.2" vs "emacs-with-packages-30.2" are different
            // derivation names but might be the same or different builds)
            let running_hash = nix_store_hash(&exe_path);
            let installed_hash = nix_store_hash(&installed);
            match (running_hash, installed_hash) {
                (Some(old), Some(new)) if old != new => {
                    stale.push((name, path));
                }
                _ => {}
            }
        }
    }
    stale
}


/// Find an application bundle by name (case-insensitive).
fn find_app(name: &str) -> Option<PathBuf> {
    let target = format!("{}.app", name);
    for dir in app_search_dirs() {
        if !dir.is_dir() {
            continue;
        }
        let candidate = dir.join(&target);
        if candidate.exists() {
            return Some(candidate);
        }
        // Case-insensitive fallback
        if let Ok(entries) = fs::read_dir(&dir) {
            for entry in entries.flatten() {
                let fname = entry.file_name().to_string_lossy().to_string();
                if fname.eq_ignore_ascii_case(&target) {
                    return Some(entry.path());
                }
            }
        }
    }
    None
}

// ---------------------------------------------------------------------------
// Nix store helpers
// ---------------------------------------------------------------------------

/// Extract the derivation name-version (e.g. "amethyst-0.24.3") from a store path.
fn nix_store_label(path: &str) -> Option<String> {
    let rest = path.strip_prefix("/nix/store/")?;
    let after_hash = rest.get(33..)?; // skip 32-char hash + dash
    Some(after_hash.split('/').next()?.to_string())
}

/// Resolve the Nix store path that an app bundle points to.
fn resolved_app_store_path(app_path: &PathBuf) -> Option<String> {
    if app_path.is_symlink() {
        let target = fs::read_link(app_path).ok()?;
        return Some(target.to_string_lossy().to_string());
    }
    // Check Contents/MacOS executables for /nix/store references
    let macos_dir = app_path.join("Contents/MacOS");
    if let Ok(entries) = fs::read_dir(&macos_dir) {
        for entry in entries.flatten() {
            let p = entry.path();
            if p.is_file() || p.is_symlink() {
                let resolved = fs::canonicalize(&p).ok()?;
                let s = resolved.to_string_lossy().to_string();
                if s.starts_with("/nix/store/") {
                    return Some(s);
                }
            }
        }
    }
    None
}

// ---------------------------------------------------------------------------
// Process helpers
// ---------------------------------------------------------------------------

/// Check whether a process is a background daemon (e.g. `emacs --fg-daemon`).
/// These are managed by launchd and must not be killed by nix-open.
fn is_daemon_process(pid: u32) -> bool {
    let ps = Command::new("ps")
        .args(["-p", &pid.to_string(), "-o", "args="])
        .output()
        .ok();
    match ps {
        Some(output) => {
            let args = String::from_utf8_lossy(&output.stdout);
            args.contains("--daemon") || args.contains("--fg-daemon")
        }
        None => false,
    }
}

/// Get the executable path of a running foreground process by app name.
/// Skips daemon processes (--daemon / --fg-daemon) which are managed by
/// launchd and should not be restarted by nix-open.
fn running_app_exe(app_name: &str) -> Option<(u32, String)> {
    let pgrep = Command::new("pgrep")
        .args(["-xi", app_name])
        .output()
        .ok()?;
    if !pgrep.status.success() {
        return None;
    }
    // Iterate all matching PIDs — skip daemons, return first foreground match.
    for line in String::from_utf8_lossy(&pgrep.stdout).lines() {
        let pid_str = line.trim();
        let pid: u32 = match pid_str.parse() {
            Ok(p) => p,
            Err(_) => continue,
        };
        if is_daemon_process(pid) {
            continue;
        }
        let ps = Command::new("ps")
            .args(["-p", pid_str, "-o", "comm="])
            .output()
            .ok();
        if let Some(output) = ps {
            let exe = String::from_utf8_lossy(&output.stdout).trim().to_string();
            if !exe.is_empty() {
                return Some((pid, exe));
            }
        }
    }
    None
}

/// Gracefully quit a macOS application via AppleScript.
fn quit_app(app_name: &str) -> bool {
    let script = format!("tell application \"{}\" to quit", app_name);
    Command::new("osascript")
        .args(["-e", &script])
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

/// Wait for a process to exit, polling up to `timeout` seconds.
fn wait_for_exit(app_name: &str, timeout_secs: u64) -> bool {
    let deadline = std::time::Instant::now()
        + std::time::Duration::from_secs(timeout_secs);
    while std::time::Instant::now() < deadline {
        if running_app_exe(app_name).is_none() {
            return true;
        }
        std::thread::sleep(std::time::Duration::from_millis(250));
    }
    false
}

/// Open an application bundle via macOS `open`.
fn open_app(app_path: &PathBuf, new_instance: bool) -> bool {
    let mut cmd = Command::new("open");
    if new_instance {
        cmd.arg("-n");
    }
    cmd.arg(app_path);
    cmd.status().map(|s| s.success()).unwrap_or(false)
}

// ---------------------------------------------------------------------------
// Main handler per app
// ---------------------------------------------------------------------------

fn app_display_name(app_path: &PathBuf) -> String {
    app_path
        .file_name()
        .unwrap_or_default()
        .to_string_lossy()
        .replace(".app", "")
}

fn app_source_label(app_path: &PathBuf) -> &'static str {
    let home = dirs::home_dir().unwrap_or_default();
    if app_path.starts_with(home.join("Applications/Home Manager Apps")) {
        "Home Manager"
    } else if app_path.starts_with(home.join("Applications/Nix Apps")) {
        "Nix Apps"
    } else {
        "system"
    }
}

/// Resolve the `emacsclient` binary, preferring the Nix profile copy
/// (reliable in GUI launcher contexts where PATH may not include Nix paths)
/// with a bare-name PATH fallback.
fn emacsclient_path() -> String {
    let home = dirs::home_dir().unwrap_or_default();
    let nix_client = home.join(".nix-profile/bin/emacsclient");
    if nix_client.exists() {
        nix_client.to_string_lossy().into_owned()
    } else {
        "emacsclient".to_string()
    }
}

/// `emacsclient` arguments to create a new GUI frame on the running daemon:
/// `-c` (new frame), `-n` (return immediately — no shell prompt wait).
///
/// Deliberately omits the `-a ""` alternate-editor fallback.  `-a ""` makes
/// emacsclient spawn an *unmanaged* `emacs --daemon` whenever the launchd
/// server is momentarily down — leaking orphan daemons that launchd never
/// reaps (the historical source of runaway Emacs processes).  We connect to
/// the launchd-managed daemon only, and kickstart that service explicitly
/// when it is not answering (see `handle_emacs_daemon_frame`).
fn emacsclient_frame_args() -> &'static [&'static str] {
    &["-c", "-n"]
}

/// `launchctl` arguments that ensure the launchd-managed Emacs daemon is
/// running.  `kickstart` (without `-k`) starts the service if it is not
/// running and is a no-op if it already is — so it never kills a healthy
/// daemon, unlike `kickstart -k`.
fn launchctl_ensure_args(uid: u32) -> Vec<String> {
    vec![
        "kickstart".to_string(),
        format!("gui/{}/org.nixos.emacs-server", uid),
    ]
}

/// Attempt to create the GUI frame.  Returns true on success.
fn try_emacs_frame(client: &str) -> bool {
    Command::new(client)
        .args(emacsclient_frame_args())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

/// Bring the Emacs frame to the foreground.  The daemon runs with
/// ProcessType=Background so macOS does not automatically raise its windows;
/// an explicit AppleScript activate call is required.
fn activate_emacs_app() {
    let _ = Command::new("osascript")
        .args(["-e", "tell application \"Emacs\" to activate"])
        .status();
}

/// Return true once the launchd Emacs daemon answers an `emacsclient` eval.
/// Polls up to `timeout_secs`.  Uses a no-op eval (`-e t`) WITHOUT `-a ""`,
/// so it never spawns a daemon — it only detects when the kickstarted server
/// has finished initialising and opened its socket.
fn wait_for_emacs_daemon(client: &str, timeout_secs: u64) -> bool {
    let deadline = std::time::Instant::now()
        + std::time::Duration::from_secs(timeout_secs);
    while std::time::Instant::now() < deadline {
        let ready = Command::new(client)
            .args(["-e", "t"])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .map(|s| s.success())
            .unwrap_or(false);
        if ready {
            return true;
        }
        std::thread::sleep(std::time::Duration::from_millis(300));
    }
    false
}

/// Create a new Emacs GUI frame on the launchd-managed daemon.
///
/// Never spawns an unmanaged orphan daemon: it connects to the existing
/// launchd server, and if that server is not answering it kickstarts
/// `org.nixos.emacs-server` (launchd-managed, so it is supervised and reaped)
/// and retries once the socket is ready.
fn handle_emacs_daemon_frame() -> bool {
    let client = emacsclient_path();
    eprintln!("🖥️  Emacs: creating daemon frame via emacsclient");

    // First attempt: connect to the launchd-managed daemon (no `-a ""`).
    if try_emacs_frame(&client) {
        activate_emacs_app();
        eprintln!("   ✅ Emacs frame opened");
        return true;
    }

    // Daemon not answering — kickstart the launchd service and retry once
    // its socket is ready, rather than letting emacsclient orphan-spawn one.
    eprintln!("   ⏳ daemon not responding — kickstarting org.nixos.emacs-server");
    let uid = unsafe { libc::getuid() };
    let _ = Command::new("launchctl")
        .args(launchctl_ensure_args(uid))
        .status();

    if wait_for_emacs_daemon(&client, 20) && try_emacs_frame(&client) {
        activate_emacs_app();
        eprintln!("   ✅ Emacs frame opened");
        return true;
    }

    eprintln!(
        "   ❌ org.nixos.emacs-server did not come up — try: \
         launchctl kickstart -k gui/$(id -u)/org.nixos.emacs-server"
    );
    false
}

fn handle_open_app(name: &str, restart: bool, new_instance: bool) -> bool {
    // Special case: Emacs — connect to the running daemon instead of
    // spawning a separate standalone Emacs.app process.  This keeps all
    // buffers, LSP servers, and session caches in one shared heap.
    // `--restart` still falls through to quit+reopen the app normally.
    if name.eq_ignore_ascii_case("emacs") && !restart {
        return handle_emacs_daemon_frame();
    }

    let app_path = match find_app(name) {
        Some(p) => p,
        None => {
            eprintln!("❌ {} — not found in any application directory", name);
            return false;
        }
    };

    let display = app_display_name(&app_path);
    let installed_label = resolved_app_store_path(&app_path)
        .and_then(|p| nix_store_label(&p));

    if restart {
        if let Some((pid, exe_path)) = running_app_exe(name) {
            let running_label = nix_store_label(&exe_path);
            match (&running_label, &installed_label) {
                (Some(old), Some(new)) if old != new => {
                    eprintln!("🔄 {} → {} (pid {})", old, new, pid);
                }
                (Some(cur), _) => {
                    eprintln!("🔄 {} (restarting, pid {})", cur, pid);
                }
                _ => {
                    eprintln!("🔄 {} (restarting, pid {})", display, pid);
                }
            }
            if !quit_app(&display) {
                eprintln!("   ⚠️  AppleScript quit failed, sending SIGTERM...");
                unsafe { libc::kill(pid as i32, libc::SIGTERM); }
            }
            if !wait_for_exit(name, 5) {
                eprintln!("   ⚠️  Still running after 5s, sending SIGKILL...");
                unsafe { libc::kill(pid as i32, libc::SIGKILL); }
                std::thread::sleep(std::time::Duration::from_millis(500));
            }
        } else {
            if let Some(label) = &installed_label {
                eprintln!("📦 {} (not running, opening)", label);
            } else {
                eprintln!("📦 {} (not running, opening)", display);
            }
        }
    } else if !new_instance {
        let source = app_source_label(&app_path);
        if let Some(label) = &installed_label {
            eprintln!("📦 {} ({})", label, source);
        } else {
            eprintln!("📦 {} ({})", display, source);
        }
    }

    if open_app(&app_path, new_instance) {
        eprintln!("   ✅ {}", display);
        true
    } else {
        eprintln!("   ❌ {} — failed to open", display);
        false
    }
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

fn main() {
    let cli = Cli::parse();

    if cli.all {
        // --restart --all: find and restart stale Nix-managed apps
        let stale = find_stale_nix_apps();
        if stale.is_empty() {
            eprintln!("✅ All running Nix apps are up to date.");
            return;
        }
        eprintln!("Found {} stale app(s):", stale.len());
        let mut all_ok = true;
        for (name, _) in &stale {
            if !handle_open_app(name, true, false) {
                all_ok = false;
            }
        }
        if !all_ok {
            std::process::exit(1);
        }
    } else {
        let mut all_ok = true;
        for name in &cli.apps {
            if !handle_open_app(name, cli.restart, cli.new) {
                all_ok = false;
            }
        }
        if !all_ok {
            std::process::exit(1);
        }
    }
}


#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn frame_args_never_use_alternate_editor() {
        // The orphan-daemon footgun is the `-a ""` alternate-editor fallback;
        // it must never be present, or a down launchd server gets shadowed by
        // an unmanaged `emacs --daemon`.
        let args = emacsclient_frame_args();
        assert!(!args.contains(&"-a"), "frame args must not include -a");
        assert_eq!(args, &["-c", "-n"]);
    }

    #[test]
    fn launchctl_targets_the_launchd_emacs_service() {
        assert_eq!(
            launchctl_ensure_args(501),
            vec![
                "kickstart".to_string(),
                "gui/501/org.nixos.emacs-server".to_string(),
            ]
        );
        // `kickstart` (no `-k`) so a healthy daemon is never killed/restarted.
        assert!(
            !launchctl_ensure_args(501).contains(&"-k".to_string()),
            "ensure must not force-restart with -k"
        );
    }
}
