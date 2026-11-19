// Chores adapter: pending Taskwarrior tasks for the sidebar's Tasks section.
//
// Runs `task <filter> export` read-only (gc, hooks and confirmations off, so
// a poll never renumbers or rewrites anything) and writes task-chores.json.
// Projects in `exclude_projects`, and their sub-projects, are dropped: the
// perf-hitch auto-filer files its findings as tasks, and a hundred of them
// would bury the handful a human wrote.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::path::PathBuf;
use std::process::Stdio;
use std::time::Duration;
use tokio::process::Command;

use crate::{atomic_write_json, update_meta, AdapterStatus, SharedMeta};

const TASK_TIMEOUT: Duration = Duration::from_secs(30);

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(default)]
pub struct ChoresConfig {
    pub enabled: bool,
    pub interval_secs: u64,
    /// Taskwarrior filter, e.g. `+chore status:pending`.
    pub filter: String,
    pub exclude_projects: Vec<String>,
}

impl Default for ChoresConfig {
    fn default() -> Self {
        Self {
            enabled: false,
            interval_secs: 120,
            filter: "+chore status:pending".into(),
            exclude_projects: vec!["decknix.perf".into()],
        }
    }
}

#[derive(Debug, Serialize, Deserialize, PartialEq)]
pub struct Chore {
    pub uuid: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub id: Option<u64>,
    pub description: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub project: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub tags: Vec<String>,
    pub urgency: f64,
    /// Set while the task is started (`task start`).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub start: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub due: Option<String>,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct ChoresFile {
    pub updated: DateTime<Utc>,
    pub items: Vec<Chore>,
}

fn excluded(project: Option<&str>, exclude: &[String]) -> bool {
    project.is_some_and(|p| exclude.iter().any(|x| p == x || p.starts_with(&format!("{x}."))))
}

/// Chores from `task export` JSON, most urgent first.
pub fn parse_export(json: &str, exclude: &[String]) -> Result<Vec<Chore>, String> {
    let v: Value = serde_json::from_str(json).map_err(|e| format!("task export json: {e}"))?;
    let mut out: Vec<Chore> = v.as_array().into_iter().flatten()
        .filter(|t| !excluded(t.get("project").and_then(Value::as_str), exclude))
        .filter_map(|t| Some(Chore {
            uuid: t.get("uuid")?.as_str()?.to_string(),
            id: t.get("id").and_then(Value::as_u64).filter(|i| *i > 0),
            description: t.get("description")?.as_str()?.to_string(),
            project: t.get("project").and_then(Value::as_str).map(str::to_string),
            tags: t.get("tags").and_then(Value::as_array).into_iter().flatten()
                .filter_map(|s| s.as_str().map(str::to_string)).collect(),
            urgency: t.get("urgency").and_then(Value::as_f64).unwrap_or(0.0),
            start: t.get("start").and_then(Value::as_str).map(str::to_string),
            due: t.get("due").and_then(Value::as_str).map(str::to_string),
        }))
        .collect();
    out.sort_by(|a, b| b.start.is_some().cmp(&a.start.is_some())
        .then(b.urgency.partial_cmp(&a.urgency).unwrap_or(std::cmp::Ordering::Equal)));
    Ok(out)
}

pub async fn poll_chores(config: &ChoresConfig) -> Result<ChoresFile, String> {
    let mut args = vec!["rc.gc=off", "rc.hooks=off", "rc.confirmation=off", "rc.verbose=nothing"];
    args.extend(config.filter.split_whitespace());
    args.push("export");
    let child = Command::new("task")
        .args(&args)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true)
        .spawn()
        .map_err(|e| format!("task not runnable: {e}"))?;
    let out = tokio::time::timeout(TASK_TIMEOUT, child.wait_with_output())
        .await
        .map_err(|_| "task export timed out".to_string())?
        .map_err(|e| format!("task: {e}"))?;
    if !out.status.success() {
        return Err(format!("task export: {}", String::from_utf8_lossy(&out.stderr).trim()));
    }
    Ok(ChoresFile {
        updated: Utc::now(),
        items: parse_export(&String::from_utf8_lossy(&out.stdout), &config.exclude_projects)?,
    })
}

pub async fn run_chores_adapter(config: ChoresConfig, dir: PathBuf, meta: SharedMeta, once: bool) {
    let interval = Duration::from_secs(config.interval_secs.max(30));
    loop {
        let last_error = match poll_chores(&config).await {
            Ok(data) => match atomic_write_json(&dir, "task-chores.json", &data).await {
                Ok(()) => { eprintln!("hub: task-chores: {} items", data.items.len()); None }
                Err(e) => Some(format!("write error: {e}")),
            },
            Err(e) => { eprintln!("hub: task-chores error: {e}"); Some(e) }
        };
        update_meta(&meta, AdapterStatus {
            name: "task-chores".into(),
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

    const EXPORT: &str = r#"[
      {"id": 3, "uuid": "a", "description": "renew cert", "project": "home", "tags": ["chore"], "urgency": 4.2},
      {"id": 4, "uuid": "b", "description": "perf hitch", "project": "decknix.perf", "urgency": 9.0},
      {"id": 5, "uuid": "c", "description": "sub perf", "project": "decknix.perf.gc", "urgency": 9.0},
      {"id": 6, "uuid": "d", "description": "decknix itself", "project": "decknix", "urgency": 1.0},
      {"id": 7, "uuid": "e", "description": "started one", "urgency": 0.5, "start": "20261119T000000Z"},
      {"uuid": "f"}
    ]"#;

    #[test]
    fn excluded_projects_and_their_children_are_dropped() {
        let items = parse_export(EXPORT, &["decknix.perf".into()]).unwrap();
        let uuids: Vec<&str> = items.iter().map(|c| c.uuid.as_str()).collect();
        assert_eq!(uuids, vec!["e", "a", "d"], "started first, then by urgency");
    }

    #[test]
    fn fields_carry_through() {
        let items = parse_export(EXPORT, &[]).unwrap();
        let a = items.iter().find(|c| c.uuid == "a").unwrap();
        assert_eq!(a.id, Some(3));
        assert_eq!(a.project.as_deref(), Some("home"));
        assert_eq!(a.tags, vec!["chore"]);
    }

    #[test]
    fn bad_json_is_an_error() {
        assert!(parse_export("nope", &[]).is_err());
        assert!(parse_export("[]", &[]).unwrap().is_empty());
    }
}
