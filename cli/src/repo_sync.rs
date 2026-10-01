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

        /// Only sync clones whose directory name or path contains this string.
        /// Lets the sidebar retry one repo after clearing a lock, instead of
        /// waiting up to the 3h launchd interval for the whole sweep.
        #[arg(long, value_name = "NAME")]
        only: Option<String>,
    },
    /// Remove an abandoned `.git/index.lock', but only when it is provably
    /// abandoned: older than the staleness threshold AND with no git process
    /// live in the repo. Refuses otherwise, because deleting a live lock
    /// corrupts the index of whatever holds it.
    FixLock {
        /// Repository path (the working tree, not the `.git' dir).
        path: PathBuf,

        /// Seconds after which a lock counts as abandoned.
        #[arg(long, default_value_t = STALE_LOCK_SECS)]
        older_than: u64,

        /// Report the decision without removing anything.
        #[arg(long)]
        dry_run: bool,

        /// Emit machine-readable JSON.
        #[arg(long)]
        json: bool,
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

/// Primary clones under the configured workspace roots, as `repos list` sees them.
pub fn configured_clone_paths() -> Vec<PathBuf> {
    discover_all(&repo_config(&[], None), None)
        .into_iter()
        .map(|r| r.path)
        .collect()
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

/// Does this git failure mean `index.lock' already exists?  Pure.
///
/// Matched on the message rather than an exit code because git reports it as a
/// generic failure; the wording has been stable across git versions and is what
/// the operator sees.
pub fn index_lock_failure(message: &str) -> bool {
    message.contains("index.lock") && message.contains("File exists")
}

/// Seconds after which an `index.lock' is treated as abandoned.
///
/// No real git operation holds the index for an hour.  The lock that prompted
/// this was two weeks old, so the threshold is not the interesting part -- the
/// point is that it is a threshold at all, rather than deleting on sight.
pub const STALE_LOCK_SECS: u64 = 3600;

/// Should a lock of AGE_SECS be removed, given whether it is still HELD?
/// Pure, so the rule is testable without creating locks.
///
/// Both conditions are required.  Age alone would race a long checkout on a
/// repo the size of the monolith; "no live process" alone would delete a lock a
/// sibling agent had just taken, corrupting its index.
pub fn lock_is_stale(age_secs: u64, held: bool, threshold_secs: u64) -> bool {
    !held && age_secs >= threshold_secs
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
                // A lock failure is separated from every other merge failure
                // because it is the one with a safe, mechanical remedy. It went
                // unnoticed for 61 consecutive runs against `upside' -- two
                // weeks with no updates -- because the summary reported a flat
                // "3 errors" and nothing distinguished "needs a click" from
                // "needs a human".
                let msg = e.to_string();
                if index_lock_failure(&msg) {
                    r.outcome = "error-lock".into();
                    r.detail = format!(
                        "index.lock blocks fast-forward of {def} (+{n}); clear it if stale"
                    );
                } else {
                    r.outcome = "error".into();
                    r.detail = format!("ff-only merge failed: {msg}");
                }
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

/// Does REPO match a `--only' needle?  Directory name first, then the full
/// path, so both `--only upside' and a pasted absolute path work.
fn repo_matches(repo: &Repo, needle: &str) -> bool {
    let name = repo
        .path
        .file_name()
        .map(|s| s.to_string_lossy().to_string())
        .unwrap_or_default();
    name.contains(needle) || repo.path.to_string_lossy().contains(needle)
}

/// Where the sweep leaves its report for the Emacs sidebar to read.
pub fn report_path() -> PathBuf {
    dirs::home_dir()
        .unwrap_or_default()
        .join(".config/decknix/repo-sync.json")
}

fn write_report(results: &[SyncResult]) -> std::io::Result<()> {
    let arr: Vec<_> = results.iter().map(result_json).collect();
    write_report_rows(&arr)
}

fn write_report_rows(arr: &[serde_json::Value]) -> std::io::Result<()> {
    let path = report_path();
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let body = serde_json::json!({ "updated": now, "repos": arr });
    // Write-then-rename: the sidebar polls this path, and a reader that
    // arrives mid-write would otherwise parse a truncated file and conclude
    // there are no problems.
    let tmp = path.with_extension("json.tmp");
    std::fs::write(&tmp, serde_json::to_string_pretty(&body).unwrap_or_default())?;
    std::fs::rename(&tmp, &path)
}

/// Merge RESULTS into the existing report, replacing only their own rows.
///
/// A scoped (`--only') sync used to write no report at all, on the grounds
/// that rewriting it with one row would erase the other 59.  But the sidebar
/// renders FROM the report, so the row it had just fixed stayed on screen:
/// `fix-lock' removed an abandoned lock, the scoped re-sync confirmed the
/// repo was clean, and `upside' still showed "stale lock" because nothing
/// rewrote its row.  Refreshing the view cannot help when the data behind it
/// is unchanged.
///
/// Patching keeps both properties: other repos' rows survive, and the rows
/// this run actually observed are current.  Rows are keyed on `path', which
/// is what `result_json' emits and what the sidebar matches on.
fn patch_report(results: &[SyncResult]) -> std::io::Result<()> {
    let path = report_path();
    let existing: Vec<serde_json::Value> = std::fs::read_to_string(&path)
        .ok()
        .and_then(|s| serde_json::from_str::<serde_json::Value>(&s).ok())
        .and_then(|v| v.get("repos").cloned())
        .and_then(|v| v.as_array().cloned())
        .unwrap_or_default();

    let fresh: Vec<serde_json::Value> = results.iter().map(result_json).collect();
    write_report_rows(&merge_rows(existing, fresh))
}

/// Replace rows in EXISTING that FRESH also covers, keyed on `path'.
///
/// Pure so the merge can be tested without a filesystem: the failure it
/// guards against is losing the 59 rows a scoped sync did not look at.
fn merge_rows(
    existing: Vec<serde_json::Value>,
    fresh: Vec<serde_json::Value>,
) -> Vec<serde_json::Value> {
    let replaced: std::collections::HashSet<String> = fresh
        .iter()
        .filter_map(|r| r.get("path").and_then(|p| p.as_str()).map(str::to_owned))
        .collect();

    let mut merged: Vec<serde_json::Value> = existing
        .into_iter()
        .filter(|r| {
            r.get("path")
                .and_then(|p| p.as_str())
                .map(|p| !replaced.contains(p))
                .unwrap_or(true)
        })
        .collect();
    merged.extend(fresh);
    merged
}

/// Does any process currently hold LOCK open?
///
/// Asks `lsof' about the lock file itself rather than scanning `ps' for the
/// repo path.  The `ps' approach matched its OWN invocation -- the parent
/// shell's argv contains both the repo path and `.git/index.lock', so the
/// check reported "live" every time and `fix-lock' could never succeed. A
/// safety check that always refuses is indistinguishable from a broken one.
///
/// git creates `index.lock' with O_CREAT|O_EXCL and keeps the descriptor until
/// it commits or rolls back, so an open descriptor is the accurate signal.
///
/// Fails CLOSED: if `lsof' cannot be run we report held, so an unusable probe
/// refuses to delete rather than guessing.
fn lock_is_held(lock: &Path) -> bool {
    match std::process::Command::new("lsof").arg("-t").arg("--").arg(lock).output() {
        Ok(out) => !String::from_utf8_lossy(&out.stdout).trim().is_empty(),
        Err(_) => true,
    }
}

fn lock_age_secs(lock: &Path) -> Option<u64> {
    let meta = std::fs::metadata(lock).ok()?;
    let mtime = meta.modified().ok()?;
    std::time::SystemTime::now().duration_since(mtime).ok().map(|d| d.as_secs())
}

pub fn run(action: RepoAction) -> Result<()> {
    match action {
        RepoAction::Sync { workspace, org, dry_run, json, jobs, depth, only } => {
            let cfg = repo_config(&workspace, depth);
            let mut repos = discover_all(&cfg, org.as_deref());
            if let Some(needle) = only.as_deref() {
                repos = repos.into_iter().filter(|r| repo_matches(r, needle)).collect();
            }
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

            // Persist the report unless this was a dry run or a single-repo
            // retry: the sidebar renders from this file rather than shelling
            // out per paint, and a partial sweep must not overwrite the full
            // picture with one repo.
            if !dry_run {
                let wrote = if only.is_none() {
                    write_report(&results)
                } else {
                    // Scoped: patch these rows into the existing report so a
                    // fixed repo stops showing its old problem, without
                    // discarding the rows this run did not look at.
                    patch_report(&results)
                };
                if let Err(e) = wrote {
                    eprintln!("decknix: could not write repo-sync report: {e}");
                }
            }

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
                    "error" | "error-lock" => {
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
        RepoAction::FixLock { path, older_than, dry_run, json } => {
            let lock = path.join(".git/index.lock");
            let (ok, reason) = if !lock.exists() {
                (false, "no index.lock present".to_string())
            } else {
                let live = lock_is_held(&lock);
                match lock_age_secs(&lock) {
                    None => (false, "cannot read lock mtime".to_string()),
                    Some(age) => {
                        if lock_is_stale(age, live, older_than) {
                            (true, format!("abandoned {age}s, lock not held by any process"))
                        } else if live {
                            (false, format!("a process still holds the lock ({age}s old)"))
                        } else {
                            (false, format!("only {age}s old, under the {older_than}s threshold"))
                        }
                    }
                }
            };
            let removed = if ok && !dry_run {
                match std::fs::remove_file(&lock) {
                    Ok(_) => true,
                    Err(e) => {
                        if json {
                            println!("{}", serde_json::json!({
                                "path": path.to_string_lossy(), "removed": false,
                                "stale": ok, "reason": format!("remove failed: {e}") }));
                        } else {
                            println!("REFUSED  {}: remove failed: {e}", path.display());
                        }
                        return Ok(());
                    }
                }
            } else {
                false
            };
            if json {
                println!("{}", serde_json::to_string_pretty(&serde_json::json!({
                    "path": path.to_string_lossy(),
                    "lock": lock.to_string_lossy(),
                    "stale": ok,
                    "removed": removed,
                    "dryRun": dry_run,
                    "reason": reason,
                }))?);
            } else if removed {
                println!("removed {} ({reason})", lock.display());
            } else if ok {
                println!("would remove {} ({reason})", lock.display());
            } else {
                println!("REFUSED  {} ({reason})", lock.display());
            }
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
mod lock_tests {
    use super::*;

    #[test]
    fn index_lock_failure_recognises_gits_wording() {
        assert!(index_lock_failure(
            "error: Unable to create '/w/upside/.git/index.lock': File exists."));
    }

    #[test]
    fn index_lock_failure_ignores_other_merge_errors() {
        // Must not classify a real conflict as a clearable lock -- the sidebar
        // would then offer "clear lock" as the remedy for a merge conflict.
        assert!(!index_lock_failure("error: Your local changes would be overwritten"));
        assert!(!index_lock_failure("fatal: refusing to merge unrelated histories"));
        assert!(!index_lock_failure("could not open index.lock for writing"));
    }

    #[test]
    fn a_live_git_process_is_never_stale() {
        // Age is irrelevant while something holds it: deleting a lock a sibling
        // agent just took corrupts that process's index.
        assert!(!lock_is_stale(u64::MAX, true, STALE_LOCK_SECS));
        assert!(!lock_is_stale(0, true, STALE_LOCK_SECS));
    }

    #[test]
    fn a_young_lock_is_never_stale_even_with_no_process_seen() {
        // `ps' is a snapshot; a checkout on a repo the size of the monolith can
        // sit between samples.
        assert!(!lock_is_stale(0, false, STALE_LOCK_SECS));
        assert!(!lock_is_stale(STALE_LOCK_SECS - 1, false, STALE_LOCK_SECS));
    }

    #[test]
    fn an_old_lock_with_no_process_is_stale() {
        assert!(lock_is_stale(STALE_LOCK_SECS, false, STALE_LOCK_SECS));
        // The one that prompted this was two weeks old.
        assert!(lock_is_stale(14 * 24 * 3600, false, STALE_LOCK_SECS));
    }

    #[test]
    fn repo_matches_by_name_or_full_path() {
        let repo = Repo { org: "o".into(), path: PathBuf::from("/w/nurturecloud/upside") };
        assert!(repo_matches(&repo, "upside"));
        assert!(repo_matches(&repo, "/w/nurturecloud/upside"));
        assert!(!repo_matches(&repo, "downside"));
    }
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

    fn row(path: &str, outcome: &str) -> serde_json::Value {
        serde_json::json!({ "path": path, "outcome": outcome })
    }

    #[test]
    fn scoped_patch_keeps_the_rows_it_did_not_look_at() {
        // The reason a scoped sync wrote no report at all: rewriting it with
        // one row erased the other 59.
        let existing = vec![row("/a", "fetched"), row("/b", "error-lock"), row("/c", "skipped")];
        let fresh = vec![row("/b", "fetched")];
        let merged = merge_rows(existing, fresh);
        assert_eq!(merged.len(), 3);
        let paths: Vec<&str> =
            merged.iter().filter_map(|r| r["path"].as_str()).collect();
        assert!(paths.contains(&"/a"));
        assert!(paths.contains(&"/c"));
    }

    #[test]
    fn scoped_patch_replaces_the_fixed_row() {
        // The bug: `fix-lock' cleared upside's lock, the scoped re-sync saw a
        // clean repo, and the sidebar still read "stale lock" because nothing
        // rewrote the row.
        let existing = vec![row("/upside", "error-lock")];
        let fresh = vec![row("/upside", "fetched")];
        let merged = merge_rows(existing, fresh);
        assert_eq!(merged.len(), 1);
        assert_eq!(merged[0]["outcome"].as_str(), Some("fetched"));
    }

    #[test]
    fn scoped_patch_into_an_empty_report_just_adds() {
        let merged = merge_rows(vec![], vec![row("/a", "fetched")]);
        assert_eq!(merged.len(), 1);
    }

    #[test]
    fn scoped_patch_keeps_rows_with_no_path() {
        // A malformed row must not be silently dropped by the merge.
        let existing = vec![serde_json::json!({ "outcome": "weird" })];
        let merged = merge_rows(existing, vec![row("/a", "fetched")]);
        assert_eq!(merged.len(), 2);
    }
}
