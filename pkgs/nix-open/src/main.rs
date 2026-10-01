use clap::Parser;
use std::fs;
use std::path::PathBuf;
use std::process::{Command, Output, Stdio};
use std::thread;
use std::time::{Duration, Instant};

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
    /// Restart the app. For Emacs, restart the launchd daemon (loses open
    /// buffers), wait for readiness, then create a frame.
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

    /// Show status of a running app: whether it's running the latest
    /// Nix-deployed version or needs a restart. For Emacs, also shows
    /// daemon uptime.
    #[arg(short, long)]
    status: bool,

    /// Wait for the app to be ready after opening/restarting.
    /// For Emacs: polls until the daemon responds to emacsclient.
    /// For other apps: waits until the process is running.
    /// Emacs waits until ready (Ctrl-C to cancel); other apps time out after 60s.
    #[arg(short, long)]
    wait: bool,

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

/// Explicit restart only: `kickstart -k` kills the existing daemon and loses
/// all in-memory Emacs buffers. Plain `nix-open emacs` must never call this.
fn launchctl_restart_args(uid: u32) -> Vec<String> {
    vec![
        "kickstart".to_string(),
        "-k".to_string(),
        format!("gui/{}/org.nixos.emacs-server", uid),
    ]
}

fn should_ensure_emacs_launchd(pid: Option<u32>) -> bool {
    pid.is_none()
}

const EMACS_PROBE_TIMEOUT: Duration = Duration::from_secs(2);
const EMACS_POLL_INTERVAL: Duration = Duration::from_millis(500);
const EMACS_PROGRESS_INTERVAL: Duration = Duration::from_secs(5);

/// A client eval must not block the progress reporter indefinitely when the
/// socket exists but Emacs is busy in synchronous init code. Reap timed-out
/// clients; never touch the daemon during a probe.
fn emacsclient_eval(client: &str, expression: &str, timeout: Duration) -> Option<Output> {
    let mut child = Command::new(client)
        .args(["-e", expression])
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;
    let start = Instant::now();
    loop {
        match child.try_wait() {
            Ok(Some(_)) => return child.wait_with_output().ok(),
            Ok(None) if start.elapsed() < timeout => thread::sleep(Duration::from_millis(100)),
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                return None;
            }
        }
    }
}

fn emacs_daemon_responding(client: &str) -> bool {
    emacsclient_eval(client, "t", EMACS_PROBE_TIMEOUT).is_some_and(|out| out.status.success())
}

fn emacs_wait_progress(elapsed: Duration, pid: Option<u32>) -> String {
    match pid {
        Some(pid) => format!(
            "Emacs daemon PID {pid} is still initializing or busy ({}s); waiting...",
            elapsed.as_secs()
        ),
        None => format!(
            "Waiting for launchd Emacs daemon ({}s); still retrying...",
            elapsed.as_secs()
        ),
    }
}

/// No arbitrary cold-start deadline: return only once the daemon responds.
fn poll_until_emacs_ready<F, G>(
    mut probe: F,
    interval: Duration,
    progress_interval: Duration,
    mut report: G,
) -> Duration
where
    F: FnMut() -> bool,
    G: FnMut(Duration),
{
    let start = Instant::now();
    let mut next_report = start + progress_interval;
    loop {
        if probe() {
            return start.elapsed();
        }
        if Instant::now() >= next_report {
            report(start.elapsed());
            next_report = Instant::now() + progress_interval;
        }
        thread::sleep(interval);
    }
}

fn wait_for_emacs_daemon(client: &str, uid: u32) {
    eprintln!("   ⏳ Waiting for Emacs server (Ctrl-C to stop waiting; daemon stays running)");
    let elapsed = poll_until_emacs_ready(
        || emacs_daemon_responding(client),
        EMACS_POLL_INTERVAL,
        EMACS_PROGRESS_INTERVAL,
        |elapsed| eprintln!("   ⏳ {}", emacs_wait_progress(elapsed, daemon_pid(uid))),
    );
    eprintln!("   ✅ Emacs server ready ({:.1}s)", elapsed.as_secs_f32());
}

/// Create a GUI frame only after the server answers a readiness probe.
/// Leave stderr visible if frame creation itself fails.
fn try_emacs_frame(client: &str) -> bool {
    Command::new(client)
        .args(emacsclient_frame_args())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

// ---------------------------------------------------------------------------
// Wait for app readiness (--wait flag)
// ---------------------------------------------------------------------------

const WAIT_FLAG_TIMEOUT_SECS: u64 = 60;
const WAIT_FLAG_POLL_INTERVAL_MS: u64 = 500;

/// Wait for a generic app to be running (by process name).
/// Returns true if app is found running, false on timeout.
fn wait_for_app_process(name: &str) -> bool {
    let start = Instant::now();
    let timeout = Duration::from_secs(WAIT_FLAG_TIMEOUT_SECS);
    let poll_interval = Duration::from_millis(WAIT_FLAG_POLL_INTERVAL_MS);

    eprint!("Waiting for {}", name);
    while start.elapsed() < timeout {
        // Check if the app has a running process
        if running_app_exe(name).is_some() {
            eprintln!(" ready ({:.1}s)", start.elapsed().as_secs_f32());
            return true;
        }

        eprint!(".");
        thread::sleep(poll_interval);
    }

    eprintln!(" timeout after {}s", WAIT_FLAG_TIMEOUT_SECS);
    false
}

/// Generic apps retain the 60s `--wait` bound. Emacs waits during frame
/// creation instead, regardless of whether `--wait` was specified.
fn wait_for_app(name: &str) -> bool {
    wait_for_app_process(name)
}

/// Parse the `pid = N` line out of `launchctl print` output.  Factored out so
/// `daemon_pid` is unit-testable against a captured fixture without shelling
/// out to launchd.
fn parse_pid_from_launchctl_print(text: &str) -> Option<u32> {
    for line in text.lines() {
        if let Some(rest) = line.trim().strip_prefix("pid = ") {
            return rest.trim().parse().ok();
        }
    }
    None
}

/// Look up the PID of the launchd-managed Emacs daemon.  Returns `None` if the
/// service is not loaded or its `launchctl print` output cannot be parsed.
///
/// This is the only reliable way to target the daemon for AppleScript
/// activation without going through LaunchServices: the daemon runs from a
/// bare `bin/emacs --fg-daemon` (a different Mach-O from `Emacs.app`), so
/// name-based queries are either wrong (`tell application "Emacs"` launches
/// the bundle — see `handle_emacs_daemon_frame`) or catastrophically slow
/// (`process "Emacs"` via System Events enumerates every running process by
/// name and was observed to take >40 s on a populated session).  A
/// PID-targeted activation is O(1) and bypasses both footguns.
fn daemon_pid(uid: u32) -> Option<u32> {
    let out = Command::new("launchctl")
        .args(["print", &format!("gui/{}/org.nixos.emacs-server", uid)])
        .output()
        .ok()?;
    parse_pid_from_launchctl_print(&String::from_utf8_lossy(&out.stdout))
}

/// AppleScript that raises an already-running process by Unix PID.
///
/// Targeting `whose unix id is N` matters for two reasons:
///   1. Speed — it is an O(1) lookup.  The previous name-based form
///      (`process "Emacs"` via System Events) enumerated every running
///      process and took ~46 s on a populated session, manifesting as
///      `nix-open emacs` apparently hanging after `emacsclient` had already
///      created the frame.
///   2. Correctness — the launchd daemon is bare `bin/emacs --fg-daemon`,
///      not the `Emacs.app` bundle, so any `tell application "Emacs"` form
///      resolves via LaunchServices and launches a *second* standalone Emacs
///      alongside the daemon.  A PID can only refer to a running process,
///      so it can never trigger a bundle launch.
///
/// The `exists` guard makes the script a silent no-op if the PID has died
/// between lookup and activation.
fn activate_applescript_for_pid(pid: u32) -> String {
    format!(
        "tell application \"System Events\" to \
         if exists (first process whose unix id is {pid}) \
         then set frontmost of (first process whose unix id is {pid}) to true"
    )
}

/// Bring the running launchd-managed Emacs daemon's frame to the foreground.
/// The daemon runs with `ProcessType=Background` so macOS does not raise its
/// windows automatically.  Activates by PID, never by name — see
/// `activate_applescript_for_pid` for rationale.  Silently no-ops when the
/// daemon PID cannot be resolved: there is nothing useful to activate, and we
/// must not fall back to a name-based form that could launch the bundle.
fn activate_emacs_app(uid: u32) {
    let Some(pid) = daemon_pid(uid) else { return };
    let _ = Command::new("osascript")
        .args(["-e", &activate_applescript_for_pid(pid)])
        .status();
}

/// Open a frame on the single launchd-managed daemon. Plain open waits for
/// a starting daemon without killing it; only explicit `-r` restarts it.
/// Neither path invokes Emacs.app or an emacsclient alternate editor.
fn handle_emacs_daemon_frame(restart: bool) -> bool {
    let client = emacsclient_path();
    let uid = unsafe { libc::getuid() };
    eprintln!("🖥️  Emacs: creating daemon frame via emacsclient");

    let ready = if restart {
        eprintln!("   🔄 Restarting launchd Emacs daemon (open buffers will be lost)");
        let status = Command::new("launchctl")
            .args(launchctl_restart_args(uid))
            .status();
        if !status.is_ok_and(|s| s.success()) {
            eprintln!("   ❌ launchctl could not restart org.nixos.emacs-server");
            return false;
        }
        false
    } else {
        emacs_daemon_responding(&client)
    };

    if !ready {
        if !restart {
            let pid = daemon_pid(uid);
            if should_ensure_emacs_launchd(pid) {
                eprintln!("   ⏳ Emacs daemon not running; asking launchd to start it");
                let status = Command::new("launchctl")
                    .args(launchctl_ensure_args(uid))
                    .status();
                if !status.is_ok_and(|s| s.success()) {
                    eprintln!("   ❌ launchctl could not start org.nixos.emacs-server");
                    return false;
                }
            } else {
                eprintln!(
                    "   ⏳ Emacs daemon PID {} is starting or busy; not restarting it",
                    pid.unwrap()
                );
            }
        }
        wait_for_emacs_daemon(&client, uid);
    }

    if !try_emacs_frame(&client) {
        eprintln!("   ❌ Emacs server responded, but creating a frame failed");
        return false;
    }
    activate_emacs_app(uid);
    eprintln!("   ✅ Emacs frame opened");
    true
}

/// Get the executable path of the running Emacs daemon process.
fn running_emacs_daemon_exe() -> Option<String> {
    let output = Command::new("pgrep")
        .args(["-f", "emacs.*--fg-daemon"])
        .output()
        .ok()?;
    let pids: Vec<&str> = std::str::from_utf8(&output.stdout)
        .ok()?
        .lines()
        .collect();
    let pid = pids.first()?;

    let ps_out = Command::new("ps")
        .args(["-o", "args=", "-p", pid])
        .output()
        .ok()?;
    let args = std::str::from_utf8(&ps_out.stdout).ok()?.trim();
    args.split_whitespace().next().map(|s| s.to_string())
}

/// Get the current Nix profile's emacs path (resolved through symlinks).
fn current_profile_emacs() -> Option<String> {
    let home = dirs::home_dir()?;
    let emacs_link = home.join(".nix-profile/bin/emacs");
    fs::canonicalize(&emacs_link)
        .ok()
        .map(|p| p.to_string_lossy().to_string())
}

/// Check if the profile's emacs wrapper references the running emacs binary.
/// The profile resolves to emacs-with-packages which wraps the base emacs.
/// We check via `nix-store -q --references` if the wrapper depends on the
/// running binary's store path.
fn emacs_wrapper_references_running(wrapper_path: &str, running_path: &str) -> bool {
    // Extract the store path (the /nix/store/...-name portion)
    let running_store = running_path
        .strip_suffix("/bin/emacs")
        .or_else(|| running_path.strip_suffix("/bin/emacs-30.2"))
        .unwrap_or(running_path);

    let wrapper_store = wrapper_path
        .strip_suffix("/bin/emacs")
        .unwrap_or(wrapper_path);

    let output = Command::new("nix-store")
        .args(["-q", "--references", wrapper_store])
        .output();

    match output {
        Ok(out) if out.status.success() => {
            let refs = String::from_utf8_lossy(&out.stdout);
            refs.lines().any(|line| line == running_store)
        }
        _ => false,
    }
}

/// Show the status of a running app: version comparison and restart hint.
/// For Emacs, also shows daemon uptime.
fn handle_app_status(name: &str) {
    // Special case: Emacs daemon
    if name.eq_ignore_ascii_case("emacs") {
        handle_emacs_daemon_status();
        return;
    }

    // General app status
    let app_path = match find_app(name) {
        Some(p) => p,
        None => {
            eprintln!("{}: not found in any application directory", name);
            return;
        }
    };

    let display = app_display_name(&app_path);
    let installed = resolved_app_store_path(&app_path);

    match running_app_exe(name) {
        Some((pid, exe_path)) => {
            let running_label = nix_store_label(&exe_path);
            let installed_label = installed.as_ref().and_then(|p| nix_store_label(p));

            match (&running_label, &installed_label) {
                (Some(r), Some(i)) if r == i => {
                    eprintln!("{}: up to date (pid {})", display, pid);
                    eprintln!("  Version: {}", r);
                }
                (Some(r), Some(i)) => {
                    eprintln!("{}: stale (restart needed, pid {})", display, pid);
                    eprintln!("  Running: {}", r);
                    eprintln!("  Current: {}", i);
                    eprintln!("  Run: nix-open -r {}", name.to_lowercase());
                }
                (Some(r), None) => {
                    eprintln!("{}: running (pid {})", display, pid);
                    eprintln!("  Version: {}", r);
                }
                (None, _) => {
                    eprintln!("{}: running (pid {})", display, pid);
                }
            }
        }
        None => {
            eprintln!("{}: not running", display);
            if let Some(label) = installed.as_ref().and_then(|p| nix_store_label(p)) {
                eprintln!("  Installed: {}", label);
            }
        }
    }
}

/// Show the status of the Emacs daemon: running/stopped, uptime, version status.
fn handle_emacs_daemon_status() {
    let client = emacsclient_path();

    // A busy daemon may accept a socket connection without answering yet.
    // Status must return promptly rather than waiting through startup.
    let uptime_result = emacsclient_eval(&client, "(emacs-uptime)", EMACS_PROBE_TIMEOUT);

    let uptime = match uptime_result {
        Some(out) if out.status.success() => {
            Some(String::from_utf8_lossy(&out.stdout)
                .trim()
                .trim_matches('"')
                .to_string())
        }
        _ => None,
    };

    // Check version status
    let running = running_emacs_daemon_exe();
    let current = current_profile_emacs();

    // The profile's emacs resolves to emacs-with-packages-30.2 which wraps
    // the base emacs-30.2 binary. The daemon runs the base binary directly.
    // Check if the wrapper references the running binary via nix-store refs.
    let versions_match = match (&running, &current) {
        (Some(r), Some(c)) => r == c || emacs_wrapper_references_running(c, r),
        _ => false,
    };

    match (&running, &current, &uptime) {
        (Some(r), Some(_c), Some(up)) if versions_match => {
            eprintln!("Emacs daemon: up to date");
            eprintln!("  Uptime:  {}", up);
            if let Some(label) = nix_store_label(r) {
                eprintln!("  Version: {}", label);
            }
        }
        (Some(r), Some(c), Some(up)) => {
            eprintln!("Emacs daemon: stale (restart needed)");
            eprintln!("  Uptime:  {}", up);
            if let Some(old) = nix_store_label(r) {
                eprintln!("  Running: {}", old);
            }
            if let Some(new) = nix_store_label(c) {
                eprintln!("  Current: {}", new);
            }
            eprintln!("  Run: nix-open -r emacs (restarts daemon; loses open buffers)");
        }
        (Some(r), _, Some(up)) => {
            eprintln!("Emacs daemon: running");
            eprintln!("  Uptime:  {}", up);
            if let Some(label) = nix_store_label(r) {
                eprintln!("  Version: {}", label);
            }
        }
        (_, _, None) => {
            if let Some(pid) = daemon_pid(unsafe { libc::getuid() }) {
                eprintln!("Emacs daemon: starting or busy (pid {pid}); status probe did not answer within 2s");
                eprintln!("  Run: nix-open emacs to wait and open a frame");
                return;
            }
            eprintln!("Emacs daemon: not running");
            if let Some(c) = &current {
                if let Some(label) = nix_store_label(c) {
                    eprintln!("  Installed: {}", label);
                }
            }
        }
        _ => {
            eprintln!("Emacs daemon: running (cannot determine version)");
        }
    }
}

fn handle_open_app(name: &str, restart: bool, new_instance: bool) -> bool {
    // Special case: Emacs — connect to the running daemon instead of
    // spawning a separate standalone Emacs.app process.  This keeps all
    // buffers, LSP servers, and session caches in one shared heap.
    // Even `--restart` must target launchd, never the Emacs.app bundle.
    if name.eq_ignore_ascii_case("emacs") {
        return handle_emacs_daemon_frame(restart);
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

    if cli.status {
        // --status: show app version status
        for name in &cli.apps {
            handle_app_status(name);
        }
        return;
    }

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
            } else if cli.wait && !name.eq_ignore_ascii_case("emacs") && !wait_for_app(name) {
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
            } else if cli.wait && !name.eq_ignore_ascii_case("emacs") && !wait_for_app(name) {
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

    #[test]
    fn explicit_restart_targets_launchd_and_kills_only_when_requested() {
        assert_eq!(
            launchctl_restart_args(501),
            vec!["kickstart", "-k", "gui/501/org.nixos.emacs-server"]
        );
        assert!(!launchctl_ensure_args(501).contains(&"-k".to_string()));
    }

    #[test]
    fn activate_script_never_launches_the_app_bundle() {
        let script = activate_applescript_for_pid(99329);
        // Must NOT use the LaunchServices `tell application "Emacs"` form: with
        // only the daemon running, that launches a standalone Emacs.app bundle
        // (the orphan-app footgun), not the daemon frame.
        assert!(
            !script.contains("tell application \"Emacs\""),
            "activate must not target the Emacs.app bundle — it would launch it"
        );
        // Must target the daemon by PID, not by name.  Name-based
        // (`process \"Emacs\"`) AppleScript enumerates every running process
        // and was observed to take ~46 s on a populated session — the
        // regression that made `nix-open emacs` appear to hang.  PID lookup
        // is O(1) and can only refer to a running process, so it can never
        // launch the bundle.
        assert!(script.contains("System Events"), "must use System Events");
        assert!(
            !script.contains("process \"Emacs\""),
            "must not enumerate processes by name — that path is O(n) and \
             observed at 46s on populated sessions"
        );
        assert!(
            script.contains("unix id is 99329"),
            "must target the daemon by Unix PID"
        );
        assert!(script.contains("exists"), "must guard on existence");
        assert!(script.contains("frontmost"), "must raise via frontmost");
    }

    #[test]
    fn parses_pid_from_launchctl_print() {
        // Captured shape of `launchctl print gui/$UID/org.nixos.emacs-server`
        // — tab-indented `pid = N` line buried among many other fields.
        let fixture = "gui/501/org.nixos.emacs-server = {\n\
                       \tactive count = 5\n\
                       \tstate = running\n\
                       \tpid = 99329\n\
                       \tlast exit code = 15\n\
                       }\n";
        assert_eq!(parse_pid_from_launchctl_print(fixture), Some(99329));
    }

    #[test]
    fn pid_parser_returns_none_when_service_is_not_loaded() {
        // launchctl print on an unloaded service prints to stderr and emits
        // no `pid = ` line on stdout — parser must surface that as None.
        assert_eq!(parse_pid_from_launchctl_print(""), None);
        assert_eq!(
            parse_pid_from_launchctl_print("Could not find service\n"),
            None,
        );
    }

    #[test]
    fn slow_daemon_is_not_treated_as_failed_or_kickstarted_again() {
        // launchd already has a PID while init.el is still loading. No
        // `kickstart -k` or redundant ensure, regardless of socket state.
        assert!(!should_ensure_emacs_launchd(Some(50123)));
        assert!(should_ensure_emacs_launchd(None));
        let mut attempts = 0;
        let waited = poll_until_emacs_ready(
            || {
                attempts += 1;
                attempts == 76
            },
            Duration::ZERO,
            Duration::from_secs(5),
            |_| {},
        );
        assert_eq!(attempts, 76, "do not give up after a fixed poll count");
        assert!(waited < Duration::from_secs(5));
    }

    #[test]
    fn readiness_progress_explains_what_is_still_happening() {
        assert!(emacs_wait_progress(Duration::from_secs(75), Some(1234))
            .contains("75s"));
        assert!(emacs_wait_progress(Duration::from_secs(75), Some(1234))
            .contains("1234"));
        assert!(emacs_wait_progress(Duration::from_secs(75), None)
            .contains("launchd"));
        let mut attempts = 0;
        let mut reports = 0;
        poll_until_emacs_ready(
            || { attempts += 1; attempts == 4 },
            Duration::from_millis(3),
            Duration::from_millis(1),
            |_| reports += 1,
        );
        assert!(reports >= 2, "a slow daemon must produce heartbeat updates");
    }

    #[test]
    fn unresponsive_client_probe_is_killed_and_reaped() {
        use std::os::unix::fs::PermissionsExt;
        let dir = std::env::temp_dir().join(format!(
            "nix-open-probe-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
        ));
        fs::create_dir(&dir).unwrap();
        let client = dir.join("emacsclient");
        fs::write(&client, "#!/bin/sh\nexec sleep 3\n").unwrap();
        fs::set_permissions(&client, fs::Permissions::from_mode(0o755)).unwrap();
        let start = Instant::now();
        let result = emacsclient_eval(client.to_str().unwrap(), "t", Duration::from_millis(50));
        fs::remove_dir_all(dir).unwrap();
        assert!(result.is_none(), "a blocked eval must time out");
        assert!(start.elapsed() < Duration::from_secs(1), "status must not hang");
    }
}
