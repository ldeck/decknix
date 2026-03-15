use clap::{Parser, Subcommand, CommandFactory};
use serde::Deserialize;
use std::collections::HashMap;
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

        /// Use a local framework checkout instead of the pinned remote.
        /// Reads path from --dev-path, or DECKNIX_DEV env var, or defaults to ~/tools/decknix.
        #[arg(long)]
        dev: bool,

        /// Explicit path to a local decknix framework checkout (implies --dev)
        #[arg(long, value_name = "PATH")]
        dev_path: Option<String>,
    },
    Help {
        /// The command to look up
        subcommand: Option<String>,
    },
    // This variant catches unknown commands to check extensions
    #[command(external_subcommand)]
    External(Vec<String>),
}

/// Resolve the local framework path for --dev mode.
/// Priority: --dev-path flag > DECKNIX_DEV env var > ~/tools/decknix
fn resolve_dev_path(explicit: Option<&str>) -> anyhow::Result<PathBuf> {
    if let Some(p) = explicit {
        let path = PathBuf::from(p);
        if !path.is_dir() {
            anyhow::bail!("--dev-path '{}' is not a directory", p);
        }
        return Ok(path);
    }

    if let Ok(env_path) = std::env::var("DECKNIX_DEV") {
        let path = PathBuf::from(&env_path);
        if !path.is_dir() {
            anyhow::bail!("DECKNIX_DEV='{}' is not a directory", env_path);
        }
        return Ok(path);
    }

    let default = dirs::home_dir()
        .unwrap_or_default()
        .join("tools/decknix");
    if !default.is_dir() {
        anyhow::bail!(
            "Default dev path '{}' not found. Set DECKNIX_DEV or use --dev-path.",
            default.display()
        );
    }
    Ok(default)
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

fn main() -> anyhow::Result<()> {
    let extensions = load_merged_extensions();

    // parse args
    let cli = Cli::parse();

    match cli.command {
        Some(Commands::Switch { dry_run, dev, dev_path }) => {
            let use_dev = dev || dev_path.is_some();
            // darwin-rebuild switch --dry-run still activates; use 'build' for true dry run
            let action = if dry_run { "build" } else { "switch" };

            if use_dev {
                let path = resolve_dev_path(dev_path.as_deref())?;
                if dry_run {
                    println!("🔍 Dry run (dev: {})...", path.display());
                } else {
                    println!("🔄 Switching (dev: {})...", path.display());
                }
                let mut cmd = Command::new("sudo");
                cmd.arg("darwin-rebuild").arg(action)
                    .arg("--flake").arg(".#default")
                    .arg("--impure")
                    .arg("--override-input").arg("decknix")
                    .arg(format!("path:{}", path.display()));
                let status = cmd.status()?;
                std::process::exit(status.code().unwrap_or(1));
            } else {
                if dry_run {
                    println!("🔍 Dry run...");
                } else {
                    println!("🔄 Switching...");
                }
                let mut cmd = Command::new("sudo");
                cmd.arg("darwin-rebuild").arg(action)
                    .arg("--flake").arg(".#default")
                    .arg("--impure");
                let status = cmd.status()?;
                std::process::exit(status.code().unwrap_or(1));
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
