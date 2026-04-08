// decknix-hub — Background work-item aggregator
//
// Polls external services (GitHub, Jira, CI/CD) on independent timers,
// writes per-adapter JSON files to ~/.config/decknix/hub/.
// Emacs, CLI, and other consumers read those files (file-notify for live updates).

use chrono::{DateTime, Utc};
use clap::Parser;
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use std::time::Duration;
use tokio::process::Command;
use tokio::signal;

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

#[derive(Parser, Debug)]
#[command(name = "decknix-hub")]
#[command(about = "Background work-item aggregator for decknix")]
struct Cli {
    /// Run once and exit (for testing / cron).
    #[arg(long)]
    once: bool,

    /// Config file path (default: ~/.config/decknix/hub-config.json).
    #[arg(long, short)]
    config: Option<PathBuf>,

    /// Hub data directory (default: ~/.config/decknix/hub/).
    #[arg(long)]
    hub_dir: Option<PathBuf>,
}

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

#[derive(Debug, Deserialize, Serialize)]
#[serde(default)]
struct HubConfig {
    github: GitHubConfig,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(default)]
struct GitHubConfig {
    enabled: bool,
    reviews_interval_secs: u64,
    wip_interval_secs: u64,
    /// Repos to watch for review requests. Empty = all (uses gh search).
    review_repos: Vec<String>,
}

impl Default for HubConfig {
    fn default() -> Self {
        Self {
            github: GitHubConfig::default(),
        }
    }
}

impl Default for GitHubConfig {
    fn default() -> Self {
        Self {
            enabled: true,
            reviews_interval_secs: 60,
            wip_interval_secs: 120,
            review_repos: vec![],
        }
    }
}

// ---------------------------------------------------------------------------
// Data models — written to JSON files
// ---------------------------------------------------------------------------

#[derive(Debug, Serialize, Deserialize)]
struct ReviewRequest {
    id: String,
    repo: String,
    number: u64,
    title: String,
    author: String,
    url: String,
    created: DateTime<Utc>,
    #[serde(skip_serializing_if = "Option::is_none")]
    draft: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    labels: Option<Vec<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    ci: Option<CiStatus>,
}

#[derive(Debug, Serialize, Deserialize)]
struct CiStatus {
    status: String, // "pass", "fail", "running", "pending"
    #[serde(skip_serializing_if = "Option::is_none")]
    url: Option<String>,
}

#[derive(Debug, Serialize, Deserialize)]
struct ReviewsFile {
    updated: DateTime<Utc>,
    items: Vec<ReviewRequest>,
}

#[derive(Debug, Serialize, Deserialize)]
struct WipPr {
    number: u64,
    title: String,
    state: String,
    url: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    draft: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    ci: Option<CiStatus>,
    #[serde(skip_serializing_if = "Option::is_none")]
    branch: Option<String>,
}

#[derive(Debug, Serialize, Deserialize)]
struct WipRepo {
    repo: String,
    prs: Vec<WipPr>,
}

#[derive(Debug, Serialize, Deserialize)]
struct WipFile {
    updated: DateTime<Utc>,
    repos: Vec<WipRepo>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct AdapterStatus {
    name: String,
    last_poll: Option<DateTime<Utc>>,
    last_error: Option<String>,
    ok: bool,
}

#[derive(Debug, Serialize, Deserialize)]
struct MetaFile {
    updated: DateTime<Utc>,
    adapters: Vec<AdapterStatus>,
}

// ---------------------------------------------------------------------------
// Utilities
// ---------------------------------------------------------------------------

/// Resolve the hub data directory.
fn hub_dir(cli: &Cli) -> PathBuf {
    cli.hub_dir.clone().unwrap_or_else(|| {
        dirs::home_dir()
            .unwrap_or_default()
            .join(".config/decknix/hub")
    })
}

/// Load config from file, falling back to defaults if missing.
fn load_config(cli: &Cli) -> HubConfig {
    let path = cli.config.clone().unwrap_or_else(|| {
        dirs::home_dir()
            .unwrap_or_default()
            .join(".config/decknix/hub-config.json")
    });
    if path.exists() {
        match std::fs::read_to_string(&path) {
            Ok(contents) => match serde_json::from_str(&contents) {
                Ok(cfg) => return cfg,
                Err(e) => eprintln!("hub: config parse error: {e}, using defaults"),
            },
            Err(e) => eprintln!("hub: config read error: {e}, using defaults"),
        }
    }
    HubConfig::default()
}

/// Atomic JSON write: write to a temp file, then rename.
/// This ensures readers never see partial/corrupt JSON.
async fn atomic_write_json<T: Serialize>(dir: &Path, filename: &str, data: &T) -> std::io::Result<()> {
    let target = dir.join(filename);
    let tmp = dir.join(format!(".{}.tmp", filename));
    let json = serde_json::to_string_pretty(data)
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::Other, e))?;
    tokio::fs::write(&tmp, json.as_bytes()).await?;
    tokio::fs::rename(&tmp, &target).await?;
    Ok(())
}

/// Run `gh` CLI and return stdout as String, or an error message.
async fn gh_json(args: &[&str]) -> Result<String, String> {
    let output = Command::new("gh")
        .args(args)
        .output()
        .await
        .map_err(|e| format!("gh exec error: {e}"))?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(format!("gh error ({}): {}", output.status, stderr.trim()));
    }
    Ok(String::from_utf8_lossy(&output.stdout).to_string())
}


// ---------------------------------------------------------------------------
// GitHub Reviews Adapter
// ---------------------------------------------------------------------------

/// Intermediate struct for deserialising gh search output.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct GhSearchPr {
    number: u64,
    title: String,
    url: String,
    created_at: String,
    is_draft: Option<bool>,
    #[serde(default)]
    labels: Vec<GhLabel>,
    author: Option<GhAuthor>,
    repository: Option<GhRepo>,
}

#[derive(Debug, Deserialize)]
struct GhLabel {
    name: String,
}

#[derive(Debug, Deserialize)]
struct GhAuthor {
    login: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct GhRepo {
    name_with_owner: String,
}

#[derive(Debug, Deserialize)]
struct GhCheck {
    state: Option<String>,
    conclusion: Option<String>,
    #[serde(rename = "detailsUrl")]
    details_url: Option<String>,
}

/// Summarise CI checks into a single status.
fn summarise_ci(checks: &Option<Vec<GhCheck>>) -> Option<CiStatus> {
    let checks = checks.as_ref()?;
    if checks.is_empty() {
        return None;
    }
    // If any failed → fail; if any pending/in_progress → running; else pass
    let mut has_fail = false;
    let mut has_pending = false;
    let mut url = None;
    for c in checks {
        if let Some(ref conc) = c.conclusion {
            match conc.as_str() {
                "FAILURE" | "ERROR" | "TIMED_OUT" | "CANCELLED" | "ACTION_REQUIRED" => {
                    has_fail = true;
                    if url.is_none() {
                        url = c.details_url.clone();
                    }
                }
                _ => {}
            }
        } else if let Some(ref state) = c.state {
            if state != "SUCCESS" && state != "NEUTRAL" && state != "SKIPPED" {
                has_pending = true;
            }
        }
    }
    let status = if has_fail {
        "fail"
    } else if has_pending {
        "running"
    } else {
        "pass"
    };
    Some(CiStatus {
        status: status.to_string(),
        url,
    })
}

/// Fetch CI status for a single PR via `gh pr view`.
async fn fetch_pr_ci(repo: &str, number: u64) -> Option<CiStatus> {
    // gh pr view gives us statusCheckRollup which search doesn't
    let output = gh_json(&[
        "pr", "view",
        &number.to_string(),
        "--repo", repo,
        "--json", "statusCheckRollup",
    ]).await.ok()?;

    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct PrView { status_check_rollup: Option<Vec<GhCheck>> }

    let view: PrView = serde_json::from_str(&output).ok()?;
    summarise_ci(&view.status_check_rollup)
}

/// Fetch PR reviews assigned to the current user.
async fn poll_github_reviews(_config: &GitHubConfig) -> Result<ReviewsFile, String> {
    let output = gh_json(&[
        "search", "prs",
        "--review-requested=@me",
        "--state=open",
        "--json", "number,title,url,createdAt,isDraft,labels,author,repository",
        "--limit", "50",
    ]).await?;

    let prs: Vec<GhSearchPr> = serde_json::from_str(&output)
        .map_err(|e| format!("parse error: {e}"))?;

    let mut items: Vec<ReviewRequest> = Vec::with_capacity(prs.len());
    for pr in &prs {
        let repo = pr.repository.as_ref()
            .map(|r| r.name_with_owner.clone())
            .unwrap_or_default();
        // Fetch CI status per PR (parallel would be nicer but gh CLI
        // has rate limits; sequential is safer for a background poller)
        let ci = fetch_pr_ci(&repo, pr.number).await;
        items.push(ReviewRequest {
            id: format!("gh:{}#{}", repo, pr.number),
            repo: repo.clone(),
            number: pr.number,
            title: pr.title.clone(),
            author: pr.author.as_ref().map(|a| a.login.clone()).unwrap_or_default(),
            url: pr.url.clone(),
            created: pr.created_at.parse().unwrap_or_else(|_| Utc::now()),
            draft: pr.is_draft,
            labels: if pr.labels.is_empty() {
                None
            } else {
                Some(pr.labels.iter().map(|l| l.name.clone()).collect())
            },
            ci,
        });
    }

    // Sort oldest first (most urgent at top)
    items.sort_by_key(|r| r.created);

    Ok(ReviewsFile {
        updated: Utc::now(),
        items,
    })
}

// ---------------------------------------------------------------------------
// GitHub WIP Adapter
// ---------------------------------------------------------------------------

/// Fetch branch name and CI for a PR via `gh pr view`.
async fn fetch_pr_details(repo: &str, number: u64) -> (Option<String>, Option<CiStatus>) {
    let output = match gh_json(&[
        "pr", "view",
        &number.to_string(),
        "--repo", repo,
        "--json", "headRefName,statusCheckRollup",
    ]).await {
        Ok(o) => o,
        Err(_) => return (None, None),
    };

    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct PrDetail {
        head_ref_name: Option<String>,
        status_check_rollup: Option<Vec<GhCheck>>,
    }

    match serde_json::from_str::<PrDetail>(&output) {
        Ok(d) => (d.head_ref_name, summarise_ci(&d.status_check_rollup)),
        Err(_) => (None, None),
    }
}

/// Intermediate struct for gh search output (WIP PRs).
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct GhMyPr {
    number: u64,
    title: String,
    url: String,
    state: String,
    is_draft: Option<bool>,
    repository: Option<GhRepo>,
}

/// Fetch the current user's open PRs across all repos.
async fn poll_github_wip(_config: &GitHubConfig) -> Result<WipFile, String> {
    let output = gh_json(&[
        "search", "prs",
        "--author=@me",
        "--state=open",
        "--json", "number,title,url,state,isDraft,repository",
        "--limit", "50",
    ]).await?;

    let prs: Vec<GhMyPr> = serde_json::from_str(&output)
        .map_err(|e| format!("parse error: {e}"))?;

    // Group by repository
    let mut repo_map: std::collections::BTreeMap<String, Vec<WipPr>> =
        std::collections::BTreeMap::new();

    for pr in &prs {
        let repo = pr.repository.as_ref()
            .map(|r| r.name_with_owner.clone())
            .unwrap_or_else(|| "unknown".to_string());
        // Fetch branch + CI per PR
        let (branch, ci) = fetch_pr_details(&repo, pr.number).await;
        let entry = repo_map.entry(repo).or_default();
        entry.push(WipPr {
            number: pr.number,
            title: pr.title.clone(),
            state: pr.state.clone(),
            url: pr.url.clone(),
            draft: pr.is_draft,
            ci,
            branch,
        });
    }

    let repos = repo_map.into_iter().map(|(repo, prs)| WipRepo { repo, prs }).collect();

    Ok(WipFile {
        updated: Utc::now(),
        repos,
    })
}

// ---------------------------------------------------------------------------
// Adapter runner — independent async task per adapter
// ---------------------------------------------------------------------------

use std::sync::Arc;
use tokio::sync::Mutex;

/// Shared meta state that each adapter updates after polling.
type SharedMeta = Arc<Mutex<Vec<AdapterStatus>>>;

/// Spawn a GitHub reviews adapter task.
async fn run_reviews_adapter(
    config: GitHubConfig,
    dir: PathBuf,
    meta: SharedMeta,
    once: bool,
) {
    let interval = Duration::from_secs(config.reviews_interval_secs);
    loop {
        let result = poll_github_reviews(&config).await;
        let status = match &result {
            Ok(data) => {
                if let Err(e) = atomic_write_json(&dir, "github-reviews.json", data).await {
                    eprintln!("hub: write github-reviews.json: {e}");
                    AdapterStatus {
                        name: "github-reviews".into(),
                        last_poll: Some(Utc::now()),
                        last_error: Some(format!("write error: {e}")),
                        ok: false,
                    }
                } else {
                    eprintln!("hub: github-reviews: {} items", data.items.len());
                    AdapterStatus {
                        name: "github-reviews".into(),
                        last_poll: Some(Utc::now()),
                        last_error: None,
                        ok: true,
                    }
                }
            }
            Err(e) => {
                eprintln!("hub: github-reviews error: {e}");
                AdapterStatus {
                    name: "github-reviews".into(),
                    last_poll: Some(Utc::now()),
                    last_error: Some(e.clone()),
                    ok: false,
                }
            }
        };
        update_meta(&meta, status, &dir).await;
        if once { return; }
        tokio::time::sleep(interval).await;
    }
}

/// Spawn a GitHub WIP adapter task.
async fn run_wip_adapter(
    config: GitHubConfig,
    dir: PathBuf,
    meta: SharedMeta,
    once: bool,
) {
    let interval = Duration::from_secs(config.wip_interval_secs);
    loop {
        let result = poll_github_wip(&config).await;
        let status = match &result {
            Ok(data) => {
                if let Err(e) = atomic_write_json(&dir, "github-wip.json", data).await {
                    eprintln!("hub: write github-wip.json: {e}");
                    AdapterStatus {
                        name: "github-wip".into(),
                        last_poll: Some(Utc::now()),
                        last_error: Some(format!("write error: {e}")),
                        ok: false,
                    }
                } else {
                    let pr_count: usize = data.repos.iter().map(|r| r.prs.len()).sum();
                    eprintln!("hub: github-wip: {} PRs across {} repos",
                             pr_count, data.repos.len());
                    AdapterStatus {
                        name: "github-wip".into(),
                        last_poll: Some(Utc::now()),
                        last_error: None,
                        ok: true,
                    }
                }
            }
            Err(e) => {
                eprintln!("hub: github-wip error: {e}");
                AdapterStatus {
                    name: "github-wip".into(),
                    last_poll: Some(Utc::now()),
                    last_error: Some(e.clone()),
                    ok: false,
                }
            }
        };
        update_meta(&meta, status, &dir).await;
        if once { return; }
        tokio::time::sleep(interval).await;
    }
}

/// Update the shared meta state and write meta.json.
async fn update_meta(meta: &SharedMeta, status: AdapterStatus, dir: &Path) {
    let mut adapters = meta.lock().await;
    // Replace existing entry for this adapter, or insert
    if let Some(existing) = adapters.iter_mut().find(|a| a.name == status.name) {
        *existing = status;
    } else {
        adapters.push(status);
    }
    let meta_file = MetaFile {
        updated: Utc::now(),
        adapters: adapters.clone(),
    };
    if let Err(e) = atomic_write_json(dir, "meta.json", &meta_file).await {
        eprintln!("hub: write meta.json: {e}");
    }
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

#[tokio::main]
async fn main() {
    let cli = Cli::parse();
    let config = load_config(&cli);
    let dir = hub_dir(&cli);

    // Ensure hub directory exists
    if let Err(e) = tokio::fs::create_dir_all(&dir).await {
        eprintln!("hub: failed to create {}: {e}", dir.display());
        std::process::exit(1);
    }

    eprintln!("hub: data dir = {}", dir.display());
    eprintln!("hub: mode = {}", if cli.once { "once" } else { "daemon" });

    let meta: SharedMeta = Arc::new(Mutex::new(Vec::new()));
    let mut handles = Vec::new();

    // Spawn GitHub adapters
    if config.github.enabled {
        eprintln!("hub: github-reviews adapter: every {}s", config.github.reviews_interval_secs);
        eprintln!("hub: github-wip adapter: every {}s", config.github.wip_interval_secs);

        let gh_cfg = config.github;

        handles.push(tokio::spawn(run_reviews_adapter(
            GitHubConfig {
                enabled: gh_cfg.enabled,
                reviews_interval_secs: gh_cfg.reviews_interval_secs,
                wip_interval_secs: gh_cfg.wip_interval_secs,
                review_repos: gh_cfg.review_repos.clone(),
            },
            dir.clone(),
            meta.clone(),
            cli.once,
        )));

        handles.push(tokio::spawn(run_wip_adapter(
            gh_cfg,
            dir.clone(),
            meta.clone(),
            cli.once,
        )));
    }

    if handles.is_empty() {
        eprintln!("hub: no adapters enabled, exiting");
        return;
    }

    if cli.once {
        // Wait for all tasks to complete
        for h in handles {
            let _ = h.await;
        }
        eprintln!("hub: done (once mode)");
    } else {
        // Daemon mode: wait for SIGTERM/SIGINT
        eprintln!("hub: running (Ctrl-C or SIGTERM to stop)");
        match signal::ctrl_c().await {
            Ok(()) => eprintln!("hub: shutting down"),
            Err(e) => eprintln!("hub: signal error: {e}"),
        }
    }
}