use clap::{Parser, Subcommand, CommandFactory};
use serde::Deserialize;
use std::collections::HashMap;
use std::collections::HashSet;
use std::process::Command;
use std::fs;
use std::path::PathBuf;

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
    Help {
        /// The command to look up
        subcommand: Option<String>,
    },
    // This variant catches unknown commands to check extensions
    #[command(external_subcommand)]
    External(Vec<String>),
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
enum Style {
    B, // bold
    U, // underline
    I, // Italic
}

fn styled_str(text: &str, styles: &[Style]) -> String {
    let mut codes = String::new();
    for style in styles {
        match style {
            Style::B => codes.push_str("\x1b[1m"),
            Style::U => codes.push_str("\x1b[4m"),
            Style::I => codes.push_str("\x1b[3m"),
        }
    }
    // apply codes, then text, then reset everything at the end
    format!("{}{}\x1b[0m", codes, text)
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
