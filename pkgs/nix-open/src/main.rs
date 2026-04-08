use clap::Parser;
use std::fs;
use std::path::PathBuf;
use std::process::Command;

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

    /// Application name(s) (without .app suffix).
    #[arg(required = true)]
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

/// Get the executable path of a running process by app name.
fn running_app_exe(app_name: &str) -> Option<(u32, String)> {
    let pgrep = Command::new("pgrep")
        .args(["-xi", app_name])
        .output()
        .ok()?;
    if !pgrep.status.success() {
        return None;
    }
    let pid_str = String::from_utf8_lossy(&pgrep.stdout)
        .lines()
        .next()?
        .trim()
        .to_string();
    let pid: u32 = pid_str.parse().ok()?;

    let ps = Command::new("ps")
        .args(["-p", &pid_str, "-o", "comm="])
        .output()
        .ok()?;
    let exe = String::from_utf8_lossy(&ps.stdout).trim().to_string();
    if exe.is_empty() { None } else { Some((pid, exe)) }
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

fn handle_open_app(name: &str, restart: bool, new_instance: bool) -> bool {
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
