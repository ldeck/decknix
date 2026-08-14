//! `decknix repos sync` — keep local clones fresh.
//!
//! Iterates the configured workspace roots (one per GitHub org), discovers the
//! git clones under each, and brings each repo's default branch up to date with
//! `origin` — WITHOUT ever disturbing uncommitted work or the checked-out
//! branch. A fresh local tree of every org's code materially helps AI agents
//! (grep, rebase targets, up-to-date `origin/main`).
//!
//! Safety model, per repo:
//!   * Always `git fetch --prune origin` (prompts disabled, SSH in batch mode)
//!     so `origin/*` refs stay current and the run never hangs on a password.
//!   * On the default branch + clean + behind  -> fast-forward the checkout.
//!   * On a feature branch                      -> fast-forward the local
//!     default ref in place (no checkout change) so `main` is fresh for AI.
//!   * Dirty / ahead / diverged / detached      -> fetch only. Never force,
//!     never checkout, never touch a dirty tree.
//!
//! This is what the `decknix-repo-sync` launchd agent runs on a timer.

use anyhow::{anyhow, Result};
use clap::Subcommand;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::{Arc, Mutex};

fn home() -> PathBuf {
    dirs::home_dir().unwrap_or_default()
}

/// Expand a leading `~/` and return an absolute path.
fn resolve_dir(s: &str) -> PathBuf {
    if s == "~" {
        home()
    } else if let Some(rest) = s.strip_prefix("~/") {
        home().join(rest)
    } else {
        PathBuf::from(s)
    }
}

#[derive(Subcommand)]
pub enum RepoAction {
    /// Fetch + fast-forward the default branch of every clone in the configured
    /// workspaces (never touches dirty trees or the checked-out feature branch).
    Sync {
        /// Workspace root(s) to scan (repeatable). Accepts `PATH` or `org=PATH`.
        /// Defaults to the `[repos].workspaces` setting.
        #[arg(long, value_name = "[ORG=]PATH")]
        workspace: Vec<String>,

        /// Only sync clones under the workspace labelled with this org.
        #[arg(long)]
        org: Option<String>,

        /// Report what would happen without fetching or updating anything.
        #[arg(long)]
        dry_run: bool,

        /// Emit machine-readable JSON instead of a human summary.
        #[arg(long)]
        json: bool,

        /// Max concurrent repos (default: min(8, CPUs)).
        #[arg(long)]
        jobs: Option<usize>,

        /// Directory depth to scan under each root for `.git` clones (default 2).
        #[arg(long)]
        depth: Option<usize>,
    },
    /// List the clones that `sync` would consider, with current branch + status.
    /// Local only — does not touch the network.
    List {
        #[arg(long, value_name = "[ORG=]PATH")]
        workspace: Vec<String>,
        #[arg(long)]
        org: Option<String>,
        #[arg(long)]
        depth: Option<usize>,
        #[arg(long)]
        json: bool,
    },
}

/// A configured workspace root plus its org label.
#[derive(Clone, Debug)]
struct Workspace {
    org: String,
    root: PathBuf,
}

struct RepoConfig {
    workspaces: Vec<Workspace>,
    scan_depth: usize,
}

/// Parse `"org=~/path"` / `"~/path"` into a labelled workspace. A bare path
/// takes its org label from the directory's own name.
fn parse_workspace(spec: &str) -> Workspace {
    match spec.split_once('=') {
        Some((org, path)) => Workspace {
            org: org.trim().to_string(),
            root: resolve_dir(path.trim()),
        },
        None => {
            let root = resolve_dir(spec.trim());
            let org = root
                .file_name()
                .map(|s| s.to_string_lossy().to_string())
                .unwrap_or_else(|| spec.trim().to_string());
            Workspace { org, root }
        }
    }
}

/// Read `[repos]` out of settings.toml, applying built-in defaults so the
/// section is entirely optional.
fn repo_config(cli_workspaces: &[String], cli_depth: Option<usize>) -> RepoConfig {
    // Built-in fallback matches the machine's known layout: personal tools live
    // flat under ~/tools; the nurturecloud org's clones sit under ~/Code/nurturecloud.
    let mut cfg = RepoConfig {
        workspaces: vec![
            parse_workspace("ldeck=~/tools"),
            parse_workspace("nurturecloud=~/Code/nurturecloud"),
        ],
        scan_depth: 2,
    };

    let path = home().join(".config/decknix/settings.toml");
    if let Ok(s) = std::fs::read_to_string(&path) {
        if let Ok(v) = s.parse::<toml::Value>() {
            if let Some(sec) = v.get("repos").and_then(|x| x.as_table()) {
                if let Some(arr) = sec.get("workspaces").and_then(|x| x.as_array()) {
                    let parsed: Vec<Workspace> = arr
                        .iter()
                        .filter_map(|x| x.as_str())
                        .map(parse_workspace)
                        .collect();
                    if !parsed.is_empty() {
                        cfg.workspaces = parsed;
                    }
                }
                if let Some(d) = sec.get("scan_depth").and_then(|x| x.as_integer()) {
                    if d > 0 {
                        cfg.scan_depth = d as usize;
                    }
                }
            }
        }
    }

    // CLI overrides win over config + defaults.
    if !cli_workspaces.is_empty() {
        cfg.workspaces = cli_workspaces.iter().map(|s| parse_workspace(s)).collect();
    }
    if let Some(d) = cli_depth {
        if d > 0 {
            cfg.scan_depth = d;
        }
    }
    cfg
}

/// A discovered clone: its org label and working-tree path.
#[derive(Clone, Debug)]
struct Repo {
    org: String,
    path: PathBuf,
}

/// Walk a root up to `depth` levels looking for primary clones — directories
/// whose `.git` is itself a directory. A `.git` *file* is a gitlink (linked
/// worktree or submodule): it shares the primary clone's object store and refs,
/// so the primary's fetch already refreshes it — we skip it to avoid redundant
/// network round-trips. Does not descend into a repo once found.
fn discover(root: &Path, org: &str, depth: usize, out: &mut Vec<Repo>) {
    if !root.is_dir() {
        return;
    }
    let dotgit = root.join(".git");
    if dotgit.is_dir() {
        out.push(Repo { org: org.to_string(), path: root.to_path_buf() });
        return; // don't recurse into a repo (submodules/worktrees are theirs)
    }
    if dotgit.is_file() {
        return; // linked worktree / submodule — covered via its primary clone
    }
    if depth == 0 {
        return;
    }
    let entries = match std::fs::read_dir(root) {
        Ok(e) => e,
        Err(_) => return,
    };
    let mut children: Vec<PathBuf> = entries
        .filter_map(|e| e.ok())
        .map(|e| e.path())
        .filter(|p| p.is_dir())
        .collect();
    children.sort();
    for child in children {
        // Skip obvious noise directories.
        if let Some(name) = child.file_name().and_then(|s| s.to_str()) {
            if matches!(name, "node_modules" | ".direnv" | "target" | ".git") {
                continue;
            }
        }
        discover(&child, org, depth - 1, out);
    }
}

fn discover_all(cfg: &RepoConfig, org_filter: Option<&str>) -> Vec<Repo> {
    let mut repos = Vec::new();
    for ws in &cfg.workspaces {
        if let Some(f) = org_filter {
            if ws.org != f {
                continue;
            }
        }
        discover(&ws.root, &ws.org, cfg.scan_depth, &mut repos);
    }
    repos.sort_by(|a, b| a.path.cmp(&b.path));
    repos.dedup_by(|a, b| a.path == b.path);
    repos
}

/// Run a git command in `repo`, returning trimmed stdout on success.
fn git(repo: &Path, args: &[&str]) -> Result<String> {
    let out = Command::new("git")
        .arg("-C")
        .arg(repo)
        .args(args)
        // Never block on interactive prompts; fail fast on unreachable hosts.
        .env("GIT_TERMINAL_PROMPT", "0")
        .env(
            "GIT_SSH_COMMAND",
            std::env::var("GIT_SSH_COMMAND")
                .unwrap_or_else(|_| "ssh -o BatchMode=yes -o ConnectTimeout=10".to_string()),
        )
        .output()?;
    if !out.status.success() {
        return Err(anyhow!(
            "git {}: {}",
            args.join(" "),
            String::from_utf8_lossy(&out.stderr).trim()
        ));
    }
    Ok(String::from_utf8_lossy(&out.stdout).trim().to_string())
}

/// The action chosen for a repo after inspecting its state. Pure/testable.
#[derive(Debug, Clone, PartialEq, Eq)]
enum Plan {
    /// Working checkout is the default branch, clean, behind by N -> ff checkout.
    FfCheckout(u32),
    /// On a feature branch; local default is behind by N and ff-able -> move ref.
    FfRef(u32),
    /// Refs refreshed; nothing to fast-forward (up to date, ahead, or no local default).
    FetchedOnly,
    /// Would fast-forward but the checkout is dirty.
    SkipDirty,
    /// Local default has commits origin lacks and is behind -> diverged, can't ff.
    SkipDiverged,
}

/// Decide what to do given the post-fetch state.
///   * `has_local_default` — a local `refs/heads/<def>` exists.
///   * `on_default` — the checked-out branch IS the default branch.
///   * `dirty` — working tree has uncommitted changes.
///   * `ahead` — commits local default has that origin default lacks.
///   * `behind` — commits origin default has that local default lacks.
fn decide(has_local_default: bool, on_default: bool, dirty: bool, ahead: u32, behind: u32) -> Plan {
    if !has_local_default || behind == 0 {
        return Plan::FetchedOnly;
    }
    if ahead > 0 {
        return Plan::SkipDiverged;
    }
    // behind > 0, ahead == 0  -> fast-forwardable.
    if on_default {
        if dirty {
            Plan::SkipDirty
        } else {
            Plan::FfCheckout(behind)
        }
    } else {
        Plan::FfRef(behind)
    }
}

#[derive(Debug, Clone)]
struct SyncResult {
    org: String,
    path: PathBuf,
    default_branch: String,
    outcome: String, // short machine-ish token
    detail: String,  // human phrase
    error: bool,
}

/// Resolve the default branch: prefer origin/HEAD, fall back to main/master
/// that actually exist on origin.
fn default_branch(repo: &Path) -> Option<String> {
    if let Ok(s) = git(repo, &["symbolic-ref", "-q", "--short", "refs/remotes/origin/HEAD"]) {
        // "origin/main" -> "main"
        if let Some(b) = s.strip_prefix("origin/") {
            if !b.is_empty() {
                return Some(b.to_string());
            }
        }
    }
    for cand in ["main", "master"] {
        if git(repo, &["rev-parse", "--verify", "-q", &format!("refs/remotes/origin/{cand}")]).is_ok() {
            return Some(cand.to_string());
        }
    }
    None
}

/// Fetch and, per the safety model, fast-forward one repo.
fn sync_one(repo: &Repo, dry_run: bool) -> SyncResult {
    let mut r = SyncResult {
        org: repo.org.clone(),
        path: repo.path.clone(),
        default_branch: String::new(),
        outcome: String::new(),
        detail: String::new(),
        error: false,
    };

    // Must have an origin remote.
    match git(&repo.path, &["remote"]) {
        Ok(remotes) if remotes.split_whitespace().any(|x| x == "origin") => {}
        Ok(_) => {
            r.outcome = "no-origin".into();
            r.detail = "no 'origin' remote".into();
            return r;
        }
        Err(e) => {
            r.outcome = "error".into();
            r.detail = e.to_string();
            r.error = true;
            return r;
        }
    }

    if dry_run {
        // Report intended default branch + current state without fetching.
        let def = default_branch(&repo.path).unwrap_or_else(|| "?".into());
        r.default_branch = def;
        r.outcome = "would-fetch".into();
        r.detail = "dry run (no fetch)".into();
        return r;
    }

    if let Err(e) = git(&repo.path, &["fetch", "--prune", "--quiet", "origin"]) {
        r.outcome = "error".into();
        r.detail = format!("fetch failed: {e}");
        r.error = true;
        return r;
    }

    let def = match default_branch(&repo.path) {
        Some(d) => d,
        None => {
            r.outcome = "fetched".into();
            r.detail = "fetched; no default branch resolvable".into();
            return r;
        }
    };
    r.default_branch = def.clone();

    let origin_ref = format!("refs/remotes/origin/{def}");
    let local_ref = format!("refs/heads/{def}");
    let has_local = git(&repo.path, &["rev-parse", "--verify", "-q", &local_ref]).is_ok();

    let current = git(&repo.path, &["symbolic-ref", "-q", "--short", "HEAD"]).ok();
    let on_default = current.as_deref() == Some(def.as_str());
    let dirty = git(&repo.path, &["status", "--porcelain"])
        .map(|s| !s.is_empty())
        .unwrap_or(true);

    let (ahead, behind) = if has_local {
        git(
            &repo.path,
            &["rev-list", "--left-right", "--count", &format!("{local_ref}...{origin_ref}")],
        )
        .ok()
        .and_then(|s| {
            let mut it = s.split_whitespace();
            let a = it.next()?.parse::<u32>().ok()?;
            let b = it.next()?.parse::<u32>().ok()?;
            Some((a, b))
        })
        .unwrap_or((0, 0))
    } else {
        (0, 0)
    };

    match decide(has_local, on_default, dirty, ahead, behind) {
        Plan::FfCheckout(n) => match git(&repo.path, &["merge", "--ff-only", &origin_ref]) {
            Ok(_) => {
                r.outcome = "updated".into();
                r.detail = format!("fast-forwarded {def} +{n}");
            }
            Err(e) => {
                r.outcome = "error".into();
                r.detail = format!("ff-only merge failed: {e}");
                r.error = true;
            }
        },
        Plan::FfRef(n) => {
            match git(
                &repo.path,
                &["update-ref", &local_ref, &origin_ref],
            ) {
                Ok(_) => {
                    r.outcome = "updated-ref".into();
                    r.detail =
                        format!("advanced {def} +{n} (on {})", current.as_deref().unwrap_or("detached"));
                }
                Err(e) => {
                    r.outcome = "error".into();
                    r.detail = format!("update-ref failed: {e}");
                    r.error = true;
                }
            }
        }
        Plan::FetchedOnly => {
            r.outcome = "fetched".into();
            r.detail = if !has_local {
                "fetched (no local default)".into()
            } else if ahead > 0 {
                format!("fetched ({def} ahead +{ahead})")
            } else {
                "up to date".into()
            };
        }
        Plan::SkipDirty => {
            r.outcome = "skipped".into();
            r.detail = format!("fetched; {def} behind +{behind} but working tree dirty");
        }
        Plan::SkipDiverged => {
            r.outcome = "skipped".into();
            r.detail = format!("fetched; {def} diverged (+{ahead}/-{behind})");
        }
    }
    r
}

/// Run `sync_one` across repos with a bounded worker pool.
fn run_pool(repos: Vec<Repo>, jobs: usize, dry_run: bool) -> Vec<SyncResult> {
    if repos.is_empty() {
        return Vec::new();
    }
    let jobs = jobs.max(1).min(repos.len());
    let queue = Arc::new(Mutex::new(repos.into_iter()));
    let results = Arc::new(Mutex::new(Vec::new()));

    std::thread::scope(|scope| {
        for _ in 0..jobs {
            let queue = Arc::clone(&queue);
            let results = Arc::clone(&results);
            scope.spawn(move || loop {
                let next = {
                    let mut q = queue.lock().unwrap();
                    q.next()
                };
                match next {
                    Some(repo) => {
                        let res = sync_one(&repo, dry_run);
                        results.lock().unwrap().push(res);
                    }
                    None => break,
                }
            });
        }
    });

    let mut out = Arc::try_unwrap(results).unwrap().into_inner().unwrap();
    out.sort_by(|a, b| a.path.cmp(&b.path));
    out
}

fn default_jobs() -> usize {
    std::thread::available_parallelism()
        .map(|n| n.get())
        .unwrap_or(4)
        .min(8)
}

fn result_json(r: &SyncResult) -> serde_json::Value {
    serde_json::json!({
        "org": r.org,
        "path": r.path.to_string_lossy(),
        "defaultBranch": r.default_branch,
        "outcome": r.outcome,
        "detail": r.detail,
        "error": r.error,
    })
}

pub fn run(action: RepoAction) -> Result<()> {
    match action {
        RepoAction::Sync { workspace, org, dry_run, json, jobs, depth } => {
            let cfg = repo_config(&workspace, depth);
            let repos = discover_all(&cfg, org.as_deref());
            if repos.is_empty() {
                if json {
                    println!("{}", serde_json::json!({"repos": [], "summary": {}}));
                } else {
                    println!("No clones found under configured workspaces.");
                    for ws in &cfg.workspaces {
                        println!("  {} -> {}", ws.org, ws.root.display());
                    }
                }
                return Ok(());
            }
            let jobs = jobs.unwrap_or_else(default_jobs);
            let results = run_pool(repos, jobs, dry_run);

            if json {
                let arr: Vec<_> = results.iter().map(result_json).collect();
                println!("{}", serde_json::to_string_pretty(&serde_json::json!({ "repos": arr }))?);
                return Ok(());
            }

            // Human summary: one line per repo, grouped nothing-fancy, then a tally.
            let mut updated = 0;
            let mut fetched = 0;
            let mut skipped = 0;
            let mut errored = 0;
            for r in &results {
                let name = r
                    .path
                    .file_name()
                    .map(|s| s.to_string_lossy().to_string())
                    .unwrap_or_else(|| r.path.display().to_string());
                let tag = match r.outcome.as_str() {
                    "updated" | "updated-ref" => {
                        updated += 1;
                        "UPDATED"
                    }
                    "error" => {
                        errored += 1;
                        "ERROR  "
                    }
                    "skipped" | "no-origin" => {
                        skipped += 1;
                        "SKIPPED"
                    }
                    _ => {
                        fetched += 1;
                        "fetched"
                    }
                };
                println!("  {tag}  {:<18} {}  [{}]", name, r.detail, r.org);
            }
            println!();
            println!(
                "{} repos: {} updated, {} fetched, {} skipped, {} errors{}",
                results.len(),
                updated,
                fetched,
                skipped,
                errored,
                if dry_run { "  (dry run)" } else { "" }
            );
        }
        RepoAction::List { workspace, org, depth, json } => {
            let cfg = repo_config(&workspace, depth);
            let repos = discover_all(&cfg, org.as_deref());
            if json {
                let arr: Vec<_> = repos
                    .iter()
                    .map(|r| serde_json::json!({"org": r.org, "path": r.path.to_string_lossy()}))
                    .collect();
                println!("{}", serde_json::to_string_pretty(&serde_json::json!({ "repos": arr }))?);
            } else {
                for r in &repos {
                    let branch = git(&r.path, &["symbolic-ref", "-q", "--short", "HEAD"])
                        .unwrap_or_else(|_| "(detached)".into());
                    let dirty = git(&r.path, &["status", "--porcelain"])
                        .map(|s| !s.is_empty())
                        .unwrap_or(false);
                    println!(
                        "  {:<26} {}{}  [{}]",
                        r.path.file_name().map(|s| s.to_string_lossy().to_string()).unwrap_or_default(),
                        branch,
                        if dirty { " *" } else { "" },
                        r.org
                    );
                }
                println!("\n{} clones under {} workspace(s)", repos.len(), cfg.workspaces.len());
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_workspace_labelled_and_bare() {
        let w = parse_workspace("nurturecloud=~/Code/nurturecloud");
        assert_eq!(w.org, "nurturecloud");
        assert_eq!(w.root, home().join("Code/nurturecloud"));

        let b = parse_workspace("~/Code/nurturecloud");
        assert_eq!(b.org, "nurturecloud"); // org derived from dir name
        assert_eq!(b.root, home().join("Code/nurturecloud"));
    }

    #[test]
    fn decide_covers_the_safety_matrix() {
        // No local default branch, or already up to date -> fetch only.
        assert_eq!(decide(false, false, false, 0, 0), Plan::FetchedOnly);
        assert_eq!(decide(true, true, false, 0, 0), Plan::FetchedOnly);
        // On default, clean, behind -> fast-forward the checkout.
        assert_eq!(decide(true, true, false, 0, 3), Plan::FfCheckout(3));
        // On default, dirty, behind -> refuse to touch the tree.
        assert_eq!(decide(true, true, true, 0, 3), Plan::SkipDirty);
        // On default, ahead + behind -> diverged, cannot ff.
        assert_eq!(decide(true, true, false, 2, 3), Plan::SkipDiverged);
        // On a feature branch, default behind, ff-able -> advance the ref in place.
        assert_eq!(decide(true, false, false, 0, 5), Plan::FfRef(5));
        // On a feature branch but local default is ahead too -> diverged.
        assert_eq!(decide(true, false, false, 1, 5), Plan::SkipDiverged);
        // Local ahead only (behind 0) -> nothing to pull.
        assert_eq!(decide(true, true, false, 4, 0), Plan::FetchedOnly);
    }

    #[test]
    fn discover_finds_clones_and_stops_at_repo_root() {
        let tmp = std::env::temp_dir().join(format!("decknix-reposync-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&tmp);
        // <root>/repo-a/.git  and  <root>/group/repo-b/.git
        std::fs::create_dir_all(tmp.join("repo-a/.git")).unwrap();
        std::fs::create_dir_all(tmp.join("repo-a/submodule/.git")).unwrap(); // must NOT be found (inside a repo)
        std::fs::create_dir_all(tmp.join("group/repo-b/.git")).unwrap();
        std::fs::create_dir_all(tmp.join("empty")).unwrap();

        let mut out = Vec::new();
        discover(&tmp, "acme", 3, &mut out);
        let paths: Vec<_> = out.iter().map(|r| r.path.clone()).collect();

        assert!(paths.contains(&tmp.join("repo-a")));
        assert!(paths.contains(&tmp.join("group/repo-b")));
        assert!(!paths.iter().any(|p| p.ends_with("submodule")));
        assert!(out.iter().all(|r| r.org == "acme"));

        let _ = std::fs::remove_dir_all(&tmp);
    }
}
