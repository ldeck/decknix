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
// Writes kargo-stages.json.  A missing or unauthenticated `kargo` degrades to
// an `errors` entry; the repo list is still written so the sidebar knows
// those repos ship through Kargo and shows their merges as pending.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::OnceLock;
use std::time::Duration;
use tokio::process::Command;
use tokio::sync::RwLock;

use crate::{atomic_write_json, update_meta, AdapterStatus, SharedMeta};

const KARGO_TIMEOUT: Duration = Duration::from_secs(60);

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(default)]
pub struct KargoConfig {
    pub enabled: bool,
    pub interval_secs: u64,
    pub repos: Vec<KargoRepo>,
}

impl Default for KargoConfig {
    fn default() -> Self {
        Self { enabled: false, interval_secs: 300, repos: Vec::new() }
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
}

#[derive(Debug, Serialize, Deserialize, PartialEq)]
pub struct KargoPr {
    pub repo: String,
    pub number: u64,
    pub merge_commit: String,
    pub stages: Vec<String>,
    /// Stages whose current freight contains the merge and passed verification.
    pub reached: Vec<String>,
    /// Stages promoting or verifying freight right now.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub promoting: Vec<String>,
    /// Stages whose last promotion or verification failed.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub failed: Vec<String>,
    /// When the last stage verified the freight holding the merge.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub verified_at: Option<String>,
}

/// What one Kargo stage says about its current freight.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct StageInfo {
    pub revision: Option<String>,
    pub verified: bool,
    pub verified_at: Option<String>,
    pub promoting: bool,
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

/// The git revision a freight item was built from: the OCI revision
/// annotation, else a sha suffix on an image tag or chart version
/// (`2749.0.0-<sha>`, `12.0.0-r123.<sha>`), else a git commit.
pub fn freight_revision(item: &Value) -> Option<String> {
    let images = item.get("images").and_then(Value::as_array);
    if let Some(rev) = images.into_iter().flatten()
        .filter_map(|i| i.pointer("/annotations/org.opencontainers.image.revision"))
        .filter_map(Value::as_str)
        .find(|s| is_sha(s)) {
        return Some(rev.to_string());
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

/// Read a Stage object.
pub fn stage_info(stage: &Value) -> StageInfo {
    let status = stage.get("status").unwrap_or(&Value::Null);
    let current = status.pointer("/freightHistory/0");
    let revision = current
        .and_then(|c| c.get("items")).and_then(Value::as_object)
        .and_then(|items| items.values().find_map(freight_revision));
    let verification = current
        .and_then(|c| c.pointer("/verificationHistory/0"));
    let vphase = verification.and_then(|v| v.get("phase")).and_then(Value::as_str);
    let promotion_phase = status.pointer("/lastPromotion/status/phase").and_then(Value::as_str);
    let promoting = status.pointer("/currentPromotion/name").and_then(Value::as_str)
        .map(|n| !n.is_empty()).unwrap_or(false)
        || matches!(vphase, Some("Running") | Some("Pending"));
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
                .and_then(|items| items.values().find_map(freight_revision))?;
            let v = h.pointer("/verificationHistory/0")?;
            (v.get("phase").and_then(Value::as_str) == Some("Successful")).then_some(())?;
            Some((rev, v.get("finishTime").and_then(Value::as_str)?.to_string()))
        })
        .collect();
    StageInfo { revision, verified, verified_at, promoting, failed, history }
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

/// Decide one PR's stages from each stage's info and a containment oracle.
pub fn pr_stages<F>(repo: &KargoRepo, number: u64, merge: &str,
                    infos: &HashMap<String, StageInfo>, mut contains: F) -> KargoPr
where
    F: FnMut(&str) -> Option<bool>,
{
    let mut reached = Vec::new();
    let mut promoting = Vec::new();
    let mut failed = Vec::new();
    let mut verified_at = None;
    for stage in &repo.stages {
        let Some(info) = infos.get(&repo.kargo_stage(stage)) else { continue };
        let holds = info.revision.as_deref().and_then(&mut contains).unwrap_or(false);
        if holds && info.verified {
            reached.push(stage.clone());
            verified_at = info.verified_at.clone();
        } else if info.failed {
            failed.push(stage.clone());
        } else if info.promoting || holds {
            promoting.push(stage.clone());
        }
    }
    let all = reached.len() == repo.stages.len();
    KargoPr {
        repo: repo.repo.clone(),
        number,
        merge_commit: merge.to_string(),
        stages: repo.stages.clone(),
        reached,
        promoting,
        failed,
        verified_at: if all { verified_at } else { None },
    }
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
    let out = crate::gh_json(&["api", &path, "--jq", ".status"]).await.ok()?;
    let answer = compare_contains(out.trim())?;
    contains_cache().write().await.insert(key, answer);
    Some(answer)
}

async fn kargo_json(args: &[String]) -> Result<Value, String> {
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

/// My merged PRs with a merge commit, from the WIP adapter's output.
fn merged_prs(dir: &Path) -> Vec<(String, u64, String)> {
    let Ok(text) = std::fs::read_to_string(dir.join("github-wip.json")) else { return Vec::new() };
    let Ok(v) = serde_json::from_str::<Value>(&text) else { return Vec::new() };
    merged_prs_from(&v)
}

pub fn merged_prs_from(wip: &Value) -> Vec<(String, u64, String)> {
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
                out.push((name.to_string(), number, merge.to_string()));
            }
        }
    }
    out
}

pub async fn poll_kargo(config: &KargoConfig, dir: &Path) -> KargoStagesFile {
    let mut errors = Vec::new();
    let prs_in = merged_prs(dir);
    let mut infos: HashMap<String, StageInfo> = HashMap::new();

    let mut by_project: HashMap<&str, Vec<String>> = HashMap::new();
    for r in &config.repos {
        if !prs_in.iter().any(|(repo, _, _)| repo.eq_ignore_ascii_case(&r.repo)) {
            continue;
        }
        by_project.entry(r.project.as_str()).or_default()
            .extend(r.stages.iter().map(|s| r.kargo_stage(s)));
    }
    for (project, names) in by_project {
        let mut args = vec!["get".to_string(), "stages".into(), "--project".into(), project.into()];
        args.extend(names);
        args.extend(["-o".to_string(), "json".into()]);
        match kargo_json(&args).await {
            Ok(v) => for stage in list_items(&v) {
                if let Some(name) = stage.pointer("/metadata/name").and_then(Value::as_str) {
                    infos.insert(name.to_string(), stage_info(stage));
                }
            },
            Err(e) => errors.push(e),
        }
    }

    let mut prs = Vec::new();
    for (repo_name, number, merge) in &prs_in {
        let Some(repo) = config.repos.iter().find(|r| r.repo.eq_ignore_ascii_case(repo_name)) else { continue };
        let mut answers: HashMap<String, Option<bool>> = HashMap::new();
        for stage in &repo.stages {
            if let Some(rev) = infos.get(&repo.kargo_stage(stage)).and_then(|i| i.revision.clone()) {
                if !answers.contains_key(&rev) {
                    answers.insert(rev.clone(), revision_contains(&repo.repo, merge, &rev).await);
                }
            }
        }
        let mut pr = pr_stages(repo, *number, merge, &infos, |rev| answers.get(rev).copied().flatten());
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
        prs.push(pr);
    }

    KargoStagesFile {
        updated: Utc::now(),
        repos: config.repos.iter().map(|r| r.repo.clone()).collect(),
        prs,
        errors,
    }
}

pub async fn run_kargo_adapter(config: KargoConfig, dir: PathBuf, meta: SharedMeta, once: bool) {
    let interval = Duration::from_secs(config.interval_secs.max(30));
    loop {
        let data = poll_kargo(&config, &dir).await;
        let last_error = match atomic_write_json(&dir, "kargo-stages.json", &data).await {
            Err(e) => Some(format!("write error: {e}")),
            Ok(()) => data.errors.first().cloned(),
        };
        eprintln!("hub: kargo-stages: {} PRs, {} errors", data.prs.len(), data.errors.len());
        update_meta(&meta, AdapterStatus {
            name: "kargo-stages".into(),
            last_poll: Some(Utc::now()),
            ok: last_error.is_none(),
            last_error,
        }, &dir).await;
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
            stage_pattern: None,
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
            {"org.opencontainers.image.revision": sha}}]})).as_deref(), Some(sha));
        assert_eq!(freight_revision(&json!({"images": [{"tag": format!("2749.0.0-{sha}")}]})).as_deref(), Some(sha));
        assert_eq!(freight_revision(&json!({"charts": [{"version": "12.0.0-r123.abc1234"}]})).as_deref(), Some("abc1234"));
        assert_eq!(freight_revision(&json!({"commits": [{"id": sha}]})).as_deref(), Some(sha));
        assert_eq!(freight_revision(&json!({"images": [{"tag": "0.398.0"}]})), None);
    }

    #[test]
    fn stage_info_reads_verification_and_promotion() {
        let i = stage_info(&stage("fub-us-dev-deploy", "abcdef1", Some("Successful"), ""));
        assert_eq!(i.revision.as_deref(), Some("abcdef1"));
        assert!(i.verified && !i.promoting && !i.failed);
        assert_eq!(i.verified_at.as_deref(), Some("2026-11-18T02:21:45Z"));
        let i = stage_info(&stage("x", "abcdef1", Some("Running"), ""));
        assert!(!i.verified && i.promoting);
        let i = stage_info(&stage("x", "abcdef1", Some("Failed"), ""));
        assert!(i.failed && !i.verified);
        let i = stage_info(&stage("x", "abcdef1", None, "promo-1"));
        assert!(i.verified && i.promoting, "no verification: promotion verifies");
        assert_eq!(i.verified_at.as_deref(), Some("2026-11-18T02:15:48Z"));
    }

    #[test]
    fn the_real_fixture_parses() {
        let v: Value = serde_json::from_str(include_str!("../tests/fixtures/kargo-stages.json")).unwrap();
        let items = list_items(&v);
        assert_eq!(items.len(), 3);
        let i = stage_info(items[0]);
        assert_eq!(i.revision.as_deref(), Some("44b00c4e7c22cf1b22e72534b94a393603e5120f"));
        assert!(i.verified);
    }

    #[test]
    fn a_pr_reaches_the_stages_whose_freight_contains_it() {
        let repo = fub();
        let infos: HashMap<String, StageInfo> = [
            ("fub-us-dev-deploy", stage_info(&stage("", "new", Some("Successful"), ""))),
            ("fub-us-stg-deploy", stage_info(&stage("", "new", Some("Running"), ""))),
            ("fub-us-prd-deploy", stage_info(&stage("", "old", Some("Successful"), ""))),
        ].into_iter().map(|(k, v)| (k.to_string(), v)).collect();
        // The fixture's revisions are not hex, so supply them directly.
        let infos: HashMap<String, StageInfo> = infos.into_iter().map(|(k, mut v)| {
            v.revision = Some(if k.contains("prd") { "0ld0ld0".into() } else { "ae1ae1ae".into() });
            (k, v)
        }).collect();
        let pr = pr_stages(&repo, 7, "m", &infos, |rev| Some(rev == "ae1ae1ae"));
        assert_eq!(pr.reached, vec!["us-dev".to_string()]);
        assert_eq!(pr.promoting, vec!["us-stg".to_string()]);
        assert!(pr.failed.is_empty());
        assert_eq!(pr.verified_at, None, "only set once every stage is reached");
        let all = pr_stages(&repo, 7, "m", &infos, |_| Some(true));
        assert_eq!(all.reached.len(), 2, "stg is still verifying");
    }

    #[test]
    fn every_stage_reached_records_when_the_last_verified() {
        let repo = fub();
        let infos: HashMap<String, StageInfo> = repo.stages.iter().map(|s| {
            (repo.kargo_stage(s), StageInfo { revision: Some("abcdef1".into()), verified: true,
                                              verified_at: Some(format!("t-{s}")), ..Default::default() })
        }).collect();
        let pr = pr_stages(&repo, 7, "m", &infos, |_| Some(true));
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
        assert_eq!(merged_prs_from(&wip), vec![("o/fub".to_string(), 1, "abc".to_string())]);
    }
}
