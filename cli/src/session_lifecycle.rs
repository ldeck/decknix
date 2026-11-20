//! `decknix session spawn | retire | dispatch status|on|off`: let a
//! coordinator scale its lanes up and down and switch the Emacs dispatch
//! receiver, through the same private request directory `send` uses.
//!
//! All three write version 3 requests (`v: 3` with a `kind`):
//!
//!   * `spawn` and `retire` go to `agent-dispatch/pending/`, read by the
//!     receiver (`decknix-agent-dispatch.el`). A spawn's receipt reads
//!     `launching` until `receipts/<id>.spawned.json` names the session.
//!   * `dispatch` (`op: on|off`) goes to `agent-dispatch/control/`, read by
//!     the separately enabled control watcher
//!     (`decknix-agent-dispatch-control.el`). The heartbeat's `control`
//!     field says whether it is running.
//!
//! The CLI does the cheap checks itself (idempotent spawn against the live
//! and saved sessions, exact retire targets, receiver state) so most
//! refusals never write a file. The receiver repeats the checks that
//! matter: its view of live sessions is the authoritative one.
//!
//! See docs/specs/session-messaging/spec.md section 10.

use anyhow::{bail, Result};
use clap::Subcommand;
use serde_json::{json, Value};
use std::fs;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use crate::session;
use crate::session_lookup::{self, Cand, Loaded, Outcome, Scope, Tier};
use crate::session_msg::{self, ago, now_secs, read_json, short, str_of, Dirs, Heartbeat};

pub const EXIT_USAGE: i32 = 2;
pub const EXIT_STALE: i32 = 15;
pub const EXIT_NO_CONTROL: i32 = 16;
pub const EXIT_WORKSPACE_MISMATCH: i32 = 23;

const MAX_TTL_SECS: i64 = 86400;
const CONTROL_TTL_SECS: i64 = 60;
const RETIRE_TTL_SECS: i64 = 3600;
const MAX_TAG_CHARS: usize = 80;
const MAX_REASON_CHARS: usize = 300;

#[derive(Subcommand)]
pub enum DispatchAction {
    /// Is the Emacs dispatch receiver on? Heartbeat age, who armed it,
    /// whether the control watcher runs, request counts (exit 0 on, 14 off,
    /// 15 no fresh heartbeat)
    Status {
        /// Emit JSON
        #[arg(long)]
        json: bool,
    },
    /// Turn the receiver on through the control watcher (ask the human first)
    On {
        /// Also release spawns queued with `spawn --queue` before arming
        #[arg(long)]
        release_queued: bool,
        /// Seconds to wait for the watcher to apply it
        #[arg(long, default_value_t = 15, value_name = "SECS")]
        wait: u64,
    },
    /// Turn the receiver off; waiting messages are settled `not-sent`
    Off {
        /// Seconds to wait for the watcher to apply it
        #[arg(long, default_value_t = 15, value_name = "SECS")]
        wait: u64,
    },
}

// ---------------------------------------------------------------------------
// Requests (pure apart from the id)
// ---------------------------------------------------------------------------

#[derive(Clone, Debug, Default)]
pub struct SpawnSpec {
    pub workspace: String,
    pub tags: Vec<String>,
    pub brief: String,
    pub agent: Option<String>,
    pub name: Option<String>,
    pub model: Option<String>,
    pub mode: Option<String>,
    pub resume_session_id: Option<String>,
    pub queue: bool,
    pub ttl: i64,
    pub from: Option<String>,
    pub from_name: Option<String>,
}

fn check_tags(tags: &[String]) -> Result<()> {
    if tags.is_empty() {
        bail!("give at least one --tag");
    }
    if let Some(t) = tags.iter().find(|t| t.trim().is_empty() || t.chars().count() > MAX_TAG_CHARS) {
        bail!("tag {:?} must be non-blank and at most {} characters", t, MAX_TAG_CHARS);
    }
    Ok(())
}

fn insert_opt(o: &mut serde_json::Map<String, Value>, k: &str, v: &Option<String>) {
    if let Some(x) = v.as_ref().filter(|x| !x.is_empty()) {
        o.insert(k.into(), json!(x));
    }
}

fn insert_sender(o: &mut serde_json::Map<String, Value>, from: &Option<String>, from_name: &Option<String>) {
    if let Some(f) = from.as_ref().filter(|f| session_msg::strict_uuid(f)) {
        o.insert("from".into(), json!(f));
    }
    if let Some(n) = from_name {
        o.insert("from_name".into(), json!(n.chars().take(80).collect::<String>()));
    }
}

pub fn build_spawn_request(id: &str, spec: &SpawnSpec, now: i64) -> Result<Value> {
    if !spec.workspace.starts_with('/') {
        bail!("workspace must be an absolute path: {}", spec.workspace);
    }
    check_tags(&spec.tags)?;
    session_msg::check_prompt(&spec.brief)?;
    if spec.ttl < 1 || spec.ttl > MAX_TTL_SECS {
        bail!("--ttl must be 1..{} seconds", MAX_TTL_SECS);
    }
    if let Some(r) = spec.resume_session_id.as_ref().filter(|r| !session_msg::strict_uuid(r)) {
        bail!("resume id must be a full lowercase UUID: {}", r);
    }
    let mut req = json!({
        "v": 3,
        "id": id,
        "kind": "spawn",
        "created_at": now,
        "expires_at": now + spec.ttl,
        "workspace": spec.workspace,
        "tags": spec.tags,
        "brief": spec.brief,
        "brief_sha256": session_msg::hex::sha256(spec.brief.as_bytes()),
    });
    let o = req.as_object_mut().unwrap();
    insert_opt(o, "agent", &spec.agent);
    insert_opt(o, "name", &spec.name);
    insert_opt(o, "model", &spec.model);
    insert_opt(o, "mode", &spec.mode);
    insert_opt(o, "resume_session_id", &spec.resume_session_id);
    if spec.queue {
        o.insert("queue".into(), json!(true));
    }
    insert_sender(o, &spec.from, &spec.from_name);
    Ok(req)
}

#[derive(Clone, Debug, Default)]
pub struct RetireSpec {
    pub session_id: String,
    pub expect_tags: Vec<String>,
    pub expect_buffer: Option<String>,
    pub reason: Option<String>,
    pub force: bool,
    pub from: Option<String>,
    pub from_name: Option<String>,
}

pub fn build_retire_request(id: &str, spec: &RetireSpec, now: i64) -> Result<Value> {
    if !session_msg::strict_uuid(&spec.session_id) {
        bail!("session id must be a full lowercase UUID: {}", spec.session_id);
    }
    if spec.reason.as_ref().map(|r| r.chars().count() > MAX_REASON_CHARS).unwrap_or(false) {
        bail!("--reason is limited to {} characters", MAX_REASON_CHARS);
    }
    let mut req = json!({
        "v": 3,
        "id": id,
        "kind": "retire",
        "created_at": now,
        "expires_at": now + RETIRE_TTL_SECS,
        "session_id": spec.session_id,
        "expect_tags": spec.expect_tags,
    });
    let o = req.as_object_mut().unwrap();
    insert_opt(o, "expect_buffer", &spec.expect_buffer);
    insert_opt(o, "reason", &spec.reason.as_ref().map(|r| r.trim().to_string()));
    if spec.force {
        o.insert("force".into(), json!(true));
    }
    insert_sender(o, &spec.from, &spec.from_name);
    Ok(req)
}

pub fn build_control_request(id: &str, on: bool, release_queued: bool, from: &Option<String>, now: i64) -> Value {
    let mut req = json!({
        "v": 3,
        "id": id,
        "kind": "dispatch",
        "op": if on { "on" } else { "off" },
        "created_at": now,
        "expires_at": now + CONTROL_TTL_SECS,
    });
    let o = req.as_object_mut().unwrap();
    if on && release_queued {
        o.insert("release_queued".into(), json!(true));
    }
    insert_sender(o, from, &None);
    req
}

// ---------------------------------------------------------------------------
// Decisions (pure)
// ---------------------------------------------------------------------------

/// `--tag us,lane-07 --tag PLAT-1` as `["us", "lane-07", "PLAT-1"]`.
pub fn split_tag_args(raw: &[String]) -> Vec<String> {
    raw.iter().flat_map(|t| t.split(',')).map(str::trim).filter(|t| !t.is_empty()).map(str::to_string).collect()
}

/// Candidates (live or saved, per LIVE) carrying every tag in TAGS exactly
/// or ignoring case. Normalised matches (`lane-7` for `lane-07`) do not
/// count: spawning must not mistake one lane for another.
pub fn exact_tag_matches(cands: &[Cand], tags: &[String], live: bool) -> Vec<usize> {
    (0..cands.len())
        .filter(|&i| cands[i].live == live)
        .filter(|&i| matches!(session_lookup::tags_tier(tags, &cands[i].tags), Some(Tier::Exact) | Some(Tier::Case)))
        .collect()
}

#[derive(Debug, PartialEq)]
pub enum SpawnPlan {
    /// One live session already carries the tags: report it, write nothing.
    Existing(usize),
    AmbiguousLive(Vec<usize>),
    AmbiguousSaved(Vec<usize>),
    /// The one saved session lives in another workspace.
    WorkspaceMismatch(usize),
    Resume(usize),
    New,
}

/// WORKSPACE is canonical. A saved session whose workspace is unknown is
/// resumed in WORKSPACE rather than refused.
pub fn plan_spawn(cands: &[Cand], tags: &[String], workspace: &str, no_resume: bool) -> SpawnPlan {
    let live = exact_tag_matches(cands, tags, true);
    match live.len() {
        1 => return SpawnPlan::Existing(live[0]),
        n if n > 1 => return SpawnPlan::AmbiguousLive(live),
        _ => {}
    }
    if no_resume {
        return SpawnPlan::New;
    }
    let saved = exact_tag_matches(cands, tags, false);
    match saved.len() {
        0 => SpawnPlan::New,
        1 => {
            let i = saved[0];
            match session_lookup::filled_workspace(&cands[i]) {
                Some(w) if session_lookup::canon_ws(&w) != workspace => SpawnPlan::WorkspaceMismatch(i),
                _ => SpawnPlan::Resume(i),
            }
        }
        _ => SpawnPlan::AmbiguousSaved(saved),
    }
}

#[derive(Debug, PartialEq)]
pub enum Gate {
    Go,
    Stale(String),
    Off(String),
}

/// May a lifecycle request be written? QUEUE skips the receiver checks: the
/// request waits for `dispatch on --release-queued`.
pub fn receiver_gate(hb: Option<&Heartbeat>, fresh: bool, queue: bool) -> Gate {
    if queue {
        return Gate::Go;
    }
    match hb {
        None => Gate::Stale("no Emacs heartbeat: is Emacs running with decknix-agent-session-export-mode?".into()),
        Some(_) if !fresh => Gate::Stale("the Emacs heartbeat is stale: Emacs is not running, or is stuck".into()),
        Some(h) if !h.receiver => Gate::Off(
            "the dispatch receiver is off, so nothing would act on this. Check `decknix session dispatch status`, \
             then ask the human before `decknix session dispatch on`"
                .into(),
        ),
        _ => Gate::Go,
    }
}

/// Is resolution R exact enough to retire by? A full id, or a buffer name
/// or tags matched exactly or ignoring case. An id prefix, a workspace or a
/// normalised match could name the wrong lane.
pub fn exact_retire_target(how: &str, tier: Option<Tier>) -> bool {
    matches!(how, "id" | "buffer" | "tags") && matches!(tier, Some(Tier::Exact) | Some(Tier::Case))
}

/// Which way `dispatch on|off` should go: Some(true) to publish, Some(false)
/// when the receiver is already there, Err(exit) when it cannot be asked.
pub fn control_plan(hb: Option<&Heartbeat>, fresh: bool, on: bool) -> std::result::Result<bool, (i32, String)> {
    let h = match hb {
        Some(h) if fresh => h,
        _ => return Err((EXIT_STALE, "no fresh Emacs heartbeat: is Emacs running?".into())),
    };
    if h.receiver == on {
        return Ok(false);
    }
    if !h.control {
        return Err((
            EXIT_NO_CONTROL,
            format!(
                "the dispatch control watcher is not running in Emacs, so the receiver cannot be switched from here; \
                 ask the human to run M-x decknix-agent-dispatch-mode{}",
                if on { "" } else { " (to turn it off)" }
            ),
        ));
    }
    Ok(true)
}

// ---------------------------------------------------------------------------
// Commands
// ---------------------------------------------------------------------------

fn expand_dir(p: &str) -> PathBuf {
    let raw = match p.strip_prefix("~/") {
        Some(rest) => dirs::home_dir().unwrap_or_default().join(rest),
        None if p == "~" => dirs::home_dir().unwrap_or_default(),
        None => PathBuf::from(p),
    };
    let raw = if raw.is_relative() { std::env::current_dir().unwrap_or_default().join(raw) } else { raw };
    raw.canonicalize().unwrap_or(raw)
}

fn read_brief(file: Option<String>, stdin: bool, args: Vec<String>) -> Result<String> {
    match (file, stdin, args.is_empty()) {
        (Some(f), false, true) => fs::read_to_string(&f).map_err(|e| anyhow::anyhow!("reading {}: {}", f, e)),
        (None, true, true) => {
            let mut s = String::new();
            std::io::stdin().read_to_string(&mut s)?;
            Ok(s)
        }
        (None, false, false) => Ok(args.join(" ")),
        _ => bail!("give the brief once: --brief-file F, --stdin, or after `--`"),
    }
}

fn sender(loaded: &Loaded, from: Option<String>) -> Result<(Option<String>, Option<String>)> {
    let from = from.or_else(session_msg::default_from);
    if let Some(f) = &from {
        if !session_msg::strict_uuid(f) {
            bail!("--from must be a full lowercase session UUID");
        }
    }
    let name = from
        .as_ref()
        .and_then(|f| loaded.live.sessions.iter().find(|v| str_of(v, "id") == f))
        .map(|v| str_of(v, "buffer").to_string())
        .filter(|n| !n.is_empty());
    Ok((from, name))
}

fn list(loaded: &Loaded, idx: &[usize]) {
    let now = now_secs();
    for &i in idx {
        eprintln!("  {}", session_lookup::cand_line(&loaded.cands[i], now));
    }
}

/// Poll a request's receipt until DONE says it is settled, or TIMEOUT.
fn wait_status(dispatch: &Path, id: &str, timeout: Duration, done: impl Fn(&str) -> bool) -> Option<Value> {
    let start = Instant::now();
    loop {
        let v = session_msg::message_status(dispatch, id, now_secs());
        if v.as_ref().map(|v| done(str_of(v, "state"))).unwrap_or(false) || start.elapsed() >= timeout {
            return v;
        }
        std::thread::sleep(Duration::from_millis(500));
    }
}

fn final_spawn_state(s: &str) -> bool {
    !matches!(s, "queued" | "waiting" | "launching" | "submitting" | "")
}

#[allow(clippy::too_many_arguments)]
pub fn cmd_spawn(
    workspace: &str,
    tags: Vec<String>,
    agent: String,
    name: Option<String>,
    model: Option<String>,
    mode: Option<String>,
    brief_file: Option<String>,
    stdin: bool,
    brief_args: Vec<String>,
    queue: bool,
    no_resume: bool,
    wait: u64,
    ttl: &str,
    from: Option<String>,
    json_out: bool,
) -> Result<i32> {
    let ws = expand_dir(workspace);
    if !ws.is_dir() {
        eprintln!("workspace does not exist: {}", ws.display());
        return Ok(EXIT_USAGE);
    }
    let ws = ws.to_string_lossy().trim_end_matches('/').to_string();
    let tags = split_tag_args(&tags);
    check_tags(&tags)?;
    let brief = read_brief(brief_file, stdin, brief_args)?;
    session_msg::check_prompt(&brief)?;
    let ttl = session_msg::parse_ttl(ttl)?;

    let dirs = Dirs::resolve()?;
    let loaded = session_lookup::load(&dirs)?;
    let now = now_secs();
    let resume = match plan_spawn(&loaded.cands, &tags, &ws, no_resume) {
        SpawnPlan::Existing(i) => {
            let c = &loaded.cands[i];
            if json_out {
                let mut v = session_lookup::cand_json(c, now);
                v["outcome"] = json!("existing");
                println!("{}", serde_json::to_string_pretty(&v)?);
            } else {
                println!("{}", c.id);
                eprintln!("existing: {}", session_lookup::cand_line(c, now));
            }
            return Ok(0);
        }
        SpawnPlan::AmbiguousLive(v) => {
            eprintln!("{} live sessions carry {}; retire or retag one first:", v.len(), tags.join(","));
            list(&loaded, &v);
            return Ok(session_lookup::EXIT_AMBIGUOUS);
        }
        SpawnPlan::AmbiguousSaved(v) => {
            eprintln!("{} saved sessions carry {}; resume one by id, or pass --no-resume to start fresh:", v.len(), tags.join(","));
            list(&loaded, &v);
            return Ok(session_lookup::EXIT_AMBIGUOUS);
        }
        SpawnPlan::WorkspaceMismatch(i) => {
            let c = &loaded.cands[i];
            eprintln!(
                "the saved session carrying {} is in {}, not {}; pass that --workspace, or --no-resume to start fresh:",
                tags.join(","),
                session_lookup::filled_workspace(c).unwrap_or_default(),
                ws
            );
            list(&loaded, &[i]);
            return Ok(EXIT_WORKSPACE_MISMATCH);
        }
        SpawnPlan::Resume(i) => Some(loaded.cands[i].id.clone()),
        SpawnPlan::New => None,
    };
    let receiver_on = loaded.live.fresh && loaded.live.heartbeat.as_ref().map(|h| h.receiver).unwrap_or(false);
    match receiver_gate(loaded.live.heartbeat.as_ref(), loaded.live.fresh, queue) {
        Gate::Go => {}
        Gate::Stale(why) => {
            eprintln!("not spawned: {}", why);
            return Ok(EXIT_STALE);
        }
        Gate::Off(why) => {
            eprintln!("not spawned: {}", why);
            return Ok(session_msg::EXIT_NO_RECEIVER);
        }
    }
    let (from, from_name) = sender(&loaded, from)?;
    let spec = SpawnSpec {
        workspace: ws.clone(),
        tags: tags.clone(),
        brief,
        agent: Some(agent),
        name,
        model,
        mode,
        resume_session_id: resume.clone(),
        queue,
        ttl,
        from,
        from_name,
    };
    let id = session::new_uuid_v4()?;
    let req = build_spawn_request(&id, &spec, now)?;
    session_msg::publish_request(&dirs.dispatch, &req)?;
    if !json_out {
        eprintln!(
            "spawn {} requested for {} in {}{}",
            short(&id),
            tags.join(","),
            ws,
            resume.as_ref().map(|r| format!(" (resuming {})", short(r))).unwrap_or_default()
        );
    }
    if wait == 0 || !receiver_on {
        if !json_out {
            println!("{}", id);
            if !receiver_on {
                eprintln!("queued: released by `decknix session dispatch on --release-queued` (after asking the human)");
            }
            eprintln!("check: decknix session message {}", id);
        } else {
            println!("{}", serde_json::to_string(&json!({"id": id, "state": "queued"}))?);
        }
        return Ok(session_msg::EXIT_PENDING);
    }
    let v = wait_status(&dirs.dispatch, &id, Duration::from_secs(wait), final_spawn_state)
        .unwrap_or_else(|| json!({"id": id, "state": "queued"}));
    let state = str_of(&v, "state").to_string();
    if json_out {
        println!("{}", serde_json::to_string_pretty(&v)?);
    } else if state == "spawned" {
        println!("{}", str_of(&v, "session_id"));
        eprintln!("{}: {} ({})", str_of(&v, "outcome"), str_of(&v, "buffer"), short(&id));
    } else {
        eprintln!(
            "{} {}{}",
            short(&id),
            state,
            v.get("reason").and_then(Value::as_str).map(|r| format!(" ({})", r)).unwrap_or_default()
        );
        if !final_spawn_state(&state) {
            eprintln!("still {} after {}; check: decknix session message {}", state, ago(Some(wait as i64)), id);
        }
    }
    Ok(session_msg::exit_for(&state))
}

pub fn cmd_retire(target: &str, reason: Option<String>, force: bool, wait: u64, json_out: bool) -> Result<i32> {
    let dirs = Dirs::resolve()?;
    let loaded = session_lookup::load(&dirs)?;
    let now = now_secs();
    let r = session_lookup::resolve(target, &loaded.cands, Scope::Live);
    if r.outcome != Outcome::Match {
        eprintln!("{}", session_lookup::explain(&r, &loaded.cands, now));
        if let Some(n) = loaded.heartbeat_note() {
            eprintln!("note: {}", n);
        }
        return Ok(session_lookup::exit_code(&r.outcome));
    }
    let c = &loaded.cands[r.matches[0]];
    if !exact_retire_target(r.how, r.tier) {
        eprintln!(
            "retire needs an exact target: {:?} matched by {} ({}). Use the full id, the buffer name or the exact tags:",
            target,
            r.how,
            r.tier.map(|t| format!("{:?}", t).to_lowercase()).unwrap_or_default()
        );
        list(&loaded, &[r.matches[0]]);
        return Ok(session_lookup::EXIT_AMBIGUOUS);
    }
    if session_lookup::self_id().as_deref() == Some(c.id.as_str()) && !force {
        eprintln!("that is this session; retiring yourself needs --force");
        return Ok(EXIT_USAGE);
    }
    match receiver_gate(loaded.live.heartbeat.as_ref(), loaded.live.fresh, false) {
        Gate::Go => {}
        Gate::Stale(why) => {
            eprintln!("not retired: {}", why);
            return Ok(EXIT_STALE);
        }
        Gate::Off(why) => {
            eprintln!("not retired: {}", why);
            return Ok(session_msg::EXIT_NO_RECEIVER);
        }
    }
    let (from, from_name) = sender(&loaded, None)?;
    let spec = RetireSpec {
        session_id: c.id.clone(),
        expect_tags: c.tags.clone(),
        expect_buffer: c.buffer.clone(),
        reason,
        force,
        from,
        from_name,
    };
    let id = session::new_uuid_v4()?;
    let req = build_retire_request(&id, &spec, now)?;
    session_msg::publish_request(&dirs.dispatch, &req)?;
    if !json_out {
        eprintln!("retire {} requested for {} ({})", short(&id), c.buffer.as_deref().unwrap_or("-"), short(&c.id));
    }
    let v = wait_status(&dirs.dispatch, &id, Duration::from_secs(wait), |s| !matches!(s, "queued" | "waiting" | "submitting" | ""))
        .unwrap_or_else(|| json!({"id": id, "state": "queued"}));
    let state = str_of(&v, "state").to_string();
    if json_out {
        println!("{}", serde_json::to_string_pretty(&v)?);
    } else {
        println!("{}  {}{}", short(&id), state, v.get("reason").and_then(Value::as_str).map(|r| format!(" ({})", r)).unwrap_or_default());
        if matches!(state.as_str(), "queued" | "waiting") {
            eprintln!("the lane is still busy; it is retired when its turn ends (or the request expires in 1h). check: decknix session message {}", id);
        }
    }
    Ok(session_msg::exit_for(&state))
}

fn count_json(dir: &Path, pred: impl Fn(&Value) -> bool) -> usize {
    fs::read_dir(dir)
        .map(|rd| {
            rd.flatten()
                .filter(|e| e.file_name().to_string_lossy().ends_with(".json"))
                .filter(|e| read_json(&e.path()).map(|v| pred(&v)).unwrap_or(false))
                .count()
        })
        .unwrap_or(0)
}

fn waiting_ids(dispatch: &Path) -> Vec<String> {
    let mut ids: Vec<String> = fs::read_dir(dispatch.join("inflight"))
        .map(|rd| {
            rd.flatten()
                .filter_map(|e| e.file_name().to_string_lossy().strip_suffix(".json").map(str::to_string))
                .collect()
        })
        .unwrap_or_default();
    ids.sort();
    ids
}

fn load_heartbeat(dirs: &Dirs) -> (Option<Heartbeat>, bool) {
    let hb = read_json(&dirs.sessions.join("_emacs.json")).and_then(|v| Heartbeat::from_value(&v));
    let fresh = hb.as_ref().map(|h| h.fresh(now_secs(), session_msg::pid_alive)).unwrap_or(false);
    (hb, fresh)
}

pub fn cmd_dispatch(action: DispatchAction) -> Result<i32> {
    match action {
        DispatchAction::Status { json } => cmd_dispatch_status(json),
        DispatchAction::On { release_queued, wait } => cmd_dispatch_switch(true, release_queued, wait),
        DispatchAction::Off { wait } => cmd_dispatch_switch(false, false, wait),
    }
}

fn cmd_dispatch_status(json_out: bool) -> Result<i32> {
    let dirs = Dirs::resolve()?;
    let (hb, fresh) = load_heartbeat(&dirs);
    let now = now_secs();
    let pending = count_json(&dirs.dispatch.join("pending"), |_| true);
    let queued = count_json(&dirs.dispatch.join("pending"), |v| v.get("queue").and_then(Value::as_bool).unwrap_or(false));
    let inflight = count_json(&dirs.dispatch.join("inflight"), |_| true);
    let receiver = fresh && hb.as_ref().map(|h| h.receiver).unwrap_or(false);
    let code = if !fresh { EXIT_STALE } else if receiver { 0 } else { session_msg::EXIT_NO_RECEIVER };
    if json_out {
        println!(
            "{}",
            serde_json::to_string_pretty(&json!({
                "heartbeat": hb.as_ref().map(|h| json!({"pid": h.pid, "at": h.at, "age": now - h.at, "fresh": fresh})),
                "receiver": receiver,
                "armed_at": hb.as_ref().and_then(|h| h.armed_at),
                "armed_by": hb.as_ref().and_then(|h| h.armed_by.clone()),
                "control": fresh && hb.as_ref().map(|h| h.control).unwrap_or(false),
                "remote_control": hb.as_ref().and_then(|h| h.remote_control),
                "pending": pending,
                "queued": queued,
                "inflight": inflight,
            }))?
        );
        return Ok(code);
    }
    match &hb {
        None => println!("heartbeat  none (is Emacs running with decknix-agent-session-export-mode?)"),
        Some(h) => println!("heartbeat  {} ago, pid {}{}", ago(Some(now - h.at)), h.pid, if fresh { "" } else { " (STALE)" }),
    }
    let armed = hb
        .as_ref()
        .filter(|_| receiver)
        .map(|h| {
            format!(
                ", armed {} ago by {}",
                ago(h.armed_at.map(|a| now - a)),
                h.armed_by.as_deref().unwrap_or("?")
            )
        })
        .unwrap_or_default();
    println!("receiver   {}{}", if receiver { "on" } else { "OFF" }, armed);
    let control = hb.as_ref().map(|h| fresh && h.control).unwrap_or(false);
    println!(
        "control    {}",
        if !control {
            "not running (only the human can switch the receiver: M-x decknix-agent-dispatch-mode)".to_string()
        } else if hb.as_ref().and_then(|h| h.remote_control) == Some(false) {
            "running; remote `on` disabled (off still works)".to_string()
        } else {
            "running (decknix session dispatch on|off)".to_string()
        }
    );
    println!("requests   {} pending ({} queued spawn), {} in flight", pending, queued, inflight);
    Ok(code)
}

fn cmd_dispatch_switch(on: bool, release_queued: bool, wait: u64) -> Result<i32> {
    let dirs = Dirs::resolve()?;
    let (hb, fresh) = load_heartbeat(&dirs);
    match control_plan(hb.as_ref(), fresh, on) {
        Err((code, why)) => {
            eprintln!("{}", why);
            return Ok(code);
        }
        Ok(false) => {
            println!("receiver already {}", if on { "on" } else { "off" });
            return Ok(0);
        }
        Ok(true) => {}
    }
    if !on {
        let waiting = waiting_ids(&dirs.dispatch);
        if !waiting.is_empty() {
            eprintln!(
                "warning: {} waiting request(s) will be settled not-sent (disarmed): {}",
                waiting.len(),
                waiting.iter().map(|w| short(w).to_string()).collect::<Vec<_>>().join(" ")
            );
        }
    }
    let id = session::new_uuid_v4()?;
    let req = build_control_request(&id, on, release_queued, &session_msg::default_from(), now_secs());
    session_msg::publish_to(&dirs.dispatch, "control", &req)?;
    let v = wait_status(&dirs.dispatch, &id, Duration::from_secs(wait), |s| !s.is_empty() && s != "queued");
    let state = v.as_ref().map(|v| str_of(v, "state").to_string()).unwrap_or_default();
    if state != "applied" {
        match v.as_ref().filter(|_| !state.is_empty()) {
            Some(v) => eprintln!("not switched: {}{}", state, v.get("reason").and_then(Value::as_str).map(|r| format!(" ({})", r)).unwrap_or_default()),
            None => {
                let _ = fs::remove_file(dirs.dispatch.join("control").join(format!("{}.json", id)));
                eprintln!("the control watcher did not pick the request up within {}s; withdrawn", wait);
                return Ok(session_msg::EXIT_PENDING);
            }
        }
        return Ok(session_msg::exit_for(&state));
    }
    let start = Instant::now();
    loop {
        let (hb, _) = load_heartbeat(&dirs);
        if hb.as_ref().map(|h| h.receiver == on).unwrap_or(false) || start.elapsed() >= Duration::from_secs(5) {
            let h = hb.unwrap_or_default();
            if on {
                println!("receiver on (armed by {})", h.armed_by.as_deref().unwrap_or("control"));
            } else {
                println!("receiver off");
            }
            return Ok(0);
        }
        std::thread::sleep(Duration::from_millis(300));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const LANE: &str = "11111111-2222-4333-8444-555555555555";
    const OTHER: &str = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee";
    const RID: &str = "99999999-8888-4777-8666-555555555555";

    fn cand(id: &str, live: bool, tags: &[&str], ws: Option<&str>) -> Cand {
        Cand {
            id: id.into(),
            live,
            state: if live { "idle".into() } else { "saved".into() },
            tags: tags.iter().map(|t| t.to_string()).collect(),
            workspace: ws.map(str::to_string),
            ..Default::default()
        }
    }

    fn tags(t: &[&str]) -> Vec<String> {
        t.iter().map(|s| s.to_string()).collect()
    }

    fn spawn_spec() -> SpawnSpec {
        SpawnSpec {
            workspace: "/ws".into(),
            tags: tags(&["us", "lane-07"]),
            brief: "Pick up lane 07.".into(),
            agent: Some("claude".into()),
            ttl: 3600,
            ..Default::default()
        }
    }

    #[test]
    fn spawn_request_is_v3_with_a_brief_hash() {
        let mut s = spawn_spec();
        s.queue = true;
        s.mode = Some("auto".into());
        s.from = Some(OTHER.into());
        let r = build_spawn_request(RID, &s, 1000).unwrap();
        assert_eq!(r["v"], json!(3));
        assert_eq!(r["kind"], json!("spawn"));
        assert_eq!(r["tags"], json!(["us", "lane-07"]));
        assert_eq!(r["expires_at"], json!(4600));
        assert_eq!(r["brief_sha256"], json!(session_msg::hex::sha256(b"Pick up lane 07.")));
        assert_eq!(r["queue"], json!(true));
        assert_eq!(r["mode"], json!("auto"));
        assert_eq!(r["from"], json!(OTHER));
        assert!(r.get("resume_session_id").is_none());
        assert!(r.get("model").is_none());
    }

    #[test]
    fn spawn_request_validation() {
        let bad = |f: &dyn Fn(&mut SpawnSpec)| {
            let mut s = spawn_spec();
            f(&mut s);
            build_spawn_request(RID, &s, 0).is_err()
        };
        assert!(bad(&|s| s.workspace = "relative".into()));
        assert!(bad(&|s| s.tags.clear()));
        assert!(bad(&|s| s.tags = tags(&[" "])));
        assert!(bad(&|s| s.brief = "help".into()));
        assert!(bad(&|s| s.ttl = MAX_TTL_SECS + 1));
        assert!(bad(&|s| s.resume_session_id = Some("1111".into())));
        assert!(!bad(&|s| s.resume_session_id = Some(LANE.into())));
    }

    #[test]
    fn retire_and_control_requests() {
        let r = build_retire_request(
            RID,
            &RetireSpec { session_id: LANE.into(), expect_tags: tags(&["us", "lane-07"]), expect_buffer: Some("*Claude: us/lane-07*".into()), force: true, ..Default::default() },
            1000,
        )
        .unwrap();
        assert_eq!(r["kind"], json!("retire"));
        assert_eq!(r["expect_tags"], json!(["us", "lane-07"]));
        assert_eq!(r["force"], json!(true));
        assert_eq!(r["expires_at"], json!(1000 + RETIRE_TTL_SECS));
        assert!(build_retire_request(RID, &RetireSpec { session_id: "abc".into(), ..Default::default() }, 0).is_err());
        let c = build_control_request(RID, true, true, &None, 1000);
        assert_eq!(c["kind"], json!("dispatch"));
        assert_eq!(c["op"], json!("on"));
        assert_eq!(c["release_queued"], json!(true));
        assert_eq!(c["expires_at"], json!(1060));
        assert!(build_control_request(RID, false, true, &None, 1000).get("release_queued").is_none());
    }

    #[test]
    fn tag_args_split_on_commas() {
        assert_eq!(split_tag_args(&tags(&["us,lane-07", " PLAT-1 "])), tags(&["us", "lane-07", "PLAT-1"]));
    }

    #[test]
    fn an_existing_live_lane_is_reported_and_nothing_is_written() {
        let cs = vec![cand(LANE, true, &["US", "lane-07", "PLAT-1"], Some("/ws")), cand(OTHER, true, &["us", "lane-08"], None)];
        assert_eq!(plan_spawn(&cs, &tags(&["us", "lane-07"]), "/ws", false), SpawnPlan::Existing(0));
        let dir = tempfile::tempdir().unwrap();
        assert!(fs::read_dir(dir.path()).unwrap().next().is_none());
    }

    #[test]
    fn a_normalised_tag_does_not_count_as_the_lane() {
        let cs = vec![cand(LANE, true, &["us", "lane-7"], None)];
        assert_eq!(plan_spawn(&cs, &tags(&["us", "lane-07"]), "/ws", false), SpawnPlan::New);
    }

    #[test]
    fn two_live_lanes_are_ambiguous() {
        let cs = vec![cand(LANE, true, &["us", "lane-07"], None), cand(OTHER, true, &["us", "lane-07"], None)];
        assert!(matches!(plan_spawn(&cs, &tags(&["us", "lane-07"]), "/ws", false), SpawnPlan::AmbiguousLive(v) if v.len() == 2));
    }

    #[test]
    fn a_saved_lane_is_resumed_unless_its_workspace_differs() {
        let cs = vec![cand(LANE, false, &["us", "lane-07"], Some("/ws"))];
        assert_eq!(plan_spawn(&cs, &tags(&["us", "lane-07"]), "/ws", false), SpawnPlan::Resume(0));
        assert_eq!(plan_spawn(&cs, &tags(&["us", "lane-07"]), "/elsewhere", false), SpawnPlan::WorkspaceMismatch(0));
        assert_eq!(plan_spawn(&cs, &tags(&["us", "lane-07"]), "/elsewhere", true), SpawnPlan::New);
        let two = vec![cand(LANE, false, &["us", "lane-07"], None), cand(OTHER, false, &["us", "lane-07"], None)];
        assert!(matches!(plan_spawn(&two, &tags(&["us", "lane-07"]), "/ws", false), SpawnPlan::AmbiguousSaved(_)));
        assert_eq!(plan_spawn(&two, &tags(&["us", "lane-07"]), "/ws", true), SpawnPlan::New);
    }

    #[test]
    fn the_receiver_gate() {
        let on = Heartbeat { pid: 1, at: 1, receiver: true, ..Default::default() };
        let off = Heartbeat { pid: 1, at: 1, receiver: false, ..Default::default() };
        assert_eq!(receiver_gate(Some(&on), true, false), Gate::Go);
        assert!(matches!(receiver_gate(Some(&off), true, false), Gate::Off(_)));
        assert!(matches!(receiver_gate(Some(&on), false, false), Gate::Stale(_)));
        assert!(matches!(receiver_gate(None, false, false), Gate::Stale(_)));
        assert_eq!(receiver_gate(Some(&off), true, true), Gate::Go);
        assert_eq!(receiver_gate(None, false, true), Gate::Go);
    }

    #[test]
    fn retire_needs_an_exact_target() {
        assert!(exact_retire_target("id", Some(Tier::Exact)));
        assert!(exact_retire_target("tags", Some(Tier::Case)));
        assert!(exact_retire_target("buffer", Some(Tier::Exact)));
        assert!(!exact_retire_target("tags", Some(Tier::Loose)));
        assert!(!exact_retire_target("id-prefix", Some(Tier::Exact)));
        assert!(!exact_retire_target("workspace", Some(Tier::Exact)));
    }

    #[test]
    fn retire_resolution_tiers_come_from_the_resolver() {
        let cs = vec![cand(LANE, true, &["us", "lane-07"], None), cand(OTHER, true, &["us", "lane-08"], None)];
        let r = session_lookup::resolve("us,lane-07", &cs, Scope::Live);
        assert_eq!(r.outcome, Outcome::Match);
        assert!(exact_retire_target(r.how, r.tier));
        let r = session_lookup::resolve("us,lane-7", &cs, Scope::Live);
        assert_eq!(r.outcome, Outcome::Match);
        assert!(!exact_retire_target(r.how, r.tier));
        let r = session_lookup::resolve(&LANE[..8], &cs, Scope::Live);
        assert!(!exact_retire_target(r.how, r.tier));
        let r = session_lookup::resolve(LANE, &cs, Scope::Live);
        assert!(exact_retire_target(r.how, r.tier));
    }

    #[test]
    fn dispatch_switch_plan() {
        let on = Heartbeat { pid: 1, at: 1, receiver: true, control: true, ..Default::default() };
        let off_no_control = Heartbeat { pid: 1, at: 1, receiver: false, control: false, ..Default::default() };
        assert_eq!(control_plan(Some(&on), true, true), Ok(false));
        assert_eq!(control_plan(Some(&on), true, false), Ok(true));
        assert_eq!(control_plan(Some(&off_no_control), true, false), Ok(false));
        assert_eq!(control_plan(Some(&off_no_control), true, true).unwrap_err().0, EXIT_NO_CONTROL);
        assert!(control_plan(Some(&off_no_control), true, true).unwrap_err().1.contains("M-x decknix-agent-dispatch-mode"));
        assert_eq!(control_plan(Some(&on), false, false).unwrap_err().0, EXIT_STALE);
        assert_eq!(control_plan(None, false, true).unwrap_err().0, EXIT_STALE);
    }

    #[test]
    fn control_requests_go_to_control_and_spawns_to_pending() {
        let dir = tempfile::tempdir().unwrap();
        let d = dir.path().join("agent-dispatch");
        let c = build_control_request(RID, true, false, &None, 1000);
        let p = session_msg::publish_to(&d, "control", &c).unwrap();
        assert_eq!(p, d.join("control").join(format!("{}.json", RID)));
        let s = build_spawn_request(OTHER, &spawn_spec(), 1000).unwrap();
        let p = session_msg::publish_request(&d, &s).unwrap();
        assert_eq!(p, d.join("pending").join(format!("{}.json", OTHER)));
        assert_eq!(count_json(&d.join("pending"), |_| true), 1);
    }
}
