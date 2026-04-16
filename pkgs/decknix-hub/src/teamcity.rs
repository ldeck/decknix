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
}

/// Top-level deploys file
#[derive(Debug, Serialize, Deserialize)]
pub struct TeamCityDeploysFile {
    pub updated: DateTime<Utc>,
    pub repos: Vec<RepoDeployStatus>,
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

async fn fetch_tc_builds(client: &Client, url: &str) -> Result<Vec<TcBuild>, String> {
    let resp = client.get(url).header("Accept", "application/json").send().await
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
    let client = Client::new();
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

/// Discover the mapping from GitHub repo slug (e.g. "upside") to TC project ID
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
        // Extract repo slug: "https://github.com/UpsideRealty/nct-public-api#refs/..."
        if let Some(pos) = name.find("UpsideRealty/") {
            let after = &name[pos + "UpsideRealty/".len()..];
            let repo_slug = after.split('#').next().unwrap_or(after);
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

/// For each WIP branch, query all builds in the TC project and extract deploy status per env.
async fn poll_deploy_status(
    client: &Client,
    base: &str,
    hub_dir: &Path,
    repo_tc_map: &HashMap<String, String>,
) -> TeamCityDeploysFile {
    let branch_map = load_wip_branch_map(hub_dir);
    eprintln!("hub: tc deploys: tracking {} branches (wip + linked)", branch_map.len());
    let mut repos: HashMap<String, RepoDeployStatus> = HashMap::new();

    // Group branches by repo (from both WIP and linked-prs)
    let mut repo_branches: HashMap<String, Vec<(String, u64)>> = HashMap::new();
    for (branch, (repo, pr_num)) in &branch_map {
        repo_branches
            .entry(repo.clone())
            .or_default()
            .push((branch.clone(), *pr_num));
    }

    for (repo, branches) in &repo_branches {
        // Extract repo slug: "UpsideRealty/upside" → "upside"
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
                    });
                }
            }

            if !env_statuses.is_empty() {
                // Sort environments in pipeline order
                let mut envs: Vec<EnvDeployStatus> = env_statuses.into_values().collect();
                let env_order = |e: &str| match e {
                    "development" => 0,
                    "testing" => 1,
                    "stable" => 2,
                    "production" => 3,
                    "uk_production" => 4,
                    _ => 5,
                };
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
        {
            let url = format!(
                "{}/app/rest/builds?locator=affectedProject:{},branch:default:any,defaultFilter:true,state:any,count:30",
                base, tc_project
            );
            match fetch_tc_builds(client, &url).await {
                Ok(builds) => {
                    let mut env_statuses: HashMap<&str, EnvDeployStatus> = HashMap::new();
                    for b in &builds {
                        let bt_id = b.build_type_id.as_deref().unwrap_or("");
                        if let Some((env_key, step)) = extract_env_from_bt_id(bt_id, &tc_project) {
                            env_statuses.entry(env_key).or_insert_with(|| {
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
                            });
                        }
                    }
                    if !env_statuses.is_empty() {
                        let mut envs: Vec<EnvDeployStatus> = env_statuses.into_values().collect();
                        let env_order = |e: &str| match e {
                            "development" => 0, "testing" => 1, "stable" => 2,
                            "production" => 3, "uk_production" => 4, _ => 5,
                        };
                        envs.sort_by_key(|e| env_order(&e.env));
                        branch_statuses.push(BranchDeployStatus {
                            branch: "__default__".to_string(),
                            pr_number: None,
                            environments: envs,
                        });
                    }
                }
                Err(e) => {
                    eprintln!("hub: tc deploys {repo}/{tc_project}:default: {e}");
                }
            }
        }

        if !branch_statuses.is_empty() {
            repos.insert(repo.clone(), RepoDeployStatus {
                repo: repo.clone(),
                tc_project: tc_project.clone(),
                branches: branch_statuses,
            });
        }
    }

    TeamCityDeploysFile {
        updated: Utc::now(),
        repos: repos.into_values().collect(),
    }
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
    let client = Client::new();
    let base = config.proxy_url.trim_end_matches('/').to_string();

    // Discover repo → TC project mapping on startup (cached for lifetime)
    let repo_tc_map = discover_repo_tc_mapping(&client, &base).await;

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
        if !repo_tc_map.is_empty() {
            let deploys = poll_deploy_status(&client, &base, &dir, &repo_tc_map).await;
            let deploy_count: usize = deploys.repos.iter()
                .map(|r| r.branches.len())
                .sum();
            if let Err(e) = atomic_write_json(&dir, "teamcity-deploys.json", &deploys).await {
                eprintln!("hub: write teamcity-deploys.json: {e}");
            } else {
                eprintln!("hub: tc deploys: {} repos, {} branches", deploys.repos.len(), deploy_count);
            }
        }

        if once { return; }
        tokio::time::sleep(interval).await;
    }
}