// Kargo adapter: which deploy stages hold each of my merged PRs.
//
// For every configured repo it reads the current freight of each stage with
// `kargo get stages --project P NAME... -o json`, takes the git revision the
// freight was built from, and asks GitHub whether that revision contains the
// PR's merge commit (compare API: `ahead` or `identical`).  Freight is built
// from the newest green main build, so the merge commit is rarely the freight
// revision itself; an ancestry check is required.  Compare answers are cached
// forever: two commits' ancestry never changes.
//
// A repo may be configured once per region (each its own warehouse and
// stage chain, with a `region` label); every regional entry becomes its own
// PR entry, so the sidebar can track each region as a separate shipper.
//
// A stage that already verified freight holding the merge stays reached while
// newer freight verifies there.  Reading only the newest freight made every
// merged PR fall back to "deploying" each time a later merge rolled through,
// which on a busy repo is most of the day.
//
// A merge that changes nothing the repo deploys never gets freight of its
// own, so it would wait forever.  It is marked `no_deploy` (and dated by its
// merge) when either its own files touch none of the repo's runtime paths,
// or, `no_deploy_after_hours` after the merge with no stage holding it,
// every file changed between the revision the first stage runs and the
// merge is outside them.  Runtime paths are the repo's `runtime_paths`
// globs when configured (its freight build's path filter), else every file
// except documentation and repository metadata.
//
// Which stages promote automatically comes from the project's ProjectConfig
// promotion policies; the others are listed as `manual`, so the sidebar can
// say a merge is ready for a person to promote rather than in progress.
//
// Writes kargo-stages.json.  A poll that cannot read a repo's stages never
// overwrites what the last good poll said about it: each of that repo's PR
// entries is carried forward from the previous file with `stale` set, and
// the repo is listed under `stale` with the error, when it started failing
// and when it last succeeded.  Writing empty `reached` lists instead made
// every merge read "merged, not deployed" for the length of a Kargo login
// expiry, PRs that had reached production included.
//
// Failures are classified.  An expired login (the CLI's silent token
// refresh fails, then every call fails the same way) is not retried and
// stops the poll's remaining calls; a timeout or connection error is
// retried with backoff.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::OnceLock;
use std::time::Duration;
use tokio::process::Command;
use tokio::sync::RwLock;

use crate::{atomic_write_json, update_meta, AdapterStatus, SharedMeta};

const KARGO_TIMEOUT: Duration = Duration::from_secs(60);

/// Pauses before each retry of a transient `kargo` failure.
pub const KARGO_RETRY_DELAYS: [Duration; 2] = [Duration::from_secs(2), Duration::from_secs(8)];

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(default)]
pub struct KargoConfig {
    pub enabled: bool,
    pub interval_secs: u64,
    pub repos: Vec<KargoRepo>,
    /// Hours a merge no stage holds waits before the freight-to-merge
    /// check; 0 disables it.
    pub no_deploy_after_hours: u64,
}

impl Default for KargoConfig {
    fn default() -> Self {
        Self { enabled: false, interval_secs: 300, repos: Vec::new(), no_deploy_after_hours: 6 }
    }
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct KargoRepo {
    /// GitHub `owner/name`.
    pub repo: String,
    pub project: String,
    pub warehouse: String,
    /// Display names in promotion order, e.g. `us-dev`, `us-stg`, `us-prd`.
    pub stages: Vec<String>,
    /// Kargo stage name for a display name; `{warehouse}` and `{stage}` are
    /// substituted.  Defaults to `{warehouse}-{stage}-deploy`.
    #[serde(default)]
    pub stage_pattern: Option<String>,
    /// Label for this deploy path when the repo ships through several, e.g.
    /// `US`; copied onto each PR entry.
    #[serde(default)]
    pub region: Option<String>,
    /// Globs of the files that change what the repo deploys; None for the
    /// default (everything but docs and repository metadata).
    #[serde(default)]
    pub runtime_paths: Option<Vec<String>>,
}

impl KargoRepo {
    pub fn kargo_stage(&self, stage: &str) -> String {
        self.stage_pattern
            .as_deref()
            .unwrap_or("{warehouse}-{stage}-deploy")
            .replace("{warehouse}", &self.warehouse)
            .replace("{stage}", stage)
    }
}

#[derive(Debug, Serialize, Deserialize)]
pub struct KargoStagesFile {
    pub updated: DateTime<Utc>,
    /// Every configured repo, whether or not this poll succeeded.
    pub repos: Vec<String>,
    pub prs: Vec<KargoPr>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub errors: Vec<String>,
    /// Repos whose stages this poll could not read.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub stale: Vec<KargoStale>,
}

/// A repo whose Kargo data is the last good poll's, not this one's.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct KargoStale {
    pub repo: String,
    pub error: String,
    /// When the failures began.
    pub since: DateTime<Utc>,
    /// When a poll last read this repo's stages.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_ok: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct KargoPr {
    pub repo: String,
    pub number: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub region: Option<String>,
    pub merge_commit: String,
    pub stages: Vec<String>,
    /// Stages whose current freight contains the merge and passed verification.
    pub reached: Vec<String>,
    /// Stages running a promotion right now.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub promoting: Vec<String>,
    /// Stages holding the merge whose verification has not passed yet.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub verifying: Vec<String>,
    /// Stages that wait for a person to promote them.  Absent when the
    /// project's promotion policies could not be read.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub manual: Option<Vec<String>>,
    /// Stages whose last promotion or verification failed.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub failed: Vec<String>,
    /// When the last stage verified the freight holding the merge.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub verified_at: Option<String>,
    /// The stage lists are not this poll's: carried from the last good poll,
    /// or unknown when there was none.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub stale: bool,
    /// When the stage lists were read.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub as_of: Option<DateTime<Utc>>,
    /// Why this merge needs no deploy, when it changes no runtime file.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub no_deploy: Option<String>,
}

/// What one Kargo stage says about its current freight.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct StageInfo {
    pub revision: Option<String>,
    pub verified: bool,
    pub verified_at: Option<String>,
    /// A promotion is running (`currentPromotion` is set).
    pub promoting: bool,
    /// The current freight's verification is running or pending.
    pub verifying: bool,
    pub failed: bool,
    /// Earlier freight this stage verified, newest first, as (revision, when).
    pub history: Vec<(String, String)>,
}

/// The items of a `kargo get ... -o json` result, which is a `List` for
/// several objects and the bare object for exactly one.
pub fn list_items(v: &Value) -> Vec<&Value> {
    match v.get("kind").and_then(Value::as_str) {
        Some("List") => v.get("items").and_then(Value::as_array)
            .map(|a| a.iter().collect()).unwrap_or_default(),
        Some(_) => vec![v],
        None => Vec::new(),
    }
}

fn is_sha(s: &str) -> bool {
    (7..=40).contains(&s.len()) && s.chars().all(|c| c.is_ascii_hexdigit())
}

fn image_source_is(image: &Value, repo: &str) -> bool {
    image.pointer("/annotations/org.opencontainers.image.source").and_then(Value::as_str)
        .map(|src| src.trim_end_matches(".git").to_ascii_lowercase()
            .ends_with(&format!("/{}", repo.to_ascii_lowercase())))
        .unwrap_or(false)
}

/// The git revision a freight item was built from: the OCI revision
/// annotation, else a sha suffix on an image tag or chart version
/// (`2749.0.0-<sha>`, `12.0.0-r123.<sha>`), else a git commit.
///
/// Freight often bundles images from several repos (a shared sidecar) or
/// several images from one repo built at different commits (a schema
/// image), so with REPO the first image whose source annotation names it
/// wins over the first image overall.
pub fn freight_revision(item: &Value, repo: Option<&str>) -> Option<String> {
    let images = item.get("images").and_then(Value::as_array);
    let revision = |i: &Value| i.pointer("/annotations/org.opencontainers.image.revision")
        .and_then(Value::as_str).filter(|s| is_sha(s)).map(str::to_string);
    if let Some(rev) = repo.and_then(|r| images.into_iter().flatten()
        .filter(|i| image_source_is(i, r)).find_map(revision)) {
        return Some(rev);
    }
    if let Some(rev) = images.into_iter().flatten().find_map(revision) {
        return Some(rev);
    }
    let suffix = |s: &str| s.rsplit(['-', '.']).next()
        .filter(|t| is_sha(t) && t.len() >= 7 && t.chars().any(|c| c.is_ascii_alphabetic()))
        .map(str::to_string);
    let tags = images.into_iter().flatten()
        .filter_map(|i| i.get("tag").and_then(Value::as_str));
    let charts = item.get("charts").and_then(Value::as_array).into_iter().flatten()
        .filter_map(|c| c.get("version").and_then(Value::as_str));
    if let Some(s) = tags.chain(charts).find_map(suffix) {
        return Some(s);
    }
    item.get("commits").and_then(Value::as_array).into_iter().flatten()
        .filter_map(|c| c.get("id").and_then(Value::as_str))
        .find(|s| is_sha(s))
        .map(str::to_string)
}

/// Read a Stage object deploying REPO's freight (any repo when None).
pub fn stage_info(stage: &Value, repo: Option<&str>) -> StageInfo {
    let status = stage.get("status").unwrap_or(&Value::Null);
    let current = status.pointer("/freightHistory/0");
    let revision = current
        .and_then(|c| c.get("items")).and_then(Value::as_object)
        .and_then(|items| items.values().find_map(|i| freight_revision(i, repo)));
    let verification = current
        .and_then(|c| c.pointer("/verificationHistory/0"));
    let vphase = verification.and_then(|v| v.get("phase")).and_then(Value::as_str);
    let promotion_phase = status.pointer("/lastPromotion/status/phase").and_then(Value::as_str);
    let promoting = status.pointer("/currentPromotion/name").and_then(Value::as_str)
        .map(|n| !n.is_empty()).unwrap_or(false);
    let verifying = matches!(vphase, Some("Running") | Some("Pending"));
    let failed = matches!(vphase, Some("Failed") | Some("Error") | Some("Errored"))
        || matches!(promotion_phase, Some("Failed") | Some("Errored"));
    // A stage with no verification configured is verified by its promotion.
    let verified = match vphase {
        Some(p) => p == "Successful",
        None => current.is_some() && !matches!(promotion_phase, Some("Failed") | Some("Errored")),
    };
    let verified_at = if verified {
        verification.and_then(|v| v.get("finishTime")).and_then(Value::as_str)
            .or_else(|| status.pointer("/lastPromotion/finishedAt").and_then(Value::as_str))
            .map(str::to_string)
    } else {
        None
    };
    let history = status.get("freightHistory").and_then(Value::as_array)
        .into_iter().flatten().skip(1)
        .filter_map(|h| {
            let rev = h.get("items").and_then(Value::as_object)
                .and_then(|items| items.values().find_map(|i| freight_revision(i, repo)))?;
            let v = h.pointer("/verificationHistory/0")?;
            (v.get("phase").and_then(Value::as_str) == Some("Successful")).then_some(())?;
            Some((rev, v.get("finishTime").and_then(Value::as_str)?.to_string()))
        })
        .collect();
    StageInfo { revision, verified, verified_at, promoting, verifying, failed, history }
}

/// When the last stage first verified freight containing the merge: the
/// oldest entry of its history that contains it, else the current one.
/// Without this every shipped PR took the time of the latest deploy, so an
/// old merge looked freshly shipped and outstayed its retention.
pub fn first_verified<F>(info: &StageInfo, mut contains: F) -> Option<String>
where
    F: FnMut(&str) -> Option<bool>,
{
    info.history.iter().rev()
        .find(|(rev, _)| contains(rev).unwrap_or(false))
        .map(|(_, at)| at.clone())
        .or_else(|| info.verified_at.clone())
}

/// The project's auto-promoting stage names, from a ProjectConfig object.
/// A policy names its stage either as `stage` or as `stageSelector.name`.
pub fn auto_stages(project_config: &Value) -> HashSet<String> {
    project_config.pointer("/spec/promotionPolicies").and_then(Value::as_array)
        .into_iter().flatten()
        .filter(|p| p.get("autoPromotionEnabled").and_then(Value::as_bool) == Some(true))
        .filter_map(|p| p.get("stage").and_then(Value::as_str)
            .or_else(|| p.pointer("/stageSelector/name").and_then(Value::as_str)))
        .map(str::to_string)
        .collect()
}

/// Decide one PR's stages from each stage's info and a containment oracle.
/// AUTO, when known, is the project's auto-promoting stage set.
pub fn pr_stages<F>(repo: &KargoRepo, number: u64, merge: &str,
                    infos: &HashMap<String, StageInfo>, auto: Option<&HashSet<String>>,
                    mut contains: F) -> KargoPr
where
    F: FnMut(&str) -> Option<bool>,
{
    let mut reached = Vec::new();
    let mut promoting = Vec::new();
    let mut verifying = Vec::new();
    let mut failed = Vec::new();
    let mut verified_at = None;
    for stage in &repo.stages {
        let Some(info) = infos.get(&repo.kargo_stage(stage)) else { continue };
        let holds = info.revision.as_deref().and_then(&mut contains).unwrap_or(false);
        let held_before = info.history.first()
            .and_then(|(rev, _)| contains(rev)).unwrap_or(false);
        if holds && (info.verified || held_before) {
            reached.push(stage.clone());
            verified_at = if info.verified { info.verified_at.clone() }
                          else { info.history.first().map(|(_, at)| at.clone()) };
        } else if info.failed {
            failed.push(stage.clone());
        } else if info.promoting {
            promoting.push(stage.clone());
        } else if holds {
            verifying.push(stage.clone());
        }
    }
    let manual = auto.map(|a| repo.stages.iter()
        .filter(|s| !a.contains(&repo.kargo_stage(s))).cloned().collect());
    let all = reached.len() == repo.stages.len();
    KargoPr {
        repo: repo.repo.clone(),
        number,
        region: repo.region.clone(),
        merge_commit: merge.to_string(),
        stages: repo.stages.clone(),
        reached,
        promoting,
        verifying,
        manual,
        failed,
        verified_at: if all { verified_at } else { None },
        stale: false,
        as_of: None,
        no_deploy: None,
    }
}

/// Files that are not runtime when a repo names no `runtime_paths`.
pub const DEFAULT_NON_RUNTIME: [&str; 9] = [
    "docs/**", "specs/**", ".specify/**", "**/*.md", "LICENSE*", "**/.gitignore",
    "**/CODEOWNERS", ".github/ISSUE_TEMPLATE/**", ".github/pull_request_template.md",
];

/// Whether PATH matches GLOB: `**` any run of directories (or none), `*`
/// anything within one segment, `?` one character in a segment.
pub fn glob_match(glob: &str, path: &str) -> bool {
    fn segs(g: &[&str], p: &[&str]) -> bool {
        match (g.first(), p.first()) {
            (None, None) => true,
            (Some(&"**"), _) => segs(&g[1..], p) || (!p.is_empty() && segs(g, &p[1..])),
            (Some(gs), Some(ps)) => seg(gs.as_bytes(), ps.as_bytes()) && segs(&g[1..], &p[1..]),
            _ => false,
        }
    }
    fn seg(g: &[u8], p: &[u8]) -> bool {
        match (g.first(), p.first()) {
            (None, None) => true,
            (Some(b'*'), _) => seg(&g[1..], p) || (!p.is_empty() && seg(g, &p[1..])),
            (Some(b'?'), Some(_)) => seg(&g[1..], &p[1..]),
            (Some(a), Some(b)) => a == b && seg(&g[1..], &p[1..]),
            _ => false,
        }
    }
    let g: Vec<&str> = glob.split('/').collect();
    let p: Vec<&str> = path.split('/').collect();
    segs(&g, &p)
}

/// Whether changing PATH changes what REPO deploys.
pub fn is_runtime(repo: &KargoRepo, path: &str) -> bool {
    match &repo.runtime_paths {
        Some(globs) => globs.iter().any(|g| glob_match(g, path)),
        None => !DEFAULT_NON_RUNTIME.iter().any(|g| glob_match(g, path)),
    }
}

/// The no-deploy reason for a merge whose changed FILES are all outside
/// REPO's runtime paths, or None (also for an empty or unknown list).
pub fn no_runtime_change(repo: &KargoRepo, files: Option<&[String]>, reason: &str) -> Option<String> {
    let files = files.filter(|f| !f.is_empty())?;
    (!files.iter().any(|f| is_runtime(repo, f))).then(|| reason.to_string())
}

/// GitHub truncates a compare's file list here; a full list is not proof.
const COMPARE_FILES_CAP: usize = 300;

static FILES_CACHE: OnceLock<RwLock<HashMap<String, Vec<String>>>> = OnceLock::new();
fn files_cache() -> &'static RwLock<HashMap<String, Vec<String>>> {
    FILES_CACHE.get_or_init(|| RwLock::new(HashMap::new()))
}

/// The files a merged PR changed, cached forever (a merged PR's files do
/// not change); None when GitHub cannot say.
async fn pr_files(repo: &str, number: u64) -> Option<Vec<String>> {
    let key = format!("pr:{repo}#{number}");
    if let Some(hit) = files_cache().read().await.get(&key) {
        return Some(hit.clone());
    }
    let path = format!("repos/{repo}/pulls/{number}/files");
    let out = crate::gh_json(&["api", "--paginate", &path, "--jq", ".[].filename"]).await.ok()?;
    let files: Vec<String> = out.lines().map(str::trim).filter(|l| !l.is_empty()).map(str::to_string).collect();
    files_cache().write().await.insert(key, files.clone());
    Some(files)
}

/// The files changed from FROM to TO, when TO is ahead of FROM and GitHub
/// listed them all; cached forever.
async fn compare_files(repo: &str, from: &str, to: &str) -> Option<Vec<String>> {
    let key = format!("cmp:{repo}:{from}...{to}");
    if let Some(hit) = files_cache().read().await.get(&key) {
        return Some(hit.clone());
    }
    let path = format!("repos/{repo}/compare/{from}...{to}");
    let out = crate::gh_json(&["api", &path, "--jq", "[.status, (.files // [] | .[].filename)] | .[]"]).await.ok()?;
    let mut lines = out.lines().map(str::trim).filter(|l| !l.is_empty());
    if lines.next() != Some("ahead") {
        return None;
    }
    let files: Vec<String> = lines.map(str::to_string).collect();
    if files.len() >= COMPARE_FILES_CAP {
        return None;
    }
    files_cache().write().await.insert(key, files.clone());
    Some(files)
}

/// GitHub compare `status` meaning HEAD contains BASE.
pub fn compare_contains(status: &str) -> Option<bool> {
    match status {
        "ahead" | "identical" => Some(true),
        "behind" | "diverged" => Some(false),
        _ => None,
    }
}

static CONTAINS_CACHE: OnceLock<RwLock<HashMap<(String, String, String), bool>>> = OnceLock::new();
fn contains_cache() -> &'static RwLock<HashMap<(String, String, String), bool>> {
    CONTAINS_CACHE.get_or_init(|| RwLock::new(HashMap::new()))
}

async fn revision_contains(repo: &str, merge: &str, revision: &str) -> Option<bool> {
    if revision.starts_with(merge) || merge.starts_with(revision) {
        return Some(true);
    }
    let key = (repo.to_string(), merge.to_string(), revision.to_string());
    if let Some(hit) = contains_cache().read().await.get(&key) {
        return Some(*hit);
    }
    let path = format!("repos/{repo}/compare/{merge}...{revision}");
    let answer = match crate::gh_json(&["api", &path, "--jq", ".status"]).await {
        Ok(out) => compare_contains(out.trim())?,
        Err(e) => compare_error_answer(&e)?,
    };
    contains_cache().write().await.insert(key, answer);
    Some(answer)
}

/// What a failed compare call says about containment: GitHub answering
/// 404 or 422 means the revision is not this repo's (freight can carry
/// another repo's image), which is a definite no; anything else (timeout,
/// network, auth) is unknown, so the PR's entry must not be rebuilt from it.
pub fn compare_error_answer(error: &str) -> Option<bool> {
    (error.contains("HTTP 404") || error.contains("HTTP 422")).then_some(false)
}

/// Why a `kargo` call failed, which decides whether retrying can help.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum KargoFailure {
    /// The login expired or was refused; every call fails until `kargo login`.
    Auth,
    /// A timeout or connection problem worth retrying.
    Transient,
    Other,
}

pub fn classify_failure(message: &str) -> KargoFailure {
    let m = message.to_ascii_lowercase();
    const AUTH: [&str; 6] = ["re-authenticate", "refreshing token", "unauthenticated",
                             "token is expired", "401", "kargo login"];
    const TRANSIENT: [&str; 10] = ["timed out", "timeout", "deadline exceeded", "connection refused",
                                   "connection reset", "no such host", "unavailable", "502",
                                   "503", "eof"];
    if AUTH.iter().any(|k| m.contains(k)) {
        KargoFailure::Auth
    } else if TRANSIENT.iter().any(|k| m.contains(k)) {
        KargoFailure::Transient
    } else {
        KargoFailure::Other
    }
}

/// The error recorded for a failed call: an expired login says what to run.
pub fn failure_message(kind: KargoFailure, raw: &str) -> String {
    match kind {
        KargoFailure::Auth => format!("login expired, run `kargo login --sso` ({})",
                                      raw.chars().take(120).collect::<String>()),
        _ => raw.to_string(),
    }
}

/// Run `kargo ARGS`, retrying a transient failure after each of
/// `KARGO_RETRY_DELAYS`.  The error names its kind.
async fn kargo_json(args: &[String]) -> Result<Value, (KargoFailure, String)> {
    let mut delays = KARGO_RETRY_DELAYS.iter();
    loop {
        match kargo_json_once(args).await {
            Ok(v) => return Ok(v),
            Err(e) => {
                let kind = classify_failure(&e);
                match (kind, delays.next()) {
                    (KargoFailure::Transient, Some(d)) => tokio::time::sleep(*d).await,
                    _ => return Err((kind, failure_message(kind, &e))),
                }
            }
        }
    }
}

async fn kargo_json_once(args: &[String]) -> Result<Value, String> {
    let child = Command::new("kargo")
        .args(args)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true)
        .spawn()
        .map_err(|e| format!("kargo not runnable: {e}"))?;
    let out = tokio::time::timeout(KARGO_TIMEOUT, child.wait_with_output())
        .await
        .map_err(|_| format!("kargo timed out after {}s", KARGO_TIMEOUT.as_secs()))?
        .map_err(|e| format!("kargo: {e}"))?;
    if !out.status.success() {
        let err = String::from_utf8_lossy(&out.stderr);
        return Err(format!("kargo {}: {}", args.join(" "), err.trim().chars().take(200).collect::<String>()));
    }
    serde_json::from_slice(&out.stdout).map_err(|e| format!("kargo json: {e}"))
}

/// My merged PRs with a merge commit, from the WIP adapter's output; None
/// when that output cannot be read, which is not the same as no PRs.
fn merged_prs(dir: &Path) -> Option<Vec<MergedPr>> {
    let text = std::fs::read_to_string(dir.join("github-wip.json")).ok()?;
    let v = serde_json::from_str::<Value>(&text).ok()?;
    Some(merged_prs_from(&v))
}

/// The previous poll's file, the fallback for whatever this poll cannot read.
pub fn read_previous(dir: &Path) -> Option<KargoStagesFile> {
    serde_json::from_str(&std::fs::read_to_string(dir.join("kargo-stages.json")).ok()?).ok()
}

/// FRESH, a PR entry this poll built, or the stale stand-in for it when
/// TRUSTED is false: the previous poll's entry for the same PR and region,
/// else FRESH with no stage reached.  Either way it is marked stale, and
/// keeps the time the stand-in was read.
pub fn settle_entry(fresh: KargoPr, trusted: bool, previous: Option<&KargoStagesFile>,
                    now: DateTime<Utc>) -> KargoPr {
    if trusted {
        return KargoPr { stale: false, as_of: Some(now), ..fresh };
    }
    let prior = previous.and_then(|p| p.prs.iter().find(|e| {
        e.repo.eq_ignore_ascii_case(&fresh.repo) && e.number == fresh.number && e.region == fresh.region
    }));
    match prior {
        Some(e) => KargoPr { stale: true, ..e.clone() },
        None => KargoPr { reached: Vec::new(), promoting: Vec::new(), verifying: Vec::new(),
                          failed: Vec::new(), verified_at: None, stale: true, as_of: None, ..fresh },
    }
}

/// The `stale` list for repos FAILED (repo -> error) this poll, keeping each
/// one's start from PREVIOUS and its last success from its newest entry there.
pub fn stale_repos(failed: &HashMap<String, String>, previous: Option<&KargoStagesFile>,
                   now: DateTime<Utc>) -> Vec<KargoStale> {
    let mut out: Vec<KargoStale> = failed.iter().map(|(repo, error)| {
        let before = previous.and_then(|p| p.stale.iter().find(|s| s.repo.eq_ignore_ascii_case(repo)));
        let newest = previous.into_iter().flat_map(|p| p.prs.iter())
            .filter(|e| e.repo.eq_ignore_ascii_case(repo))
            .filter_map(|e| e.as_of).max();
        KargoStale {
            repo: repo.clone(),
            error: error.clone(),
            since: before.map(|s| s.since).unwrap_or(now),
            last_ok: newest.or_else(|| before.and_then(|s| s.last_ok)),
        }
    }).collect();
    out.sort_by(|a, b| a.repo.cmp(&b.repo));
    out
}

/// (repo, number, merge commit, merged at).
pub type MergedPr = (String, u64, String, Option<String>);

pub fn merged_prs_from(wip: &Value) -> Vec<MergedPr> {
    let mut out = Vec::new();
    for repo in wip.get("repos").and_then(Value::as_array).into_iter().flatten() {
        let name = repo.get("repo").and_then(Value::as_str).unwrap_or_default();
        for pr in repo.get("prs").and_then(Value::as_array).into_iter().flatten() {
            let merged = pr.get("state").and_then(Value::as_str)
                .map(|s| s.eq_ignore_ascii_case("merged")).unwrap_or(false);
            let (Some(number), Some(merge)) = (
                pr.get("number").and_then(Value::as_u64),
                pr.get("merge_commit").and_then(Value::as_str),
            ) else { continue };
            if merged {
                let at = pr.get("merged_at").and_then(Value::as_str).map(str::to_string);
                out.push((name.to_string(), number, merge.to_string(), at));
            }
        }
    }
    out
}

pub async fn poll_kargo(config: &KargoConfig, dir: &Path,
                        previous: Option<&KargoStagesFile>) -> KargoStagesFile {
    let now = Utc::now();
    let mut errors = Vec::new();
    let mut repos: Vec<String> = Vec::new();
    for r in &config.repos {
        if !repos.iter().any(|x| x.eq_ignore_ascii_case(&r.repo)) {
            repos.push(r.repo.clone());
        }
    }
    let Some(prs_in) = merged_prs(dir) else {
        // No PR list to work from: the last good file stands as it was.
        let mut errors = vec!["github-wip.json unreadable; kept the previous stages".to_string()];
        if let Some(p) = previous {
            errors.extend(p.errors.iter().cloned());
        }
        return KargoStagesFile {
            updated: now, repos,
            prs: previous.map(|p| p.prs.clone()).unwrap_or_default(),
            errors,
            stale: previous.map(|p| p.stale.clone()).unwrap_or_default(),
        };
    };
    let mut infos: HashMap<String, StageInfo> = HashMap::new();

    let mut by_project: HashMap<&str, Vec<String>> = HashMap::new();
    let mut stage_repo: HashMap<String, &str> = HashMap::new();
    for r in &config.repos {
        if !prs_in.iter().any(|(repo, ..)| repo.eq_ignore_ascii_case(&r.repo)) {
            continue;
        }
        for s in &r.stages {
            let name = r.kargo_stage(s);
            stage_repo.insert(name.clone(), r.repo.as_str());
            by_project.entry(r.project.as_str()).or_default().push(name);
        }
    }
    // Once the login has expired every further call fails the same way, so
    // the rest are skipped rather than spent.
    let mut auth_error: Option<String> = None;
    let mut policies: HashMap<String, HashSet<String>> = HashMap::new();
    for project in by_project.keys() {
        if auth_error.is_some() { break; }
        let args = ["get", "projectconfig", "--project", project, "-o", "json"]
            .map(str::to_string);
        match kargo_json(&args).await {
            Ok(v) => { policies.insert(project.to_string(), auto_stages(&v)); }
            Err((kind, e)) => {
                if kind == KargoFailure::Auth { auth_error = Some(e.clone()); }
                errors.push(e);
            }
        }
    }
    let mut failed_projects: HashMap<String, String> = HashMap::new();
    for (project, names) in by_project {
        if let Some(e) = &auth_error {
            failed_projects.insert(project.to_string(), e.clone());
            continue;
        }
        let mut args = vec!["get".to_string(), "stages".into(), "--project".into(), project.into()];
        args.extend(names);
        args.extend(["-o".to_string(), "json".into()]);
        match kargo_json(&args).await {
            Ok(v) => for stage in list_items(&v) {
                if let Some(name) = stage.pointer("/metadata/name").and_then(Value::as_str) {
                    infos.insert(name.to_string(),
                                 stage_info(stage, stage_repo.get(name).copied()));
                }
            },
            Err((kind, e)) => {
                if kind == KargoFailure::Auth { auth_error = Some(e.clone()); }
                failed_projects.insert(project.to_string(), e.clone());
                errors.push(e);
            }
        }
    }

    let mut failed_repos: HashMap<String, String> = HashMap::new();
    let mut prs = Vec::new();
    for (repo_name, number, merge, merged_at) in &prs_in {
        let mut answers: HashMap<String, Option<bool>> = HashMap::new();
        for repo in config.repos.iter().filter(|r| r.repo.eq_ignore_ascii_case(repo_name)) {
        let project_error = failed_projects.get(&repo.project).cloned();
        if let Some(e) = &project_error {
            failed_repos.insert(repo.repo.clone(), e.clone());
        }
        for stage in &repo.stages {
            let Some(info) = infos.get(&repo.kargo_stage(stage)) else { continue };
            // The freight verified before the current one is asked about only
            // while the current one is unverified: that is the one case where
            // it decides whether the stage still holds the merge.
            let prior = (!info.verified).then(|| info.history.first().map(|(r, _)| r.clone())).flatten();
            for rev in info.revision.iter().cloned().chain(prior) {
                if !answers.contains_key(&rev) {
                    answers.insert(rev.clone(), revision_contains(&repo.repo, merge, &rev).await);
                }
            }
        }
        let mut pr = pr_stages(repo, *number, merge, &infos, policies.get(&repo.project),
                               |rev| answers.get(rev).copied().flatten());
        if pr.verified_at.is_some() {
            if let Some(last) = repo.stages.last().and_then(|s| infos.get(&repo.kargo_stage(s))) {
                for (rev, _) in &last.history {
                    if !answers.contains_key(rev) {
                        answers.insert(rev.clone(), revision_contains(&repo.repo, merge, rev).await);
                    }
                }
                pr.verified_at = first_verified(last, |rev| answers.get(rev).copied().flatten());
            }
        }
        // An unread project, or a containment GitHub could not answer, leaves
        // this entry a guess; the previous poll's answer is the better one.
        let unknown = answers.values().any(Option::is_none);
        if unknown && project_error.is_none() {
            failed_repos.entry(repo.repo.clone())
                .or_insert_with(|| "GitHub compare failed".to_string());
        }
        let trusted = project_error.is_none() && !unknown;
        if trusted && pr.reached.len() < repo.stages.len() {
            pr.no_deploy = no_deploy_reason(repo, &pr, merge, merged_at.as_deref(), &infos,
                                            config.no_deploy_after_hours, now).await;
            if pr.no_deploy.is_some() {
                pr.verified_at = merged_at.clone();
            }
        }
        let mut pr = settle_entry(pr, trusted, previous, now);
        if trusted && !policies.contains_key(&repo.project) {
            // Policies unread but stages fine: keep what was known of them.
            pr.manual = previous.and_then(|p| p.prs.iter().find(|e| {
                e.repo.eq_ignore_ascii_case(&pr.repo) && e.number == pr.number && e.region == pr.region
            })).and_then(|e| e.manual.clone());
        }
        prs.push(pr);
        }
    }

    KargoStagesFile {
        updated: now,
        repos,
        prs,
        errors,
        stale: stale_repos(&failed_repos, previous, now),
    }
}

/// Why PR (REPO's merge MERGE at MERGED_AT) needs no deploy, or None.
async fn no_deploy_reason(repo: &KargoRepo, pr: &KargoPr, merge: &str, merged_at: Option<&str>,
                          infos: &HashMap<String, StageInfo>, after_hours: u64,
                          now: DateTime<Utc>) -> Option<String> {
    let own = pr_files(&repo.repo, pr.number).await;
    if let Some(reason) = no_runtime_change(repo, own.as_deref(), "no runtime files changed") {
        return Some(reason);
    }
    let held = !pr.reached.is_empty() || !pr.promoting.is_empty() || !pr.verifying.is_empty();
    let age = merged_at.and_then(|t| t.parse::<DateTime<Utc>>().ok()).map(|t| now - t)?;
    if held || after_hours == 0 || age < chrono::Duration::hours(after_hours as i64) {
        return None;
    }
    let first = repo.stages.first().and_then(|s| infos.get(&repo.kargo_stage(s)))?;
    let deployed = first.revision.as_deref()?;
    let between = compare_files(&repo.repo, deployed, merge).await;
    no_runtime_change(repo, between.as_deref(), "no runtime change since the deployed build")
}

pub async fn run_kargo_adapter(config: KargoConfig, dir: PathBuf, meta: SharedMeta, once: bool) {
    let interval = Duration::from_secs(config.interval_secs.max(30));
    let mut previous = read_previous(&dir);
    loop {
        let data = poll_kargo(&config, &dir, previous.as_ref()).await;
        let last_error = match atomic_write_json(&dir, "kargo-stages.json", &data).await {
            Err(e) => Some(format!("write error: {e}")),
            Ok(()) => data.errors.first().cloned(),
        };
        eprintln!("hub: kargo-stages: {} PRs, {} errors, {} repos stale{}",
                  data.prs.len(), data.errors.len(), data.stale.len(),
                  data.errors.first().map(|e| format!(": {e}")).unwrap_or_default());
        update_meta(&meta, AdapterStatus {
            name: "kargo-stages".into(),
            last_poll: Some(Utc::now()),
            ok: last_error.is_none(),
            last_error,
        }, &dir).await;
        previous = Some(data);
        if once { return; }
        tokio::time::sleep(interval).await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn fub() -> KargoRepo {
        KargoRepo {
            repo: "o/fub".into(), project: "p".into(), warehouse: "fub".into(),
            stages: vec!["us-dev".into(), "us-stg".into(), "us-prd".into()],
            stage_pattern: None, region: None, runtime_paths: None,
        }
    }

    fn stage(name: &str, revision: &str, vphase: Option<&str>, current_promotion: &str) -> Value {
        let mut fh = json!({
            "items": {"Warehouse/fub": {"images": [{
                "tag": format!("2749.0.0-{revision}"),
                "annotations": {"org.opencontainers.image.revision": revision}}]}}});
        if let Some(p) = vphase {
            fh["verificationHistory"] = json!([{"phase": p, "finishTime": "2026-11-18T02:21:45Z"}]);
        }
        json!({"kind": "Stage", "metadata": {"name": name},
               "status": {"freightHistory": [fh],
                          "currentPromotion": {"name": current_promotion},
                          "lastPromotion": {"finishedAt": "2026-11-18T02:15:48Z",
                                            "status": {"phase": "Succeeded"}}}})
    }

    #[test]
    fn stage_names_follow_the_pattern() {
        assert_eq!(fub().kargo_stage("us-stg"), "fub-us-stg-deploy");
        let r = KargoRepo { stage_pattern: Some("{warehouse}-{stage}".into()), ..fub() };
        assert_eq!(r.kargo_stage("us-stg"), "fub-us-stg");
    }

    #[test]
    fn list_and_bare_object_both_yield_items() {
        let one = json!({"kind": "Stage", "metadata": {"name": "a"}});
        assert_eq!(list_items(&one).len(), 1);
        let many = json!({"kind": "List", "items": [one.clone(), one]});
        assert_eq!(list_items(&many).len(), 2);
        assert!(list_items(&json!({"kind": "List", "items": []})).is_empty());
    }

    #[test]
    fn revision_prefers_the_annotation_then_tag_suffixes_then_commits() {
        let sha = "44b00c4e7c22cf1b22e72534b94a393603e5120f";
        assert_eq!(freight_revision(&json!({"images": [{"annotations":
            {"org.opencontainers.image.revision": sha}}]}), None).as_deref(), Some(sha));
        assert_eq!(freight_revision(&json!({"images": [{"tag": format!("2749.0.0-{sha}")}]}), None).as_deref(), Some(sha));
        assert_eq!(freight_revision(&json!({"charts": [{"version": "12.0.0-r123.abc1234"}]}), None).as_deref(), Some("abc1234"));
        assert_eq!(freight_revision(&json!({"commits": [{"id": sha}]}), None).as_deref(), Some(sha));
        assert_eq!(freight_revision(&json!({"images": [{"tag": "0.398.0"}]}), None), None);
    }

    #[test]
    fn stage_info_reads_verification_and_promotion() {
        let i = stage_info(&stage("fub-us-dev-deploy", "abcdef1", Some("Successful"), ""), None);
        assert_eq!(i.revision.as_deref(), Some("abcdef1"));
        assert!(i.verified && !i.promoting && !i.failed);
        assert_eq!(i.verified_at.as_deref(), Some("2026-11-18T02:21:45Z"));
        let i = stage_info(&stage("x", "abcdef1", Some("Running"), ""), None);
        assert!(!i.verified && i.verifying && !i.promoting, "verifying is not promoting");
        let i = stage_info(&stage("x", "abcdef1", Some("Failed"), ""), None);
        assert!(i.failed && !i.verified);
        let i = stage_info(&stage("x", "abcdef1", None, "promo-1"), None);
        assert!(i.verified && i.promoting, "no verification: promotion verifies");
        assert_eq!(i.verified_at.as_deref(), Some("2026-11-18T02:15:48Z"));
    }

    #[test]
    fn the_real_fixture_parses() {
        let v: Value = serde_json::from_str(include_str!("../tests/fixtures/kargo-stages.json")).unwrap();
        let items = list_items(&v);
        assert_eq!(items.len(), 3);
        let i = stage_info(items[0], None);
        assert_eq!(i.revision.as_deref(), Some("44b00c4e7c22cf1b22e72534b94a393603e5120f"));
        assert!(i.verified);
    }

    #[test]
    fn a_pr_reaches_the_stages_whose_freight_contains_it() {
        let repo = fub();
        let infos: HashMap<String, StageInfo> = [
            ("fub-us-dev-deploy", stage_info(&stage("", "new", Some("Successful"), ""), None)),
            ("fub-us-stg-deploy", stage_info(&stage("", "new", Some("Running"), ""), None)),
            ("fub-us-prd-deploy", stage_info(&stage("", "old", Some("Successful"), ""), None)),
        ].into_iter().map(|(k, v)| (k.to_string(), v)).collect();
        // The fixture's revisions are not hex, so supply them directly.
        let infos: HashMap<String, StageInfo> = infos.into_iter().map(|(k, mut v)| {
            v.revision = Some(if k.contains("prd") { "0ld0ld0".into() } else { "ae1ae1ae".into() });
            (k, v)
        }).collect();
        let pr = pr_stages(&repo, 7, "m", &infos, None, |rev| Some(rev == "ae1ae1ae"));
        assert_eq!(pr.reached, vec!["us-dev".to_string()]);
        assert_eq!(pr.verifying, vec!["us-stg".to_string()]);
        assert!(pr.promoting.is_empty(), "no promotion is running");
        assert!(pr.failed.is_empty());
        assert_eq!(pr.verified_at, None, "only set once every stage is reached");
        let all = pr_stages(&repo, 7, "m", &infos, None, |_| Some(true));
        assert_eq!(all.reached.len(), 2, "stg is still verifying");
    }

    #[test]
    fn every_stage_reached_records_when_the_last_verified() {
        let repo = fub();
        let infos: HashMap<String, StageInfo> = repo.stages.iter().map(|s| {
            (repo.kargo_stage(s), StageInfo { revision: Some("abcdef1".into()), verified: true,
                                              verified_at: Some(format!("t-{s}")), ..Default::default() })
        }).collect();
        let pr = pr_stages(&repo, 7, "m", &infos, None, |_| Some(true));
        assert_eq!(pr.reached.len(), 3);
        assert_eq!(pr.verified_at.as_deref(), Some("t-us-prd"));
    }

    #[test]
    fn the_oldest_verified_freight_holding_the_merge_dates_the_ship() {
        let info = StageInfo {
            verified_at: Some("t3".into()),
            history: vec![("bbb".into(), "t2".into()), ("aaa".into(), "t1".into())],
            ..Default::default()
        };
        assert_eq!(first_verified(&info, |r| Some(r != "aaa")).as_deref(), Some("t2"));
        assert_eq!(first_verified(&info, |_| Some(false)).as_deref(), Some("t3"));
    }

    #[test]
    fn the_repos_own_image_names_the_revision() {
        // Shaped like the monolith freight: the app image, a shared sidecar
        // from another repo, and a schema image from the same repo built at
        // an older commit.
        let ann = |src: &str, rev: &str| json!({"tag": format!("1.0.0-{rev}"), "annotations": {
            "org.opencontainers.image.source": src,
            "org.opencontainers.image.revision": rev}});
        let item = json!({"images": [
            ann("https://github.com/o/sidecar", "9995248caf2d2c0fc6b3c9f883b66f6c1225926b"),
            ann("https://github.com/o/mono", "1f7d6a229ca9d74703e9333bebcac1ab8a17405b"),
            ann("https://github.com/o/mono", "627961576f2bf0a4a946c99cbb8431d1a2020c0d")]});
        assert_eq!(freight_revision(&item, Some("O/Mono")).as_deref(),
                   Some("1f7d6a229ca9d74703e9333bebcac1ab8a17405b"));
        assert_eq!(freight_revision(&item, None).as_deref(),
                   Some("9995248caf2d2c0fc6b3c9f883b66f6c1225926b"), "no repo: first image");
        assert_eq!(freight_revision(&item, Some("o/other")).as_deref(),
                   Some("9995248caf2d2c0fc6b3c9f883b66f6c1225926b"), "no match: first image");
    }

    #[test]
    fn a_regional_entry_carries_its_region() {
        let repo = KargoRepo { region: Some("US".into()), ..fub() };
        let pr = pr_stages(&repo, 7, "m", &HashMap::new(), None, |_| Some(true));
        assert_eq!(pr.region.as_deref(), Some("US"));
        let json = serde_json::to_value(&pr).unwrap();
        assert_eq!(json["region"], "US");
        let plain = serde_json::to_value(pr_stages(&fub(), 7, "m", &HashMap::new(), None, |_| None)).unwrap();
        assert!(plain.get("region").is_none(), "no region, no key: old files unchanged");
    }

    #[test]
    fn config_without_a_region_still_parses() {
        let c: KargoConfig = serde_json::from_value(json!({"enabled": true, "repos": [
            {"repo": "o/fub", "project": "p", "warehouse": "fub", "stages": ["us-dev"]},
            {"repo": "o/fub", "project": "p", "warehouse": "fub-uk", "stages": ["uk-dev"], "region": "UK"}]})).unwrap();
        assert_eq!(c.repos[0].region, None);
        assert_eq!(c.repos[1].region.as_deref(), Some("UK"));
    }

    #[test]
    fn a_stage_that_verified_the_merge_stays_reached_while_newer_freight_verifies() {
        // us-prd verified freight `old1` holding the merge; freight `new1`,
        // also holding it, is verifying now.  That is shipped, not deploying.
        let repo = fub();
        let mut infos: HashMap<String, StageInfo> = HashMap::new();
        for s in &repo.stages {
            infos.insert(repo.kargo_stage(s), StageInfo {
                revision: Some("new1".into()), verifying: true,
                history: vec![("old1".into(), format!("t-{s}"))], ..Default::default() });
        }
        let pr = pr_stages(&repo, 7, "m", &infos, None, |_| Some(true));
        assert_eq!(pr.reached.len(), 3);
        assert!(pr.verifying.is_empty() && pr.promoting.is_empty());
        assert_eq!(pr.verified_at.as_deref(), Some("t-us-prd"));
        // A merge only in the new freight is verifying, not reached.
        let pr = pr_stages(&repo, 7, "m", &infos, None, |rev| Some(rev == "new1"));
        assert!(pr.reached.is_empty());
        assert_eq!(pr.verifying.len(), 3);
    }

    #[test]
    fn freight_without_the_merge_verifying_is_not_this_prs_deploy() {
        let repo = fub();
        let infos: HashMap<String, StageInfo> = [(repo.kargo_stage("us-dev"), StageInfo {
            revision: Some("other".into()), verifying: true, ..Default::default() })]
            .into_iter().collect();
        let pr = pr_stages(&repo, 7, "m", &infos, None, |_| Some(false));
        assert!(pr.verifying.is_empty() && pr.promoting.is_empty() && pr.reached.is_empty());
    }

    #[test]
    fn manual_stages_come_from_the_promotion_policies() {
        let pc = json!({"spec": {"promotionPolicies": [
            {"stage": "fub-us-dev-deploy", "autoPromotionEnabled": true},
            {"stageSelector": {"name": "fub-us-stg-deploy"}, "autoPromotionEnabled": true},
            {"stage": "fub-us-prd-deploy"}]}});
        let auto = auto_stages(&pc);
        assert_eq!(auto.len(), 2);
        let pr = pr_stages(&fub(), 7, "m", &HashMap::new(), Some(&auto), |_| None);
        assert_eq!(pr.manual, Some(vec!["us-prd".to_string()]));
        let unknown = serde_json::to_value(pr_stages(&fub(), 7, "m", &HashMap::new(), None, |_| None)).unwrap();
        assert!(unknown.get("manual").is_none(), "policies unread: no claim either way");
        let all_auto: HashSet<String> = fub().stages.iter().map(|s| fub().kargo_stage(s)).collect();
        let known = serde_json::to_value(pr_stages(&fub(), 7, "m", &HashMap::new(), Some(&all_auto), |_| None)).unwrap();
        assert_eq!(known["manual"], json!([]), "known and none manual is an empty list");
    }

    #[test]
    fn compare_status_maps_to_containment() {
        assert_eq!(compare_contains("ahead"), Some(true));
        assert_eq!(compare_contains("identical"), Some(true));
        assert_eq!(compare_contains("behind"), Some(false));
        assert_eq!(compare_contains("diverged"), Some(false));
        assert_eq!(compare_contains(""), None);
    }

    #[test]
    fn merged_prs_need_a_merge_commit() {
        let wip = json!({"repos": [{"repo": "o/fub", "prs": [
            {"number": 1, "state": "MERGED", "merge_commit": "abc"},
            {"number": 2, "state": "OPEN"},
            {"number": 3, "state": "MERGED"}]}]});
        assert_eq!(merged_prs_from(&wip), vec![("o/fub".to_string(), 1, "abc".to_string(), None)]);
    }

    fn entry(number: u64, reached: &[&str], as_of: Option<&str>) -> KargoPr {
        KargoPr {
            reached: reached.iter().map(|s| s.to_string()).collect(),
            as_of: as_of.map(|t| t.parse().unwrap()),
            ..pr_stages(&fub(), number, "m", &HashMap::new(), None, |_| None)
        }
    }

    fn file(prs: Vec<KargoPr>, stale: Vec<KargoStale>) -> KargoStagesFile {
        KargoStagesFile { updated: Utc::now(), repos: vec!["o/fub".into()], prs, errors: vec![], stale }
    }

    #[test]
    fn an_expired_login_is_auth_and_says_what_to_run() {
        // The text the CLI printed on 2026-11-24 while every poll failed.
        let raw = "kargo get projectconfig --project p -o json: Error: get client from config: \
                   error refreshing token: error refreshing token; please use `kargo login` to re-authenticate";
        assert_eq!(classify_failure(raw), KargoFailure::Auth);
        assert_eq!(classify_failure("rpc error: code = Unauthenticated desc = 401"), KargoFailure::Auth);
        assert!(failure_message(KargoFailure::Auth, raw).starts_with("login expired, run `kargo login --sso`"));
    }

    #[test]
    fn timeouts_and_connection_errors_are_retried_others_are_not() {
        assert_eq!(classify_failure("kargo timed out after 60s"), KargoFailure::Transient);
        assert_eq!(classify_failure("dial tcp: lookup kargo.example.com: no such host"), KargoFailure::Transient);
        assert_eq!(classify_failure("code = Unavailable desc = 503"), KargoFailure::Transient);
        assert_eq!(classify_failure("stage \"x\" not found"), KargoFailure::Other);
        assert_eq!(failure_message(KargoFailure::Other, "boom"), "boom");
        assert_eq!(KARGO_RETRY_DELAYS.len(), 2, "two retries, then give up until the next poll");
    }

    #[test]
    fn a_compare_github_refused_is_a_no_and_an_unreachable_one_unknown() {
        assert_eq!(compare_error_answer("gh: Not Found (HTTP 404)"), Some(false));
        assert_eq!(compare_error_answer("gh: No common ancestor (HTTP 422)"), Some(false));
        assert_eq!(compare_error_answer("gh timeout after 30s: gh api ..."), None);
    }

    #[test]
    fn a_failed_poll_keeps_the_last_good_stages_marked_stale() {
        let now: DateTime<Utc> = "2026-11-24T03:00:00Z".parse().unwrap();
        let shipped = entry(545, &["us-dev", "us-stg", "us-prd"], Some("2026-11-24T01:00:00Z"));
        let previous = file(vec![shipped.clone()], vec![]);
        let fresh = entry(545, &[], None);
        let kept = settle_entry(fresh.clone(), false, Some(&previous), now);
        assert_eq!(kept.reached, shipped.reached, "never written over with an empty list");
        assert!(kept.stale);
        assert_eq!(kept.as_of, shipped.as_of, "the age is the last good read's");
        let unknown = settle_entry(entry(9, &["us-dev"], None), false, Some(&previous), now);
        assert!(unknown.stale && unknown.reached.is_empty() && unknown.as_of.is_none(),
                "no earlier answer: unknown, not a claim");
        let good = settle_entry(fresh, true, Some(&previous), now);
        assert!(!good.stale);
        assert_eq!(good.as_of, Some(now));
    }

    #[test]
    fn a_regional_entry_is_carried_only_into_its_own_region() {
        let now = Utc::now();
        let uk = KargoPr { region: Some("UK".into()), ..entry(1, &["uk-dev"], Some("2026-11-24T01:00:00Z")) };
        let previous = file(vec![uk], vec![]);
        let us = KargoPr { region: Some("US".into()), ..entry(1, &[], None) };
        assert!(settle_entry(us, false, Some(&previous), now).reached.is_empty());
    }

    #[test]
    fn a_stale_repo_keeps_when_it_started_failing_and_when_it_last_worked() {
        let t = |s: &str| -> DateTime<Utc> { s.parse().unwrap() };
        let failed: HashMap<String, String> = [("o/fub".to_string(), "login expired".to_string())].into();
        let previous = file(vec![entry(1, &[], Some("2026-11-24T01:00:00Z")),
                                 entry(2, &[], Some("2026-11-24T01:05:00Z"))], vec![]);
        let first = stale_repos(&failed, Some(&previous), t("2026-11-24T02:00:00Z"));
        assert_eq!(first, vec![KargoStale { repo: "o/fub".into(), error: "login expired".into(),
                                            since: t("2026-11-24T02:00:00Z"),
                                            last_ok: Some(t("2026-11-24T01:05:00Z")) }]);
        let carried = file(vec![KargoPr { stale: true, ..entry(1, &[], Some("2026-11-24T01:05:00Z")) }], first);
        let later = stale_repos(&failed, Some(&carried), t("2026-11-24T03:00:00Z"));
        assert_eq!(later[0].since, t("2026-11-24T02:00:00Z"), "since does not move while it keeps failing");
        assert!(stale_repos(&HashMap::new(), Some(&carried), Utc::now()).is_empty());
    }

    #[test]
    fn files_written_before_staleness_still_parse_and_new_fields_stay_quiet() {
        let old = r#"{"updated": "2026-11-24T03:18:02Z", "repos": ["o/fub"], "prs": [
            {"repo": "o/fub", "number": 1, "merge_commit": "m", "stages": ["us-dev"], "reached": []}]}"#;
        let f: KargoStagesFile = serde_json::from_str(old).unwrap();
        assert!(!f.prs[0].stale && f.prs[0].as_of.is_none() && f.stale.is_empty());
        let json = serde_json::to_value(entry(1, &[], None)).unwrap();
        assert!(json.get("stale").is_none() && json.get("as_of").is_none());
    }

    #[test]
    fn globs_match_segments_and_runs_of_directories() {
        assert!(glob_match("cmd/**", "cmd/go-links/main.go"));
        assert!(glob_match("go.*", "go.sum"));
        assert!(!glob_match("go.*", "cmd/go.mod"), "a bare glob is anchored at the root");
        assert!(glob_match("**/*.md", "README.md"));
        assert!(glob_match("**/*.md", "docs/a/b.md"));
        assert!(glob_match("Dockerfile", "Dockerfile"));
        assert!(!glob_match("Dockerfile", "nix/Dockerfile"));
        assert!(glob_match("helm/**", "helm/templates/x.yaml"));
        assert!(glob_match("LICENSE*", "LICENSE"));
        assert!(glob_match("a?c", "abc") && !glob_match("a?c", "a/c"));
    }

    #[test]
    fn a_nix_flake_pr_changes_nothing_a_go_service_deploys() {
        // nc-helix/go-links#7, against its build workflow's path filter.
        let repo = KargoRepo {
            runtime_paths: Some(["cmd/**", "go.*", "Dockerfile", ".dockerignore", "helm/**",
                                 "justfile", ".github/workflows/build-and-push.yaml"]
                                .map(String::from).to_vec()),
            ..fub()
        };
        let files: Vec<String> = [".github/workflows/nix.yaml", "README.md", "flake.lock", "flake.nix",
                                  "nix/darwin.nix", "nix/nixos.nix"].map(String::from).to_vec();
        assert_eq!(no_runtime_change(&repo, Some(&files), "r").as_deref(), Some("r"));
        let mut code = files.clone();
        code.push("cmd/go-links/main.go".into());
        assert_eq!(no_runtime_change(&repo, Some(&code), "r"), None);
        assert_eq!(no_runtime_change(&repo, Some(&[]), "r"), None, "no files listed is no proof");
        assert_eq!(no_runtime_change(&repo, None, "r"), None);
    }

    #[test]
    fn without_runtime_paths_only_docs_and_metadata_are_not_runtime() {
        let repo = fub();
        for f in ["docs/x.md", "specs/a/plan.md", ".specify/memory.md", "AGENTS.md", "LICENSE",
                  ".github/CODEOWNERS", ".gitignore"] {
            assert!(!is_runtime(&repo, f), "{f}");
        }
        for f in ["flake.nix", "src/main.rs", ".github/workflows/build.yaml", "Dockerfile"] {
            assert!(is_runtime(&repo, f), "{f}: unknown files count, conservatively");
        }
    }

    #[test]
    fn a_no_deploy_reason_is_written_and_old_files_parse_without_one() {
        let json = serde_json::to_value(KargoPr { no_deploy: Some("no runtime files changed".into()),
                                                  ..entry(1, &[], None) }).unwrap();
        assert_eq!(json["no_deploy"], "no runtime files changed");
        assert!(serde_json::to_value(entry(1, &[], None)).unwrap().get("no_deploy").is_none());
        let c: KargoConfig = serde_json::from_value(json!({"repos": []})).unwrap();
        assert_eq!(c.no_deploy_after_hours, 6);
    }
}
