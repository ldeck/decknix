// TeamCity adapter — polls builds via IAP proxy
//
// Auth: IAP proxy handles Google IAP authentication transparently.
// The daemon just hits localhost:{port} which proxies to TeamCity.
// Writes teamcity-builds.json and teamcity-deploys.json to hub data directory.

use chrono::{DateTime, Utc};
use reqwest::Client;
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use std::time::Duration;

use crate::{atomic_write_json, update_meta, AdapterStatus, SharedMeta};

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(default)]
pub struct TeamCityConfig {
    pub enabled: bool,
    pub interval_secs: u64,
    /// IAP proxy URL (e.g. "http://localhost:8080")
    pub proxy_url: String,
    /// Only include builds for these repos (owner/repo format).
    /// Empty = include all. Used to cross-link with WIP PR branches.
    pub repos: Vec<String>,
    /// How many recent finished builds to include per branch (default: 1)
    pub recent_finished_count: u32,
}

impl Default for TeamCityConfig {
    fn default() -> Self {
        Self {
            enabled: false,
            interval_secs: 60,
            proxy_url: "http://localhost:8080".into(),
            repos: vec![],
            recent_finished_count: 1,
        }
    }
}

// ---------------------------------------------------------------------------
// Data models — written to teamcity-builds.json
// ---------------------------------------------------------------------------

#[derive(Debug, Serialize, Deserialize)]
pub struct TeamCityBuild {
    pub id: u64,
    pub build_type_id: String,
    pub build_type_name: String,
    pub number: Option<String>,
    pub status: String,       // "SUCCESS", "FAILURE", "ERROR", "UNKNOWN"
    pub state: String,        // "running", "finished", "queued"
    pub branch: Option<String>,
    pub branch_is_default: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub progress_pct: Option<u32>,
    pub url: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub started: Option<DateTime<Utc>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub finished: Option<DateTime<Utc>>,
    /// WIP PR number this build is associated with (cross-linked by branch)
    #[serde(skip_serializing_if = "Option::is_none")]
    pub wip_pr_number: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub wip_repo: Option<String>,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct TeamCityBuildsFile {
    pub updated: DateTime<Utc>,
    pub builds: Vec<TeamCityBuild>,
}

// ---------------------------------------------------------------------------
// Data models — written to teamcity-deploys.json
// ---------------------------------------------------------------------------

/// Deployment status for a single environment
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EnvDeployStatus {
    pub env: String, // "development", "testing", "stable", "production", "uk_production"
    pub status: String, // "SUCCESS", "FAILURE", "ERROR", "UNKNOWN"
    pub state: String,  // "running", "queued", "finished"
    pub build_id: u64,
    pub url: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub finished: Option<DateTime<Utc>>,
    /// The build type that determined this status (e.g. "AppDeploy" or "TerraformApply")
    pub deploy_type: String,
}

/// Deployment status for a single branch within a repo
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BranchDeployStatus {
    pub branch: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pr_number: Option<u64>,
    pub environments: Vec<EnvDeployStatus>,
}

/// Deployment status for a repo
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RepoDeployStatus {
    pub repo: String,
    pub tc_project: String,
    pub branches: Vec<BranchDeployStatus>,
    /// The branches are the last good poll's: this one could not read them.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub stale: bool,
    /// When the branches were read.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub as_of: Option<DateTime<Utc>>,
}

/// Top-level deploys file
#[derive(Debug, Serialize, Deserialize)]
pub struct TeamCityDeploysFile {
    pub updated: DateTime<Utc>,
    pub repos: Vec<RepoDeployStatus>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub errors: Vec<String>,
    /// Repos whose deploys this poll could not read.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub stale: Vec<crate::kargo::KargoStale>,
}

/// A TeamCity error that means "no such build configuration", which most
/// projects legitimately lack for some environments, as opposed to the
/// proxy or the server failing.
pub fn missing_config_error(e: &str) -> bool {
    e.contains("404")
}

/// FRESH with every repo in FAILED (repo -> error) replaced by its PREVIOUS
/// entry marked stale (or kept, marked stale, when there is none), and the
/// stale list recorded.  The same rule as kargo-stages.json: a poll that
/// cannot read a repo never writes its deploys as absent.
pub fn settle_deploys(mut fresh: TeamCityDeploysFile, failed: &HashMap<String, String>,
                      previous: Option<&TeamCityDeploysFile>) -> TeamCityDeploysFile {
    let now = fresh.updated;
    for r in fresh.repos.iter_mut() {
        if !failed.contains_key(&r.repo) {
            r.stale = false;
            r.as_of = Some(now);
        }
    }
    for (repo, error) in failed {
        let prior = previous.and_then(|p| p.repos.iter().find(|r| r.repo.eq_ignore_ascii_case(repo)));
        fresh.repos.retain(|r| !r.repo.eq_ignore_ascii_case(repo) || prior.is_none());
        match (prior, fresh.repos.iter_mut().find(|r| r.repo.eq_ignore_ascii_case(repo))) {
            (Some(p), _) => fresh.repos.push(RepoDeployStatus { stale: true, ..p.clone() }),
            (None, Some(r)) => { r.stale = true; r.as_of = None; }
            (None, None) => {}
        }
        let before = previous.and_then(|p| p.stale.iter().find(|s| s.repo.eq_ignore_ascii_case(repo)));
        fresh.stale.push(crate::kargo::KargoStale {
            repo: repo.clone(),
            error: error.clone(),
            since: before.map(|s| s.since).unwrap_or(now),
            last_ok: prior.and_then(|p| p.as_of).or_else(|| before.and_then(|s| s.last_ok)),
        });
        fresh.errors.push(format!("{repo}: {error}"));
    }
    fresh.stale.sort_by(|a, b| a.repo.cmp(&b.repo));
    fresh
}

pub fn read_previous_deploys(dir: &Path) -> Option<TeamCityDeploysFile> {
    serde_json::from_str(&std::fs::read_to_string(dir.join("teamcity-deploys.json")).ok()?).ok()
}

// ---------------------------------------------------------------------------
// Environment detection from build_type_id
// ---------------------------------------------------------------------------

/// Known deployment environments and their patterns in build_type_id
const ENV_PATTERNS: &[(&str, &str)] = &[
    ("development", "Development"),
    ("testing", "Testing"),
    ("stable", "Stable"),
    ("production", "Production"),
    ("uk_production", "UkProduction"),
];

/// Deploy step suffixes we track (most specific → least specific)
const DEPLOY_STEPS: &[&str] = &["AppDeploy", "TerraformApply"];

/// Extract environment from a build_type_id like "Monolith_DevelopmentAppDeploy"
fn extract_env_from_bt_id(bt_id: &str, tc_project: &str) -> Option<(&'static str, &'static str)> {
    // Strip project prefix: "Monolith_DevelopmentAppDeploy" → "DevelopmentAppDeploy"
    let suffix = bt_id.strip_prefix(tc_project)
        .and_then(|s| s.strip_prefix('_'))?;
    for &(env_key, env_pattern) in ENV_PATTERNS {
        if suffix.starts_with(env_pattern) {
            let step_part = &suffix[env_pattern.len()..];
            for &step in DEPLOY_STEPS {
                if step_part == step {
                    return Some((env_key, step));
                }
            }
        }
    }
    None
}

// ---------------------------------------------------------------------------
// TeamCity REST API response structs
// ---------------------------------------------------------------------------

#[derive(Debug, Deserialize)]
struct TcBuildsResponse {
    build: Option<Vec<TcBuild>>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct TcBuild {
    id: u64,
    build_type_id: Option<String>,
    number: Option<String>,
    status: Option<String>,
    state: Option<String>,
    branch_name: Option<String>,
    default_branch: Option<bool>,
    #[serde(rename = "percentageComplete")]
    percentage_complete: Option<u32>,
    #[serde(rename = "webUrl")]
    web_url: Option<String>,
    #[serde(rename = "startDate")]
    start_date: Option<String>,
    #[serde(rename = "finishDate")]
    finish_date: Option<String>,
}

#[derive(Debug, Deserialize)]
struct TcBuildTypeResponse {
    id: Option<String>,
    name: Option<String>,
}


// ---------------------------------------------------------------------------
// TeamCity date parsing
// ---------------------------------------------------------------------------

/// Parse TeamCity date format "20260410T143022+1000" into DateTime<Utc>
fn parse_tc_date(s: &str) -> Option<DateTime<Utc>> {
    chrono::DateTime::parse_from_str(s, "%Y%m%dT%H%M%S%z")
        .ok()
        .map(|dt| dt.with_timezone(&Utc))
}

// ---------------------------------------------------------------------------
// Build type name cache
// ---------------------------------------------------------------------------

use std::collections::HashMap;
use std::sync::OnceLock;
use tokio::sync::RwLock;

static BT_NAME_CACHE: OnceLock<RwLock<HashMap<String, String>>> = OnceLock::new();

fn bt_cache() -> &'static RwLock<HashMap<String, String>> {
    BT_NAME_CACHE.get_or_init(|| RwLock::new(HashMap::new()))
}

async fn get_build_type_name(client: &Client, base: &str, bt_id: &str) -> String {
    {
        let cache = bt_cache().read().await;
        if let Some(name) = cache.get(bt_id) {
            return name.clone();
        }
    }
    let url = format!("{}/app/rest/buildTypes/id:{}", base, bt_id);
    let name = match client.get(&url).header("Accept", "application/json").send().await {
        Ok(resp) if resp.status().is_success() => {
            resp.json::<TcBuildTypeResponse>().await.ok()
                .and_then(|bt| bt.name)
                .unwrap_or_else(|| bt_id.to_string())
        }
        _ => bt_id.to_string(),
    };
    {
        let mut cache = bt_cache().write().await;
        cache.insert(bt_id.to_string(), name.clone());
    }
    name
}

// ---------------------------------------------------------------------------
// WIP branch cross-linking
// ---------------------------------------------------------------------------

pub fn load_wip_branch_map(dir: &Path) -> HashMap<String, (String, u64)> {
    let mut map = HashMap::new();

    // Shared structs — both github-wip.json and linked-prs.json use
    // the same {repos: [{repo, prs: [{number, branch}]}]} shape.
    #[derive(Deserialize)]
    struct RepoFile { repos: Option<Vec<RepoEntry>> }
    #[derive(Deserialize)]
    struct RepoEntry { repo: String, prs: Vec<PrEntry> }
    #[derive(Deserialize)]
    struct PrEntry { number: u64, branch: Option<String> }

    // Read from both files — linked-prs.json (written by Emacs for
    // live-session linked PRs) supplements github-wip.json (the user's
    // own open PRs).
    for filename in &["github-wip.json", "linked-prs.json"] {
        let path = dir.join(filename);
        if let Ok(contents) = std::fs::read_to_string(&path) {
            if let Ok(data) = serde_json::from_str::<RepoFile>(&contents) {
                for repo in data.repos.unwrap_or_default() {
                    for pr in &repo.prs {
                        if let Some(ref branch) = pr.branch {
                            map.entry(branch.clone())
                                .or_insert_with(|| (repo.repo.clone(), pr.number));
                        }
                    }
                }
            }
        }
    }
    map
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// TC's default `/app/rest/builds` listing omits startDate/finishDate and
/// several other fields. We must request them explicitly via `fields=` to
/// populate EnvDeployStatus.finished (used for "was this PR deployed?"
/// temporal comparisons) and TeamCityBuild.started/finished.
const TC_BUILD_FIELDS: &str = "build(id,buildTypeId,number,status,state,\
branchName,defaultBranch,percentageComplete,webUrl,startDate,finishDate)";

async fn fetch_tc_builds(client: &Client, url: &str) -> Result<Vec<TcBuild>, String> {
    let url_with_fields = if url.contains("fields=") {
        url.to_string()
    } else {
        let sep = if url.contains('?') { '&' } else { '?' };
        format!("{url}{sep}fields={TC_BUILD_FIELDS}")
    };
    let resp = client.get(&url_with_fields).header("Accept", "application/json").send().await
        .map_err(|e| format!("TC HTTP: {e}"))?;
    if !resp.status().is_success() {
        return Err(format!("TC API {}", resp.status()));
    }
    let data: TcBuildsResponse = resp.json().await
        .map_err(|e| format!("TC parse: {e}"))?;
    Ok(data.build.unwrap_or_default())
}

// ---------------------------------------------------------------------------
// Polling
// ---------------------------------------------------------------------------

fn tc_build_to_model(
    b: &TcBuild,
    bt_name: String,
    base: &str,
    branch_map: &HashMap<String, (String, u64)>,
) -> TeamCityBuild {
    let branch = b.branch_name.clone();
    let (wip_repo, wip_pr) = branch.as_ref()
        .and_then(|br| branch_map.get(br))
        .map(|(r, n)| (Some(r.clone()), Some(*n)))
        .unwrap_or((None, None));

    TeamCityBuild {
        id: b.id,
        build_type_id: b.build_type_id.clone().unwrap_or_default(),
        build_type_name: bt_name,
        number: b.number.clone(),
        status: b.status.clone().unwrap_or_else(|| "UNKNOWN".into()),
        state: b.state.clone().unwrap_or_else(|| "unknown".into()),
        branch: b.branch_name.clone(),
        branch_is_default: b.default_branch.unwrap_or(false),
        progress_pct: b.percentage_complete,
        url: b.web_url.clone().unwrap_or_else(|| format!("{}/viewLog.html?buildId={}", base, b.id)),
        started: b.start_date.as_deref().and_then(parse_tc_date),
        finished: b.finish_date.as_deref().and_then(parse_tc_date),
        wip_pr_number: wip_pr,
        wip_repo,
    }
}

pub async fn poll_teamcity_builds(
    config: &TeamCityConfig,
    hub_dir: &Path,
) -> Result<TeamCityBuildsFile, String> {
    let client = crate::http_client();
    let base = config.proxy_url.trim_end_matches('/');
    let branch_map = load_wip_branch_map(hub_dir);
    let mut all_builds: Vec<TeamCityBuild> = Vec::new();

    // 1. Running builds
    let running_url = format!(
        "{}/app/rest/builds?locator=running:true,personal:false,count:50",
        base
    );
    if let Ok(builds) = fetch_tc_builds(&client, &running_url).await {
        for b in &builds {
            let bt_id = b.build_type_id.as_deref().unwrap_or("");
            let bt_name = get_build_type_name(&client, base, bt_id).await;
            all_builds.push(tc_build_to_model(b, bt_name, base, &branch_map));
        }
    }

    // 2. Recent finished builds for WIP branches
    // For each WIP branch, fetch the latest finished build
    for (branch, _) in &branch_map {
        let url = format!(
            "{}/app/rest/builds?locator=branch:{},state:finished,personal:false,count:{}",
            base,
            urlencoding_branch(branch),
            config.recent_finished_count
        );
        if let Ok(builds) = fetch_tc_builds(&client, &url).await {
            for b in &builds {
                // Skip if already present (from running)
                if all_builds.iter().any(|existing| existing.id == b.id) {
                    continue;
                }
                let bt_id = b.build_type_id.as_deref().unwrap_or("");
                let bt_name = get_build_type_name(&client, base, bt_id).await;
                all_builds.push(tc_build_to_model(b, bt_name, base, &branch_map));
            }
        }
    }

    // 3. Also fetch recent default branch builds (for deployment tracking)
    let default_url = format!(
        "{}/app/rest/builds?locator=branch:default:any,defaultFilter:true,state:finished,personal:false,count:5",
        base
    );
    if let Ok(builds) = fetch_tc_builds(&client, &default_url).await {
        for b in &builds {
            if all_builds.iter().any(|existing| existing.id == b.id) {
                continue;
            }
            let bt_id = b.build_type_id.as_deref().unwrap_or("");
            let bt_name = get_build_type_name(&client, base, bt_id).await;
            all_builds.push(tc_build_to_model(b, bt_name, base, &branch_map));
        }
    }

    Ok(TeamCityBuildsFile {
        updated: Utc::now(),
        builds: all_builds,
    })
}

/// Simple URL encoding for branch names in TC locator
fn urlencoding_branch(branch: &str) -> String {
    branch.replace(' ', "%20").replace('/', "%2F")
}

// ---------------------------------------------------------------------------
// VCS root discovery — repo → TC project mapping
// ---------------------------------------------------------------------------

#[derive(Debug, Deserialize)]
struct TcVcsRootsResponse {
    #[serde(rename = "vcs-root")]
    vcs_root: Option<Vec<TcVcsRoot>>,
}

#[derive(Debug, Deserialize)]
struct TcVcsRoot {
    id: Option<String>,
    name: Option<String>,
}


/// The repository name of a VCS root named after its GitHub URL, e.g.
/// "https://github.com/acme/widgets#refs/heads/main" or
/// "git@github.com:acme/widgets.git" both give "widgets".
fn vcs_root_repo_slug(name: &str) -> Option<&str> {
    let pos = name.find("github.com")?;
    let path = name[pos + "github.com".len()..].trim_start_matches(['/', ':']);
    let repo = path.split_once('/')?.1;
    let repo = repo.split(['#', '/']).next().unwrap_or(repo);
    let repo = repo.strip_suffix(".git").unwrap_or(repo);
    (!repo.is_empty()).then_some(repo)
}
/// Discover the mapping from GitHub repo slug (e.g. "widget") to TC project ID
/// (e.g. "Monolith") by parsing VCS root names.
async fn discover_repo_tc_mapping(client: &Client, base: &str) -> HashMap<String, String> {
    let url = format!("{}/app/rest/vcs-roots?locator=count:200", base);
    let mut mapping = HashMap::new();
    let resp = match client.get(&url).header("Accept", "application/json").send().await {
        Ok(r) if r.status().is_success() => r,
        Ok(r) => {
            eprintln!("hub: tc vcs-roots: HTTP {}", r.status());
            return mapping;
        }
        Err(e) => {
            eprintln!("hub: tc vcs-roots: {e}");
            return mapping;
        }
    };
    let data: TcVcsRootsResponse = match resp.json().await {
        Ok(d) => d,
        Err(e) => {
            eprintln!("hub: tc vcs-roots parse: {e}");
            return mapping;
        }
    };
    for vcs in data.vcs_root.unwrap_or_default() {
        let name = vcs.name.unwrap_or_default();
        let vid = vcs.id.unwrap_or_default();
        if let Some(repo_slug) = vcs_root_repo_slug(&name) {
            // TC project is the first segment of the VCS root ID
            let tc_project = vid.split('_').next().unwrap_or(&vid);
            // Skip VCS roots with odd/compound IDs (e.g. "HttpsGithubCom...")
            if !tc_project.starts_with("Https") {
                mapping.insert(repo_slug.to_string(), tc_project.to_string());
            }
        }
    }
    eprintln!("hub: tc vcs mapping: {} repos discovered", mapping.len());
    mapping
}

// ---------------------------------------------------------------------------
// Deploy status polling
// ---------------------------------------------------------------------------

/// Canonical order of environments in the deploy pipeline.
fn env_order(e: &str) -> u8 {
    match e {
        "development" => 0,
        "testing" => 1,
        "stable" => 2,
        "production" => 3,
        "uk_production" => 4,
        _ => 5,
    }
}

/// Build an `EnvDeployStatus` from a raw `TcBuild`.
fn tc_build_to_env_status(
    b: &TcBuild,
    env_key: &str,
    step: &str,
    base: &str,
) -> EnvDeployStatus {
    EnvDeployStatus {
        env: env_key.to_string(),
        status: b.status.clone().unwrap_or_else(|| "UNKNOWN".into()),
        state: b.state.clone().unwrap_or_else(|| "unknown".into()),
        build_id: b.id,
        url: b.web_url.clone().unwrap_or_else(|| {
            format!("{}/viewLog.html?buildId={}", base, b.id)
        }),
        finished: b.finish_date.as_deref().and_then(parse_tc_date),
        deploy_type: step.to_string(),
    }
}

/// Fetch the most recent default-branch deploy for each known
/// (env × step) combination in TC_PROJECT. Build configurations that
/// do not exist in the project simply yield empty results and are
/// skipped. When both AppDeploy and TerraformApply exist for the same
/// env, the first match in DEPLOY_STEPS order wins (AppDeploy before
/// TerraformApply), matching the previous behaviour.
async fn fetch_default_branch_envs(
    client: &Client,
    base: &str,
    tc_project: &str,
) -> (Vec<EnvDeployStatus>, Option<String>) {
    let mut failure = None;
    let mut env_statuses: HashMap<&'static str, EnvDeployStatus> = HashMap::new();
    for &(env_key, env_pattern) in ENV_PATTERNS {
        for &step in DEPLOY_STEPS {
            if env_statuses.contains_key(env_key) {
                break; // earlier step already matched for this env
            }
            let bt_id = format!("{}_{}{}", tc_project, env_pattern, step);
            let url = format!(
                "{}/app/rest/builds?locator=buildType:(id:{}),branch:default:any,defaultFilter:true,state:any,count:1",
                base, bt_id
            );
            match fetch_tc_builds(client, &url).await {
                Ok(builds) => {
                    if let Some(b) = builds.first() {
                        env_statuses.insert(
                            env_key,
                            tc_build_to_env_status(b, env_key, step, base),
                        );
                    }
                }
                Err(e) => {
                    // 404 / missing build config is expected; log quietly.
                    eprintln!("hub: tc deploys {tc_project}:{bt_id}: {e}");
                    if !missing_config_error(&e) && failure.is_none() {
                        failure = Some(e);
                    }
                }
            }
        }
    }
    let mut envs: Vec<EnvDeployStatus> = env_statuses.into_values().collect();
    envs.sort_by_key(|e| env_order(&e.env));
    (envs, failure)
}

/// For each WIP branch, query all builds in the TC project and extract deploy status per env.
async fn poll_deploy_status(
    client: &Client,
    base: &str,
    hub_dir: &Path,
    repo_tc_map: &HashMap<String, String>,
    previous: Option<&TeamCityDeploysFile>,
) -> TeamCityDeploysFile {
    let branch_map = load_wip_branch_map(hub_dir);
    eprintln!("hub: tc deploys: tracking {} branches (wip + linked)", branch_map.len());
    let mut repos: HashMap<String, RepoDeployStatus> = HashMap::new();
    let mut failed: HashMap<String, String> = HashMap::new();
    if branch_map.is_empty() {
        if let Some(p) = previous.filter(|p| !p.repos.is_empty()) {
            // No branches to look up is an unreadable WIP feed, not a world
            // without deploys: the last good file stands.
            return TeamCityDeploysFile {
                updated: Utc::now(),
                repos: p.repos.clone(),
                errors: vec!["no WIP branches to track; kept the previous deploys".into()],
                stale: p.stale.clone(),
            };
        }
    }

    // Group branches by repo (from both WIP and linked-prs)
    let mut repo_branches: HashMap<String, Vec<(String, u64)>> = HashMap::new();
    for (branch, (repo, pr_num)) in &branch_map {
        repo_branches
            .entry(repo.clone())
            .or_default()
            .push((branch.clone(), *pr_num));
    }

    for (repo, branches) in &repo_branches {
        // Extract repo slug: "acme/widgets" → "widgets"
        let repo_slug = repo.split('/').last().unwrap_or(repo);
        let tc_project = match repo_tc_map.get(repo_slug) {
            Some(p) => p.clone(),
            None => {
                eprintln!("hub: tc deploys: no TC project for repo {repo} (slug: {repo_slug})");
                continue;
            }
        };

        let mut branch_statuses = Vec::new();

        for (branch, pr_num) in branches {
            // Fetch all builds for this branch in this TC project
            let url = format!(
                "{}/app/rest/builds?locator=affectedProject:{},branch:{},state:any,count:30",
                base,
                tc_project,
                urlencoding_branch(branch)
            );
            let builds = match fetch_tc_builds(client, &url).await {
                Ok(b) => b,
                Err(e) => {
                    eprintln!("hub: tc deploys {}/{}:{}: {e}", repo, tc_project, branch);
                    if !missing_config_error(&e) {
                        failed.entry(repo.clone()).or_insert(e);
                    }
                    continue;
                }
            };

            // For each environment, find the most recent deploy build
            let mut env_statuses: HashMap<&str, EnvDeployStatus> = HashMap::new();

            if builds.is_empty() {
                eprintln!("hub: tc deploys {repo}/{tc_project}:{branch}: 0 builds found");
            }

            for b in &builds {
                let bt_id = b.build_type_id.as_deref().unwrap_or("");
                if let Some((env_key, step)) = extract_env_from_bt_id(bt_id, &tc_project) {
                    // Keep the most recent (first encountered, since TC returns newest first)
                    env_statuses.entry(env_key).or_insert_with(|| {
                        tc_build_to_env_status(b, env_key, step, base)
                    });
                }
            }

            if !env_statuses.is_empty() {
                // Sort environments in pipeline order
                let mut envs: Vec<EnvDeployStatus> = env_statuses.into_values().collect();
                envs.sort_by_key(|e| env_order(&e.env));

                branch_statuses.push(BranchDeployStatus {
                    branch: branch.clone(),
                    pr_number: Some(*pr_num),
                    environments: envs,
                });
            }
        }

        // Also fetch default branch deploy status for this repo.
        // After a PR merges, deployments run on the default branch —
        // this lets merged PRs show DTSP based on post-merge deploys.
        //
        // We query each (env × step) build configuration directly with
        // count:1 so that infrequent deploys (Production, UK) are always
        // found regardless of how many Dev/Test builds have run since.
        {
            let (envs, failure) = fetch_default_branch_envs(client, base, &tc_project).await;
            if let Some(e) = failure {
                failed.entry(repo.clone()).or_insert(e);
            }
            if !envs.is_empty() {
                branch_statuses.push(BranchDeployStatus {
                    branch: "__default__".to_string(),
                    pr_number: None,
                    environments: envs,
                });
            }
        }

        if !branch_statuses.is_empty() {
            repos.insert(repo.clone(), RepoDeployStatus {
                repo: repo.clone(),
                tc_project: tc_project.clone(),
                branches: branch_statuses,
                stale: false,
                as_of: None,
            });
        }
    }

    settle_deploys(TeamCityDeploysFile {
        updated: Utc::now(),
        repos: repos.into_values().collect(),
        errors: Vec::new(),
        stale: Vec::new(),
    }, &failed, previous)
}

// ---------------------------------------------------------------------------
// Adapter runner
// ---------------------------------------------------------------------------

pub async fn run_teamcity_adapter(
    config: TeamCityConfig,
    dir: PathBuf,
    meta: SharedMeta,
    once: bool,
) {
    let interval = Duration::from_secs(config.interval_secs);
    let client = crate::http_client();
    let base = config.proxy_url.trim_end_matches('/').to_string();

    // Repo -> TC project mapping, rediscovered on every poll until one
    // succeeds.  Discovered once at startup, a single failure -- the IAP
    // proxy not yet up when the daemon starts -- left it empty for the
    // daemon's lifetime, so deploy polling never ran and
    // teamcity-deploys.json silently froze.
    let mut repo_tc_map = HashMap::new();
    let mut previous_deploys = read_previous_deploys(&dir);

    loop {
        let result = poll_teamcity_builds(&config, &dir).await;
        let status = match &result {
            Ok(data) => {
                if let Err(e) = atomic_write_json(&dir, "teamcity-builds.json", data).await {
                    eprintln!("hub: write teamcity-builds.json: {e}");
                    AdapterStatus {
                        name: "teamcity-builds".into(),
                        last_poll: Some(Utc::now()),
                        last_error: Some(format!("write error: {e}")),
                        ok: false,
                    }
                } else {
                    let running = data.builds.iter().filter(|b| b.state == "running").count();
                    eprintln!("hub: teamcity: {} builds ({} running)", data.builds.len(), running);
                    AdapterStatus {
                        name: "teamcity-builds".into(),
                        last_poll: Some(Utc::now()),
                        last_error: None,
                        ok: true,
                    }
                }
            }
            Err(e) => {
                eprintln!("hub: teamcity error: {e}");
                AdapterStatus {
                    name: "teamcity-builds".into(),
                    last_poll: Some(Utc::now()),
                    last_error: Some(e.clone()),
                    ok: false,
                }
            }
        };
        update_meta(&meta, status.clone(), &dir).await;

        // Poll deploy status for WIP branches
        if repo_tc_map.is_empty() {
            repo_tc_map = discover_repo_tc_mapping(&client, &base).await;
        }
        let deploys_status = |last_error: Option<String>| AdapterStatus {
            name: "teamcity-deploys".into(),
            last_poll: Some(Utc::now()),
            ok: last_error.is_none(),
            last_error,
        };
        if repo_tc_map.is_empty() {
            let error = "no repo mapping: vcs-roots discovery failed".to_string();
            // TeamCity unreachable: every repo's last good deploys stand, marked.
            if let Some(p) = previous_deploys.take() {
                let failed = p.repos.iter().map(|r| (r.repo.clone(), error.clone())).collect();
                let kept = settle_deploys(TeamCityDeploysFile {
                    updated: Utc::now(), repos: Vec::new(), errors: Vec::new(), stale: Vec::new(),
                }, &failed, Some(&p));
                if let Err(e) = atomic_write_json(&dir, "teamcity-deploys.json", &kept).await {
                    eprintln!("hub: write teamcity-deploys.json: {e}");
                }
                previous_deploys = Some(kept);
            }
            update_meta(&meta, deploys_status(Some(error)), &dir).await;
        } else {
            let deploys = poll_deploy_status(&client, &base, &dir, &repo_tc_map,
                                             previous_deploys.as_ref()).await;
            let deploy_count: usize = deploys.repos.iter()
                .map(|r| r.branches.len())
                .sum();
            let write = atomic_write_json(&dir, "teamcity-deploys.json", &deploys).await;
            if let Err(e) = &write {
                eprintln!("hub: write teamcity-deploys.json: {e}");
            } else {
                eprintln!("hub: tc deploys: {} repos, {} branches", deploys.repos.len(), deploy_count);
            }
            let error = write.err().map(|e| format!("write error: {e}"))
                .or_else(|| deploys.errors.first().cloned());
            update_meta(&meta, deploys_status(error), &dir).await;
            previous_deploys = Some(deploys);
        }

        if once { return; }
        tokio::time::sleep(interval).await;
    }
}
#[cfg(test)]
mod vcs_root_tests {
    use super::vcs_root_repo_slug;

    #[test]
    fn slug_from_https_url_with_ref() {
        assert_eq!(
            vcs_root_repo_slug("https://github.com/acme/widgets#refs/heads/main"),
            Some("widgets")
        );
    }

    #[test]
    fn slug_from_ssh_url() {
        assert_eq!(vcs_root_repo_slug("git@github.com:acme/widgets.git"), Some("widgets"));
    }

    #[test]
    fn no_slug_without_github_url() {
        assert_eq!(vcs_root_repo_slug("Widgets main"), None);
        assert_eq!(vcs_root_repo_slug("https://github.com/acme"), None);
    }
}

#[cfg(test)]
mod settle_tests {
    use super::*;

    fn repo(name: &str, as_of: Option<&str>) -> RepoDeployStatus {
        RepoDeployStatus {
            repo: name.into(), tc_project: "P".into(),
            branches: vec![BranchDeployStatus { branch: "__default__".into(), pr_number: None, environments: vec![] }],
            stale: false, as_of: as_of.map(|t| t.parse().unwrap()),
        }
    }

    fn file(repos: Vec<RepoDeployStatus>) -> TeamCityDeploysFile {
        TeamCityDeploysFile { updated: "2026-11-24T03:00:00Z".parse().unwrap(), repos,
                              errors: vec![], stale: vec![] }
    }

    #[test]
    fn only_a_missing_build_configuration_is_expected() {
        assert!(missing_config_error("TC API 404 Not Found"));
        assert!(!missing_config_error("TC HTTP: error sending request"));
        assert!(!missing_config_error("TC API 502 Bad Gateway"));
    }

    #[test]
    fn a_repo_the_poll_could_not_read_keeps_its_last_deploys_marked_stale() {
        let previous = file(vec![repo("o/a", Some("2026-11-24T01:00:00Z")), repo("o/b", Some("2026-11-24T01:00:00Z"))]);
        let failed: HashMap<String, String> = [("o/a".to_string(), "TC HTTP: refused".to_string())].into();
        let out = settle_deploys(file(vec![repo("o/b", None)]), &failed, Some(&previous));
        let a = out.repos.iter().find(|r| r.repo == "o/a").expect("never dropped");
        assert!(a.stale);
        assert_eq!(a.as_of, previous.repos[0].as_of);
        let b = out.repos.iter().find(|r| r.repo == "o/b").unwrap();
        assert!(!b.stale && b.as_of == Some(out.updated));
        assert_eq!(out.stale.len(), 1);
        assert_eq!(out.stale[0].last_ok, previous.repos[0].as_of);
        assert_eq!(out.errors, vec!["o/a: TC HTTP: refused".to_string()]);
    }

    #[test]
    fn a_failing_repo_with_no_earlier_answer_is_kept_and_marked() {
        let failed: HashMap<String, String> = [("o/a".to_string(), "x".to_string())].into();
        let out = settle_deploys(file(vec![repo("o/a", None)]), &failed, None);
        assert!(out.repos[0].stale && out.repos[0].as_of.is_none());
    }

    #[test]
    fn old_deploy_files_still_parse() {
        let f: TeamCityDeploysFile = serde_json::from_str(
            r#"{"updated": "2026-11-24T03:00:00Z", "repos": [{"repo": "o/a", "tc_project": "P", "branches": []}]}"#).unwrap();
        assert!(!f.repos[0].stale && f.errors.is_empty());
    }
}
