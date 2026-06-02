// decknix-hub — Background work-item aggregator
//
// Polls external services (GitHub, Jira, CI/CD) on independent timers,
// writes per-adapter JSON files to ~/.config/decknix/hub/.
// Emacs, CLI, and other consumers read those files (file-notify for live updates).

mod jira;
mod teamcity;

use chrono::{DateTime, Utc};
use clap::Parser;
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};
use tokio::process::Command;
use tokio::signal;

// ---------------------------------------------------------------------------
// PR-details cache TTL
// ---------------------------------------------------------------------------
//
// Both the WIP and Reviews caches key on (repo, number) and invalidate when
// GitHub's `updatedAt` changes.  That is sufficient for fields tied to the
// PR itself (CI, review decision, comments) but NOT for `mergeable` /
// `mergeStateStatus`, which flip to `CONFLICTING` / `DIRTY` when a *different*
// branch merges to main — an event that does NOT bump this PR's `updatedAt`.
// Without a TTL the sidebar can show a stale green ● indefinitely while the
// PR actually has a fresh merge conflict.
//
// We layer a TTL on top of the updatedAt key so quiet PRs still get refreshed
// periodically.  Five minutes balances API budget (5 polls of grace at the
// default 60s cadence) against worst-case staleness for conflict surfacing.
const PR_CACHE_TTL: Duration = Duration::from_secs(300);

/// Pure freshness check shared by the WIP and Reviews caches.  Returns true
/// when the caller can re-use the cached entry instead of refetching.
fn cache_entry_fresh(
    cached_updated_at: &str,
    current_updated_at: &str,
    inserted_at: Instant,
    now: Instant,
    ttl: Duration,
) -> bool {
    cached_updated_at == current_updated_at
        && now.saturating_duration_since(inserted_at) < ttl
}

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
    jira: jira::JiraConfig,
    teamcity: teamcity::TeamCityConfig,
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
            jira: jira::JiraConfig::default(),
            teamcity: teamcity::TeamCityConfig::default(),
        }
    }
}

impl Default for GitHubConfig {
    fn default() -> Self {
        Self {
            enabled: true,
            // With GraphQL batching, N uncached PRs cost ~1 call/repo rather
            // than N calls, so 60s is safe even with large review queues.
            reviews_interval_secs: 60,
            wip_interval_secs: 60,
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
    #[serde(skip_serializing_if = "Option::is_none")]
    mergeable: Option<String>, // "MERGEABLE", "CONFLICTING", "UNKNOWN"
    #[serde(skip_serializing_if = "Option::is_none")]
    my_review: Option<String>, // "APPROVED", "CHANGES_REQUESTED", "COMMENTED", "PENDING", "DISMISSED"
    #[serde(skip_serializing_if = "Option::is_none")]
    mentioned: Option<bool>, // true when user was directly requested as reviewer (not just via team)
    #[serde(skip_serializing_if = "Option::is_none")]
    team_requested: Option<bool>, // true when one of user's teams was requested as reviewer
    #[serde(skip_serializing_if = "Option::is_none")]
    others_requested: Option<bool>, // true when any User reviewer other than me is requested
    #[serde(skip_serializing_if = "Option::is_none")]
    needs_reply: Option<bool>, // true when latest comment/review is from someone else (bot or human)
    #[serde(skip_serializing_if = "Option::is_none")]
    bot_pending: Option<bool>, // true when the latest comment/review is from a bot
    #[serde(skip_serializing_if = "Option::is_none")]
    replies_to_me: Option<bool>, // true when a non-bot human posted after one of my comments/reviews
    #[serde(skip_serializing_if = "Option::is_none")]
    total_threads: Option<u32>, // total inline review threads on the PR
    #[serde(skip_serializing_if = "Option::is_none")]
    unresolved_threads: Option<u32>, // unresolved threads where last comment author != me
    #[serde(skip_serializing_if = "Option::is_none")]
    review_decision: Option<String>, // "APPROVED", "CHANGES_REQUESTED", "REVIEW_REQUIRED"
}

#[derive(Debug, Serialize, Deserialize, Clone)]
struct CheckDetail {
    name: String,
    conclusion: Option<String>, // "SUCCESS", "FAILURE", "ACTION_REQUIRED", etc.
    #[serde(skip_serializing_if = "Option::is_none")]
    url: Option<String>,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
struct CiStatus {
    status: String, // "pass", "fail", "running", "pending"
    #[serde(skip_serializing_if = "Option::is_none")]
    url: Option<String>,
    /// Individual check results for granular filtering on the consumer side.
    #[serde(skip_serializing_if = "Option::is_none")]
    checks: Option<Vec<CheckDetail>>,
}

#[derive(Debug, Serialize, Deserialize)]
struct ReviewsFile {
    updated: DateTime<Utc>,
    /// GitHub login of the viewer this file was generated for.  Lets the
    /// consumer (Emacs sidebar) cheaply exclude self-authored PRs when
    /// applying the @-mention / team filters.
    #[serde(skip_serializing_if = "Option::is_none")]
    viewer: Option<String>,
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
    mergeable: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    branch: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    updated: Option<DateTime<Utc>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    review_decision: Option<String>, // "APPROVED", "CHANGES_REQUESTED", "REVIEW_REQUIRED"
    #[serde(skip_serializing_if = "Option::is_none")]
    needs_reply: Option<bool>, // true when latest comment/review is from someone else (bot or human)
    #[serde(skip_serializing_if = "Option::is_none")]
    bot_pending: Option<bool>, // true when the latest comment/review is from a bot
    #[serde(skip_serializing_if = "Option::is_none")]
    replies_to_me: Option<bool>, // true when a non-bot human posted after one of my comments/reviews
    #[serde(skip_serializing_if = "Option::is_none")]
    total_threads: Option<u32>, // total inline review threads on the PR
    #[serde(skip_serializing_if = "Option::is_none")]
    unresolved_threads: Option<u32>, // unresolved threads where last comment author != me
    #[serde(skip_serializing_if = "Option::is_none")]
    merged_at: Option<DateTime<Utc>>, // when the PR was merged (None for open PRs)
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
pub struct AdapterStatus {
    pub name: String,
    pub last_poll: Option<DateTime<Utc>>,
    pub last_error: Option<String>,
    pub ok: bool,
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
pub async fn atomic_write_json<T: Serialize>(dir: &Path, filename: &str, data: &T) -> std::io::Result<()> {
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
        let stdout = String::from_utf8_lossy(&output.stdout);
        let combined = format!("{}{}", stderr, stdout);
        let error_msg = combined.trim();

        if error_msg.contains("RATE_LIMIT") || error_msg.contains("rate limit exceeded") {
            eprintln!("hub: GitHub rate limit hit, sleeping 60s before returning error...");
            tokio::time::sleep(Duration::from_secs(60)).await;
        }

        return Err(format!("gh error ({}): {}", output.status, error_msg));
    }
    Ok(String::from_utf8_lossy(&output.stdout).to_string())
}


// ---------------------------------------------------------------------------
// Archived repo cache
// ---------------------------------------------------------------------------

use std::collections::HashMap;
use std::sync::OnceLock;
use tokio::sync::RwLock;

/// Cache of repo name → archived status.  Populated lazily per poll cycle.
/// Archived status rarely changes, so we cache for the lifetime of the process
/// and only look up repos we haven't seen before.
static ARCHIVED_CACHE: OnceLock<RwLock<HashMap<String, bool>>> = OnceLock::new();

fn archived_cache() -> &'static RwLock<HashMap<String, bool>> {
    ARCHIVED_CACHE.get_or_init(|| RwLock::new(HashMap::new()))
}

/// Check if a repo is archived (cached).  Returns `true` for archived repos.
async fn is_repo_archived(repo: &str) -> bool {
    // Fast path: check cache
    {
        let cache = archived_cache().read().await;
        if let Some(&archived) = cache.get(repo) {
            return archived;
        }
    }
    // Slow path: query GitHub API
    let archived = match gh_json(&[
        "api", &format!("repos/{repo}"),
        "--jq", ".archived",
    ]).await {
        Ok(output) => output.trim() == "true",
        Err(e) => {
            eprintln!("hub: failed to check archived status for {repo}: {e}");
            false // assume not archived on error
        }
    };
    // Store in cache
    {
        let mut cache = archived_cache().write().await;
        cache.insert(repo.to_string(), archived);
    }
    archived
}

/// Filter a list of repo names, returning the set of archived ones.
async fn find_archived_repos(repos: &[String]) -> std::collections::HashSet<String> {
    let mut archived = std::collections::HashSet::new();
    for repo in repos {
        if is_repo_archived(repo).await {
            archived.insert(repo.clone());
        }
    }
    archived
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
    updated_at: Option<String>,
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
    /// GitHub marks App accounts with `is_bot: true` on `gh` output.
    /// Not always present, so we also fall back to the `[bot]` suffix
    /// convention used by all GitHub Apps.
    #[serde(default)]
    is_bot: Option<bool>,
}

/// Classification of a comment/review author relative to the current user.
#[derive(Debug, Copy, Clone, PartialEq, Eq)]
enum Actor {
    Me,
    Bot,
    Other,
}

fn classify_author(author: Option<&GhAuthor>, my_login: &str) -> Actor {
    match author {
        Some(a) if a.login.eq_ignore_ascii_case(my_login) => Actor::Me,
        Some(a) if a.is_bot.unwrap_or(false) || a.login.ends_with("[bot]") => Actor::Bot,
        _ => Actor::Other,
    }
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct GhRepo {
    name_with_owner: String,
}

#[derive(Debug, Deserialize)]
struct GhCheck {
    #[serde(default)]
    name: Option<String>,
    state: Option<String>,
    conclusion: Option<String>,
    #[serde(rename = "detailsUrl")]
    details_url: Option<String>,
}

/// Summarise CI checks into a single status with individual check details.
fn summarise_ci(checks: &Option<Vec<GhCheck>>) -> Option<CiStatus> {
    let checks = checks.as_ref()?;
    if checks.is_empty() {
        return None;
    }
    // If any failed → fail; if any pending/in_progress → running; else pass
    let mut has_fail = false;
    let mut has_pending = false;
    let mut url = None;
    let mut details: Vec<CheckDetail> = Vec::with_capacity(checks.len());
    for c in checks {
        let conc_str = c.conclusion.as_deref().or(c.state.as_deref());
        details.push(CheckDetail {
            name: c.name.clone().unwrap_or_else(|| "unknown".into()),
            conclusion: conc_str.map(|s| s.to_string()),
            url: c.details_url.clone(),
        });
        // Two GraphQL node shapes feed this list: `CheckRun` carries
        // `conclusion` once complete (and `status` while in progress), while
        // `StatusContext` only ever carries `state` (no `conclusion`) with
        // values like SUCCESS/FAILURE/ERROR/PENDING. Combine both so a
        // FAILURE/ERROR is treated as a fail regardless of source field.
        let combined = c.conclusion.as_deref().or(c.state.as_deref());
        match combined {
            Some("FAILURE") | Some("ERROR") | Some("TIMED_OUT")
            | Some("CANCELLED") | Some("ACTION_REQUIRED") => {
                has_fail = true;
                if url.is_none() {
                    url = c.details_url.clone();
                }
            }
            Some("SUCCESS") | Some("NEUTRAL") | Some("SKIPPED") => {}
            // Anything else (PENDING / IN_PROGRESS / QUEUED / EXPECTED / …)
            // is still in-flight.
            Some(_) | None => {
                if c.conclusion.is_none() {
                    has_pending = true;
                }
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
        checks: if details.is_empty() { None } else { Some(details) },
    })
}

/// Get the current GitHub user login.  Cached after first call.
async fn get_github_login() -> Option<String> {
    use std::sync::OnceLock;
    static LOGIN: OnceLock<Option<String>> = OnceLock::new();
    // OnceLock::get_or_init is sync — run the async fetch only on first access.
    if let Some(cached) = LOGIN.get() {
        return cached.clone();
    }
    let result = match gh_json(&["api", "user", "-q", ".login"]).await {
        Ok(s) => Some(s.trim().trim_matches('"').to_string()),
        Err(_) => None,
    };
    LOGIN.get_or_init(|| result.clone());
    result
}

#[derive(Debug, Deserialize)]
struct GhReview {
    author: Option<GhAuthor>,
    state: Option<String>,
}

/// Per-PR inline review thread stats used by the Tier 1 attention
/// heuristic.  GraphQL `reviewThreads` carries the `isResolved` flag
/// that `gh pr view --json` does not surface, so we run a small
/// dedicated query alongside the main fetch.  A thread is considered
/// "actionable to me" when it is unresolved AND the last commenter is
/// not me — if I posted last, the ball is in their court even though
/// the thread is open.
struct ReviewThreadStats {
    total: u32,
    unresolved_to_me: u32,
}

/// Parse a flat array of GraphQL review-thread nodes (as `serde_json::Value`)
/// into `ReviewThreadStats`.  Shared by both the batched and the single-PR paths.
fn parse_thread_nodes(nodes: &[serde_json::Value], my_login: Option<&str>) -> ReviewThreadStats {
    let total = nodes.len() as u32;
    let me = my_login.map(|s| s.to_ascii_lowercase());
    let unresolved_to_me = nodes.iter().filter(|t| {
        let unresolved = !t.get("isResolved")
            .and_then(|v| v.as_bool())
            .unwrap_or(false);
        if !unresolved { return false; }
        let last_login = t.get("comments")
            .and_then(|c| c.get("nodes"))
            .and_then(|ns| ns.as_array())
            .and_then(|arr| arr.last())
            .and_then(|n| n.get("author"))
            .and_then(|a| a.get("login"))
            .and_then(|l| l.as_str())
            .map(|s| s.to_ascii_lowercase());
        match (last_login, me.as_deref()) {
            (Some(ll), Some(m)) => ll != m,
            // Unknown author or unknown me-login — count as actionable
            // so we err on the side of surfacing it.
            _ => true,
        }
    }).count() as u32;
    ReviewThreadStats { total, unresolved_to_me }
}

/// Single-PR fallback: fetch review-thread stats for one PR via `gh api graphql`.
/// Returns `None` on any error so the caller falls back to the activity-based heuristic.
async fn fetch_review_threads_single(
    repo: &str,
    number: u64,
    my_login: Option<&str>,
) -> Option<ReviewThreadStats> {
    let (owner, name) = repo.split_once('/')?;
    let thread_fields =
        "reviewThreads(first: 100) { nodes { isResolved comments(last: 1) { nodes { author { login } } } } }";
    let query = format!(
        "{{ repository(owner: \"{owner}\", name: \"{name}\") {{ pullRequest(number: {number}) {{ {thread_fields} }} }} }}"
    );
    let query_arg = format!("query={query}");
    let output = gh_json(&["api", "graphql", "-f", &query_arg]).await.ok()?;
    let json: serde_json::Value = serde_json::from_str(&output).ok()?;
    let nodes = json.get("data")
        .and_then(|d| d.get("repository"))
        .and_then(|r| r.get("pullRequest"))
        .and_then(|pr| pr.get("reviewThreads"))
        .and_then(|rt| rt.get("nodes"))
        .and_then(|n| n.as_array())?;
    Some(parse_thread_nodes(nodes, my_login))
}

/// Batch-fetch review-thread stats for multiple PRs via a **single aliased
/// GraphQL call per repository**.  Instead of N round-trips (one per PR),
/// this issues one `gh api graphql` request per unique owner/repo, with each
/// PR aliased as `p{number}` inside the repository block.
///
/// Returns a map from `(repo, number)` → `ReviewThreadStats`.  PRs that fail
/// (repo parse error, individual alias missing from response, etc.) are simply
/// absent from the returned map; callers fall back gracefully.
async fn batch_fetch_review_threads(
    prs: &[(String, u64)],
    my_login: Option<&str>,
) -> HashMap<(String, u64), ReviewThreadStats> {
    // Group PR numbers by repo.
    let mut by_repo: HashMap<String, Vec<u64>> = HashMap::new();
    for (repo, number) in prs {
        by_repo.entry(repo.clone()).or_default().push(*number);
    }

    let thread_fields =
        "reviewThreads(first: 100) { nodes { isResolved comments(last: 1) { nodes { author { login } } } } }";

    // One future per repo — all repos are queried concurrently.
    let futs: Vec<_> = by_repo.iter().map(|(repo, numbers)| {
        let repo = repo.clone();
        let numbers = numbers.clone();
        let my_login = my_login.map(|s| s.to_string());
        async move {
            let Some((owner, name)) = repo.split_once('/') else {
                return (repo, HashMap::new());
            };
            // Build aliased query: p{n}: pullRequest(number: N) { ... }
            let pr_aliases: String = numbers.iter()
                .map(|n| format!("p{n}: pullRequest(number: {n}) {{ {thread_fields} }}"))
                .collect::<Vec<_>>()
                .join(" ");
            let query = format!(
                "{{ repository(owner: \"{owner}\", name: \"{name}\") {{ {pr_aliases} }} }}"
            );
            let query_arg = format!("query={query}");

            let Ok(output) = gh_json(&["api", "graphql", "-f", &query_arg]).await else {
                return (repo, HashMap::new());
            };
            let Ok(json): Result<serde_json::Value, _> = serde_json::from_str(&output) else {
                return (repo, HashMap::new());
            };
            let Some(repo_data) = json.get("data").and_then(|d| d.get("repository")) else {
                return (repo, HashMap::new());
            };

            let mut stats: HashMap<(String, u64), ReviewThreadStats> = HashMap::new();
            for number in &numbers {
                let alias = format!("p{number}");
                let Some(nodes) = repo_data.get(&alias)
                    .and_then(|pr| pr.get("reviewThreads"))
                    .and_then(|rt| rt.get("nodes"))
                    .and_then(|n| n.as_array())
                else { continue };
                stats.insert(
                    (repo.clone(), *number),
                    parse_thread_nodes(nodes, my_login.as_deref()),
                );
            }
            (repo, stats)
        }
    }).collect();

    // Collect all per-repo results into a single map.
    let mut results: HashMap<(String, u64), ReviewThreadStats> = HashMap::new();
    for fut in futs {
        let (_, repo_stats) = fut.await;
        results.extend(repo_stats);
    }
    results
}

/// Result of fetching review-request PR details.
#[derive(Clone)]
struct ReviewPrDetails {
    ci: Option<CiStatus>,
    mergeable: Option<String>,
    my_review: Option<String>,
    mentioned: Option<bool>,
    team_requested: Option<bool>,
    others_requested: Option<bool>,
    needs_reply: Option<bool>,
    bot_pending: Option<bool>,
    replies_to_me: Option<bool>,
    total_threads: Option<u32>,
    unresolved_threads: Option<u32>,
    review_decision: Option<String>,
}

impl Default for ReviewPrDetails {
    fn default() -> Self {
        Self {
            ci: None, mergeable: None, my_review: None, mentioned: None,
            team_requested: None, others_requested: None, needs_reply: None,
            bot_pending: None, replies_to_me: None, total_threads: None,
            unresolved_threads: None, review_decision: None,
        }
    }
}


static REVIEWS_CACHE: OnceLock<RwLock<HashMap<(String, u64), (String, Instant, ReviewPrDetails)>>> = OnceLock::new();
fn reviews_cache() -> &'static RwLock<HashMap<(String, u64), (String, Instant, ReviewPrDetails)>> {
    REVIEWS_CACHE.get_or_init(|| RwLock::new(HashMap::new()))
}

/// Fetch CI status, mergeable state, review state, mention, and reply status.
/// `prefetched_threads` may be `Some` when the caller has already obtained
/// thread stats via `batch_fetch_review_threads`; if `None` we fall back to
/// an individual `fetch_review_threads` call so the function remains usable
/// in isolation (e.g. tests or one-off invocations).
async fn fetch_pr_ci(
    repo: &str,
    number: u64,
    my_login: Option<&str>,
    prefetched_threads: Option<ReviewThreadStats>,
) -> ReviewPrDetails {
    // Run the `gh pr view` and (optional) review-thread GraphQL fetches in
    // parallel.  When threads were already batch-fetched by the caller we skip
    // the individual GraphQL round-trip entirely.
    let number_s = number.to_string();
    let args: [&str; 7] = [
        "pr", "view",
        &number_s,
        "--repo", repo,
        "--json", "statusCheckRollup,mergeable,mergeStateStatus,latestReviews,comments,reviews,reviewRequests,reviewDecision",
    ];
    let threads = match prefetched_threads {
        Some(t) => Some(t),
        None => fetch_review_threads_single(repo, number, my_login).await,
    };
    let output = match gh_json(&args).await {
        Ok(o) => o,
        Err(_) => return ReviewPrDetails {
            total_threads: threads.as_ref().map(|t| t.total),
            unresolved_threads: threads.as_ref().map(|t| t.unresolved_to_me),
            ..ReviewPrDetails::default()
        },
    };

    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct PrView {
        status_check_rollup: Option<Vec<GhCheck>>,
        mergeable: Option<String>,
        #[allow(dead_code)]
        merge_state_status: Option<String>,
        latest_reviews: Option<Vec<GhReview>>,
        comments: Option<Vec<GhComment>>,
        reviews: Option<Vec<GhReviewEntry>>,
        review_requests: Option<Vec<GhReviewRequestEntry>>,
        review_decision: Option<String>,
    }

    /// A review request entry — can be a User or Team.
    #[derive(Deserialize)]
    struct GhReviewRequestEntry {
        #[serde(rename = "__typename")]
        typename: Option<String>,
        login: Option<String>,  // present when typename == "User"
        #[allow(dead_code)]
        name: Option<String>,   // present when typename == "Team"
    }

    match serde_json::from_str::<PrView>(&output) {
        Ok(view) => {
            let ci = summarise_ci(&view.status_check_rollup);
            let mergeable = view.mergeable;
            // Find my latest review state
            let my_review = my_login.and_then(|login| {
                view.latest_reviews.as_ref()?.iter()
                    .find(|r| {
                        r.author.as_ref()
                            .map(|a| a.login.eq_ignore_ascii_case(login))
                            .unwrap_or(false)
                    })
                    .and_then(|r| r.state.clone())
            });
            // Check if user was directly requested as a reviewer (not just via team)
            let directly_requested = my_login.map(|login| {
                view.review_requests.as_ref()
                    .map(|rrs| rrs.iter().any(|rr| {
                        rr.typename.as_deref() == Some("User")
                            && rr.login.as_ref()
                                .map(|l| l.eq_ignore_ascii_case(login))
                                .unwrap_or(false)
                    }))
                    .unwrap_or(false)
            }).unwrap_or(false);
            // Check if any of the user's teams was requested as a reviewer.
            // We can't validate team membership cheaply here, but `gh search
            // prs --review-requested=@me` already constrains to PRs where the
            // user (or one of their teams) is requested, so any Team entry on
            // such a PR is implicitly one of the user's teams.
            let team_requested = view.review_requests.as_ref()
                .map(|rrs| rrs.iter().any(|rr| rr.typename.as_deref() == Some("Team")))
                .unwrap_or(false);
            // Check if any User reviewer *other than me* is requested.  Drives
            // the bot-filter's `mentioned' state: a team-requested PR with no
            // other individuals tagged is treated as "for me / my team to
            // handle", while one with Alice/Bob individually tagged is treated
            // as team-noise that someone else is already on.
            let others_requested = my_login.map(|login| {
                view.review_requests.as_ref()
                    .map(|rrs| rrs.iter().any(|rr| {
                        rr.typename.as_deref() == Some("User")
                            && rr.login.as_ref()
                                .map(|l| !l.eq_ignore_ascii_case(login))
                                .unwrap_or(false)
                    }))
                    .unwrap_or(false)
            }).unwrap_or_else(|| {
                // No my_login: any User entry counts as "others".
                view.review_requests.as_ref()
                    .map(|rrs| rrs.iter().any(|rr| rr.typename.as_deref() == Some("User")))
                    .unwrap_or(false)
            });
            // Check for @-mentions in comment/review bodies and classify the
            // trailing activity stream into needs_reply / bot_pending /
            // replies_to_me.  All four signals share the same pass.
            let (comment_mentioned, needs_reply, bot_pending, replies_to_me) =
                my_login.map(|login| {
                let mention_pattern = format!("@{}", login);
                let mention_pattern_lower = mention_pattern.to_lowercase();
                let mut found_mention = false;
                let mut activities: Vec<(&str, Actor)> = Vec::new();
                if let Some(ref comments) = view.comments {
                    for c in comments {
                        if let Some(ref body) = c.body {
                            if body.to_lowercase().contains(&mention_pattern_lower) {
                                found_mention = true;
                            }
                        }
                        if let Some(ref ts) = c.created_at {
                            activities.push((ts.as_str(),
                                             classify_author(c.author.as_ref(), login)));
                        }
                    }
                }
                if let Some(ref reviews) = view.reviews {
                    for r in reviews {
                        if let Some(ref body) = r.body {
                            if body.to_lowercase().contains(&mention_pattern_lower) {
                                found_mention = true;
                            }
                        }
                        if let Some(ref ts) = r.submitted_at {
                            activities.push((ts.as_str(),
                                             classify_author(r.author.as_ref(), login)));
                        }
                    }
                }
                activities.sort_by_key(|(ts, _)| *ts);
                // Latest non-self activity (bot or human) means a reply has
                // landed since my turn — matches the original semantics.
                let reply_needed = activities.last()
                    .map(|(_, a)| *a != Actor::Me)
                    .unwrap_or(false);
                // Bot activity at the head of the stream signals the author
                // likely needs to push a fix (Codacy/CI/etc.) before further
                // review makes sense.
                let bot_pending = activities.last()
                    .map(|(_, a)| *a == Actor::Bot)
                    .unwrap_or(false);
                // A human replied *after* one of my comments — worth a look
                // because they engaged with something I said specifically.
                let replies_to_me = activities.iter()
                    .rposition(|(_, a)| *a == Actor::Me)
                    .map(|i| activities.iter().skip(i + 1)
                         .any(|(_, a)| *a == Actor::Other))
                    .unwrap_or(false);
                (found_mention, reply_needed, bot_pending, replies_to_me)
            }).unwrap_or((false, false, false, false));
            // mentioned = directly requested OR @-mentioned in a comment
            let mentioned = directly_requested || comment_mentioned;
            ReviewPrDetails {
                ci,
                mergeable,
                my_review,
                mentioned: Some(mentioned),
                team_requested: Some(team_requested),
                others_requested: Some(others_requested),
                needs_reply: Some(needs_reply),
                bot_pending: Some(bot_pending),
                replies_to_me: Some(replies_to_me),
                total_threads: threads.as_ref().map(|t| t.total),
                unresolved_threads: threads.as_ref().map(|t| t.unresolved_to_me),
                review_decision: view.review_decision,
            }
        }
        Err(_) => ReviewPrDetails {
            total_threads: threads.as_ref().map(|t| t.total),
            unresolved_threads: threads.as_ref().map(|t| t.unresolved_to_me),
            ..ReviewPrDetails::default()
        },
    }
}

/// Fetch PR reviews assigned to the current user.
async fn poll_github_reviews(_config: &GitHubConfig) -> Result<ReviewsFile, String> {
    // Limit 200 — `gh search prs` defaults to recency-sorted, so 50
    // was capping older requests in heavy-review weeks (the sidebar
    // `F all' preset had nothing >13d to show against the user's
    // actual queue).  200 stays well under GitHub's per-page max
    // and the per-PR enrichment cost is bearable at the default
    // 60s poll cadence.
    let output = gh_json(&[
        "search", "prs",
        "--review-requested=@me",
        "--state=open",
        "--json", "number,title,url,createdAt,updatedAt,isDraft,labels,author,repository",
        "--limit", "200",
    ]).await?;

    let prs: Vec<GhSearchPr> = serde_json::from_str(&output)
        .map_err(|e| format!("parse error: {e}"))?;

    // Collect unique repo names and filter out archived repositories
    let repo_names: Vec<String> = prs.iter()
        .filter_map(|pr| pr.repository.as_ref().map(|r| r.name_with_owner.clone()))
        .collect::<std::collections::HashSet<_>>()
        .into_iter()
        .collect();
    let archived = find_archived_repos(&repo_names).await;

    // Get current user's login for review state lookup
    let my_login = get_github_login().await;

    // Identify which PRs are not in cache (need fresh detail + thread fetches).
    // Cache hit requires updatedAt match AND insertion within `PR_CACHE_TTL` —
    // see the TTL rationale at the top of this file.
    let now = Instant::now();
    let uncached_pairs: Vec<(String, u64)> = {
        let cache = reviews_cache().read().await;
        prs.iter()
            .filter_map(|pr| {
                let repo = pr.repository.as_ref()?.name_with_owner.clone();
                if archived.contains(&repo) { return None; }
                let updated_at = pr.updated_at.clone().unwrap_or_default();
                let hit = cache.get(&(repo.clone(), pr.number))
                    .map(|(ts, inserted, _)| {
                        cache_entry_fresh(ts, &updated_at, *inserted, now, PR_CACHE_TTL)
                    })
                    .unwrap_or(false);
                if hit { None } else { Some((repo, pr.number)) }
            })
            .collect()
    };

    // Batch-fetch review threads for all uncached PRs — one GraphQL call per repo.
    let batched_threads = batch_fetch_review_threads(&uncached_pairs, my_login.as_deref()).await;

    let mut items: Vec<ReviewRequest> = Vec::with_capacity(prs.len());
    for pr in &prs {
        let repo = pr.repository.as_ref()
            .map(|r| r.name_with_owner.clone())
            .unwrap_or_default();
        // Skip PRs from archived repositories
        if archived.contains(&repo) {
            continue;
        }
        // Use cache when updatedAt unchanged AND within TTL; otherwise refetch.
        let updated_at = pr.updated_at.clone().unwrap_or_default();
        let cache_key = (repo.clone(), pr.number);

        let cached_details = {
            let cache = reviews_cache().read().await;
            cache.get(&cache_key).and_then(|(ts, inserted, details)| {
                if cache_entry_fresh(ts, &updated_at, *inserted, now, PR_CACHE_TTL) {
                    Some(details.clone())
                } else {
                    None
                }
            })
        };

        let details = if let Some(d) = cached_details {
            d
        } else {
            let prefetched = batched_threads.get(&(repo.clone(), pr.number))
                .map(|s| ReviewThreadStats { total: s.total, unresolved_to_me: s.unresolved_to_me });
            let d = fetch_pr_ci(&repo, pr.number, my_login.as_deref(), prefetched).await;
            let mut cache = reviews_cache().write().await;
            cache.insert(cache_key, (updated_at, Instant::now(), d.clone()));
            d
        };

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
            ci: details.ci,
            mergeable: details.mergeable,
            my_review: details.my_review,
            mentioned: details.mentioned,
            team_requested: details.team_requested,
            others_requested: details.others_requested,
            needs_reply: details.needs_reply,
            bot_pending: details.bot_pending,
            replies_to_me: details.replies_to_me,
            total_threads: details.total_threads,
            unresolved_threads: details.unresolved_threads,
            review_decision: details.review_decision,
        });
    }

    // Sort oldest first (most urgent at top)
    items.sort_by_key(|r| r.created);

    Ok(ReviewsFile {
        updated: Utc::now(),
        viewer: my_login,
        items,
    })
}

// ---------------------------------------------------------------------------
// GitHub WIP Adapter
// ---------------------------------------------------------------------------

/// Result of fetching detailed PR information.
#[derive(Clone)]
struct PrDetails {
    branch: Option<String>,
    ci: Option<CiStatus>,
    mergeable: Option<String>,
    review_decision: Option<String>,
    needs_reply: Option<bool>,
    bot_pending: Option<bool>,
    replies_to_me: Option<bool>,
    total_threads: Option<u32>,
    unresolved_threads: Option<u32>,
    merged_at: Option<String>,
}

impl Default for PrDetails {
    fn default() -> Self {
        Self {
            branch: None, ci: None, mergeable: None, review_decision: None,
            needs_reply: None, bot_pending: None, replies_to_me: None,
            total_threads: None, unresolved_threads: None,
            merged_at: None,
        }
    }
}

static WIP_CACHE: OnceLock<RwLock<HashMap<(String, u64), (String, Instant, PrDetails)>>> = OnceLock::new();
fn wip_cache() -> &'static RwLock<HashMap<(String, u64), (String, Instant, PrDetails)>> {
    WIP_CACHE.get_or_init(|| RwLock::new(HashMap::new()))
}

/// Comment/review with author and timestamp for determining reply status.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct GhComment {
    author: Option<GhAuthor>,
    created_at: Option<String>,
    body: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct GhReviewEntry {
    author: Option<GhAuthor>,
    submitted_at: Option<String>,
    body: Option<String>,
}

/// Fetch branch, CI, mergeable, review decision, and reply status for a PR.
/// `prefetched_threads` may be `Some` when the caller has already obtained
/// thread stats via `batch_fetch_review_threads`; if `None` we fall back to
/// an individual GraphQL call.
async fn fetch_pr_details(
    repo: &str,
    number: u64,
    my_login: Option<&str>,
    prefetched_threads: Option<ReviewThreadStats>,
) -> PrDetails {
    let number_s = number.to_string();
    let args: [&str; 7] = [
        "pr", "view",
        &number_s,
        "--repo", repo,
        "--json", "headRefName,statusCheckRollup,mergeable,mergeStateStatus,reviewDecision,comments,reviews,mergedAt",
    ];
    let threads = match prefetched_threads {
        Some(t) => Some(t),
        None => fetch_review_threads_single(repo, number, my_login).await,
    };
    let output = match gh_json(&args).await {
        Ok(o) => o,
        Err(_) => return PrDetails {
            total_threads: threads.as_ref().map(|t| t.total),
            unresolved_threads: threads.as_ref().map(|t| t.unresolved_to_me),
            ..PrDetails::default()
        },
    };

    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct PrDetail {
        head_ref_name: Option<String>,
        status_check_rollup: Option<Vec<GhCheck>>,
        mergeable: Option<String>,
        #[allow(dead_code)]
        merge_state_status: Option<String>,
        review_decision: Option<String>,
        comments: Option<Vec<GhComment>>,
        reviews: Option<Vec<GhReviewEntry>>,
        merged_at: Option<String>,
    }

    match serde_json::from_str::<PrDetail>(&output) {
        Ok(d) => {
            // Classify the trailing activity stream into needs_reply /
            // bot_pending / replies_to_me.  Same logic as fetch_pr_ci so
            // that WIP and Requests share a consistent reading of the PR.
            let (needs_reply, bot_pending, replies_to_me) =
                my_login.map(|login| {
                let mut activities: Vec<(&str, Actor)> = Vec::new();
                if let Some(ref comments) = d.comments {
                    for c in comments {
                        if let Some(ref ts) = c.created_at {
                            activities.push((ts.as_str(),
                                             classify_author(c.author.as_ref(), login)));
                        }
                    }
                }
                if let Some(ref reviews) = d.reviews {
                    for r in reviews {
                        if let Some(ref ts) = r.submitted_at {
                            activities.push((ts.as_str(),
                                             classify_author(r.author.as_ref(), login)));
                        }
                    }
                }
                // ISO-8601 strings sort lexicographically — same order as chrono.
                activities.sort_by_key(|(ts, _)| *ts);
                let needs_reply = activities.last()
                    .map(|(_, a)| *a != Actor::Me)
                    .unwrap_or(false);
                let bot_pending = activities.last()
                    .map(|(_, a)| *a == Actor::Bot)
                    .unwrap_or(false);
                let replies_to_me = activities.iter()
                    .rposition(|(_, a)| *a == Actor::Me)
                    .map(|i| activities.iter().skip(i + 1)
                         .any(|(_, a)| *a == Actor::Other))
                    .unwrap_or(false);
                (Some(needs_reply), Some(bot_pending), Some(replies_to_me))
            }).unwrap_or((None, None, None));
            PrDetails {
                branch: d.head_ref_name,
                ci: summarise_ci(&d.status_check_rollup),
                mergeable: d.mergeable,
                review_decision: d.review_decision,
                needs_reply,
                bot_pending,
                replies_to_me,
                total_threads: threads.as_ref().map(|t| t.total),
                unresolved_threads: threads.as_ref().map(|t| t.unresolved_to_me),
                merged_at: d.merged_at,
            }
        }
        Err(_) => PrDetails {
            total_threads: threads.as_ref().map(|t| t.total),
            unresolved_threads: threads.as_ref().map(|t| t.unresolved_to_me),
            ..PrDetails::default()
        },
    }
}

/// Intermediate struct for gh search output (WIP PRs).
/// Note: `mergedAt` is NOT available in `gh search prs` — only in `gh pr view`.
/// We fetch it from `fetch_pr_details` instead.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct GhMyPr {
    number: u64,
    title: String,
    url: String,
    state: String,
    is_draft: Option<bool>,
    updated_at: Option<String>,
    repository: Option<GhRepo>,
}

/// Fetch the current user's open + recently merged PRs across all repos.
/// Merged PRs are included for up to 7 days after merge, allowing the
/// sidebar to track them until they are deployed.
async fn poll_github_wip(_config: &GitHubConfig) -> Result<WipFile, String> {
    let json_fields = "number,title,url,state,isDraft,updatedAt,repository";

    // 1. Open PRs
    let open_output = gh_json(&[
        "search", "prs",
        "--author=@me",
        "--state=open",
        "--json", json_fields,
        "--limit", "50",
    ]).await?;

    let open_prs: Vec<GhMyPr> = serde_json::from_str(&open_output)
        .map_err(|e| format!("parse open: {e}"))?;

    // 2. Recently merged PRs (last 7 days)
    let cutoff = (Utc::now() - chrono::Duration::days(7))
        .format("%Y-%m-%d")
        .to_string();
    let merged_output = gh_json(&[
        "search", "prs",
        "--author=@me",
        "--state=merged",
        &format!("--merged=>{cutoff}"),
        "--json", json_fields,
        "--limit", "30",
    ]).await.unwrap_or_else(|_| "[]".to_string());

    let merged_prs: Vec<GhMyPr> = serde_json::from_str(&merged_output)
        .unwrap_or_default();

    // Combine, deduplicating by (repo, number)
    let mut seen = std::collections::HashSet::new();
    let mut all_prs: Vec<GhMyPr> = Vec::new();
    for pr in open_prs.into_iter().chain(merged_prs.into_iter()) {
        let key = (
            pr.repository.as_ref().map(|r| r.name_with_owner.clone()).unwrap_or_default(),
            pr.number,
        );
        if seen.insert(key) {
            all_prs.push(pr);
        }
    }

    // Collect unique repo names and filter out archived repositories
    let repo_names: Vec<String> = all_prs.iter()
        .filter_map(|pr| pr.repository.as_ref().map(|r| r.name_with_owner.clone()))
        .collect::<std::collections::HashSet<_>>()
        .into_iter()
        .collect();
    let archived = find_archived_repos(&repo_names).await;

    // Get current user's login for reply detection
    let my_login = get_github_login().await;

    // Identify which PRs are not in cache (need fresh detail + thread fetches).
    // Cache hit requires updatedAt match AND insertion within `PR_CACHE_TTL` —
    // `mergeable` can flip to CONFLICTING when a sibling branch merges to main
    // without bumping this PR's updatedAt, so we must re-fetch periodically
    // even for quiet PRs.
    let now = Instant::now();
    let uncached_pairs: Vec<(String, u64)> = {
        let cache = wip_cache().read().await;
        all_prs.iter()
            .filter_map(|pr| {
                let repo = pr.repository.as_ref()?.name_with_owner.clone();
                if archived.contains(&repo) { return None; }
                let updated_at = pr.updated_at.clone().unwrap_or_default();
                let hit = cache.get(&(repo.clone(), pr.number))
                    .map(|(ts, inserted, _)| {
                        cache_entry_fresh(ts, &updated_at, *inserted, now, PR_CACHE_TTL)
                    })
                    .unwrap_or(false);
                if hit { None } else { Some((repo, pr.number)) }
            })
            .collect()
    };

    // Batch-fetch review threads for all uncached PRs — one GraphQL call per repo.
    let batched_threads = batch_fetch_review_threads(&uncached_pairs, my_login.as_deref()).await;

    // Group by repository
    let mut repo_map: std::collections::BTreeMap<String, Vec<WipPr>> =
        std::collections::BTreeMap::new();

    for pr in &all_prs {
        let repo = pr.repository.as_ref()
            .map(|r| r.name_with_owner.clone())
            .unwrap_or_else(|| "unknown".to_string());
        // Skip PRs from archived repositories
        if archived.contains(&repo) {
            continue;
        }
        // Use cache when updatedAt unchanged AND within TTL; otherwise refetch.
        let updated_at = pr.updated_at.clone().unwrap_or_default();
        let cache_key = (repo.clone(), pr.number);

        let cached_details = {
            let cache = wip_cache().read().await;
            cache.get(&cache_key).and_then(|(ts, inserted, details)| {
                if cache_entry_fresh(ts, &updated_at, *inserted, now, PR_CACHE_TTL) {
                    Some(details.clone())
                } else {
                    None
                }
            })
        };

        let details = if let Some(d) = cached_details {
            d
        } else {
            let prefetched = batched_threads.get(&(repo.clone(), pr.number))
                .map(|s| ReviewThreadStats { total: s.total, unresolved_to_me: s.unresolved_to_me });
            let d = fetch_pr_details(&repo, pr.number, my_login.as_deref(), prefetched).await;
            let mut cache = wip_cache().write().await;
            cache.insert(cache_key, (updated_at, Instant::now(), d.clone()));
            d
        };
        let entry = repo_map.entry(repo).or_default();
        let updated_ts = pr.updated_at.as_deref()
            .and_then(|s| s.parse::<DateTime<Utc>>().ok());
        let merged_ts = details.merged_at.as_deref()
            .and_then(|s| s.parse::<DateTime<Utc>>().ok());
        entry.push(WipPr {
            number: pr.number,
            title: pr.title.clone(),
            state: pr.state.clone(),
            url: pr.url.clone(),
            draft: pr.is_draft,
            ci: details.ci,
            mergeable: details.mergeable,
            branch: details.branch,
            updated: updated_ts,
            review_decision: details.review_decision,
            needs_reply: details.needs_reply,
            bot_pending: details.bot_pending,
            replies_to_me: details.replies_to_me,
            total_threads: details.total_threads,
            unresolved_threads: details.unresolved_threads,
            merged_at: merged_ts,
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
pub type SharedMeta = Arc<Mutex<Vec<AdapterStatus>>>;

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
pub async fn update_meta(meta: &SharedMeta, status: AdapterStatus, dir: &Path) {
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

    // Spawn Jira adapter
    if config.jira.enabled {
        eprintln!("hub: jira-tasks adapter: every {}s", config.jira.interval_secs);
        eprintln!("hub: jira project: {}", config.jira.project);
        handles.push(tokio::spawn(jira::run_jira_adapter(
            config.jira,
            dir.clone(),
            meta.clone(),
            cli.once,
        )));
    }

    // Spawn TeamCity adapter
    if config.teamcity.enabled {
        eprintln!("hub: teamcity adapter: every {}s", config.teamcity.interval_secs);
        eprintln!("hub: teamcity proxy: {}", config.teamcity.proxy_url);
        handles.push(tokio::spawn(teamcity::run_teamcity_adapter(
            config.teamcity,
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cache_entry_fresh_same_ts_within_ttl_is_hit() {
        let now = Instant::now();
        let inserted = now;
        assert!(cache_entry_fresh("t1", "t1", inserted, now, Duration::from_secs(300)));
    }

    #[test]
    fn cache_entry_fresh_different_ts_is_miss() {
        let now = Instant::now();
        let inserted = now;
        assert!(!cache_entry_fresh("t1", "t2", inserted, now, Duration::from_secs(300)));
    }

    #[test]
    fn cache_entry_fresh_expired_ttl_is_miss_even_with_same_ts() {
        // This is the scenario that motivated the TTL: a quiet PR whose
        // `updatedAt' hasn't changed, but whose `mergeable' flipped because
        // a sibling branch merged to main.  Without the TTL the cache would
        // hold the stale `MERGEABLE' value indefinitely.
        let now = Instant::now();
        let inserted = now.checked_sub(Duration::from_secs(600)).unwrap();
        assert!(!cache_entry_fresh("t1", "t1", inserted, now, Duration::from_secs(300)));
    }

    #[test]
    fn cache_entry_fresh_exact_ttl_boundary_is_miss() {
        // `<` not `<=' — at exactly TTL we refetch.
        let now = Instant::now();
        let inserted = now.checked_sub(Duration::from_secs(300)).unwrap();
        assert!(!cache_entry_fresh("t1", "t1", inserted, now, Duration::from_secs(300)));
    }
}