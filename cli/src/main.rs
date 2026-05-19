use clap::{Parser, Subcommand, CommandFactory};
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use std::process::Command;
use std::fs;
use std::path::{Path, PathBuf};
use std::io::Write;
use std::time::{SystemTime, UNIX_EPOCH, Duration};

// 1. Static Core Commands
#[derive(Parser)]
#[command(name = "decknix")]
#[command(about = "The Decknix Framework CLI", long_about = None)]
#[command(disable_help_subcommand = true)] // we take over 'help'
struct Cli {
    #[command(subcommand)]
    command: Option<Commands>,
}

#[derive(Subcommand)]
enum Commands {
    /// Update flake inputs
    Update {
        /// Specific input to update
        input: Option<String>,
    },
    /// Switch system configuration
    Switch {
        /// Build only — don't activate (uses darwin-rebuild build instead of switch)
        #[arg(long)]
        dry_run: bool,

        /// Override flake input(s) with local paths (repeatable, INPUT=PATH).
        /// Example: --override decknix=~/tools/decknix --override nc-config=~/Code/my-org/decknix-config
        #[arg(long, value_name = "INPUT=PATH")]
        r#override: Vec<String>,
    },
    /// Manage git worktrees
    Wt {
        #[command(subcommand)]
        action: WtAction,
    },
    Help {
        /// The command to look up
        subcommand: Option<String>,
    },
    // This variant catches unknown commands to check extensions
    #[command(external_subcommand)]
    External(Vec<String>),
}

#[derive(Subcommand)]
enum WtAction {
    /// List all worktrees from the registry
    List {
        /// Filter by owner/repo
        #[arg(long)]
        repo: Option<String>,
    },
    /// Re-probe worktrees and update the cache
    Refresh {
        /// Specific repo to refresh
        #[arg(long)]
        repo: Option<String>,
    },
    /// Remove dead entries and prune git worktrees
    Prune {
        /// Specific repo to prune
        #[arg(long)]
        repo: Option<String>,
    },
    /// Sweep orphan fork remotes
    CleanForkRemotes {
        /// Don't actually delete
        #[arg(long)]
        dry_run: bool,
    },
    /// Dump the registry
    Registry {
        /// Output in JSON format
        #[arg(long)]
        json: bool,
    },
}

/// Expand ~ and validate a directory path, returning a canonical path.
fn resolve_path(raw: &str, context: &str) -> anyhow::Result<PathBuf> {
    let expanded = if raw.starts_with("~/") {
        dirs::home_dir()
            .unwrap_or_default()
            .join(&raw[2..])
    } else {
        PathBuf::from(raw)
    };
    let path = expanded.canonicalize().unwrap_or(expanded);
    if !path.is_dir() {
        anyhow::bail!("{}: '{}' is not a directory", context, path.display());
    }
    Ok(path)
}

/// Parse an INPUT=PATH override string into (input_name, resolved_path).
fn parse_override(s: &str) -> anyhow::Result<(String, PathBuf)> {
    let (input_name, raw_path) = s.split_once('=')
        .ok_or_else(|| anyhow::anyhow!(
            "--override '{}': expected INPUT=PATH format (e.g. nc-config=~/Code/my-org/decknix-config)",
            s
        ))?;
    let path = resolve_path(raw_path, &format!("--override {}", input_name))?;
    Ok((input_name.to_string(), path))
}

// 2. Dynamic Configuration Schema
#[derive(Deserialize, Debug, Clone)]
struct ExtensionConfig {
    description: String,
    command: String, // Path to script or executable
}

type ExtensionMap = HashMap<String, ExtensionConfig>;

// Merge configs from decknix, and custom system and home extensions
fn load_merged_extensions() -> ExtensionMap {
    let mut map = HashMap::new();

    let paths = vec![
        PathBuf::from("/etc/decknix/extensions.json"),
        dirs::home_dir().unwrap_or_default().join(".config/decknix/extensions.json"),
    ];

    for path in paths {
        if let Ok(file) = fs::File::open(&path) {
            if let Ok(m) = serde_json::from_reader::<_, ExtensionMap>(file) {
                map.extend(m);
            }
        }
    }

    if let Ok(env_path) = std::env::var("DECKNIX_CONFIG") {
        if let Ok(file) = fs::File::open(env_path) {
            if let Ok(env_map) = serde_json::from_reader::<_, ExtensionMap>(file) {
                map.extend(env_map);
            }
        }
    }

    map
}

// 1. Define the styles
#[allow(dead_code)]
enum Style {
    B, // bold
    U, // underline
    I, // Italic
    Dim,
    Cyan,
    Green,
}

fn styled_str(text: &str, styles: &[Style]) -> String {
    let mut codes = String::new();
    for style in styles {
        match style {
            Style::B => codes.push_str("\x1b[1m"),
            Style::U => codes.push_str("\x1b[4m"),
            Style::I => codes.push_str("\x1b[3m"),
            Style::Dim => codes.push_str("\x1b[2m"),
            Style::Cyan => codes.push_str("\x1b[36m"),
            Style::Green => codes.push_str("\x1b[32m"),
        }
    }
    // apply codes, then text, then reset everything at the end
    format!("{}{}\x1b[0m", codes, text)
}

#[derive(Debug, Clone, Serialize)]
struct WorktreeEntry {
    repo: String,
    primary: PathBuf,
    worktrees: Vec<(String, PathBuf)>,
    ts: f64,
    stale: bool,
}

impl WorktreeEntry {
    fn to_value(&self) -> lexpr::Value {
        let mut wt_list = Vec::new();
        for (branch, path) in &self.worktrees {
            wt_list.push(lexpr::Value::cons(
                lexpr::Value::string(branch.clone()),
                lexpr::Value::string(path.to_string_lossy().to_string())
            ));
        }
        lexpr::Value::list(vec![
            lexpr::Value::string(self.repo.clone()),
            lexpr::Value::keyword("primary"),
            lexpr::Value::string(self.primary.to_string_lossy().to_string()),
            lexpr::Value::keyword("worktrees"),
            lexpr::Value::list(wt_list),
            lexpr::Value::keyword("ts"),
            lexpr::Value::from(self.ts),
            lexpr::Value::keyword("stale"),
            if self.stale { lexpr::Value::symbol("t") } else { lexpr::Value::Nil },
        ])
    }
}

fn registry_path() -> PathBuf {
    dirs::home_dir()
        .unwrap_or_default()
        .join(".config/decknix/hub/worktrees.el")
}

fn load_registry() -> anyhow::Result<Vec<WorktreeEntry>> {
    let path = registry_path();
    if !path.exists() {
        return Ok(Vec::new());
    }
    let content = fs::read_to_string(&path)?;
    let sexp_str = content.lines()
        .filter(|l| !l.trim_start().starts_with(";;"))
        .collect::<Vec<_>>()
        .join("\n");

    if sexp_str.trim().is_empty() {
        return Ok(Vec::new());
    }

    let value = lexpr::from_str(&sexp_str)?;
    let mut entries = Vec::new();

    if let Some(list) = value.list_iter() {
        for entry_val in list {
            if let Some(items) = entry_val.list_iter() {
                let items: Vec<_> = items.collect();
                if items.is_empty() { continue; }
                let repo = items[0].as_str().unwrap_or_default().to_string();
                let mut primary = PathBuf::new();
                let mut worktrees = Vec::new();
                let mut ts = 0.0;
                let mut stale = false;

                let mut i = 1;
                while i + 1 < items.len() {
                    let key_opt = items[i].as_symbol().or_else(|| items[i].as_keyword());
                    if let Some(key) = key_opt {
                        let val = items[i+1];
                        match key {
                            "primary" | ":primary" => primary = PathBuf::from(val.as_str().unwrap_or_default()),
                            "ts" | ":ts" => ts = val.as_f64().unwrap_or_default(),
                            "stale" | ":stale" => stale = !val.is_nil() && val.as_symbol() != Some("nil"),
                            "worktrees" | ":worktrees" => {
                                if let Some(wt_list) = val.list_iter() {
                                    for wt_pair in wt_list {
                                        if let Some(pair) = wt_pair.as_cons() {
                                            let branch = pair.car().as_str().unwrap_or_default().to_string();
                                            let path = PathBuf::from(pair.cdr().as_str().unwrap_or_default());
                                            worktrees.push((branch, path));
                                        }
                                    }
                                }
                            }
                            _ => {}
                        }
                    }
                    i += 2;
                }
                entries.push(WorktreeEntry { repo, primary, worktrees, ts, stale });
            }
        }
    }
    Ok(entries)
}

fn save_registry(entries: &[WorktreeEntry]) -> anyhow::Result<()> {
    let path = registry_path();
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }

    let sexps: Vec<_> = entries.iter().map(|e| e.to_value()).collect();
    let value = lexpr::Value::list(sexps);

    let mut f = fs::File::create(&path)?;
    writeln!(f, ";; Auto-generated worktree registry — do not edit")?;
    writeln!(f, ";; Format: ((\"owner/repo\" :primary PATH :worktrees ((BRANCH . PATH) ...) :ts FLOAT :stale BOOL) ...)")?;
    lexpr::to_writer_custom(&mut f, &value, lexpr::print::Options::elisp())?;
    writeln!(f)?;

    let _ = Command::new("touch").arg(&path).status();
    Ok(())
}

fn with_lock<F, R>(f: F) -> anyhow::Result<R>
where F: FnOnce() -> anyhow::Result<R> {
    let lock_path = dirs::home_dir().unwrap_or_default().join(".config/decknix/hub/worktrees.lock");
    if let Some(parent) = lock_path.parent() {
        fs::create_dir_all(parent)?;
    }
    let file = fs::OpenOptions::new()
        .write(true)
        .create(true)
        .open(&lock_path)?;

    let fd = std::os::unix::io::AsRawFd::as_raw_fd(&file);
    let mut retries = 0;
    loop {
        let res = unsafe { libc::flock(fd, libc::LOCK_EX | libc::LOCK_NB) };
        if res == 0 { break; }
        if retries >= 10 {
            anyhow::bail!("Lock contention on worktrees.lock; wait timeout (1s)");
        }
        std::thread::sleep(Duration::from_millis(100));
        retries += 1;
    }

    let result = f();
    unsafe { libc::flock(fd, libc::LOCK_UN) };
    result
}

fn get_git_root(path: &Path) -> Option<PathBuf> {
    if !path.exists() { return None; }
    let output = Command::new("git")
        .args(["rev-parse", "--show-toplevel"])
        .current_dir(path)
        .output()
        .ok()?;
    if output.status.success() {
        let s = String::from_utf8_lossy(&output.stdout).trim().to_string();
        return Some(PathBuf::from(s));
    }
    None
}

fn get_repo_identity(path: &Path) -> Option<String> {
    let output = Command::new("git")
        .args(["remote", "get-url", "origin"])
        .current_dir(path)
        .output()
        .ok()?;
    if output.status.success() {
        let url = String::from_utf8_lossy(&output.stdout).trim().to_string();
        let path_part = if let Some((_, p)) = url.split_once(':') {
            p
        } else if let Some(p) = url.strip_prefix("https://") {
            p.split_once('/').map(|(_, rest)| rest).unwrap_or(p)
        } else {
            &url
        };
        let parts: Vec<&str> = path_part.trim_end_matches(".git").split('/').collect();
        if parts.len() >= 2 {
            let repo = format!("{}/{}", parts[parts.len()-2], parts[parts.len()-1]);
            return Some(repo.to_lowercase());
        }
    }
    None
}

fn list_worktrees(path: &Path) -> anyhow::Result<Vec<(String, PathBuf)>> {
    let output = Command::new("git")
        .args(["worktree", "list", "--porcelain"])
        .current_dir(path)
        .output()?;
    if !output.status.success() {
        anyhow::bail!("git worktree list failed");
    }
    let s = String::from_utf8_lossy(&output.stdout);
    let mut wts = Vec::new();
    let mut curr_path = PathBuf::new();
    for line in s.lines() {
        if line.starts_with("worktree ") {
            curr_path = PathBuf::from(&line[9..]);
        } else if line.starts_with("branch ") {
            let branch = line[7..].trim_start_matches("refs/heads/").to_string();
            wts.push((branch, curr_path.clone()));
        }
    }
    Ok(wts)
}

fn discover_clones(registry: &[WorktreeEntry]) -> anyhow::Result<HashSet<PathBuf>> {
    let mut clones = HashSet::new();
    for entry in registry {
        if entry.primary.exists() {
            clones.insert(entry.primary.clone());
        }
    }
    let sessions_path = dirs::home_dir().unwrap_or_default().join(".config/decknix/agent-sessions.json");
    if sessions_path.exists() {
        if let Ok(content) = fs::read_to_string(&sessions_path) {
            if let Ok(json) = serde_json::from_str::<serde_json::Value>(&content) {
                if let Some(convs) = json.get("conversations").and_then(|v| v.as_object()) {
                    for conv in convs.values() {
                        if let Some(ws) = conv.get("workspace").and_then(|v| v.as_str()) {
                            let path = PathBuf::from(ws);
                            if let Some(root) = get_git_root(&path) {
                                clones.insert(root);
                            }
                        }
                    }
                }
            }
        }
    }
    Ok(clones)
}

fn clean_fork_remotes(dry_run: bool) -> anyhow::Result<()> {
    let registry = load_registry()?;
    for entry in registry {
        if !entry.primary.exists() { continue; }
        let output = Command::new("git").args(["remote"]).current_dir(&entry.primary).output()?;
        let remotes: Vec<String> = String::from_utf8_lossy(&output.stdout).lines().map(|s| s.to_string()).collect();
        let output = Command::new("git").args(["for-each-ref", "--format=%(refname:short) %(upstream:remotename)", "refs/heads/"]).current_dir(&entry.primary).output()?;
        let mut tracked_remotes = HashSet::new();
        for line in String::from_utf8_lossy(&output.stdout).lines() {
            let parts: Vec<&str> = line.split_whitespace().collect();
            if parts.len() == 2 { tracked_remotes.insert(parts[1].to_string()); }
        }
        for remote in remotes {
            if remote == "origin" || remote == "upstream" { continue; }
            if remote.starts_with("origin-") || remote.starts_with("pr/") {
                if !tracked_remotes.contains(&remote) {
                    if dry_run {
                        println!("🔍 [{}] Would remove orphan remote: {}", entry.repo, remote);
                    } else {
                        println!("🗑️  [{}] Removing orphan remote: {}", entry.repo, remote);
                        let _ = Command::new("git").args(["remote", "remove", &remote]).current_dir(&entry.primary).status();
                    }
                }
            }
        }
    }
    Ok(())
}

// Help Printer
fn print_extended_help(extensions: &ExtensionMap) {
    // Print standard built-in help first
    let _ = Cli::command().print_help();

    if !extensions.is_empty() {
        println!("\n\n{}", styled_str("User Extensions:", &[Style::B, Style::U]));

        let mut keys: Vec<&String> = extensions.keys().collect();
        keys.sort(); // sort keys for consistent output

        for key in keys {
            let ext = extensions.get(key).unwrap();
            println!("  {:<12} {}", styled_str(key, &[Style::B]), ext.description);
        }
    } else {
        println!();
    }
}

/// Snapshot org.nixos.* LaunchAgent plists: returns map of label -> file content hash.
fn snapshot_launch_agents() -> HashMap<String, u64> {
    let agents_dir = dirs::home_dir()
        .unwrap_or_default()
        .join("Library/LaunchAgents");
    let mut map = HashMap::new();
    if let Ok(entries) = fs::read_dir(&agents_dir) {
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().to_string();
            if name.starts_with("org.nixos.") && name.ends_with(".plist") {
                if let Ok(content) = fs::read(entry.path()) {
                    // Simple hash for change detection
                    let hash = content.iter().fold(0u64, |acc, &b| {
                        acc.wrapping_mul(31).wrapping_add(b as u64)
                    });
                    let label = name.trim_end_matches(".plist").to_string();
                    map.insert(label, hash);
                }
            }
        }
    }
    map
}

/// Gracefully stop the Emacs daemon before restarting via launchd.
///
/// Tries `emacsclient --eval '(kill-emacs)'` first for a clean shutdown
/// (no macOS crash dialog). Falls back to `pkill` for orphaned daemons
/// from the old `--daemon` (forking) mode that launchd lost track of.
fn kill_emacs_daemon() {
    // Try graceful shutdown via emacsclient first.
    // This avoids the macOS "application quit unexpectedly" dialog.
    let graceful = Command::new("emacsclient")
        .args(["--eval", "(kill-emacs)"])
        .stderr(std::process::Stdio::null())
        .status();
    match graceful {
        Ok(s) if s.success() => {
            eprintln!("   🧹 Emacs daemon stopped gracefully");
            std::thread::sleep(std::time::Duration::from_millis(500));
            return;
        }
        _ => {}
    }
    // Fallback: pkill for orphaned daemons (old --daemon forking mode).
    let result = Command::new("pkill")
        .args(["-f", "Emacs.*--.*daemon"])
        .status();
    match result {
        Ok(s) if s.success() => {
            eprintln!("   🧹 Killed orphaned Emacs daemon(s)");
            std::thread::sleep(std::time::Duration::from_millis(500));
        }
        _ => {
            // No matching processes — that's fine
        }
    }
}

/// After a successful switch, restart changed user LaunchAgents and remove obsolete ones.
fn restart_changed_agents(
    before: &HashMap<String, u64>,
    after: &HashMap<String, u64>,
) {
    let uid = unsafe { libc::getuid() };

    // Find changed services (present in both but content differs)
    let mut changed: Vec<&str> = Vec::new();
    for (label, new_hash) in after {
        if let Some(old_hash) = before.get(label) {
            if old_hash != new_hash {
                changed.push(label);
            }
        }
        // New services are handled by nix-darwin activation (launchctl load)
    }

    // Find removed services (in before but not in after)
    let after_labels: HashSet<&String> = after.keys().collect();
    let mut removed: Vec<&str> = Vec::new();
    for label in before.keys() {
        if !after_labels.contains(label) {
            removed.push(label);
        }
    }

    // Restart changed services
    for label in &changed {
        let target = format!("gui/{}/{}", uid, label);
        eprintln!("🔄 Restarting {}...", label);

        // For emacs-server: kill any orphaned daemon processes first.
        // Old plists used --daemon (forking mode) which double-forks, leaving
        // an orphaned emacs process that launchd can't track or kill.
        // New plists use --fg-daemon but we still need to clean up the old one.
        if label.contains("emacs") {
            kill_emacs_daemon();
        }

        // kickstart -k: kill existing instance and restart
        let status = Command::new("launchctl")
            .args(["kickstart", "-k", &target])
            .status();
        match status {
            Ok(s) if s.success() => eprintln!("   ✅ {}", label),
            _ => {
                // Fallback: try bootout + bootstrap
                eprintln!("   ⚠️  kickstart failed, trying bootout + bootstrap...");
                let plist = dirs::home_dir()
                    .unwrap_or_default()
                    .join(format!("Library/LaunchAgents/{}.plist", label));
                let _ = Command::new("launchctl")
                    .args(["bootout", &target])
                    .status();
                let _ = Command::new("launchctl")
                    .args(["bootstrap", &format!("gui/{}", uid), &plist.to_string_lossy()])
                    .status();
                eprintln!("   ✅ {}", label);
            }
        }
    }

    // Remove obsolete services
    for label in &removed {
        let target = format!("gui/{}/{}", uid, label);
        eprintln!("🗑️  Removing {}...", label);
        let _ = Command::new("launchctl")
            .args(["bootout", &target])
            .status();
        eprintln!("   ✅ {}", label);
    }

    if changed.is_empty() && removed.is_empty() {
        eprintln!("✅ No user LaunchAgent changes detected.");
    }
}

fn main() -> anyhow::Result<()> {
    let extensions = load_merged_extensions();

    // parse args
    let cli = Cli::parse();

    match cli.command {
        Some(Commands::Switch { dry_run, r#override }) => {
            // darwin-rebuild switch --dry-run still activates; use 'build' for true dry run
            let action = if dry_run { "build" } else { "switch" };

            // Always run from the decknix config directory so --flake .#default resolves correctly
            let config_dir = dirs::home_dir()
                .unwrap_or_default()
                .join(".config/decknix");
            if !config_dir.is_dir() {
                anyhow::bail!(
                    "Config directory '{}' not found. Run bootstrap first.",
                    config_dir.display()
                );
            }

            // Parse and resolve all --override INPUT=PATH pairs
            let mut overrides: Vec<(String, PathBuf)> = Vec::new();
            for s in &r#override {
                overrides.push(parse_override(s)?);
            }

            // Snapshot LaunchAgents before switch (for restart detection)
            let agents_before = if !dry_run { snapshot_launch_agents() } else { HashMap::new() };

            let mut cmd = Command::new("sudo");
            cmd.current_dir(&config_dir)
                .arg("darwin-rebuild").arg(action)
                .arg("--flake").arg(".#default")
                .arg("--impure");

            // Apply all overrides
            for (input_name, path) in &overrides {
                cmd.arg("--override-input").arg(input_name)
                    .arg(format!("path:{}", path.display()));
            }

            // Status message
            if overrides.is_empty() {
                println!("{}", if dry_run { "🔍 Dry run..." } else { "🔄 Switching..." });
            } else {
                let labels: Vec<String> = overrides.iter()
                    .map(|(name, path)| format!("{}={}", name, path.display()))
                    .collect();
                let icon = if dry_run { "🔍 Dry run" } else { "🔄 Switching" };
                println!("{} ({})...", icon, labels.join(", "));
            }

            let status = cmd.status()?;
            if !status.success() {
                std::process::exit(status.code().unwrap_or(1));
            }

            // After successful switch, restart any changed user LaunchAgents
            if !dry_run {
                let agents_after = snapshot_launch_agents();
                restart_changed_agents(&agents_before, &agents_after);
            }
        }
        Some(Commands::Update { input }) => {
            println!("⬇️  Updating...");
            let mut cmd = Command::new("nix");
            cmd.arg("flake").arg("update");
            if let Some(inp) = input { cmd.arg(inp); }
            let status = cmd.status()?;
            std::process::exit(status.code().unwrap_or(1));
        }
        // Handle: decknix help [cmd]
        Some(Commands::Help { subcommand }) => {
            match subcommand {
                Some(cmd) => {
                    // Check extensions first
                    if let Some(ext) = extensions.get(&cmd) {
                        println!("Extension:   {}", cmd);
                        println!("Description: {}", ext.description);
                        println!("Command:     {}", ext.command);
                    }
                    // Fallback to Clap help for built-ins
                    else {
                        let _ = Cli::command().print_help();
                    }
                }
                None => print_extended_help(&extensions),
            }
        }
        Some(Commands::Wt { action }) => {
            match action {
                WtAction::List { repo } => {
                    let registry = load_registry()?;
                    for entry in registry {
                        if let Some(r) = &repo {
                            if !entry.repo.contains(r) { continue; }
                        }
                        let stale_marker = if entry.stale { " [STALE]" } else { "" };
                        println!("{} ({}){}", styled_str(&entry.repo, &[Style::B, Style::Cyan]), entry.primary.display(), stale_marker);
                        for (branch, path) in &entry.worktrees {
                            println!("  \u{2514}\u{2500} {} -> {}", styled_str(branch, &[Style::Dim]), path.display());
                        }
                    }
                }
                WtAction::Refresh { repo } => {
                    with_lock(|| {
                        let mut registry = load_registry()?;
                        let clones = discover_clones(&registry)?;
                        let now = SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs_f64();

                        let mut found_any = false;
                        for path in clones {
                            if let Some(identity) = get_repo_identity(&path) {
                                if let Some(r) = &repo {
                                    if !identity.contains(r) { continue; }
                                }
                                found_any = true;
                                let wts = list_worktrees(&path)?;
                                if let Some(existing) = registry.iter_mut().find(|e| e.repo == identity) {
                                    existing.worktrees = wts;
                                    existing.ts = now;
                                    existing.stale = false;
                                    println!("\u{2705} Refreshed {}", identity);
                                } else {
                                    registry.push(WorktreeEntry {
                                        repo: identity.clone(),
                                        primary: path,
                                        worktrees: wts,
                                        ts: now,
                                        stale: false,
                                    });
                                    println!("\u{2728} Discovered {}", identity);
                                }
                            }
                        }

                        // Mark entries as stale if they no longer exist on disk
                        for entry in registry.iter_mut() {
                            if !entry.primary.exists() {
                                if !entry.stale {
                                    println!("\u{26a0}\u{fe0f}  Marking stale: {}", entry.repo);
                                    entry.stale = true;
                                }
                            }
                        }

                        save_registry(&registry)?;
                        if !found_any && repo.is_some() {
                            println!("\u{274c} No matches found for repo: {:?}", repo.unwrap());
                        }
                        Ok(())
                    })?;
                }
                WtAction::Prune { repo } => {
                    with_lock(|| {
                        let mut registry = load_registry()?;
                        let count_before = registry.len();
                        registry.retain(|e| {
                            if let Some(r) = &repo {
                                if !e.repo.contains(r) { return true; }
                            }
                            if !e.primary.exists() {
                                println!("\u{1f5d1}\u{fe0f}  Pruning registry entry: {}", e.repo);
                                return false;
                            }
                            true
                        });

                        for entry in &registry {
                            if let Some(r) = &repo {
                                if !entry.repo.contains(r) { continue; }
                            }
                            println!("\u{267b}\u{fe0f}  Pruning git worktrees: {}", entry.repo);
                            let _ = Command::new("git")
                                .args(["worktree", "prune"])
                                .current_dir(&entry.primary)
                                .status();
                        }

                        save_registry(&registry)?;
                        println!("\u{2705} Pruned {} entries", count_before - registry.len());
                        Ok(())
                    })?;
                }
                WtAction::CleanForkRemotes { dry_run } => {
                    clean_fork_remotes(dry_run)?;
                }
                WtAction::Registry { json } => {
                    if json {
                        let registry = load_registry()?;
                        println!("{}", serde_json::to_string_pretty(&registry)?);
                    } else {
                        println!("{}", registry_path().display());
                    }
                }
            }
        }
        Some(Commands::External(args)) => {
            let cmd_name = &args[0];

            // Handle: decknix <cmd> --help
            if args.contains(&String::from("--help")) || args.contains(&String::from("-h")) {
                if  let Some(ext) = extensions.get(cmd_name) {
                    println!("Extension:   {}", cmd_name);
                    println!("Description: {}", ext.description);
                    println!("Command:     {}", ext.command);
                    return Ok(());
                }
            }

            if let Some(ext) = extensions.get(cmd_name) {
                // Pass remaining arguments to the script
                let remaining_args = &args[1..];

                let mut shell_cmd = Command::new("sh");
                shell_cmd.arg("-c").arg(&ext.command).arg(cmd_name); // $0 is name
                shell_cmd.args(remaining_args); // $1.. are args

                let status = shell_cmd.status()?;
                std::process::exit(status.code().unwrap_or(1));
            } else {
                eprintln!("Unknown command: {}", cmd_name);
                eprintln!("Run 'decknix help' to see available commands.");
                std::process::exit(1);
            }
        }
        None => {
            // Override default help to show dynamic commands
            print_extended_help(&extensions);
        }
    }
    Ok(())
}
