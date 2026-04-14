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
    #[serde(skip_serializing_if = "Option::is_none")]
    mergeable: Option<String>, // "MERGEABLE", "CONFLICTING", "UNKNOWN"
    #[serde(skip_serializing_if = "Option::is_none")]
    my_review: Option<String>, // "APPROVED", "CHANGES_REQUESTED", "COMMENTED", "PENDING", "DISMISSED"
    #[serde(skip_serializing_if = "Option::is_none")]
    mentioned: Option<bool>, // true when @login appears in a comment body
    #[serde(skip_serializing_if = "Option::is_none")]
    needs_reply: Option<bool>, // true when latest comment/review is from someone else
}

#[derive(Debug, Serialize, Deserialize)]
struct CheckDetail {
    name: String,
    conclusion: Option<String>, // "SUCCESS", "FAILURE", "ACTION_REQUIRED", etc.
    #[serde(skip_serializing_if = "Option::is_none")]
    url: Option<String>,
}

#[derive(Debug, Serialize, Deserialize)]
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
    needs_reply: Option<bool>, // true when latest comment/review is from someone else
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
        return Err(format!("gh error ({}): {}", output.status, stderr.trim()));
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

/// Result of fetching review-request PR details.
struct ReviewPrDetails {
    ci: Option<CiStatus>,
    mergeable: Option<String>,
    my_review: Option<String>,
    mentioned: Option<bool>,
    needs_reply: Option<bool>,
}

impl Default for ReviewPrDetails {
    fn default() -> Self {
        Self { ci: None, mergeable: None, my_review: None, mentioned: None, needs_reply: None }
    }
}

/// Fetch CI status, mergeable state, review state, mention, and reply status.
async fn fetch_pr_ci(
    repo: &str,
    number: u64,
    my_login: Option<&str>,
) -> ReviewPrDetails {
    let output = match gh_json(&[
        "pr", "view",
        &number.to_string(),
        "--repo", repo,
        "--json", "statusCheckRollup,mergeable,mergeStateStatus,latestReviews,comments,reviews",
    ]).await {
        Ok(o) => o,
        Err(_) => return ReviewPrDetails::default(),
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
            // Check for @-mentions and needs_reply
            let (mentioned, needs_reply) = my_login.map(|login| {
                let mention_pattern = format!("@{}", login);
                let mention_pattern_lower = mention_pattern.to_lowercase();
                // Scan comment and review bodies for @login
                let mut found_mention = false;
                let mut activities: Vec<(&str, bool)> = Vec::new();
                if let Some(ref comments) = view.comments {
                    for c in comments {
                        if let Some(ref body) = c.body {
                            if body.to_lowercase().contains(&mention_pattern_lower) {
                                found_mention = true;
                            }
                        }
                        if let Some(ref ts) = c.created_at {
                            let is_me = c.author.as_ref()
                                .map(|a| a.login.eq_ignore_ascii_case(login))
                                .unwrap_or(false);
                            activities.push((ts.as_str(), is_me));
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
                            let is_me = r.author.as_ref()
                                .map(|a| a.login.eq_ignore_ascii_case(login))
                                .unwrap_or(false);
                            activities.push((ts.as_str(), is_me));
                        }
                    }
                }
                activities.sort_by_key(|(ts, _)| *ts);
                let reply_needed = activities.last()
                    .map(|(_, is_me)| !is_me)
                    .unwrap_or(false);
                (found_mention, reply_needed)
            }).unwrap_or((false, false));
            ReviewPrDetails {
                ci,
                mergeable,
                my_review,
                mentioned: Some(mentioned),
                needs_reply: Some(needs_reply),
            }
        }
        Err(_) => ReviewPrDetails::default(),
    }
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

    // Collect unique repo names and filter out archived repositories
    let repo_names: Vec<String> = prs.iter()
        .filter_map(|pr| pr.repository.as_ref().map(|r| r.name_with_owner.clone()))
        .collect::<std::collections::HashSet<_>>()
        .into_iter()
        .collect();
    let archived = find_archived_repos(&repo_names).await;

    // Get current user's login for review state lookup
    let my_login = get_github_login().await;

    let mut items: Vec<ReviewRequest> = Vec::with_capacity(prs.len());
    for pr in &prs {
        let repo = pr.repository.as_ref()
            .map(|r| r.name_with_owner.clone())
            .unwrap_or_default();
        // Skip PRs from archived repositories
        if archived.contains(&repo) {
            continue;
        }
        // Fetch CI + mergeable + review state + mention + reply status per PR
        let details = fetch_pr_ci(
            &repo,
            pr.number,
            my_login.as_deref(),
        ).await;
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
            needs_reply: details.needs_reply,
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

/// Result of fetching detailed PR information.
struct PrDetails {
    branch: Option<String>,
    ci: Option<CiStatus>,
    mergeable: Option<String>,
    review_decision: Option<String>,
    needs_reply: Option<bool>,
    merged_at: Option<String>,
}

impl Default for PrDetails {
    fn default() -> Self {
        Self { branch: None, ci: None, mergeable: None, review_decision: None, needs_reply: None, merged_at: None }
    }
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
async fn fetch_pr_details(repo: &str, number: u64, my_login: Option<&str>) -> PrDetails {
    let output = match gh_json(&[
        "pr", "view",
        &number.to_string(),
        "--repo", repo,
        "--json", "headRefName,statusCheckRollup,mergeable,mergeStateStatus,reviewDecision,comments,reviews,mergedAt",
    ]).await {
        Ok(o) => o,
        Err(_) => return PrDetails::default(),
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
            let needs_reply = my_login.map(|login| {
                // Collect all activity with (timestamp_str, is_me) tuples
                let mut activities: Vec<(&str, bool)> = Vec::new();
                if let Some(ref comments) = d.comments {
                    for c in comments {
                        if let Some(ref ts) = c.created_at {
                            let is_me = c.author.as_ref()
                                .map(|a| a.login.eq_ignore_ascii_case(login))
                                .unwrap_or(false);
                            activities.push((ts.as_str(), is_me));
                        }
                    }
                }
                if let Some(ref reviews) = d.reviews {
                    for r in reviews {
                        if let Some(ref ts) = r.submitted_at {
                            let is_me = r.author.as_ref()
                                .map(|a| a.login.eq_ignore_ascii_case(login))
                                .unwrap_or(false);
                            activities.push((ts.as_str(), is_me));
                        }
                    }
                }
                // Sort by timestamp (ISO 8601 strings sort lexicographically)
                activities.sort_by_key(|(ts, _)| *ts);
                // Check if the latest activity is NOT from me
                activities.last().map(|(_, is_me)| !is_me).unwrap_or(false)
            });
            PrDetails {
                branch: d.head_ref_name,
                ci: summarise_ci(&d.status_check_rollup),
                mergeable: d.mergeable,
                review_decision: d.review_decision,
                needs_reply,
                merged_at: d.merged_at,
            }
        }
        Err(_) => PrDetails::default(),
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
        // Fetch branch + CI + mergeable + review decision + reply status per PR
        let details = fetch_pr_details(&repo, pr.number, my_login.as_deref()).await;
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