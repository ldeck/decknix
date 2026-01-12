use clap::{Parser, Subcommand, Args, CommandFactory, FromArgMatches};
use serde::Deserialize;
use std::collections::HashMap;
use std::process::Command;
use std::fs;
use std::path::PathBuf;

// 1. Static Core Commands
#[derive(Parser)]
#[command(name = "decknix")]
#[command(about = "The Decknix Framework CLI", long_about = None)]
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

// Helper: Cascading Config Lookup
fn get_config_path() -> Option<PathBuf> {
    // 1. Check Env Var (Highest Priority for Dev/Test)
    if let Ok(env_path) = std::env::var("DECKNIX_CONFIG") {
        return Some(PathBuf::from(env_path));
    }

    // 2. Check User Home (~/.config/decknix/extensions.json)
    if let Some(home) = dirs::home_dir() {
        let user_path = home.join(".config/decknix/extensions.json");
        if user_path.exists() {
            return Some(user_path);
        }
    }

    // 3. Check System Global (/etc/decknix/extensions.json)
    let system_path = PathBuf::from("/etc/decknix/extensions.json");
    if system_path.exists() {
        return Some(system_path);
    }

    None
}

fn main() -> anyhow::Result<()> {
    // A. Load Extensions using the cascade
    let extensions: ExtensionMap = match get_config_path() {
        Some(path) => {
            // Uncomment to debug path resolution:
            // println!("DEBUG: Loading config from {:?}", path);
            let file = fs::File::open(path)?;
            serde_json::from_reader(file).unwrap_or_else(|_| HashMap::new())
        },
        None => HashMap::new(),
    };

    // B. Parse Args
    let cli = Cli::parse();

    match cli.command {
        Some(Commands::Switch { dry_run }) => {
          println!("🔄 Switching...");

          // Construct the darwin-rebuild command
          let mut cmd = Command::new("sudo");
          cmd.arg("darwin-rebuild")
             .arg("switch")
             .arg("--flake")
             .arg(".#default")
             .arg("--impure");

          if dry_run {
              cmd.arg("--dry-run");
          }

          let status = cmd.status()?;
          std::process::exit(status.code().unwrap_or(1));
        }
        Some(Commands::Update { input }) => {
          println!("⬇️ Updating...");

          // Call nix flake update...
          let mut cmd = Command::new("nix");
          cmd.arg("flake").arg("update");

          if let Some(inp) = input {
              cmd.arg(inp);
          }

          let status = cmd.status()?;
          std::process::exit(status.code().unwrap_or(1));
        }
        Some(Commands::External(args)) => {
          // C. Handle Dynamic Commands
          let cmd_name = &args[0];
          if let Some(ext) = extensions.get(cmd_name) {
            // Execute the command defined in JSON
            let status = Command::new("sh")
                .arg("-c")
                .arg(&ext.command)
                .status()?;
            std::process::exit(status.code().unwrap_or(1));
          } else {
            println!("Unknown command: {}", cmd_name);
            // Print available custom commands to be helpful
            if !extensions.is_empty() {
                eprintln!("\nAvailable extensions:");
                for (name, conf) in &extensions {
                    eprintln!("  {} - {}", name, conf.description);
                }
            }
            std::process::exit(1);
          }
        }
        None => {
            // Print help if no args
            Cli::command().print_help()?;
        }
    }
    Ok(())
}
