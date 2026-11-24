//! `decknix hub jira-projects`: view or change the Jira projects the sidebar's
//! Tasks section lists, without a rebuild.
//!
//! The override lives in `~/.config/decknix/settings.toml` as
//!
//! ```toml
//! [hub.jira]
//! projects = ["ABC", "XYZ"]
//! ```
//!
//! and the hub daemon re-reads it on every Jira poll.  Without it the hub uses
//! `decknix.services.hub.jira.projects` from Nix (the org default).  The file
//! is edited line by line so the user's comments and other tables survive.

use anyhow::Result;
use clap::Subcommand;
use std::path::PathBuf;

#[derive(Subcommand)]
pub enum HubAction {
    /// Show or set the Jira project keys the Tasks section lists
    JiraProjects {
        /// Project keys (space- or comma-separated); omit to show the current value
        keys: Vec<String>,
        /// Remove the override and go back to the Nix-configured default
        #[arg(long, conflicts_with = "keys")]
        clear: bool,
        /// Act on the projects offered to pick up (`pick_up_projects`) instead
        #[arg(long)]
        pick_up: bool,
    },
}

fn settings_path() -> PathBuf {
    dirs::home_dir().unwrap_or_default().join(".config/decknix/settings.toml")
}

/// Normalised keys from command-line words: split on commas, upper case,
/// letters, digits and underscores only.
pub fn parse_keys(words: &[String]) -> Vec<String> {
    words.iter()
        .flat_map(|w| w.split(','))
        .map(|k| k.trim().to_ascii_uppercase().chars()
             .filter(|c| c.is_ascii_alphanumeric() || *c == '_').collect::<String>())
        .filter(|k| !k.is_empty())
        .collect()
}

/// The `[hub.jira] projects` override in settings TEXT, if any.
pub fn read_projects(text: &str) -> Option<Vec<String>> {
    read_key(text, "projects")
}

/// The `[hub.jira] NAME` list in settings TEXT, if any.
pub fn read_key(text: &str, name: &str) -> Option<Vec<String>> {
    let table: toml::Table = text.parse().ok()?;
    let arr = table.get("hub")?.get("jira")?.get(name)?.as_array()?;
    Some(arr.iter().filter_map(|v| v.as_str().map(str::to_string)).collect())
}

fn is_header(line: &str) -> bool {
    line.trim_start().starts_with('[')
}

/// TEXT with `[hub.jira] projects` set to KEYS, or removed when KEYS is None.
pub fn set_projects(text: &str, keys: Option<&[String]>) -> String {
    set_key(text, "projects", keys)
}

/// TEXT with `[hub.jira] NAME` set to KEYS, or removed when KEYS is None.
pub fn set_key(text: &str, name: &str, keys: Option<&[String]>) -> String {
    let new_line = keys.map(|k| format!(
        "{name} = [{}]",
        k.iter().map(|s| format!("\"{s}\"")).collect::<Vec<_>>().join(", ")));
    let mut lines: Vec<String> = text.lines().map(str::to_string).collect();
    let header = lines.iter().position(|l| l.trim() == "[hub.jira]");
    match header {
        Some(h) => {
            let end = lines[h + 1..].iter().position(|l| is_header(l)).map_or(lines.len(), |i| h + 1 + i);
            let existing = (h + 1..end).find(|&i| {
                let t = lines[i].trim_start();
                t.starts_with(name) && t[name.len()..].trim_start().starts_with('=')
            });
            match (existing, new_line) {
                (Some(i), Some(l)) => lines[i] = l,
                (Some(i), None) => { lines.remove(i); }
                (None, Some(l)) => lines.insert(h + 1, l),
                (None, None) => {}
            }
        }
        None => {
            if let Some(l) = new_line {
                if lines.last().is_some_and(|l| !l.trim().is_empty()) {
                    lines.push(String::new());
                }
                lines.push("[hub.jira]".into());
                lines.push(l);
            }
        }
    }
    let mut out = lines.join("\n");
    out.push('\n');
    out
}

pub fn run(action: HubAction) -> Result<()> {
    match action {
        HubAction::JiraProjects { keys, clear, pick_up } => {
            let (name, option, what) = if pick_up {
                ("pick_up_projects", "pickUpProjects (else projects)", "Jira pick-up projects")
            } else {
                ("projects", "projects", "Jira projects")
            };
            let path = settings_path();
            let text = std::fs::read_to_string(&path).unwrap_or_default();
            if keys.is_empty() && !clear {
                match read_key(&text, name) {
                    Some(p) => println!("{}  (override in {})", p.join(" "), path.display()),
                    None => println!("no override: the hub uses decknix.services.hub.jira.{option} from your config"),
                }
                return Ok(());
            }
            let parsed = parse_keys(&keys);
            if !clear && parsed.is_empty() {
                anyhow::bail!("no valid project keys in {:?}", keys);
            }
            let updated = set_key(&text, name, if clear { None } else { Some(&parsed) });
            if let Some(dir) = path.parent() {
                std::fs::create_dir_all(dir)?;
            }
            std::fs::write(&path, updated)?;
            if clear {
                println!("cleared; the hub goes back to its configured projects at its next Jira poll");
            } else {
                println!("{what}: {}  (the hub picks this up at its next Jira poll)", parsed.join(" "));
            }
            Ok(())
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn keys(k: &[&str]) -> Vec<String> {
        k.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn keys_split_on_commas_and_are_sanitised() {
        assert_eq!(parse_keys(&keys(&["hx,dos", " PLAT ", "a-b"])), keys(&["HX", "DOS", "PLAT", "AB"]));
    }

    #[test]
    fn a_new_table_is_appended_and_the_rest_kept() {
        let text = "# mine\n[repos]\nworkspaces = [\"~/src\"]\n";
        let out = set_projects(text, Some(&keys(&["HX", "DOS"])));
        assert_eq!(out, "# mine\n[repos]\nworkspaces = [\"~/src\"]\n\n[hub.jira]\nprojects = [\"HX\", \"DOS\"]\n");
        assert_eq!(read_projects(&out), Some(keys(&["HX", "DOS"])));
    }

    #[test]
    fn an_existing_value_is_replaced_in_place() {
        let text = "[hub.jira]\n# keys\nprojects = [\"OLD\"]\n[switch.overrides]\ndecknix = \"~/x\"\n";
        let out = set_projects(text, Some(&keys(&["NEW"])));
        assert_eq!(out, "[hub.jira]\n# keys\nprojects = [\"NEW\"]\n[switch.overrides]\ndecknix = \"~/x\"\n");
    }

    #[test]
    fn clearing_removes_only_the_projects_line() {
        let text = "[hub.jira]\nprojects = [\"OLD\"]\nother = 1\n";
        assert_eq!(set_projects(text, None), "[hub.jira]\nother = 1\n");
        assert_eq!(set_projects("", None), "\n");
    }

    #[test]
    fn pick_up_projects_sit_beside_projects_without_touching_them() {
        let text = "[hub.jira]\nprojects = [\"HX\"]\n";
        let out = set_key(text, "pick_up_projects", Some(&keys(&["US"])));
        assert_eq!(out, "[hub.jira]\npick_up_projects = [\"US\"]\nprojects = [\"HX\"]\n");
        assert_eq!(read_key(&out, "pick_up_projects"), Some(keys(&["US"])));
        assert_eq!(read_projects(&out), Some(keys(&["HX"])));
        assert_eq!(set_key(&out, "pick_up_projects", None), text);
    }

    #[test]
    fn a_projects_key_in_another_table_is_left_alone() {
        let text = "[other]\nprojects = [\"X\"]\n";
        let out = set_projects(text, Some(&keys(&["HX"])));
        assert!(out.starts_with("[other]\nprojects = [\"X\"]\n"), "{out}");
        assert_eq!(read_projects(&out), Some(keys(&["HX"])));
    }
}
