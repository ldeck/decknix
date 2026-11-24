//! Approved-and-mergeable detection for the viewer's own PRs.
//!
//! Opt-in (`github.merge_ready_notify`).  After each WIP poll, every open PR
//! the viewer authored is classified: approved on its current head, not a
//! draft, CI green and mergeable is `clean` when nothing is left to answer,
//! or `comments` when threads are unresolved or a human spoke after the
//! viewer's last activity.  The hub then tells the session that raised the
//! PR, once per (head SHA, verdict), with `decknix session send --when idle`.
//!
//! The hub never merges.  The session does, so the repo's own rules and the
//! ship flow (production gates, freezes, Friday rules) stay in charge; the
//! message is only a trigger, and the session re-checks the live PR.
//!
//! Every classified PR carries a `merge_ready` object in github-wip.json.
//! Its `delivery` is `sent` once a live session has the message; anything
//! else (no claiming session, receiver off, send failed) is what the sidebar
//! ship queue surfaces as "approved · ready to merge" for the human.
//!
//! Spawning a session for an unclaimed PR is deliberately not done: the
//! hub has no session identity to sign a spawn request with, the dispatch
//! receiver only accepts spawns from coordinator sessions, and an automatic
//! spawn spends model credit on every approval.

use crate::{WipFile, WipPr};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

pub const STATE_FILE: &str = "merge-ready-state.json";

/// How long an undelivered notification waits before it is tried again.
/// A session that was closed may be resumed; the receiver may come back.
const RETRY_SECS: i64 = 300;

/// `decknix session send` is local file work; anything slower is wedged.
const SEND_TIMEOUT: Duration = Duration::from_secs(10);

/// The CLI's exit code when the Emacs dispatch receiver is off.
const EXIT_NO_RECEIVER: i32 = 14;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Verdict {
    Clean,
    Comments,
}

impl Verdict {
    fn as_str(self) -> &'static str {
        match self {
            Verdict::Clean => "clean",
            Verdict::Comments => "comments",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Delivery {
    Sent,
    NoSession,
    NoReceiver,
    Failed,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct MergeReady {
    pub verdict: Verdict,
    pub comments: u32,
    pub delivery: Delivery,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session: Option<String>,
}

/// Classify PR for VIEWER, or None when it is not (yet) the viewer's to merge.
///
/// `comments` counts unresolved threads, plus one when a human wrote after
/// the viewer's last activity.  A `BLOCKED` merge state is accepted only
/// with unresolved threads: branch protection that requires thread
/// resolution blocks exactly until they are handled.
pub fn classify(pr: &WipPr, viewer: &str) -> Option<(Verdict, u32)> {
    let eligible = pr.state == "OPEN"
        && pr.draft == Some(false)
        && pr.author.as_deref().is_some_and(|a| a.eq_ignore_ascii_case(viewer))
        && pr.review_decision.as_deref() == Some("APPROVED")
        && pr.review_stale == Some(false)
        && pr.ci.as_ref().is_some_and(|c| c.status == "pass")
        && pr.mergeable.as_deref() == Some("MERGEABLE")
        && pr.head_sha.is_some();
    if !eligible {
        return None;
    }
    let threads = pr.unresolved_total?;
    let comments = threads + u32::from(pr.human_said_something == Some(true));
    let mergeable_now = match pr.merge_state.as_deref()? {
        "CLEAN" | "HAS_HOOKS" => true,
        "BLOCKED" => threads > 0,
        _ => false,
    };
    let verdict = if comments == 0 { Verdict::Clean } else { Verdict::Comments };
    mergeable_now.then_some((verdict, comments))
}

pub fn message(url: &str, verdict: Verdict, comments: u32) -> String {
    match verdict {
        Verdict::Clean => {
            format!("PR {url} is approved and clean: merge and ship it per the auto-merge policy")
        }
        Verdict::Comments => format!(
            "PR {url} approved with {comments} comment{}: classify blocking vs follow-up per the policy, then ship",
            if comments == 1 { "" } else { "s" }
        ),
    }
}

// ---------------------------------------------------------------------------
// Ownership: which sessions raised or linked a PR
// ---------------------------------------------------------------------------

pub fn pr_key(repo: &str, number: u64) -> String {
    format!("{}#{}", repo.to_ascii_lowercase(), number)
}

fn key_from_url(url: &str) -> Option<String> {
    let rest = url.trim_end_matches('/').split("github.com/").nth(1)?;
    let mut parts = rest.split('/');
    let (owner, repo, kind, number) = (parts.next()?, parts.next()?, parts.next()?, parts.next()?);
    (kind == "pull").then_some(())?;
    Some(pr_key(&format!("{owner}/{repo}"), number.parse().ok()?))
}

fn key_from_ref(r: &str) -> Option<String> {
    let (repo, number) = r.rsplit_once('#')?;
    Some(pr_key(repo, number.parse().ok()?))
}

/// Parse session-assoc's created-PR store, an elisp alist of string lists:
/// `(("BROKER-KEY" "owner/repo#1" ...) ...)`.  Strings outside a group are
/// ignored, so a truncated or foreign file degrades to fewer owners.
pub fn parse_created_eld(text: &str) -> Vec<(String, Vec<String>)> {
    let mut groups = Vec::new();
    let mut depth = 0usize;
    let mut current: Vec<String> = Vec::new();
    let mut chars = text.chars();
    while let Some(c) = chars.next() {
        match c {
            '(' => {
                depth += 1;
                if depth == 2 {
                    current.clear();
                }
            }
            ')' => {
                if depth == 2 && !current.is_empty() {
                    let key = current.remove(0);
                    groups.push((key, std::mem::take(&mut current)));
                }
                depth = depth.saturating_sub(1);
            }
            '"' => {
                let mut s = String::new();
                while let Some(c) = chars.next() {
                    match c {
                        '\\' => {
                            if let Some(e) = chars.next() {
                                s.push(e);
                            }
                        }
                        '"' => break,
                        c => s.push(c),
                    }
                }
                if depth == 2 {
                    current.push(s);
                }
            }
            _ => {}
        }
    }
    groups
}

#[derive(Debug, Default)]
pub struct Owners(HashMap<String, Vec<String>>);

impl Owners {
    pub fn sessions(&self, key: &str) -> &[String] {
        self.0.get(key).map(Vec::as_slice).unwrap_or(&[])
    }
}

/// Map each PR to the session ids of the conversations that claim it, from
/// the conversation store (`linked_prs`) and the created-PR store (keyed by
/// broker key).  A merged conversation's PRs go to the one it merged into.
/// Ids are newest first: a conversation appends a session on every resume.
pub fn owners_from(store: &Value, created: &[(String, Vec<String>)]) -> Owners {
    let Some(convs) = store.get("conversations").and_then(Value::as_object) else {
        return Owners::default();
    };
    let created: HashMap<&str, &Vec<String>> =
        created.iter().map(|(k, v)| (k.as_str(), v)).collect();
    let mut map: HashMap<String, Vec<String>> = HashMap::new();
    for conv in convs.values() {
        let mut target = conv;
        for _ in 0..8 {
            match target.get("mergedInto").and_then(Value::as_str).and_then(|k| convs.get(k)) {
                Some(next) => target = next,
                None => break,
            }
        }
        let sessions: Vec<String> = target
            .get("sessions")
            .and_then(Value::as_array)
            .map(|a| a.iter().rev().filter_map(Value::as_str).map(String::from).collect())
            .unwrap_or_default();
        if sessions.is_empty() {
            continue;
        }
        let linked = conv
            .get("linked_prs")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(|p| p.get("url").and_then(Value::as_str))
            .filter_map(key_from_url);
        let raised = conv
            .get("brokerKey")
            .and_then(Value::as_str)
            .and_then(|b| created.get(b))
            .into_iter()
            .flat_map(|refs| refs.iter())
            .filter_map(|r| key_from_ref(r));
        for pr in linked.chain(raised) {
            let entry = map.entry(pr).or_default();
            for s in &sessions {
                if !entry.contains(s) {
                    entry.push(s.clone());
                }
            }
        }
    }
    Owners(map)
}

// ---------------------------------------------------------------------------
// Delivery
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SendOutcome {
    Queued,
    NotLive,
    NoReceiver,
    Failed,
}

pub trait Sender {
    fn send(&mut self, session: &str, message: &str) -> SendOutcome;
}

/// Sends through the `decknix session send` CLI, so the request format,
/// liveness check and receiver preflight stay in one place.
pub struct CliSender;

impl Sender for CliSender {
    fn send(&mut self, session: &str, message: &str) -> SendOutcome {
        let child = Command::new("decknix")
            .args(["session", "send", session, "--when", "idle", "--reason", "merge-ready", "-m", message])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn();
        let Ok(mut child) = child else {
            return SendOutcome::Failed;
        };
        let started = Instant::now();
        loop {
            match child.try_wait() {
                Ok(Some(status)) if status.success() => return SendOutcome::Queued,
                Ok(Some(status)) if status.code() == Some(EXIT_NO_RECEIVER) => return SendOutcome::NoReceiver,
                Ok(Some(_)) => return SendOutcome::NotLive,
                Ok(None) if started.elapsed() < SEND_TIMEOUT => std::thread::sleep(Duration::from_millis(50)),
                _ => {
                    let _ = child.kill();
                    let _ = child.wait();
                    return SendOutcome::Failed;
                }
            }
        }
    }
}

/// Try SESSIONS in order until one is live.  The receiver is shared, so the
/// first "receiver off" stops the attempt.
fn deliver(sessions: &[String], message: &str, sender: &mut dyn Sender) -> (Delivery, Option<String>) {
    let mut failed = false;
    for s in sessions {
        match sender.send(s, message) {
            SendOutcome::Queued => return (Delivery::Sent, Some(s.clone())),
            SendOutcome::NoReceiver => return (Delivery::NoReceiver, None),
            SendOutcome::Failed => failed = true,
            SendOutcome::NotLive => {}
        }
    }
    (if failed { Delivery::Failed } else { Delivery::NoSession }, None)
}

// ---------------------------------------------------------------------------
// State and the per-poll step
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Tried {
    key: String,
    at: i64,
    delivery: Delivery,
}

/// Persisted across polls and restarts so a notification fires once.
#[derive(Debug, Default, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct State {
    /// PR -> ("HEAD-SHA:VERDICT" -> session it was sent to).
    sent: BTreeMap<String, BTreeMap<String, String>>,
    /// PR -> last undelivered attempt, for the retry throttle.
    tried: BTreeMap<String, Tried>,
}

/// Classify every PR in FILE, notify owners of newly ready ones, annotate
/// `merge_ready`, and forget PRs that are no longer open.
pub fn process(file: &mut WipFile, owners: &Owners, state: &mut State, sender: &mut dyn Sender, now: i64) {
    let Some(viewer) = file.viewer.clone() else {
        return;
    };
    let mut open: HashSet<String> = HashSet::new();
    for repo in &mut file.repos {
        for pr in &mut repo.prs {
            let key = pr_key(&repo.repo, pr.number);
            if pr.state == "OPEN" {
                open.insert(key.clone());
            }
            let Some((verdict, comments)) = classify(pr, &viewer) else {
                state.tried.remove(&key);
                continue;
            };
            let dedupe = format!("{}:{}", pr.head_sha.as_deref().unwrap_or_default(), verdict.as_str());
            let ready = |delivery, session| Some(MergeReady { verdict, comments, delivery, session });
            if let Some(session) = state.sent.get(&key).and_then(|m| m.get(&dedupe)) {
                pr.merge_ready = ready(Delivery::Sent, Some(session.clone()));
                continue;
            }
            if let Some(t) = state.tried.get(&key) {
                if t.key == dedupe && now - t.at < RETRY_SECS {
                    pr.merge_ready = ready(t.delivery, None);
                    continue;
                }
            }
            let (delivery, session) = deliver(owners.sessions(&key), &message(&pr.url, verdict, comments), sender);
            match (&delivery, &session) {
                (Delivery::Sent, Some(s)) => {
                    state.sent.entry(key.clone()).or_default().insert(dedupe, s.clone());
                    state.tried.remove(&key);
                }
                _ => {
                    state.tried.insert(key.clone(), Tried { key: dedupe, at: now, delivery });
                }
            }
            pr.merge_ready = ready(delivery, session);
        }
    }
    state.sent.retain(|k, _| open.contains(k));
    state.tried.retain(|k, _| open.contains(k));
}

fn sessions_store_path(home: &Path) -> PathBuf {
    home.join(".config/decknix/agent-sessions.json")
}

fn created_store_path(home: &Path) -> PathBuf {
    std::env::var_os("XDG_STATE_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| home.join(".local/state"))
        .join("decknix/session-prs.eld")
}

fn load_owners() -> Owners {
    let Some(home) = dirs::home_dir() else {
        return Owners::default();
    };
    let store = std::fs::read_to_string(sessions_store_path(&home))
        .ok()
        .and_then(|s| serde_json::from_str::<Value>(&s).ok())
        .unwrap_or(Value::Null);
    let created = std::fs::read_to_string(created_store_path(&home))
        .map(|s| parse_created_eld(&s))
        .unwrap_or_default();
    owners_from(&store, &created)
}

/// The adapter hook: load state and owners, process, persist when changed.
pub async fn run(file: &mut WipFile, dir: &Path) {
    let path = dir.join(STATE_FILE);
    let before: State = tokio::fs::read_to_string(&path)
        .await
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default();
    let mut state = before.clone();
    let now = chrono::Utc::now().timestamp();
    tokio::task::block_in_place(|| {
        let owners = load_owners();
        process(file, &owners, &mut state, &mut CliSender, now);
    });
    if state != before {
        if let Err(e) = crate::atomic_write_json(dir, STATE_FILE, &state).await {
            eprintln!("hub: write {STATE_FILE}: {e}");
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::WipRepo;
    use serde_json::json;

    const ME: &str = "me";
    const URL: &str = "https://github.com/acme/widget/pull/7";
    const S1: &str = "11111111-1111-4111-8111-111111111111";
    const S2: &str = "22222222-2222-4222-8222-222222222222";

    fn ready_pr() -> Value {
        json!({
            "number": 7, "title": "t", "state": "OPEN", "url": URL,
            "draft": false, "ci": {"status": "pass"}, "mergeable": "MERGEABLE",
            "review_decision": "APPROVED", "review_stale": false,
            "unresolved_total": 0, "human_said_something": false,
            "author": ME, "head_sha": "abc", "merge_state": "CLEAN"
        })
    }

    fn pr(patch: Value) -> WipPr {
        let mut v = ready_pr();
        for (k, x) in patch.as_object().unwrap() {
            v[k] = x.clone();
        }
        serde_json::from_value(v).unwrap()
    }

    fn file(prs: Vec<WipPr>) -> WipFile {
        WipFile {
            updated: chrono::Utc::now(),
            repos: vec![WipRepo { repo: "acme/widget".into(), prs }],
            errors: vec![],
            viewer: Some(ME.into()),
        }
    }

    #[derive(Default)]
    struct Fake {
        live: Vec<String>,
        receiver_off: bool,
        sent: Vec<(String, String)>,
    }

    impl Sender for Fake {
        fn send(&mut self, session: &str, message: &str) -> SendOutcome {
            if self.receiver_off {
                return SendOutcome::NoReceiver;
            }
            if self.live.iter().any(|s| s == session) {
                self.sent.push((session.into(), message.into()));
                SendOutcome::Queued
            } else {
                SendOutcome::NotLive
            }
        }
    }

    fn owned_by(sessions: &[&str]) -> Owners {
        let mut m = HashMap::new();
        m.insert(pr_key("acme/widget", 7), sessions.iter().map(|s| s.to_string()).collect());
        Owners(m)
    }

    #[test]
    fn approved_green_mergeable_without_comments_is_clean() {
        assert_eq!(classify(&pr(json!({})), ME), Some((Verdict::Clean, 0)));
    }

    #[test]
    fn each_gate_blocks_on_its_own() {
        for patch in [
            json!({"draft": true}),
            json!({"draft": null}),
            json!({"state": "MERGED"}),
            json!({"author": "someone-else"}),
            json!({"review_decision": "REVIEW_REQUIRED"}),
            json!({"review_stale": true}),
            json!({"ci": {"status": "running"}}),
            json!({"ci": null}),
            json!({"mergeable": "CONFLICTING"}),
            json!({"merge_state": "BEHIND"}),
            json!({"merge_state": "DIRTY"}),
            json!({"merge_state": "BLOCKED"}),
            json!({"head_sha": null}),
            json!({"unresolved_total": null}),
        ] {
            assert_eq!(classify(&pr(patch.clone()), ME), None, "{patch}");
        }
    }

    #[test]
    fn threads_and_a_human_reply_count_as_comments() {
        assert_eq!(
            classify(&pr(json!({"unresolved_total": 2, "merge_state": "BLOCKED"})), ME),
            Some((Verdict::Comments, 2))
        );
        assert_eq!(
            classify(&pr(json!({"human_said_something": true})), ME),
            Some((Verdict::Comments, 1))
        );
    }

    #[test]
    fn messages_name_the_pr_and_the_policy() {
        assert_eq!(
            message(URL, Verdict::Clean, 0),
            format!("PR {URL} is approved and clean: merge and ship it per the auto-merge policy")
        );
        assert_eq!(
            message(URL, Verdict::Comments, 1),
            format!("PR {URL} approved with 1 comment: classify blocking vs follow-up per the policy, then ship")
        );
        assert!(message(URL, Verdict::Comments, 3).contains("with 3 comments:"));
    }

    #[test]
    fn notifies_the_live_owner_once_per_head_and_verdict() {
        let owners = owned_by(&[S1, S2]);
        let mut state = State::default();
        let mut fake = Fake { live: vec![S2.into()], ..Fake::default() };

        let mut f = file(vec![pr(json!({}))]);
        process(&mut f, &owners, &mut state, &mut fake, 1000);
        assert_eq!(fake.sent.len(), 1);
        assert_eq!(fake.sent[0].0, S2);
        let mr = f.repos[0].prs[0].merge_ready.clone().unwrap();
        assert_eq!((mr.delivery, mr.session.as_deref()), (Delivery::Sent, Some(S2)));

        let mut f = file(vec![pr(json!({}))]);
        process(&mut f, &owners, &mut state, &mut fake, 2000);
        assert_eq!(fake.sent.len(), 1, "same head and verdict: no second message");
        assert_eq!(f.repos[0].prs[0].merge_ready.as_ref().unwrap().delivery, Delivery::Sent);

        let mut f = file(vec![pr(json!({"human_said_something": true}))]);
        process(&mut f, &owners, &mut state, &mut fake, 3000);
        assert_eq!(fake.sent.len(), 2, "new verdict on the same head notifies");
        assert!(fake.sent[1].1.contains("approved with 1 comment"));

        let mut f = file(vec![pr(json!({"head_sha": "def"}))]);
        process(&mut f, &owners, &mut state, &mut fake, 4000);
        assert_eq!(fake.sent.len(), 3, "new head notifies");
    }

    #[test]
    fn a_not_ready_pr_is_not_annotated_or_sent() {
        let mut state = State::default();
        let mut fake = Fake { live: vec![S1.into()], ..Fake::default() };
        let mut f = file(vec![pr(json!({"draft": true}))]);
        process(&mut f, &owned_by(&[S1]), &mut state, &mut fake, 0);
        assert!(fake.sent.is_empty());
        assert!(f.repos[0].prs[0].merge_ready.is_none());
    }

    #[test]
    fn unclaimed_or_closed_owner_is_surfaced_and_retried_after_the_throttle() {
        let mut state = State::default();
        let mut fake = Fake::default();
        let mut f = file(vec![pr(json!({}))]);
        process(&mut f, &owned_by(&[S1]), &mut state, &mut fake, 0);
        assert_eq!(f.repos[0].prs[0].merge_ready.as_ref().unwrap().delivery, Delivery::NoSession);

        fake.live.push(S1.into());
        let mut f = file(vec![pr(json!({}))]);
        process(&mut f, &owned_by(&[S1]), &mut state, &mut fake, RETRY_SECS - 1);
        assert!(fake.sent.is_empty(), "throttled");
        assert_eq!(f.repos[0].prs[0].merge_ready.as_ref().unwrap().delivery, Delivery::NoSession);

        let mut f = file(vec![pr(json!({}))]);
        process(&mut f, &owned_by(&[S1]), &mut state, &mut fake, RETRY_SECS);
        assert_eq!(fake.sent.len(), 1, "the resumed owner gets it");

        let mut state = State::default();
        let mut f = file(vec![pr(json!({}))]);
        process(&mut f, &Owners::default(), &mut state, &mut fake, 0);
        assert_eq!(f.repos[0].prs[0].merge_ready.as_ref().unwrap().delivery, Delivery::NoSession);
    }

    #[test]
    fn receiver_off_stops_after_one_attempt() {
        let mut state = State::default();
        let mut fake = Fake { receiver_off: true, ..Fake::default() };
        let mut f = file(vec![pr(json!({}))]);
        process(&mut f, &owned_by(&[S1, S2]), &mut state, &mut fake, 0);
        assert_eq!(f.repos[0].prs[0].merge_ready.as_ref().unwrap().delivery, Delivery::NoReceiver);
    }

    #[test]
    fn merged_prs_are_forgotten() {
        let owners = owned_by(&[S1]);
        let mut state = State::default();
        let mut fake = Fake { live: vec![S1.into()], ..Fake::default() };
        process(&mut file(vec![pr(json!({}))]), &owners, &mut state, &mut fake, 0);
        assert!(!state.sent.is_empty());
        process(&mut file(vec![pr(json!({"state": "MERGED"}))]), &owners, &mut state, &mut fake, 10);
        assert!(state.sent.is_empty() && state.tried.is_empty());
    }

    #[test]
    fn no_viewer_means_no_classification() {
        let mut f = file(vec![pr(json!({}))]);
        f.viewer = None;
        let mut fake = Fake { live: vec![S1.into()], ..Fake::default() };
        process(&mut f, &owned_by(&[S1]), &mut State::default(), &mut fake, 0);
        assert!(fake.sent.is_empty());
    }

    #[test]
    fn parses_the_created_pr_alist() {
        let text = r#"(("s-1" "Acme/Widget#7" "acme/other#2") ("s-2") ("s-\"3" "x/y#1"))"#;
        assert_eq!(
            parse_created_eld(text),
            vec![
                ("s-1".to_string(), vec!["Acme/Widget#7".to_string(), "acme/other#2".to_string()]),
                ("s-2".to_string(), vec![]),
                ("s-\"3".to_string(), vec!["x/y#1".to_string()]),
            ]
        );
        assert!(parse_created_eld("garbage \"x\" (").is_empty());
    }

    #[test]
    fn owners_come_from_linked_and_created_prs_newest_session_first() {
        let store = json!({"conversations": {
            "c1": {"sessions": [S1, S2], "linked_prs": [{"url": "https://github.com/Acme/Widget/pull/7/"}]},
            "c2": {"sessions": ["old"], "brokerKey": "s-9", "mergedInto": "c3"},
            "c3": {"sessions": ["new"]},
            "c4": {"sessions": [], "linked_prs": [{"url": URL}]}
        }});
        let created = vec![("s-9".to_string(), vec!["acme/widget#8".to_string()])];
        let owners = owners_from(&store, &created);
        assert_eq!(owners.sessions(&pr_key("acme/widget", 7)), [S2, S1]);
        assert_eq!(owners.sessions(&pr_key("acme/widget", 8)), ["new"]);
        assert!(owners.sessions(&pr_key("acme/widget", 9)).is_empty());
        assert!(owners_from(&Value::Null, &[]).sessions("x").is_empty());
    }

    #[test]
    fn annotation_serialises_for_the_sidebar() {
        let mr = MergeReady { verdict: Verdict::Comments, comments: 2, delivery: Delivery::NoSession, session: None };
        assert_eq!(
            serde_json::to_value(&mr).unwrap(),
            json!({"verdict": "comments", "comments": 2, "delivery": "no-session"})
        );
    }
}
