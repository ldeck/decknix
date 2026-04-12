// TeamCity adapter — polls builds via IAP proxy
//
// Auth: IAP proxy handles Google IAP authentication transparently.
// The daemon just hits localhost:{port} which proxies to TeamCity.
// Writes teamcity-builds.json to hub data directory.

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
    let wip_path = dir.join("github-wip.json");
    if let Ok(contents) = std::fs::read_to_string(&wip_path) {
        #[derive(Deserialize)]
        struct WipFile { repos: Option<Vec<WipRepo>> }
        #[derive(Deserialize)]
        struct WipRepo { repo: String, prs: Vec<WipPr> }
        #[derive(Deserialize)]
        struct WipPr { number: u64, branch: Option<String> }

        if let Ok(wip) = serde_json::from_str::<WipFile>(&contents) {
            for repo in wip.repos.unwrap_or_default() {
                for pr in &repo.prs {
                    if let Some(ref branch) = pr.branch {
                        map.insert(branch.clone(), (repo.repo.clone(), pr.number));
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
// Adapter runner
// ---------------------------------------------------------------------------

pub async fn run_teamcity_adapter(
    config: TeamCityConfig,
    dir: PathBuf,
    meta: SharedMeta,
    once: bool,
) {
    let interval = Duration::from_secs(config.interval_secs);
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
        update_meta(&meta, status, &dir).await;
        if once { return; }
        tokio::time::sleep(interval).await;
    }
}