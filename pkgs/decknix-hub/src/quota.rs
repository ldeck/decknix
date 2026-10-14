//! Remaining model quota for the accounts the agents run on.
//!
//! A Pi session stopped answering for an afternoon: Codex had hit its usage
//! limit, the Anthropic login had lapsed and then turned out to need paid
//! extra usage, and the Gemini key was free tier. Each was discovered by a
//! prompt failing, one provider at a time. This adapter writes
//! `token-quotas.json` so the sidebar can say up front which accounts have
//! room and when the full ones reset.
//!
//! Credentials are READ, never refreshed. Pi owns them in its `auth.json`,
//! and refreshing an OAuth token rotates the refresh token: doing it here
//! would silently log Pi out. An expired access token is reported as
//! "sign in again" instead.
//!
//! The usage endpoints are the ones the providers' own CLIs read and are not
//! documented, so every field is optional and a shape change degrades to an
//! account row carrying an error rather than a crash.

use chrono::{DateTime, TimeZone, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::path::{Path, PathBuf};
use std::time::Duration;

use crate::{atomic_write_json, update_meta, AdapterStatus, SharedMeta};

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(default)]
pub struct QuotaConfig {
    pub enabled: bool,
    pub interval_secs: u64,
    /// Pi's credential store. Empty means `~/.pi/agent/auth.json`.
    pub pi_auth_path: String,
    /// Pi's session logs, scanned for provider errors where a provider has no
    /// usage endpoint. Empty means `~/.pi/agent/sessions`.
    pub pi_sessions_dir: String,
}

impl Default for QuotaConfig {
    fn default() -> Self {
        Self {
            enabled: true,
            // Usage moves slowly against a 5-hour window, and each poll is two
            // or three small authenticated requests.
            interval_secs: 300,
            pi_auth_path: String::new(),
            pi_sessions_dir: String::new(),
        }
    }
}

#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct Window {
    pub name: String,
    pub used_percent: f64,
    pub resets_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, Serialize, Default)]
pub struct Account {
    pub provider: String,
    pub label: String,
    pub plan: Option<String>,
    pub email: Option<String>,
    pub windows: Vec<Window>,
    pub limit_reached: bool,
    /// One line the sidebar shows under the windows: why an account with
    /// room is still refusing, or what to do about an error.
    pub note: Option<String>,
    pub error: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct QuotasFile {
    pub updated: DateTime<Utc>,
    pub accounts: Vec<Account>,
}

// --- parsing (pure) ----------------------------------------------------

fn parse_rfc3339(v: &Value) -> Option<DateTime<Utc>> {
    v.as_str()
        .and_then(|s| DateTime::parse_from_rfc3339(s).ok())
        .map(|d| d.with_timezone(&Utc))
}

/// Windows from Anthropic's `/api/oauth/usage`.
pub fn anthropic_windows(usage: &Value) -> Vec<Window> {
    [("five_hour", "5h"), ("seven_day", "week")]
        .iter()
        .filter_map(|(key, name)| {
            let w = usage.get(*key)?;
            Some(Window {
                name: (*name).into(),
                used_percent: w.get("utilization")?.as_f64()?,
                resets_at: w.get("resets_at").and_then(parse_rfc3339),
            })
        })
        .collect()
}

/// The note for an Anthropic account whose plan usage Pi cannot spend.
///
/// Third-party apps draw only from paid extra usage, so with it disabled Pi
/// is refused at any utilisation: "16% used" alone would read as plenty of
/// room for a client that has none.
pub fn anthropic_note(usage: &Value) -> Option<String> {
    let extra = usage.get("extra_usage")?;
    if extra.get("is_enabled").and_then(Value::as_bool) == Some(false) {
        Some("extra usage off: refuses third-party apps".into())
    } else if extra.get("spend_limit_reached").and_then(Value::as_bool) == Some(true) {
        Some("extra usage spend limit reached".into())
    } else {
        None
    }
}

/// "max 20x" from a `rate_limit_tier` of `default_claude_max_20x`.
pub fn anthropic_plan(profile: &Value) -> Option<String> {
    let tier = profile.pointer("/organization/rate_limit_tier")?.as_str()?;
    let t = tier.trim_start_matches("default_").trim_start_matches("claude_");
    Some(t.replace('_', " "))
}

/// Windows and the limit flag from ChatGPT's `/backend-api/wham/usage`.
pub fn codex_windows(usage: &Value) -> (Vec<Window>, bool) {
    let rl = usage.get("rate_limit");
    let reached = rl
        .and_then(|r| r.get("limit_reached"))
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let windows = [("primary_window", "5h"), ("secondary_window", "week")]
        .iter()
        .filter_map(|(key, fallback)| {
            let w = rl?.get(*key)?;
            let secs = w.get("limit_window_seconds").and_then(Value::as_u64);
            let name = match secs {
                Some(18000) => "5h".to_string(),
                Some(604800) => "week".to_string(),
                Some(s) if s % 3600 == 0 => format!("{}h", s / 3600),
                _ => (*fallback).to_string(),
            };
            Some(Window {
                name,
                used_percent: w.get("used_percent")?.as_f64()?,
                resets_at: w
                    .get("reset_at")
                    .and_then(Value::as_i64)
                    .and_then(|t| Utc.timestamp_opt(t, 0).single()),
            })
        })
        .collect();
    (windows, reached)
}

/// The ChatGPT account id, from `auth.json` or the access token's claims.
pub fn codex_account_id(cred: &Value) -> Option<String> {
    if let Some(id) = cred.get("accountId").and_then(Value::as_str) {
        return Some(id.to_string());
    }
    let token = cred.get("access")?.as_str()?;
    let payload = token.split('.').nth(1)?;
    use base64::Engine;
    let bytes = base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(payload.trim_end_matches('='))
        .ok()?;
    let claims: Value = serde_json::from_slice(&bytes).ok()?;
    claims
        .pointer("/https:~1~1api.openai.com~1auth/chatgpt_account_id")
        .and_then(Value::as_str)
        .map(str::to_string)
}

/// Whether a stored credential's access token has already expired.
pub fn token_expired(cred: &Value, now: DateTime<Utc>) -> bool {
    cred.get("expires")
        .and_then(Value::as_i64)
        .map(|ms| ms <= now.timestamp_millis())
        .unwrap_or(false)
}

/// The most recent Gemini quota failure in a Pi session log, as
/// (when, retry-until).
///
/// Gemini API keys have no usage endpoint, so the honest report is the last
/// refusal Pi actually received and how long Google said to wait.
pub fn gemini_last_refusal(log: &str) -> Option<(DateTime<Utc>, Option<DateTime<Utc>>)> {
    let mut found = None;
    for line in log.lines() {
        if !line.contains("RESOURCE_EXHAUSTED") {
            continue;
        }
        let Ok(entry) = serde_json::from_str::<Value>(line) else { continue };
        let msg = entry.get("message");
        if msg.and_then(|m| m.get("provider")).and_then(Value::as_str) != Some("google") {
            continue;
        }
        let Some(at) = entry.get("timestamp").and_then(parse_rfc3339) else { continue };
        let err = msg
            .and_then(|m| m.get("errorMessage"))
            .and_then(Value::as_str)
            .unwrap_or("");
        let retry = err
            .split("retryDelay")
            .nth(1)
            .and_then(|rest| {
                let digits: String = rest
                    .chars()
                    .skip_while(|c| !c.is_ascii_digit())
                    .take_while(|c| c.is_ascii_digit())
                    .collect();
                digits.parse::<i64>().ok()
            })
            .map(|secs| at + chrono::Duration::seconds(secs));
        found = Some((at, retry));
    }
    found
}

// --- fetching ----------------------------------------------------------

fn home() -> PathBuf {
    dirs::home_dir().unwrap_or_else(|| PathBuf::from("."))
}

fn or_default(configured: &str, default: &str) -> PathBuf {
    if configured.is_empty() {
        home().join(default)
    } else {
        PathBuf::from(configured)
    }
}

async fn get_json(
    client: &reqwest::Client,
    url: &str,
    headers: &[(&str, String)],
) -> Result<Value, String> {
    let mut req = client.get(url).header("User-Agent", "decknix-hub");
    for (k, v) in headers {
        req = req.header(*k, v);
    }
    let resp = req.send().await.map_err(|e| e.to_string())?;
    let status = resp.status();
    if status == reqwest::StatusCode::UNAUTHORIZED {
        return Err("signed out: run `pi`, then /login".into());
    }
    if !status.is_success() {
        return Err(format!("HTTP {}", status.as_u16()));
    }
    resp.json::<Value>().await.map_err(|e| e.to_string())
}

/// Claude Code's keychain record, in the `{access, expires}` shape Pi's
/// auth.json uses, so one code path reads either.
pub fn claude_code_cred(record: &Value) -> Option<Value> {
    let o = record.get("claudeAiOauth")?;
    let access = o.get("accessToken")?.as_str()?;
    Some(serde_json::json!({
        "access": access,
        "expires": o.get("expiresAt").and_then(Value::as_i64),
    }))
}

/// Read Claude Code's login from the macOS keychain, or None.
///
/// Preferred over Pi's copy of the same account: Claude Code is in use all
/// day and keeps its token fresh, while Pi's expires within hours of Pi
/// last running, which left the row reading "token expired" while the
/// account was fine.  Bounded, so a locked keychain cannot stall a poll.
async fn keychain_claude_code() -> Option<Value> {
    let out = tokio::time::timeout(
        Duration::from_secs(5),
        tokio::process::Command::new("/usr/bin/security")
            .args(["find-generic-password", "-s", "Claude Code-credentials", "-w"])
            .output(),
    )
    .await
    .ok()?
    .ok()?;
    if !out.status.success() {
        return None;
    }
    let record: Value = serde_json::from_slice(&out.stdout).ok()?;
    claude_code_cred(&record)
}

/// Which credential to use: the first one that has not expired, else the
/// first one at all, so an all-expired state still reports the error.
pub fn pick_credential<'a>(
    candidates: &'a [(&'static str, Value)],
    now: DateTime<Utc>,
) -> Option<&'a (&'static str, Value)> {
    candidates
        .iter()
        .find(|(_, c)| !token_expired(c, now))
        .or_else(|| candidates.first())
}

async fn anthropic_account(client: &reqwest::Client, cred: &Value, source: &str) -> Account {
    let mut acct = Account {
        provider: "anthropic".into(),
        label: "claude".into(),
        ..Default::default()
    };
    if token_expired(cred, Utc::now()) {
        acct.error = Some(match source {
            "claude-code" => "token expired: open Claude Code to refresh it".into(),
            _ => "token expired: run `pi`, then /login".into(),
        });
        return acct;
    }
    let Some(token) = cred.get("access").and_then(Value::as_str) else {
        acct.error = Some("no access token".into());
        return acct;
    };
    let headers = [
        ("Authorization", format!("Bearer {token}")),
        ("anthropic-beta", "oauth-2025-04-20".to_string()),
    ];
    match get_json(client, "https://api.anthropic.com/api/oauth/usage", &headers).await {
        Ok(usage) => {
            acct.windows = anthropic_windows(&usage);
            acct.limit_reached = acct.windows.iter().any(|w| w.used_percent >= 100.0);
            acct.note = anthropic_note(&usage);
        }
        Err(e) => acct.error = Some(e),
    }
    if let Ok(profile) =
        get_json(client, "https://api.anthropic.com/api/oauth/profile", &headers).await
    {
        acct.plan = anthropic_plan(&profile);
        acct.email = profile
            .pointer("/account/email")
            .and_then(Value::as_str)
            .map(str::to_string);
    }
    acct
}

async fn codex_account(client: &reqwest::Client, cred: &Value) -> Account {
    let mut acct = Account {
        provider: "openai-codex".into(),
        label: "codex".into(),
        ..Default::default()
    };
    if token_expired(cred, Utc::now()) {
        acct.error = Some("token expired: run `pi`, then /login".into());
        return acct;
    }
    let (Some(token), Some(account_id)) = (
        cred.get("access").and_then(Value::as_str),
        codex_account_id(cred),
    ) else {
        acct.error = Some("no access token or account id".into());
        return acct;
    };
    let headers = [
        ("Authorization", format!("Bearer {token}")),
        ("ChatGPT-Account-Id", account_id),
    ];
    match get_json(client, "https://chatgpt.com/backend-api/wham/usage", &headers).await {
        Ok(usage) => {
            let (windows, reached) = codex_windows(&usage);
            acct.windows = windows;
            acct.limit_reached = reached;
            acct.plan = usage.get("plan_type").and_then(Value::as_str).map(str::to_string);
            acct.email = usage.get("email").and_then(Value::as_str).map(str::to_string);
        }
        Err(e) => acct.error = Some(e),
    }
    acct
}

/// The Gemini row, from the newest session logs rather than an endpoint.
fn gemini_account(sessions_dir: &Path) -> Option<Account> {
    let mut logs: Vec<(std::time::SystemTime, PathBuf)> = walk_jsonl(sessions_dir)
        .into_iter()
        .filter_map(|p| Some((std::fs::metadata(&p).ok()?.modified().ok()?, p)))
        .collect();
    logs.sort_by(|a, b| b.0.cmp(&a.0));
    let latest = logs
        .iter()
        .take(10)
        .filter_map(|(_, p)| std::fs::read_to_string(p).ok())
        .filter_map(|text| gemini_last_refusal(&text))
        .max_by_key(|(at, _)| *at)?;
    let (at, retry) = latest;
    let now = Utc::now();
    let still_blocked = retry.map(|r| r > now).unwrap_or(false);
    // A refusal still in force is a full window that resets when Google said
    // to retry, so it renders like the other accounts' windows.
    let windows = match (still_blocked, retry) {
        (true, Some(r)) => vec![Window { name: "quota".into(), used_percent: 100.0, resets_at: Some(r) }],
        _ => vec![],
    };
    Some(Account {
        provider: "google".into(),
        label: "gemini".into(),
        plan: Some("free tier".into()),
        limit_reached: still_blocked,
        windows,
        // The refusal's date only matters while it is in force, and then the
        // window above carries its reset time.  Shown afterwards, "last
        // refusal 09 Oct" sat beside a green dot five days later and read
        // as current.
        note: Some(if still_blocked {
            format!("no usage API: refused at {}", at.format("%H:%MZ"))
        } else {
            "no usage API".to_string()
        }),
        ..Default::default()
    })
}

fn walk_jsonl(dir: &Path) -> Vec<PathBuf> {
    let mut out = vec![];
    let Ok(entries) = std::fs::read_dir(dir) else { return out };
    for e in entries.flatten() {
        let p = e.path();
        if p.is_dir() {
            out.extend(walk_jsonl(&p));
        } else if p.extension().and_then(|x| x.to_str()) == Some("jsonl") {
            out.push(p);
        }
    }
    out
}

pub async fn poll_quotas(config: &QuotaConfig) -> Result<QuotasFile, String> {
    let client = crate::http_client();
    let auth_path = or_default(&config.pi_auth_path, ".pi/agent/auth.json");
    let auth: Value = std::fs::read_to_string(&auth_path)
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or(Value::Null);

    let mut accounts = vec![];
    let mut anthropic: Vec<(&'static str, Value)> = vec![];
    if let Some(c) = keychain_claude_code().await {
        anthropic.push(("claude-code", c));
    }
    if let Some(c) = auth.get("anthropic") {
        anthropic.push(("pi", c.clone()));
    }
    if let Some((source, cred)) = pick_credential(&anthropic, Utc::now()) {
        accounts.push(anthropic_account(&client, cred, source).await);
    }
    if let Some(cred) = auth.get("openai-codex") {
        accounts.push(codex_account(&client, cred).await);
    }
    let sessions = or_default(&config.pi_sessions_dir, ".pi/agent/sessions");
    if let Some(g) = gemini_account(&sessions) {
        accounts.push(g);
    }
    Ok(QuotasFile { updated: Utc::now(), accounts })
}

pub async fn run_quota_adapter(config: QuotaConfig, dir: PathBuf, meta: SharedMeta, once: bool) {
    let interval = Duration::from_secs(config.interval_secs);
    loop {
        let result = poll_quotas(&config).await;
        let (ok, last_error) = match &result {
            Ok(data) => match atomic_write_json(&dir, "token-quotas.json", data).await {
                Ok(()) => {
                    eprintln!("hub: quotas: {} accounts", data.accounts.len());
                    (true, None)
                }
                Err(e) => (false, Some(format!("write error: {e}"))),
            },
            Err(e) => (false, Some(e.clone())),
        };
        update_meta(
            &meta,
            AdapterStatus {
                name: "token-quotas".into(),
                last_poll: Some(Utc::now()),
                last_error,
                ok,
            },
            &dir,
        )
        .await;
        if once {
            return;
        }
        tokio::time::sleep(interval).await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn claude_code_keychain_record_maps_to_the_pi_shape() {
        let rec = json!({"claudeAiOauth": {"accessToken": "t", "expiresAt": 2000000000000_i64, "subscriptionType": "max"}, "mcpOAuth": {}});
        let c = claude_code_cred(&rec).unwrap();
        assert_eq!(c["access"], "t");
        assert_eq!(c["expires"], 2000000000000_i64);
        assert!(claude_code_cred(&json!({"mcpOAuth": {}})).is_none());
    }

    #[test]
    fn the_first_unexpired_credential_wins() {
        // Pi's copy had expired while Claude Code's was fresh, and the row
        // reported the expiry instead of the usage.
        let now = Utc.timestamp_opt(2_000_000_000, 0).unwrap();
        let fresh = json!({"access": "a", "expires": 2_000_000_100_000_i64});
        let stale = json!({"access": "b", "expires": 1_000_000_000_000_i64});
        let both = [("pi", stale.clone()), ("claude-code", fresh.clone())];
        assert_eq!(pick_credential(&both, now).unwrap().0, "claude-code");
        let none_fresh = [("claude-code", stale.clone()), ("pi", stale)];
        assert_eq!(pick_credential(&none_fresh, now).unwrap().0, "claude-code");
        assert!(pick_credential(&[], now).is_none());
    }

    #[test]
    fn anthropic_windows_read_utilisation_and_reset() {
        let usage = json!({
            "five_hour": {"utilization": 16.0, "resets_at": "2026-10-09T08:09:59.954240+00:00"},
            "seven_day": {"utilization": 10.0, "resets_at": "2026-10-15T00:59:59+00:00"},
            "seven_day_opus": null
        });
        let w = anthropic_windows(&usage);
        assert_eq!(w.len(), 2);
        assert_eq!(w[0].name, "5h");
        assert_eq!(w[0].used_percent, 16.0);
        assert_eq!(w[1].name, "week");
        assert!(w[0].resets_at.is_some());
    }

    #[test]
    fn disabled_extra_usage_is_named_whatever_the_utilisation() {
        // 16% used read as plenty of room while Pi was being refused outright.
        let usage = json!({"five_hour": {"utilization": 16.0}, "extra_usage": {"is_enabled": false}});
        assert!(anthropic_note(&usage).unwrap().contains("third-party"));
        let usage = json!({"extra_usage": {"is_enabled": true, "spend_limit_reached": false}});
        assert_eq!(anthropic_note(&usage), None);
    }

    #[test]
    fn anthropic_plan_reads_the_tier() {
        let p = json!({"organization": {"rate_limit_tier": "default_claude_max_20x"}});
        assert_eq!(anthropic_plan(&p).as_deref(), Some("max 20x"));
    }

    #[test]
    fn codex_windows_name_themselves_from_their_length() {
        let usage = json!({"rate_limit": {
            "limit_reached": false,
            "primary_window": {"used_percent": 4, "limit_window_seconds": 18000, "reset_at": 1791542181},
            "secondary_window": {"used_percent": 53, "limit_window_seconds": 604800, "reset_at": 1791950113}
        }});
        let (w, reached) = codex_windows(&usage);
        assert!(!reached);
        assert_eq!(w.iter().map(|x| x.name.as_str()).collect::<Vec<_>>(), ["5h", "week"]);
        assert_eq!(w[1].used_percent, 53.0);
        assert_eq!(w[0].resets_at.unwrap().timestamp(), 1791542181);
    }

    #[test]
    fn codex_limit_reached_is_carried() {
        let (_, reached) = codex_windows(&json!({"rate_limit": {"limit_reached": true}}));
        assert!(reached);
    }

    #[test]
    fn codex_account_id_prefers_the_stored_field() {
        assert_eq!(codex_account_id(&json!({"accountId": "acct-1"})).as_deref(), Some("acct-1"));
    }

    #[test]
    fn codex_account_id_falls_back_to_the_token_claims() {
        use base64::Engine;
        let claims = json!({"https://api.openai.com/auth": {"chatgpt_account_id": "acct-2"}});
        let payload = base64::engine::general_purpose::URL_SAFE_NO_PAD
            .encode(serde_json::to_vec(&claims).unwrap());
        let token = format!("h.{payload}.s");
        assert_eq!(codex_account_id(&json!({"access": token})).as_deref(), Some("acct-2"));
    }

    #[test]
    fn an_expired_token_is_detected_without_using_it() {
        let now = Utc.timestamp_opt(2_000_000_000, 0).unwrap();
        assert!(token_expired(&json!({"expires": 1_999_999_999_000_i64}), now));
        assert!(!token_expired(&json!({"expires": 2_000_000_001_000_i64}), now));
        assert!(!token_expired(&json!({}), now));
    }

    #[test]
    fn gemini_refusal_reads_time_and_retry_delay() {
        let line = json!({
            "timestamp": "2026-10-09T05:24:25.000Z",
            "message": {"role": "assistant", "provider": "google", "stopReason": "error",
                        "errorMessage": "{\"error\":{\"status\":\"RESOURCE_EXHAUSTED\",\"details\":[{\"retryDelay\":\"66934s\"}]}}"}
        })
        .to_string();
        let (at, retry) = gemini_last_refusal(&format!("{{}}\n{line}\n")).unwrap();
        assert_eq!(at.to_rfc3339(), "2026-10-09T05:24:25+00:00");
        assert_eq!((retry.unwrap() - at).num_seconds(), 66934);
    }

    #[test]
    fn other_providers_refusals_are_not_counted_as_gemini() {
        let line = json!({
            "timestamp": "2026-10-09T05:24:25.000Z",
            "message": {"provider": "openai-codex", "errorMessage": "RESOURCE_EXHAUSTED"}
        })
        .to_string();
        assert!(gemini_last_refusal(&line).is_none());
    }
}
