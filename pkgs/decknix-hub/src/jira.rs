// Jira adapter — polls assigned tasks via REST API
//
// Auth: email + API token (Basic auth).
// Writes jira-tasks.json to hub data directory.

use chrono::{DateTime, Utc};
use reqwest::Client;
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
    /// Jira project key for filtering (e.g. "NC")
    pub project: String,
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
    pub key: String,         // e.g. "NC-8012"
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
}

#[derive(Debug, Serialize, Deserialize)]
pub struct JiraTasksFile {
    pub updated: DateTime<Utc>,
    pub items: Vec<JiraTask>,
}

// ---------------------------------------------------------------------------
// Jira REST API response structs
// ---------------------------------------------------------------------------

#[derive(Debug, Deserialize)]
struct JiraSearchResponse {
    issues: Vec<JiraIssue>,
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
    summary: String,
    status: JiraStatus,
    priority: Option<JiraPriority>,
    assignee: Option<JiraUser>,
    parent: Option<JiraParent>,
    issuetype: JiraIssueType,
    updated: String,
    created: String,
    #[serde(default)]
    labels: Vec<String>,
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

/// Fetch assigned Jira tasks.
pub async fn poll_jira_tasks(config: &JiraConfig) -> Result<JiraTasksFile, String> {
    let token = read_api_token(&config.api_token_file)?;
    let client = Client::new();

    let jql = build_jql(config);
    let url = format!("{}/rest/api/3/search", config.base_url.trim_end_matches('/'));

    let resp = client
        .get(&url)
        .basic_auth(&config.email, Some(&token))
        .query(&[
            ("jql", jql.as_str()),
            ("maxResults", &config.max_results.to_string()),
            ("fields", "summary,status,priority,assignee,parent,issuetype,updated,created,labels"),
        ])
        .send()
        .await
        .map_err(|e| format!("Jira HTTP error: {e}"))?;

    if !resp.status().is_success() {
        let status = resp.status();
        let body = resp.text().await.unwrap_or_default();
        return Err(format!("Jira API {status}: {}", &body[..body.len().min(200)]));
    }

    let search: JiraSearchResponse = resp.json().await
        .map_err(|e| format!("Jira parse error: {e}"))?;

    let base = config.base_url.trim_end_matches('/');
    let items: Vec<JiraTask> = search.issues.into_iter().map(|issue| {
        let f = issue.fields;
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
        }
    }).collect();

    Ok(JiraTasksFile {
        updated: Utc::now(),
        items,
    })
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
                    eprintln!("hub: jira-tasks: {} items", data.items.len());
                    AdapterStatus {
                        name: "jira-tasks".into(),
                        last_poll: Some(Utc::now()),
                        last_error: None,
                        ok: true,
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
