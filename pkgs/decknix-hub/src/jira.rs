// Jira adapter — polls assigned tasks via REST API
//
// Auth: email + API token (Basic auth).
// Writes jira-tasks.json to hub data directory.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use std::time::Duration;

use crate::{atomic_write_json, update_meta, AdapterStatus, SharedMeta};

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(default)]
pub struct JiraConfig {
    pub enabled: bool,
    pub interval_secs: u64,
    /// Jira base URL (e.g. "https://myorg.atlassian.net")
    pub base_url: String,
    /// User email for Basic auth
    pub email: String,
    /// Path to file containing the API token (one line, trimmed)
    pub api_token_file: String,
    /// Legacy single project key; used only when `projects` is empty.
    pub project: String,
    /// Project keys whose issues the Tasks section lists.  Overridden at
    /// runtime by `[hub.jira] projects` in `settings_file`, re-read on
    /// every poll, so a change applies without a rebuild or restart.
    pub projects: Vec<String>,
    /// settings.toml holding the runtime override (default
    /// ~/.config/decknix/settings.toml).
    pub settings_file: Option<String>,
    /// Also list unassigned To Do issues in open sprints.
    pub pick_up: bool,
    /// Statuses to include
    pub statuses: Vec<String>,
    /// Max results per poll
    pub max_results: u32,
}

impl Default for JiraConfig {
    fn default() -> Self {
        Self {
            enabled: false,
            interval_secs: 120,
            base_url: String::new(),
            email: String::new(),
            api_token_file: String::new(),
            project: String::new(),
            projects: Vec::new(),
            settings_file: None,
            pick_up: true,
            statuses: vec![
                "Ready".into(),
                "In Progress".into(),
                "Blocked".into(),
                "Code Review".into(),
            ],
            max_results: 50,
        }
    }
}

// ---------------------------------------------------------------------------
// Data models — written to jira-tasks.json
// ---------------------------------------------------------------------------

#[derive(Debug, Serialize, Deserialize)]
pub struct JiraTask {
    pub key: String,         // e.g. "MAIN-8012"
    pub summary: String,
    pub status: String,      // e.g. "In Progress"
    pub status_category: String, // "new", "indeterminate", "done"
    pub priority: Option<String>,
    pub assignee: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub parent_key: Option<String>,   // Epic or parent issue
    #[serde(skip_serializing_if = "Option::is_none")]
    pub parent_summary: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sprint: Option<String>,
    pub issue_type: String,
    pub url: String,
    pub updated: DateTime<Utc>,
    pub created: DateTime<Utc>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub labels: Option<Vec<String>>,
    /// Sub-tasks (child issues) — used by the progress data layer to build
    /// hierarchical task trees.  Always present (possibly empty) so consumers
    /// can iterate without nil-checks.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub subtasks: Vec<JiraTaskRef>,
    /// Issue links — "blocks" / "is blocked by" / "relates to" / etc.
    /// Direction is "inward" (this issue is the *target* of the link, e.g.
    /// "is blocked by X") or "outward" (this issue is the *source*, e.g.
    /// "blocks Y").  Empty when the issue has no links.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub links: Vec<JiraLink>,
}

/// Lightweight reference to another Jira issue.  Used both for sub-tasks and
/// inside `JiraLink` for the linked issue on the other side.
#[derive(Debug, Serialize, Deserialize)]
pub struct JiraTaskRef {
    pub key: String,
    pub summary: String,
    pub status: String,
    pub status_category: String,
    pub url: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub issue_type: Option<String>,
}

/// A directed link between two issues.  `direction` is "inward" (this issue
/// is the target — e.g. "is blocked by X") or "outward" (this issue is the
/// source — e.g. "blocks Y").  `link_type` is the human-readable Jira link
/// type name (e.g. "Blocks", "Relates", "Duplicate").
#[derive(Debug, Serialize, Deserialize)]
pub struct JiraLink {
    pub direction: String,
    pub link_type: String,
    pub other: JiraTaskRef,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct JiraTasksFile {
    pub updated: DateTime<Utc>,
    /// Issues assigned to me that are not Done.
    pub items: Vec<JiraTask>,
    /// Unassigned To Do issues in an open sprint of `projects`.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub pick_up: Vec<JiraTask>,
    /// The project keys this poll used.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub projects: Vec<String>,
    /// Queries that failed without failing the poll (pick-up).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub errors: Vec<String>,
}

// ---------------------------------------------------------------------------
// Jira REST API response structs
// ---------------------------------------------------------------------------

#[derive(Debug, Deserialize)]
struct JiraSearchResponse {
    #[serde(default)]
    issues: Vec<JiraIssue>,
    /// Enhanced-search pagination cursor. Absent/empty on the final page.
    /// Replaces the old offset paging (`startAt`/`total`), which the
    /// `/search/jql` endpoint dropped.
    #[serde(rename = "nextPageToken", default)]
    next_page_token: Option<String>,
    /// Some tenants also flag the final page explicitly.
    #[serde(rename = "isLast", default)]
    is_last: Option<bool>,
}

#[derive(Debug, Deserialize)]
struct JiraIssue {
    key: String,
    fields: JiraFields,
    #[serde(rename = "self")]
    self_url: Option<String>,
}

#[derive(Debug, Deserialize)]
struct JiraFields {
    #[serde(default)]
    summary: String,
    status: JiraStatus,
    priority: Option<JiraPriority>,
    assignee: Option<JiraUser>,
    parent: Option<JiraParent>,
    issuetype: JiraIssueType,
    // Absent on the issues nested in `subtasks`, which made a whole page
    // undecodable as soon as any issue had a sub-task.
    #[serde(default)]
    updated: String,
    #[serde(default)]
    created: String,
    #[serde(default)]
    labels: Vec<String>,
    /// Sub-tasks attached to this issue.  Jira returns these as full issue
    /// objects when the `subtasks` field is requested, so we reuse `JiraIssue`
    /// for the deserialization.
    #[serde(default)]
    subtasks: Vec<JiraIssue>,
    /// Inward / outward links to other issues.  Empty when the issue has no
    /// links or when the field wasn't requested.
    #[serde(rename = "issuelinks", default)]
    issue_links: Vec<JiraIssueLink>,
    // Sprint comes from customfield — we'll extract from the API response
}

#[derive(Debug, Deserialize)]
struct JiraStatus {
    name: String,
    #[serde(rename = "statusCategory")]
    status_category: Option<JiraStatusCategory>,
}

#[derive(Debug, Deserialize)]
struct JiraStatusCategory {
    key: String, // "new", "indeterminate", "done"
}

#[derive(Debug, Deserialize)]
struct JiraPriority {
    name: String,
}

#[derive(Debug, Deserialize)]
struct JiraUser {
    #[serde(rename = "displayName")]
    display_name: Option<String>,
}

#[derive(Debug, Deserialize)]
struct JiraParent {
    key: String,
    fields: Option<JiraParentFields>,
}

#[derive(Debug, Deserialize)]
struct JiraParentFields {
    summary: Option<String>,
}

#[derive(Debug, Deserialize)]
struct JiraIssueType {
    name: String,
}

/// A Jira issue link as returned by the REST API.  Either `inwardIssue` or
/// `outwardIssue` is set (never both); the missing side is the issue we're
/// fetching.
#[derive(Debug, Deserialize)]
struct JiraIssueLink {
    #[serde(rename = "type")]
    link_type: JiraLinkType,
    #[serde(rename = "inwardIssue")]
    inward_issue: Option<JiraLinkedIssue>,
    #[serde(rename = "outwardIssue")]
    outward_issue: Option<JiraLinkedIssue>,
}

#[derive(Debug, Deserialize)]
struct JiraLinkType {
    name: String,
}

/// A linked-issue stub returned inside an issue link.  Carries enough info
/// to render a reference without a follow-up fetch.
#[derive(Debug, Deserialize)]
struct JiraLinkedIssue {
    key: String,
    fields: Option<JiraLinkedIssueFields>,
}

#[derive(Debug, Deserialize)]
struct JiraLinkedIssueFields {
    summary: Option<String>,
    status: Option<JiraStatus>,
    issuetype: Option<JiraIssueType>,
}

// ---------------------------------------------------------------------------
// Read API token from file
// ---------------------------------------------------------------------------

fn read_api_token(path: &str) -> Result<String, String> {
    // Expand ~ to home dir
    let expanded = if path.starts_with("~/") {
        dirs::home_dir()
            .map(|h| h.join(&path[2..]))
            .unwrap_or_else(|| PathBuf::from(path))
    } else {
        PathBuf::from(path)
    };
    std::fs::read_to_string(&expanded)
        .map(|s| s.trim().to_string())
        .map_err(|e| format!("read token file {}: {e}", expanded.display()))
}

// ---------------------------------------------------------------------------
// Polling
// ---------------------------------------------------------------------------

/// Build the JQL query from config.
fn build_jql(config: &JiraConfig) -> String {
    let status_list = config.statuses
        .iter()
        .map(|s| format!("\"{}\"", s))
        .collect::<Vec<_>>()
        .join(", ");
    let project_clause = if config.project.is_empty() {
        String::new()
    } else {
        format!("project = {} AND ", config.project)
    };
    format!(
        "{}assignee = currentUser() AND status IN ({}) ORDER BY priority ASC, updated DESC",
        project_clause, status_list
    )
}

/// The project keys to query: `[hub.jira] projects` in SETTINGS (TOML text)
/// when present, else the configured list, else the legacy single project.
pub fn effective_projects(config: &JiraConfig, settings: Option<&str>) -> Vec<String> {
    let from_settings = settings
        .and_then(|t| t.parse::<toml::Table>().ok())
        .and_then(|t| t.get("hub")?.get("jira")?.get("projects")?.as_array().cloned())
        .map(|a| a.iter().filter_map(|v| v.as_str().map(normalise_key)).filter(|k| !k.is_empty()).collect::<Vec<_>>());
    match from_settings {
        Some(p) => p,
        None if !config.projects.is_empty() => config.projects.iter().map(|k| normalise_key(k)).collect(),
        None if !config.project.is_empty() => vec![normalise_key(&config.project)],
        None => Vec::new(),
    }
}

fn normalise_key(k: &str) -> String {
    k.trim().to_ascii_uppercase().chars().filter(|c| c.is_ascii_alphanumeric() || *c == '_').collect()
}

fn project_clause(projects: &[String]) -> String {
    format!("project in ({})", projects.join(", "))
}

/// Assigned to me and not Done, in PROJECTS (all projects when empty).
pub fn in_progress_jql(projects: &[String]) -> String {
    let scope = if projects.is_empty() { String::new() } else { format!("{} AND ", project_clause(projects)) };
    format!("{scope}assignee = currentUser() AND statusCategory != Done ORDER BY updated DESC")
}

/// Unassigned To Do issues in an open sprint of PROJECTS.  A project with no
/// sprints simply contributes nothing.
pub fn pick_up_jql(projects: &[String]) -> String {
    format!("{} AND assignee is EMPTY AND statusCategory = \"To Do\" AND sprint in openSprints() ORDER BY rank ASC",
            project_clause(projects))
}

/// Convert a sub-task issue (returned inside `fields.subtasks`) into the
/// lightweight `JiraTaskRef` we serialize to disk.
fn subtask_to_ref(issue: JiraIssue, base: &str) -> JiraTaskRef {
    let url = format!("{}/browse/{}", base, issue.key);
    let f = issue.fields;
    JiraTaskRef {
        key: issue.key,
        summary: f.summary,
        status: f.status.name,
        status_category: f.status.status_category
            .map(|c| c.key)
            .unwrap_or_else(|| "unknown".into()),
        url,
        issue_type: Some(f.issuetype.name),
    }
}

/// Convert a single Jira issue link into our `JiraLink`.  Returns `None`
/// when both inward and outward sides are missing (shouldn't happen in
/// practice but guards against API quirks).
fn issuelink_to_link(link: JiraIssueLink, base: &str) -> Option<JiraLink> {
    let (direction, linked) = if let Some(inward) = link.inward_issue {
        ("inward", inward)
    } else if let Some(outward) = link.outward_issue {
        ("outward", outward)
    } else {
        return None;
    };
    let url = format!("{}/browse/{}", base, linked.key);
    let (summary, status_name, status_cat, issue_type) = match linked.fields {
        Some(lf) => {
            let (sname, scat) = match lf.status {
                Some(s) => (
                    s.name,
                    s.status_category.map(|c| c.key)
                        .unwrap_or_else(|| "unknown".into()),
                ),
                None => (String::new(), "unknown".into()),
            };
            (
                lf.summary.unwrap_or_default(),
                sname,
                scat,
                lf.issuetype.map(|t| t.name),
            )
        }
        None => (String::new(), String::new(), "unknown".into(), None),
    };
    Some(JiraLink {
        direction: direction.into(),
        link_type: link.link_type.name,
        other: JiraTaskRef {
            key: linked.key,
            summary,
            status: status_name,
            status_category: status_cat,
            url,
            issue_type,
        },
    })
}

/// Fetch assigned Jira tasks, and unassigned ones to pick up.
pub async fn poll_jira_tasks(config: &JiraConfig) -> Result<JiraTasksFile, String> {
    let token = read_api_token(&config.api_token_file)?;
    let client = crate::http_client();
    let settings_path = config.settings_file.clone().map(PathBuf::from).unwrap_or_else(|| {
        dirs::home_dir().unwrap_or_default().join(".config/decknix/settings.toml")
    });
    let settings = std::fs::read_to_string(&settings_path).ok();
    let projects = effective_projects(config, settings.as_deref());
    let base = config.base_url.trim_end_matches('/');

    let jql = if projects.is_empty() && !config.statuses.is_empty() && !config.project.is_empty() {
        build_jql(config)
    } else {
        in_progress_jql(&projects)
    };
    let items = search(&client, config, &token, &jql, config.max_results as usize).await?
        .into_iter().map(|i| to_task(i, base)).collect();

    let mut errors = Vec::new();
    let mut pick_up = Vec::new();
    if config.pick_up && !projects.is_empty() {
        match search(&client, config, &token, &pick_up_jql(&projects), 50).await {
            Ok(issues) => pick_up = issues.into_iter().map(|i| to_task(i, base)).collect(),
            Err(e) => errors.push(format!("pick-up: {e}")),
        }
    }

    Ok(JiraTasksFile { updated: Utc::now(), items, pick_up, projects, errors })
}

async fn search(client: &reqwest::Client, config: &JiraConfig, token: &str, jql: &str,
                max_total: usize) -> Result<Vec<JiraIssue>, String> {
    let base = config.base_url.trim_end_matches('/');
    // Enhanced JQL search. Atlassian removed `GET /rest/api/3/search` (410
    // Gone) in favour of `/search/jql`, which is cursor-paged via
    // `nextPageToken` rather than `startAt`/`total`.
    let url = format!("{}/rest/api/3/search/jql", base);
    let fields = "summary,status,priority,assignee,parent,issuetype,updated,created,labels,subtasks,issuelinks";
    let mut issues: Vec<JiraIssue> = Vec::new();
    let mut next_page_token: Option<String> = None;

    loop {
        let remaining = max_total.saturating_sub(issues.len());
        if remaining == 0 {
            break;
        }
        // `/search/jql` caps a page at 100; request only what's left of the cap.
        let page_size = remaining.min(100).to_string();

        let mut query: Vec<(&str, String)> = vec![
            ("jql", jql.to_string()),
            ("maxResults", page_size),
            ("fields", fields.to_string()),
        ];
        if let Some(tok) = &next_page_token {
            query.push(("nextPageToken", tok.clone()));
        }

        let resp = client
            .get(&url)
            .basic_auth(&config.email, Some(token))
            .query(&query)
            .send()
            .await
            .map_err(|e| format!("Jira HTTP error: {e}"))?;

        if !resp.status().is_success() {
            let status = resp.status();
            let body = resp.text().await.unwrap_or_default();
            return Err(format!("Jira API {status}: {}", &body[..body.len().min(200)]));
        }

        let page: JiraSearchResponse = resp
            .json()
            .await
            .map_err(|e| format!("Jira parse error: {e}"))?;

        let empty_page = page.issues.is_empty();
        issues.extend(page.issues);

        // Stop on the last page: no cursor, an explicit `isLast`, or an empty
        // page (guards against a server echoing a stale token indefinitely).
        match page.next_page_token {
            Some(tok)
                if !tok.is_empty() && !page.is_last.unwrap_or(false) && !empty_page =>
            {
                next_page_token = Some(tok);
            }
            _ => break,
        }
    }

    // The final page can overshoot the cap; trim to the requested maximum.
    issues.truncate(max_total);
    Ok(issues)
}

fn to_task(issue: JiraIssue, base: &str) -> JiraTask {
    let f = issue.fields;
    let subtasks = f.subtasks.into_iter()
        .map(|sub| subtask_to_ref(sub, base))
        .collect();
    let links = f.issue_links.into_iter()
        .filter_map(|l| issuelink_to_link(l, base))
        .collect();
    JiraTask {
        key: issue.key.clone(),
        summary: f.summary,
        status: f.status.name,
        status_category: f.status.status_category
            .map(|c| c.key)
            .unwrap_or_else(|| "unknown".into()),
        priority: f.priority.map(|p| p.name),
        assignee: f.assignee.and_then(|a| a.display_name),
        parent_key: f.parent.as_ref().map(|p| p.key.clone()),
        parent_summary: f.parent.as_ref()
            .and_then(|p| p.fields.as_ref())
            .and_then(|pf| pf.summary.clone()),
        sprint: None, // Sprint requires custom field — skipped for now
        issue_type: f.issuetype.name,
        url: format!("{}/browse/{}", base, issue.key),
        updated: f.updated.parse().unwrap_or_else(|_| Utc::now()),
        created: f.created.parse().unwrap_or_else(|_| Utc::now()),
        labels: if f.labels.is_empty() { None } else { Some(f.labels) },
        subtasks,
        links,
    }
}

// ---------------------------------------------------------------------------
// Adapter runner
// ---------------------------------------------------------------------------

pub async fn run_jira_adapter(
    config: JiraConfig,
    dir: PathBuf,
    meta: SharedMeta,
    once: bool,
) {
    let interval = Duration::from_secs(config.interval_secs);
    loop {
        let result = poll_jira_tasks(&config).await;
        let status = match &result {
            Ok(data) => {
                if let Err(e) = atomic_write_json(&dir, "jira-tasks.json", data).await {
                    eprintln!("hub: write jira-tasks.json: {e}");
                    AdapterStatus {
                        name: "jira-tasks".into(),
                        last_poll: Some(Utc::now()),
                        last_error: Some(format!("write error: {e}")),
                        ok: false,
                    }
                } else {
                    eprintln!("hub: jira-tasks: {} mine, {} to pick up, projects {:?}",
                              data.items.len(), data.pick_up.len(), data.projects);
                    AdapterStatus {
                        name: "jira-tasks".into(),
                        last_poll: Some(Utc::now()),
                        last_error: data.errors.first().cloned(),
                        ok: data.errors.is_empty(),
                    }
                }
            }
            Err(e) => {
                eprintln!("hub: jira-tasks error: {e}");
                AdapterStatus {
                    name: "jira-tasks".into(),
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn build_jql_includes_project_and_statuses() {
        let cfg = JiraConfig {
            project: "NC".into(),
            statuses: vec!["Ready".into(), "In Progress".into()],
            ..Default::default()
        };
        let jql = build_jql(&cfg);
        assert!(jql.contains("project = NC AND"), "{jql}");
        assert!(jql.contains("assignee = currentUser()"), "{jql}");
        assert!(jql.contains("status IN (\"Ready\", \"In Progress\")"), "{jql}");
        assert!(jql.contains("ORDER BY priority ASC, updated DESC"), "{jql}");
    }

    #[test]
    fn build_jql_omits_project_clause_when_empty() {
        let cfg = JiraConfig { project: String::new(), ..Default::default() };
        let jql = build_jql(&cfg);
        assert!(!jql.contains("project ="), "{jql}");
        assert!(jql.starts_with("assignee = currentUser()"), "{jql}");
    }

    #[test]
    fn settings_toml_overrides_the_configured_projects() {
        let cfg = JiraConfig { projects: vec!["hx".into(), "DOS".into()], ..Default::default() };
        assert_eq!(effective_projects(&cfg, None), vec!["HX", "DOS"]);
        let toml = "[hub.jira]\nprojects = [\"plat\", \" CONN \"]\n";
        assert_eq!(effective_projects(&cfg, Some(toml)), vec!["PLAT", "CONN"]);
        assert_eq!(effective_projects(&cfg, Some("[repos]\nworkspaces = []")), vec!["HX", "DOS"]);
        assert_eq!(effective_projects(&cfg, Some("not toml [")), vec!["HX", "DOS"]);
        let legacy = JiraConfig { project: "NC".into(), ..Default::default() };
        assert_eq!(effective_projects(&legacy, None), vec!["NC"]);
        assert!(effective_projects(&JiraConfig::default(), None).is_empty());
    }

    #[test]
    fn keys_are_sanitised_so_jql_cannot_be_injected() {
        let toml = "[hub.jira]\nprojects = [\"HX) OR (1=1\"]";
        assert_eq!(effective_projects(&JiraConfig::default(), Some(toml)), vec!["HXOR11"]);
    }

    #[test]
    fn in_progress_and_pick_up_queries() {
        let p = vec!["HX".to_string(), "DOS".to_string()];
        assert_eq!(in_progress_jql(&p),
                   "project in (HX, DOS) AND assignee = currentUser() AND statusCategory != Done ORDER BY updated DESC");
        assert_eq!(in_progress_jql(&[]),
                   "assignee = currentUser() AND statusCategory != Done ORDER BY updated DESC");
        assert_eq!(pick_up_jql(&p),
                   "project in (HX, DOS) AND assignee is EMPTY AND statusCategory = \"To Do\" AND sprint in openSprints() ORDER BY rank ASC");
    }

    #[test]
    fn tasks_file_omits_empty_extras() {
        let f = JiraTasksFile { updated: Utc::now(), items: vec![], pick_up: vec![],
                                projects: vec![], errors: vec![] };
        let json = serde_json::to_string(&f).unwrap();
        assert!(!json.contains("pick_up") && !json.contains("errors"), "{json}");
    }

    // The enhanced `/search/jql` envelope: `issues` + a `nextPageToken`
    // cursor + optional `isLast`. Locks the serde renames the migration
    // depends on.
    #[test]
    fn search_response_parses_enhanced_jql_shape() {
        let json = r#"{
            "issues": [
                {"key": "MAIN-1", "self": "https://x/rest/api/3/issue/1",
                 "fields": {"summary": "s",
                   "status": {"name": "Ready", "statusCategory": {"key": "new"}},
                   "issuetype": {"name": "Task"},
                   "updated": "2026-01-01T00:00:00.000+0000",
                   "created": "2026-01-01T00:00:00.000+0000"}}
            ],
            "nextPageToken": "abc",
            "isLast": false
        }"#;
        let resp: JiraSearchResponse = serde_json::from_str(json).unwrap();
        assert_eq!(resp.issues.len(), 1);
        assert_eq!(resp.next_page_token.as_deref(), Some("abc"));
        assert_eq!(resp.is_last, Some(false));
    }

    #[test]
    fn an_issue_with_subtasks_decodes() {
        let json = r#"{"issues": [{"key": "HX-1", "fields": {"summary": "s",
            "status": {"name": "In Progress", "statusCategory": {"key": "indeterminate"}},
            "issuetype": {"name": "Story"},
            "updated": "2026-01-01T00:00:00.000+0000", "created": "2026-01-01T00:00:00.000+0000",
            "subtasks": [{"key": "HX-2", "fields": {"summary": "sub",
                "status": {"name": "To Do", "statusCategory": {"key": "new"}},
                "issuetype": {"name": "Sub-task"}}}]}}]}"#;
        let resp: JiraSearchResponse = serde_json::from_str(json).unwrap();
        assert_eq!(resp.issues[0].fields.subtasks.len(), 1);
    }

    // Last page: the cursor fields are simply absent — must default rather
    // than fail, so the poll loop terminates.
    #[test]
    fn search_response_defaults_when_cursor_absent() {
        let resp: JiraSearchResponse =
            serde_json::from_str(r#"{"issues": []}"#).unwrap();
        assert!(resp.issues.is_empty());
        assert_eq!(resp.next_page_token, None);
        assert_eq!(resp.is_last, None);
    }
}
