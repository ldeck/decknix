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
        #[arg(long)]
        dry_run: bool,
    },
    Help {
        /// The command to look up
        subcommand: Option<String>,
    },
    // This variant catches unknown commands to check extensions
    #[command(external_subcommand)]
    External(Vec<String>),
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

// Help Printer
fn print_extended_help(extensions: &ExtensionMap) {
    // Print standard built-in help first
    let _ = Cli::command().print_help();

    if !extensions.is_empty() {
        println!("\n\nUser Extensions:");

        let mut keys: Vec<&String> = extensions.keys().collect();
        keys.sort(); // sort keys for consistent output

        for key in keys {
            let ext = extensions.get(key).unwrap();
            println!("  {:<12} {}", key, ext.description);
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
        Some(Commands::Switch { dry_run }) => {
            println!("🔄 Switching...");
            let mut cmd = Command::new("sudo");
            cmd.arg("darwin-rebuild").arg("switch").arg("--flake").arg(".#default").arg("--impure");
            if dry_run { cmd.arg("--dry-run"); }
            let status = cmd.status()?;
            std::process::exit(status.code().unwrap_or(1));
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
                        println!("Extension:    {}", cmd);
                        println!("Description:  {}", ext.description);
                        println!("Command:      {}", ext.command);
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
                    println!("Extension:      {}", cmd_name);
                    println!("Description:    {}", ext.description);
                    println!("Command:        {}", ext.command);
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
