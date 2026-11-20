//! `decknix session status | list --live | send | message | watch | inbox`:
//! let one agent session see what another is doing and message it.
//!
//! Two file contracts are shared with Emacs, so none of these commands talks
//! to Emacs directly:
//!
//!   * Lane state, written by `decknix-agent-session-export.el`:
//!     `$XDG_STATE_HOME/decknix/sessions/<id>.json` plus `_emacs.json`, a
//!     heartbeat. A file is only trusted while the heartbeat is fresh and was
//!     written by the same Emacs.
//!   * Messages, read by `decknix-agent-dispatch.el` (the explicit-approval
//!     dispatcher): `$XDG_STATE_HOME/decknix/agent-dispatch/` with `pending/`,
//!     `inflight/`, `receipts/`, `notices/` and `control/`. `send` writes a
//!     version 2 request; version 1 belongs to the `decknix-agent-dispatch`
//!     script; version 3 (spawn, retire, dispatch on|off) is written by
//!     `session_lifecycle.rs`.
//!
//! See docs/specs/session-messaging/spec.md.

use anyhow::{anyhow, bail, Context, Result};
use serde_json::{json, Value};
use std::fs;
use std::io::Read;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use crate::session;
use crate::session_lookup;

pub const EXIT_PENDING: i32 = 10;
pub const EXIT_NOT_DELIVERED: i32 = 11;
pub const EXIT_UNKNOWN: i32 = 12;
pub const EXIT_BUSY: i32 = 13;
pub const EXIT_NO_RECEIVER: i32 = 14;
pub const EXIT_TIMEOUT: i32 = 124;

const MAX_PROMPT_BYTES: usize = 65536;
const MAX_REASON_CHARS: usize = 300;
const MAX_TTL_SECS: i64 = 7 * 24 * 3600;
const NOW_TTL_SECS: i64 = 60;
const RESERVED_PROMPTS: [&str; 3] = ["help", "clear", "config"];
const DISPATCH_SUBDIRS: [&str; 6] = ["pending", "inflight", "receipts", "tmp", "notices", "control"];

// ---------------------------------------------------------------------------
// Paths
// ---------------------------------------------------------------------------

pub struct Dirs {
    pub sessions: PathBuf,
    pub dispatch: PathBuf,
    pub store: PathBuf,
}

impl Dirs {
    pub fn resolve() -> Result<Self> {
        let home = dirs::home_dir().ok_or_else(|| anyhow!("cannot determine home directory"))?;
        let state = std::env::var_os("XDG_STATE_HOME")
            .map(PathBuf::from)
            .unwrap_or_else(|| home.join(".local/state"))
            .join("decknix");
        let env_dir = |k: &str, d: PathBuf| std::env::var_os(k).map(PathBuf::from).unwrap_or(d);
        Ok(Dirs {
            sessions: env_dir("DECKNIX_SESSION_STATE_DIR", state.join("sessions")),
            dispatch: env_dir("DECKNIX_AGENT_DISPATCH_DIR", state.join("agent-dispatch")),
            store: home.join(".config/decknix/agent-sessions.json"),
        })
    }
}

pub(crate) fn now_secs() -> i64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0)
}

/// Exactly a lowercase 36-character UUID, the only form the receiver accepts.
pub fn strict_uuid(s: &str) -> bool {
    session::looks_like_uuid(s) && !s.bytes().any(|c| c.is_ascii_uppercase())
}

pub(crate) fn short(id: &str) -> &str {
    if id.len() >= 8 { &id[..8] } else { id }
}

pub(crate) fn read_json(path: &Path) -> Option<Value> {
    serde_json::from_str(&fs::read_to_string(path).ok()?).ok()
}

pub fn parse_ttl(s: &str) -> Result<i64> {
    let s = s.trim().to_lowercase();
    let (num, mult) = [("d", 86400), ("h", 3600), ("m", 60), ("s", 1)]
        .iter()
        .find_map(|(suf, m)| s.strip_suffix(suf).map(|n| (n.to_string(), *m)))
        .unwrap_or((s.clone(), 1));
    let n: i64 = num.parse().map_err(|_| anyhow!("bad duration {:?} (use e.g. 90s, 30m, 24h, 7d)", s))?;
    if n <= 0 {
        bail!("duration must be positive: {:?}", s);
    }
    Ok(n * mult)
}

// ---------------------------------------------------------------------------
// Lane state
// ---------------------------------------------------------------------------

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Heartbeat {
    pub pid: i64,
    pub at: i64,
    pub interval: i64,
    pub receiver: bool,
    /// The control watcher is running, so `session dispatch on|off` works.
    pub control: bool,
    pub armed_at: Option<i64>,
    /// `human` or `control:<sender>`.
    pub armed_by: Option<String>,
    /// Whether a control request may turn the receiver on.
    pub remote_control: Option<bool>,
}

impl Heartbeat {
    pub(crate) fn from_value(v: &Value) -> Option<Self> {
        Some(Heartbeat {
            pid: v.get("pid")?.as_i64()?,
            at: v.get("at")?.as_i64()?,
            interval: v.get("interval").and_then(Value::as_i64).unwrap_or(30),
            receiver: v.get("receiver").and_then(Value::as_bool).unwrap_or(false),
            control: v.get("control").and_then(Value::as_bool).unwrap_or(false),
            armed_at: v.get("armed_at").and_then(Value::as_i64),
            armed_by: v.get("armed_by").and_then(Value::as_str).map(str::to_string),
            remote_control: v.get("remote_control").and_then(Value::as_bool),
        })
    }

    /// Fresh while written within three intervals by a running process.
    pub fn fresh(&self, now: i64, alive: impl Fn(i64) -> bool) -> bool {
        now - self.at <= 3 * self.interval.max(1) && alive(self.pid)
    }
}

pub(crate) fn pid_alive(pid: i64) -> bool {
    if pid <= 0 || pid > i32::MAX as i64 {
        return false;
    }
    let rc = unsafe { libc::kill(pid as i32, 0) };
    rc == 0 || std::io::Error::last_os_error().raw_os_error() == Some(libc::EPERM)
}

pub struct Live {
    pub heartbeat: Option<Heartbeat>,
    pub fresh: bool,
    pub sessions: Vec<Value>,
}

/// Add what a reader needs on top of the exported file: staleness, tags and
/// durations relative to NOW. Tags Emacs exported win (they are what the
/// sidebar shows); the store's are the fallback for older exports. Pure.
pub fn enrich(mut v: Value, hb: Option<&Heartbeat>, fresh: bool, tags: Option<&Value>, now: i64) -> Value {
    let same_emacs = hb.map(|h| v.get("emacs_pid").and_then(Value::as_i64) == Some(h.pid)).unwrap_or(false);
    let stale = !(fresh && same_emacs);
    let since = |k: &str| v.get(k).and_then(Value::as_i64).map(|t| (now - t).max(0));
    let quiet = since("last_activity");
    let busy_for = since("busy_since");
    let state_for = since("state_since");
    if let Some(o) = v.as_object_mut() {
        o.insert("stale".into(), json!(stale));
        let exported = o.get("tags").and_then(Value::as_array).map(|a| !a.is_empty()).unwrap_or(false);
        if !exported {
            o.insert("tags".into(), tags.cloned().unwrap_or_else(|| json!([])));
        }
        o.insert("quiet_for".into(), json!(quiet));
        o.insert("busy_for".into(), json!(busy_for));
        o.insert("state_for".into(), json!(state_for));
        o.insert("receiver".into(), json!(hb.map(|h| h.receiver && fresh).unwrap_or(false)));
    }
    v
}

pub fn load_live(dirs: &Dirs, now: i64) -> Result<Live> {
    let heartbeat = read_json(&dirs.sessions.join("_emacs.json")).and_then(|v| Heartbeat::from_value(&v));
    let fresh = heartbeat.as_ref().map(|h| h.fresh(now, pid_alive)).unwrap_or(false);
    let store = session::load_store(&dirs.store).unwrap_or_else(|_| json!({}));
    let tag_index = session::session_tag_index(&store);
    let mut sessions = Vec::new();
    if let Ok(rd) = fs::read_dir(&dirs.sessions) {
        for e in rd.flatten() {
            let name = e.file_name().to_string_lossy().to_string();
            if name.starts_with('_') || name.starts_with('.') || !name.ends_with(".json") {
                continue;
            }
            if let Some(v) = read_json(&e.path()) {
                let id = v.get("id").and_then(Value::as_str).unwrap_or("").to_string();
                sessions.push(enrich(v, heartbeat.as_ref(), fresh, tag_index.get(&id), now));
            }
        }
    }
    sessions.sort_by(|a, b| str_of(a, "buffer").cmp(str_of(b, "buffer")));
    Ok(Live { heartbeat, fresh, sessions })
}

pub(crate) fn str_of<'a>(v: &'a Value, k: &str) -> &'a str {
    v.get(k).and_then(Value::as_str).unwrap_or("")
}

fn tags_of(v: &Value) -> Vec<String> {
    v.get("tags")
        .and_then(Value::as_array)
        .map(|a| a.iter().filter_map(|t| t.as_str().map(str::to_string)).collect())
        .unwrap_or_default()
}

fn usable(v: &Value) -> bool {
    !v.get("stale").and_then(Value::as_bool).unwrap_or(true) && str_of(v, "state") != "dead"
}

pub(crate) fn ago(secs: Option<i64>) -> String {
    match secs {
        None => "-".into(),
        Some(s) if s < 90 => format!("{}s", s),
        Some(s) if s < 5400 => format!("{}m", s / 60),
        Some(s) if s < 172800 => format!("{}h", s / 3600),
        Some(s) => format!("{}d", s / 86400),
    }
}

fn opt_i64(v: &Value, k: &str) -> Option<i64> {
    v.get(k).and_then(Value::as_i64)
}

/// One-line summary used by `list --live` and in `send` output.
pub fn summary_line(v: &Value) -> String {
    let state = if v.get("stale").and_then(Value::as_bool).unwrap_or(true) {
        format!("{} (stale)", str_of(v, "state"))
    } else {
        str_of(v, "state").to_string()
    };
    let tool = v.get("tool").and_then(|t| t.get("name")).and_then(Value::as_str).unwrap_or("");
    let queued = v.get("queued").map(|q| {
        q.get("compose").and_then(Value::as_i64).unwrap_or(0) + q.get("dispatch").and_then(Value::as_i64).unwrap_or(0)
    });
    let mut s = format!(
        "{:<8}  {:<28}  {:<18}  for {:<4}  quiet {:<4}",
        short(str_of(v, "id")),
        str_of(v, "buffer"),
        state,
        ago(opt_i64(v, "state_for")),
        ago(opt_i64(v, "quiet_for")),
    );
    if let Some(q) = queued.filter(|q| *q > 0) {
        s.push_str(&format!("  queued {}", q));
    }
    if !tool.is_empty() {
        s.push_str(&format!("  tool: {}", tool));
    }
    let tags = tags_of(v);
    if !tags.is_empty() {
        s.push_str(&format!("  [{}]", tags.join(",")));
    }
    s
}

pub fn detail(v: &Value) -> String {
    let mut out = vec![
        format!("session   {}", str_of(v, "id")),
        format!("buffer    {}", str_of(v, "buffer")),
        format!(
            "state     {}{} for {}",
            str_of(v, "state"),
            if v.get("stale").and_then(Value::as_bool).unwrap_or(true) { " (STALE: Emacs heartbeat old or from another Emacs)" } else { "" },
            ago(opt_i64(v, "state_for"))
        ),
        format!("busy      {}", if v.get("busy").and_then(Value::as_bool).unwrap_or(false) { format!("yes, for {}", ago(opt_i64(v, "busy_for"))) } else { "no".into() }),
        format!("activity  last output {} ago", ago(opt_i64(v, "quiet_for"))),
    ];
    if let Some(t) = v.get("tool").filter(|t| !t.is_null()) {
        out.push(format!("tool      {} ({} in flight)", str_of(t, "name"), v.get("tools_in_flight").and_then(Value::as_i64).unwrap_or(0)));
    }
    if let Some(q) = v.get("queued") {
        out.push(format!("queued    compose {}, dispatch {}", q.get("compose").and_then(Value::as_i64).unwrap_or(0), q.get("dispatch").and_then(Value::as_i64).unwrap_or(0)));
    }
    if let Some(d) = v.get("last_delivered").filter(|d| !d.is_null()) {
        out.push(format!("delivered {} at {}", str_of(d, "id"), opt_i64(d, "at").unwrap_or(0)));
    }
    out.push(format!("receiver  {}", if v.get("receiver").and_then(Value::as_bool).unwrap_or(false) { "on" } else { "OFF (messages are not delivered)" }));
    let tags = tags_of(v);
    if !tags.is_empty() {
        out.push(format!("tags      {}", tags.join(", ")));
    }
    if let Some(p) = v.get("plan").filter(|p| !p.is_null()) {
        out.push(format!("plan      {}/{}", opt_i64(p, "done").unwrap_or(0), opt_i64(p, "total").unwrap_or(0)));
        if let Some(c) = p.get("current").and_then(Value::as_str) {
            out.push(format!("  now     {c}"));
        }
        if let Some(n) = p.get("next").and_then(Value::as_str) {
            out.push(format!("  next    {n}"));
        }
    }
    if let Some(t) = v.get("tail").and_then(Value::as_str) {
        out.push(format!("tail      {}", t.replace('\n', " ")));
    }
    out.join("\n")
}

pub fn cmd_status(target: &str, json_out: bool) -> Result<i32> {
    let dirs = Dirs::resolve()?;
    let loaded = session_lookup::load(&dirs)?;
    let v = match session_lookup::resolve_live(target, &loaded, json_out)? {
        Ok(v) => v,
        Err(code) => return Ok(code),
    };
    if json_out {
        println!("{}", serde_json::to_string_pretty(&v)?);
    } else {
        println!("{}", detail(&v));
    }
    Ok(0)
}

fn live_keys(v: &Value) -> Vec<String> {
    let mut k = tags_of(v);
    k.extend(session_lookup::buffer_core(str_of(v, "buffer")).split('/').map(|s| s.trim().to_string()).filter(|s| !s.is_empty()));
    k
}

pub fn cmd_list_live(tags: &[String], json_out: bool) -> Result<i32> {
    let dirs = Dirs::resolve()?;
    let mut live = load_live(&dirs, now_secs())?;
    if !tags.is_empty() {
        live.sessions.retain(|v| session_lookup::tags_match(tags, &live_keys(v)));
    }
    if json_out {
        println!("{}", serde_json::to_string_pretty(&json!({
            "emacs": live.heartbeat.as_ref().map(|h| json!({"pid": h.pid, "at": h.at, "fresh": live.fresh, "receiver": h.receiver})),
            "sessions": live.sessions,
        }))?);
        return Ok(0);
    }
    match &live.heartbeat {
        None => eprintln!("no Emacs heartbeat in {}: is the session export running?", dirs.sessions.display()),
        Some(h) if !live.fresh => eprintln!("Emacs heartbeat is stale (pid {}, {} ago): states below may be old", h.pid, ago(Some(now_secs() - h.at))),
        Some(h) if !h.receiver => eprintln!("dispatch receiver is OFF: messages queue but are not delivered (M-x decknix-agent-dispatch-mode)"),
        _ => {}
    }
    for v in live.sessions.iter().filter(|v| str_of(v, "state") != "dead") {
        println!("{}", summary_line(v));
    }
    Ok(0)
}

// ---------------------------------------------------------------------------
// Sending
// ---------------------------------------------------------------------------

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum When {
    Idle,
    Now,
    Interrupt,
}

impl When {
    pub fn parse(s: &str) -> Result<Self> {
        match s {
            "idle" => Ok(When::Idle),
            "now" => Ok(When::Now),
            "interrupt" => Ok(When::Interrupt),
            _ => bail!("--when must be idle, now or interrupt"),
        }
    }
    fn as_str(self) -> &'static str {
        match self {
            When::Idle => "idle",
            When::Now => "now",
            When::Interrupt => "interrupt",
        }
    }
}

pub struct SendSpec {
    pub session_id: String,
    pub prompt: String,
    pub when: When,
    pub ttl: i64,
    pub from: Option<String>,
    pub from_name: Option<String>,
    pub reason: Option<String>,
    pub notify: bool,
}

/// Validate a prompt the way the receiver will, so a bad one fails here.
pub fn check_prompt(p: &str) -> Result<()> {
    if p.len() > MAX_PROMPT_BYTES {
        bail!("message is {} bytes; limit is {}", p.len(), MAX_PROMPT_BYTES);
    }
    let t = p.trim();
    if t.is_empty() {
        bail!("message is empty");
    }
    if RESERVED_PROMPTS.contains(&t.to_lowercase().as_str()) {
        bail!("{:?} is a reserved shell word, not a prompt", t);
    }
    Ok(())
}

/// Build the version 2 request body. Pure apart from the id.
pub fn build_request(id: &str, spec: &SendSpec, now: i64) -> Result<Value> {
    if !strict_uuid(&spec.session_id) {
        bail!("session id must be a full lowercase UUID: {}", spec.session_id);
    }
    check_prompt(&spec.prompt)?;
    let max = if spec.when == When::Now { NOW_TTL_SECS * 5 } else { MAX_TTL_SECS };
    if spec.ttl < 1 || spec.ttl > max {
        bail!("ttl must be 1..{} seconds for --when {}", max, spec.when.as_str());
    }
    if let Some(r) = &spec.reason {
        if r.chars().count() > MAX_REASON_CHARS {
            bail!("--reason is limited to {} characters", MAX_REASON_CHARS);
        }
    }
    if spec.when == When::Interrupt && spec.reason.as_deref().map(str::trim).unwrap_or("").is_empty() {
        bail!("--when interrupt needs --reason: the lane's transcript records who cut its turn and why");
    }
    let mut req = json!({
        "v": 2,
        "id": id,
        "session_id": spec.session_id,
        "prompt": spec.prompt,
        "prompt_sha256": hex::sha256(spec.prompt.as_bytes()),
        "created_at": now,
        "expires_at": now + spec.ttl,
        "when": spec.when.as_str(),
    });
    let o = req.as_object_mut().unwrap();
    if let Some(f) = spec.from.as_ref().filter(|f| strict_uuid(f)) {
        o.insert("from".into(), json!(f));
        if spec.notify {
            o.insert("notify".into(), json!(true));
        }
    }
    if let Some(n) = &spec.from_name {
        o.insert("from_name".into(), json!(n.chars().take(80).collect::<String>()));
    }
    if let Some(r) = &spec.reason {
        o.insert("reason".into(), json!(r.trim()));
    }
    Ok(req)
}

pub(crate) mod hex {
    use sha2::{Digest, Sha256};
    pub fn sha256(b: &[u8]) -> String {
        Sha256::digest(b).iter().map(|x| format!("{:02x}", x)).collect()
    }
}

fn ensure_private_dir(p: &Path) -> Result<()> {
    if !p.exists() {
        fs::create_dir_all(p).with_context(|| format!("creating {}", p.display()))?;
        fs::set_permissions(p, fs::Permissions::from_mode(0o700))?;
    }
    let md = fs::symlink_metadata(p)?;
    if !md.is_dir() || md.permissions().mode() & 0o777 != 0o700 {
        bail!("{} must be a real directory with mode 0700", p.display());
    }
    Ok(())
}

pub fn ensure_dispatch_dirs(dispatch: &Path) -> Result<()> {
    ensure_private_dir(dispatch)?;
    for d in DISPATCH_SUBDIRS {
        ensure_private_dir(&dispatch.join(d))?;
    }
    Ok(())
}

/// Write REQ into pending/ atomically and without clobbering (hard link).
pub fn publish_request(dispatch: &Path, req: &Value) -> Result<PathBuf> {
    publish_to(dispatch, "pending", req)
}

/// Write REQ into SUB (pending/ or control/) atomically and without clobbering.
pub fn publish_to(dispatch: &Path, sub: &str, req: &Value) -> Result<PathBuf> {
    ensure_dispatch_dirs(dispatch)?;
    let id = req["id"].as_str().ok_or_else(|| anyhow!("request has no id"))?;
    let tmp = dispatch.join("tmp").join(format!("request-{}.tmp", id));
    fs::write(&tmp, serde_json::to_vec(req)?)?;
    fs::set_permissions(&tmp, fs::Permissions::from_mode(0o600))?;
    let target = dispatch.join(sub).join(format!("{}.json", id));
    let linked = fs::hard_link(&tmp, &target);
    let _ = fs::remove_file(&tmp);
    linked.with_context(|| format!("publishing {}", target.display()))?;
    Ok(target)
}

#[derive(Debug, PartialEq)]
pub enum Preflight {
    Go,
    Busy(String),
    NoReceiver(String),
}

/// Decide whether a send may go ahead from the lane's exported state. Pure.
pub fn preflight(when: When, lane: Option<&Value>, receiver_on: bool, force: bool) -> Preflight {
    if !receiver_on && !force {
        return Preflight::NoReceiver(
            "the dispatch receiver is off or Emacs is not running: nothing would be delivered, and a request \
             made before it is turned on is refused. Ask the human to run M-x decknix-agent-dispatch-mode"
                .into(),
        );
    }
    if when == When::Now {
        match lane {
            Some(v) if usable(v) && matches!(str_of(v, "state"), "idle" | "asking") => Preflight::Go,
            Some(v) => Preflight::Busy(format!("lane is {}; not sent", str_of(v, "state"))),
            None => Preflight::Busy("lane state unknown; not sent".into()),
        }
    } else {
        Preflight::Go
    }
}

pub(crate) fn default_from() -> Option<String> {
    ["DECKNIX_SESSION_ID", "CLAUDE_CODE_SESSION_ID"]
        .iter()
        .filter_map(|k| std::env::var(k).ok())
        .find(|v| strict_uuid(v))
}

fn read_message(message: Option<String>, file: Option<String>, stdin: bool) -> Result<String> {
    match (message, file, stdin) {
        (Some(m), None, false) => Ok(m),
        (None, Some(f), false) => fs::read_to_string(&f).with_context(|| format!("reading {}", f)),
        (None, None, true) => {
            let mut s = String::new();
            std::io::stdin().read_to_string(&mut s)?;
            Ok(s)
        }
        _ => bail!("give exactly one of --message, --message-file or --stdin"),
    }
}

#[allow(clippy::too_many_arguments)]
pub fn cmd_send(
    target: &str,
    message: Option<String>,
    message_file: Option<String>,
    stdin: bool,
    when: &str,
    ttl: Option<String>,
    from: Option<String>,
    reason: Option<String>,
    notify: bool,
    wait_receipt: Option<u64>,
    force: bool,
    json_out: bool,
) -> Result<i32> {
    let when = When::parse(when)?;
    let prompt = read_message(message, message_file, stdin)?;
    check_prompt(&prompt)?;
    if when == When::Interrupt && reason.as_deref().map(str::trim).unwrap_or("").is_empty() {
        bail!("--when interrupt needs --reason: the lane's transcript records who cut its turn and why");
    }
    let dirs = Dirs::resolve()?;
    let now = now_secs();
    let loaded = session_lookup::load(&dirs)?;
    let live = &loaded.live;
    let unknown_id = strict_uuid(target) && !loaded.cands.iter().any(|c| c.live && c.id == target);
    let resolved = if unknown_id && queue_for_unknown_id(force, live.fresh) {
        eprintln!("note: no live session has id {}; queuing for it anyway", target);
        None
    } else {
        match session_lookup::resolve_live(target, &loaded, json_out)? {
            Ok(v) => Some(v),
            Err(code) => {
                if unknown_id && !json_out {
                    eprintln!("not sent: {} is not open in Emacs, so the message would only expire (pass --force to queue it anyway)", short(target));
                }
                return Ok(code);
            }
        }
    };
    let lane = resolved.as_ref();
    let session_id = lane.map(|v| str_of(v, "id").to_string()).unwrap_or_else(|| target.to_string());
    let receiver_on = live.fresh && live.heartbeat.as_ref().map(|h| h.receiver).unwrap_or(false);
    match preflight(when, lane, receiver_on, force) {
        Preflight::Go => {}
        Preflight::Busy(why) => {
            report_lane(lane, &why, json_out)?;
            return Ok(EXIT_BUSY);
        }
        Preflight::NoReceiver(why) => {
            report_lane(lane, &why, json_out)?;
            return Ok(EXIT_NO_RECEIVER);
        }
    }
    let from = from.or_else(default_from);
    if let Some(f) = &from {
        if !strict_uuid(f) {
            bail!("--from must be a full lowercase session UUID");
        }
    }
    let from_name = from
        .as_ref()
        .and_then(|f| live.sessions.iter().find(|v| str_of(v, "id") == f))
        .map(|v| str_of(v, "buffer").to_string())
        .filter(|n| !n.is_empty());
    let ttl = match (ttl, when) {
        (Some(t), _) => parse_ttl(&t)?,
        (None, When::Now) => NOW_TTL_SECS,
        (None, When::Interrupt) => 3600,
        (None, When::Idle) => 86400,
    };
    let spec = SendSpec { session_id: session_id.clone(), prompt, when, ttl, from, from_name, reason, notify };
    let id = session::new_uuid_v4()?;
    let req = build_request(&id, &spec, now)?;
    publish_request(&dirs.dispatch, &req)?;
    if json_out {
        println!("{}", serde_json::to_string(&json!({
            "id": id, "session": session_id, "when": when.as_str(), "expires_at": now + ttl,
            "lane": lane.cloned(),
        }))?);
    } else {
        println!("{}", id);
        eprintln!(
            "queued for {} ({}), --when {}, expires in {}",
            short(&session_id),
            lane.map(|v| str_of(v, "buffer")).unwrap_or("?"),
            when.as_str(),
            ago(Some(ttl))
        );
        if let Some(v) = lane {
            eprintln!("lane: {}", summary_line(v));
        }
        eprintln!("receipt: decknix session message {}   (or: decknix session watch {})", id, id);
    }
    match wait_receipt {
        Some(secs) => wait_for(&dirs.dispatch, &[id], Until::Delivered, Duration::from_secs(secs), Duration::from_secs(1), json_out),
        None => Ok(0),
    }
}

/// Queue for a full id no live session has? Only when forced, or when live
/// state is unknown (no fresh heartbeat; the receiver check then refuses
/// unless forced). With a fresh heartbeat such an id names a closed or
/// retired session: lanes messaging a replaced coordinator by its old id
/// lost six messages to `no-session` receipts nobody read.
pub fn queue_for_unknown_id(force: bool, fresh: bool) -> bool {
    force || !fresh
}

fn report_lane(lane: Option<&Value>, why: &str, json_out: bool) -> Result<()> {
    if json_out {
        println!("{}", serde_json::to_string(&json!({"sent": false, "why": why, "lane": lane.cloned()}))?);
    } else {
        eprintln!("not sent: {}", why);
        if let Some(v) = lane {
            eprintln!("{}", detail(v));
        }
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// Receipts
// ---------------------------------------------------------------------------

/// Merged view of one message's receipt chain. A spawn's accepted receipt
/// reads `launching` until `<id>.spawned.json` says `spawned` (or why not);
/// accepted retire and dispatch receipts read `retired` and `applied`.
pub fn message_status(dispatch: &Path, id: &str, now: i64) -> Option<Value> {
    let receipt = read_json(&dispatch.join("receipts").join(format!("{}.json", id)));
    let answered = read_json(&dispatch.join("receipts").join(format!("{}.answered.json", id)));
    let spawned = read_json(&dispatch.join("receipts").join(format!("{}.spawned.json", id)));
    if let Some(r) = receipt {
        let mut v = r.clone();
        let o = v.as_object_mut()?;
        let state = r.get("state").and_then(Value::as_str).unwrap_or("unknown");
        let shown = match (state, r.get("kind").and_then(Value::as_str).unwrap_or("")) {
            ("accepted", "spawn") => "launching",
            ("accepted", "retire") => "retired",
            ("accepted", "dispatch") => "applied",
            ("accepted", _) => "delivered",
            (s, _) => s,
        };
        o.insert("state".into(), json!(shown));
        if let Some(sp) = spawned {
            let st = sp.get("state").and_then(Value::as_str).unwrap_or("spawned");
            o.insert("state".into(), json!(st));
            for k in ["session_id", "buffer", "outcome", "brief", "reason"] {
                if let Some(x) = sp.get(k) {
                    o.insert(k.into(), x.clone());
                }
            }
            o.insert("spawned_at".into(), sp.get("at").cloned().unwrap_or(Value::Null));
        }
        if let Some(a) = answered {
            o.insert("state".into(), a.get("state").cloned().unwrap_or(json!("answered")));
            o.insert("answered_at".into(), a.get("at").cloned().unwrap_or(Value::Null));
            for k in ["tail", "turn_open"] {
                if let Some(x) = a.get(k) {
                    o.insert(k.into(), x.clone());
                }
            }
        }
        return Some(v);
    }
    let inflight = dispatch.join("inflight");
    if inflight.join(format!("{}.json", id)).exists() || inflight.join(format!("{}.attempt", id)).exists() {
        let state = if inflight.join(format!("{}.attempt", id)).exists() {
            "submitting"
        } else if inflight.join(format!("{}.interrupted", id)).exists() {
            "interrupting"
        } else {
            "waiting"
        };
        let req = read_json(&inflight.join(format!("{}.json", id)));
        return Some(json!({"id": id, "state": state,
                           "session_id": req.as_ref().and_then(|r| r.get("session_id")).cloned(),
                           "expires_at": req.as_ref().and_then(|r| r.get("expires_at")).cloned()}));
    }
    let pending = read_json(&dispatch.join("pending").join(format!("{}.json", id)))?;
    let expires = pending.get("expires_at").and_then(Value::as_i64).unwrap_or(0);
    let (state, reason) = if expires <= now { ("expired", Some("never claimed: is decknix-agent-dispatch-mode on?")) } else { ("queued", None) };
    let mut v = json!({"id": id, "state": state, "session_id": pending.get("session_id"), "expires_at": expires,
                       "when": pending.get("when")});
    if let Some(r) = reason {
        v["reason"] = json!(r);
    }
    Some(v)
}

pub fn exit_for(state: &str) -> i32 {
    match state {
        "delivered" | "answered" | "spawned" | "retired" | "applied" => 0,
        "queued" | "waiting" | "interrupting" | "launching" => EXIT_PENDING,
        "unknown" | "submitting" => EXIT_UNKNOWN,
        _ => EXIT_NOT_DELIVERED,
    }
}

fn status_line(v: &Value) -> String {
    let mut s = format!("{}  {}", short(str_of(v, "id")), str_of(v, "state"));
    if let Some(r) = v.get("reason").and_then(Value::as_str) {
        s.push_str(&format!("  ({})", r));
    }
    if v.get("turn_open").and_then(Value::as_bool).unwrap_or(false) {
        s.push_str("  [turn still open on background work]");
    }
    if let Some(t) = v.get("tail").and_then(Value::as_str) {
        let t = t.replace('\n', " ");
        let n = t.chars().count();
        let tail: String = t.chars().skip(n.saturating_sub(200)).collect();
        s.push_str(&format!("\n    {}", tail));
    }
    s
}

pub fn cmd_message(id: &str, json_out: bool) -> Result<i32> {
    let dirs = Dirs::resolve()?;
    match message_status(&dirs.dispatch, id, now_secs()) {
        None => {
            eprintln!("no such message: {}", id);
            Ok(2)
        }
        Some(v) => {
            if json_out {
                println!("{}", serde_json::to_string_pretty(&v)?);
            } else {
                println!("{}", status_line(&v));
            }
            Ok(exit_for(str_of(&v, "state")))
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Until {
    Delivered,
    Answered,
}

impl Until {
    pub fn parse(s: &str) -> Result<Self> {
        match s {
            "delivered" => Ok(Until::Delivered),
            "answered" => Ok(Until::Answered),
            _ => bail!("--until must be delivered or answered"),
        }
    }
}

/// Has V reached UNTIL, or a state it can never leave?
pub fn settled(v: &Value, until: Until) -> bool {
    match str_of(v, "state") {
        "queued" | "waiting" | "interrupting" | "submitting" | "launching" => false,
        "delivered" => until == Until::Delivered,
        _ => true,
    }
}

fn wait_for(dispatch: &Path, ids: &[String], until: Until, timeout: Duration, every: Duration, json_out: bool) -> Result<i32> {
    let start = SystemTime::now();
    loop {
        let now = now_secs();
        let states: Vec<Value> = ids
            .iter()
            .map(|id| message_status(dispatch, id, now).unwrap_or_else(|| json!({"id": id, "state": "missing"})))
            .collect();
        let done = states.iter().all(|v| settled(v, until));
        let timed_out = start.elapsed().unwrap_or_default() >= timeout;
        if done || timed_out {
            for v in &states {
                if json_out {
                    println!("{}", serde_json::to_string(v)?);
                } else {
                    println!("{}", status_line(v));
                }
            }
            if !done {
                eprintln!("timed out after {}", ago(Some(timeout.as_secs() as i64)));
                return Ok(EXIT_TIMEOUT);
            }
            return Ok(states.iter().map(|v| exit_for(str_of(v, "state"))).max().unwrap_or(0));
        }
        std::thread::sleep(every);
    }
}

pub fn cmd_watch(ids: Vec<String>, until: &str, timeout: &str, json_out: bool) -> Result<i32> {
    if ids.is_empty() {
        bail!("give at least one message id");
    }
    let dirs = Dirs::resolve()?;
    let until = Until::parse(until)?;
    let timeout = Duration::from_secs(parse_ttl(timeout)? as u64);
    wait_for(&dirs.dispatch, &ids, until, timeout, Duration::from_secs(5), json_out)
}

// ---------------------------------------------------------------------------
// Notices
// ---------------------------------------------------------------------------

pub fn read_notices(dispatch: &Path, session: &str) -> Vec<(PathBuf, Value)> {
    let dir = dispatch.join("notices").join(session);
    let mut out: Vec<(PathBuf, Value)> = fs::read_dir(&dir)
        .map(|rd| {
            rd.flatten()
                .filter(|e| e.file_name().to_string_lossy().ends_with(".json"))
                .filter_map(|e| read_json(&e.path()).map(|v| (e.path(), v)))
                .collect()
        })
        .unwrap_or_default();
    out.sort_by(|a, b| a.0.cmp(&b.0));
    out
}

pub fn cmd_inbox(session: Option<String>, json_out: bool, clear: bool) -> Result<i32> {
    let session = session
        .or_else(default_from)
        .ok_or_else(|| anyhow!("no --session given and no session id in the environment"))?;
    if !strict_uuid(&session) {
        bail!("--session must be a full lowercase session UUID");
    }
    let dirs = Dirs::resolve()?;
    let notices = read_notices(&dirs.dispatch, &session);
    if json_out {
        println!("{}", serde_json::to_string_pretty(&notices.iter().map(|(_, v)| v.clone()).collect::<Vec<_>>())?);
    } else if notices.is_empty() {
        eprintln!("no notices");
    } else {
        for (_, v) in &notices {
            let to = short(str_of(v, "to"));
            println!("{}  to {}", status_line(v), to);
        }
    }
    if clear {
        for (p, _) in &notices {
            let _ = fs::remove_file(p);
        }
    }
    Ok(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    const LANE: &str = "11111111-2222-4333-8444-555555555555";
    const COORD: &str = "cccccccc-dddd-4eee-8fff-000000000000";

    fn hb(pid: i64, at: i64) -> Heartbeat {
        Heartbeat { pid, at, interval: 30, receiver: true, ..Default::default() }
    }

    fn lane(id: &str, buffer: &str, state: &str, tags: &[&str], stale: bool) -> Value {
        json!({"id": id, "buffer": buffer, "state": state, "stale": stale, "tags": tags,
               "busy": state != "idle", "emacs_pid": 42})
    }

    fn spec(when: When, reason: Option<&str>) -> SendSpec {
        SendSpec {
            session_id: LANE.into(),
            prompt: "do the thing".into(),
            when,
            ttl: 60,
            from: Some(COORD.into()),
            from_name: Some("coord".into()),
            reason: reason.map(str::to_string),
            notify: true,
        }
    }

    #[test]
    fn detail_shows_the_plan_current_and_next() {
        let v = serde_json::json!({"id": "s", "plan": {"done": 1, "total": 3,
                                    "current": "run tests", "next": "open PR"}});
        let d = detail(&v);
        assert!(d.contains("plan      1/3"), "{d}");
        assert!(d.contains("  now     run tests"), "{d}");
        assert!(d.contains("  next    open PR"), "{d}");
        assert!(!detail(&serde_json::json!({"id": "s", "plan": null})).contains("plan "));
    }

    #[test]
    fn strict_uuid_refuses_uppercase_and_prefixes() {
        assert!(strict_uuid(LANE));
        assert!(!strict_uuid(&COORD.to_uppercase()));
        assert!(!strict_uuid("11111111"));
    }

    #[test]
    fn ttl_parsing() {
        assert_eq!(parse_ttl("90").unwrap(), 90);
        assert_eq!(parse_ttl("30m").unwrap(), 1800);
        assert_eq!(parse_ttl("24h").unwrap(), 86400);
        assert_eq!(parse_ttl("7d").unwrap(), 604800);
        assert!(parse_ttl("soon").is_err());
        assert!(parse_ttl("0s").is_err());
    }

    #[test]
    fn heartbeat_freshness() {
        let h = hb(42, 1000);
        assert!(h.fresh(1090, |_| true));
        assert!(!h.fresh(1091, |_| true));
        assert!(!h.fresh(1000, |_| false));
    }

    #[test]
    fn enrich_marks_stale_and_computes_durations() {
        let h = hb(42, 1000);
        let raw = json!({"id": LANE, "emacs_pid": 42, "state": "working",
                         "last_activity": 900, "busy_since": 600, "state_since": 950});
        let v = enrich(raw.clone(), Some(&h), true, Some(&json!(["lane-1"])), 1000);
        assert_eq!(v["stale"], json!(false));
        assert_eq!(v["quiet_for"], json!(100));
        assert_eq!(v["busy_for"], json!(400));
        assert_eq!(v["state_for"], json!(50));
        assert_eq!(v["tags"], json!(["lane-1"]));
        assert_eq!(v["receiver"], json!(true));
        let other_emacs = enrich(json!({"id": LANE, "emacs_pid": 7}), Some(&h), true, None, 1000);
        assert_eq!(other_emacs["stale"], json!(true));
        let exported = enrich(json!({"id": LANE, "tags": ["from-emacs"]}), Some(&h), true, Some(&json!(["from-store"])), 1000);
        assert_eq!(exported["tags"], json!(["from-emacs"]));
        let dead_emacs = enrich(raw, Some(&h), false, None, 1000);
        assert_eq!(dead_emacs["stale"], json!(true));
        assert_eq!(dead_emacs["receiver"], json!(false));
    }

    #[test]
    fn unknown_full_id_is_refused_while_live_state_is_known() {
        assert!(!queue_for_unknown_id(false, true));
        assert!(queue_for_unknown_id(true, true));
        assert!(queue_for_unknown_id(false, false));
    }

    #[test]
    fn request_has_v2_fields_and_a_matching_hash() {
        let r = build_request("99999999-8888-4777-8666-555555555555", &spec(When::Idle, None), 1000).unwrap();
        assert_eq!(r["v"], json!(2));
        assert_eq!(r["when"], json!("idle"));
        assert_eq!(r["from"], json!(COORD));
        assert_eq!(r["notify"], json!(true));
        assert_eq!(r["expires_at"], json!(1060));
        assert_eq!(r["prompt_sha256"], json!(hex::sha256(b"do the thing")));
        assert!(r.get("reason").is_none());
    }

    #[test]
    fn interrupt_needs_a_reason() {
        let id = "99999999-8888-4777-8666-555555555555";
        assert!(build_request(id, &spec(When::Interrupt, None), 1000).is_err());
        assert!(build_request(id, &spec(When::Interrupt, Some("  ")), 1000).is_err());
        let r = build_request(id, &spec(When::Interrupt, Some("plan changed")), 1000).unwrap();
        assert_eq!(r["reason"], json!("plan changed"));
    }

    #[test]
    fn request_limits() {
        let id = "99999999-8888-4777-8666-555555555555";
        let mut s = spec(When::Idle, None);
        s.ttl = MAX_TTL_SECS + 1;
        assert!(build_request(id, &s, 0).is_err());
        let mut s = spec(When::Now, None);
        s.ttl = 3600;
        assert!(build_request(id, &s, 0).is_err());
        let mut s = spec(When::Idle, None);
        s.session_id = "11111111".into();
        assert!(build_request(id, &s, 0).is_err());
        assert!(check_prompt(" help ").is_err());
        assert!(check_prompt("  \n").is_err());
        assert!(check_prompt(&"a".repeat(MAX_PROMPT_BYTES + 1)).is_err());
    }

    #[test]
    fn now_against_a_busy_lane_is_refused_with_its_state() {
        let busy = lane(LANE, "lane", "background", &[], false);
        assert_eq!(preflight(When::Now, Some(&busy), true, false), Preflight::Busy("lane is background; not sent".into()));
        let idle = lane(LANE, "lane", "idle", &[], false);
        assert_eq!(preflight(When::Now, Some(&idle), true, false), Preflight::Go);
        let stale_idle = lane(LANE, "lane", "idle", &[], true);
        assert!(matches!(preflight(When::Now, Some(&stale_idle), true, false), Preflight::Busy(_)));
        assert_eq!(preflight(When::Idle, Some(&busy), true, false), Preflight::Go);
        assert_eq!(preflight(When::Interrupt, Some(&busy), true, false), Preflight::Go);
        assert!(matches!(preflight(When::Idle, Some(&busy), false, false), Preflight::NoReceiver(_)));
        assert_eq!(preflight(When::Idle, Some(&busy), false, true), Preflight::Go);
    }

    #[test]
    fn publish_is_private_and_never_clobbers() {
        let dir = tempfile::tempdir().unwrap();
        let d = dir.path().join("agent-dispatch");
        let r = build_request("99999999-8888-4777-8666-555555555555", &spec(When::Idle, None), 1000).unwrap();
        let p = publish_request(&d, &r).unwrap();
        assert_eq!(fs::metadata(&p).unwrap().permissions().mode() & 0o777, 0o600);
        assert_eq!(fs::metadata(d.join("notices")).unwrap().permissions().mode() & 0o777, 0o700);
        assert!(publish_request(&d, &r).is_err());
        assert_eq!(read_json(&p).unwrap()["session_id"], json!(LANE));
    }

    fn write(p: &Path, v: Value) {
        fs::create_dir_all(p.parent().unwrap()).unwrap();
        fs::write(p, serde_json::to_vec(&v).unwrap()).unwrap();
    }

    #[test]
    fn receipt_chain_merges_every_stage() {
        let dir = tempfile::tempdir().unwrap();
        let d = dir.path();
        let id = "99999999-8888-4777-8666-555555555555";
        assert!(message_status(d, id, 1000).is_none());
        write(&d.join("pending").join(format!("{}.json", id)), json!({"id": id, "session_id": LANE, "expires_at": 2000}));
        let v = message_status(d, id, 1000).unwrap();
        assert_eq!(v["state"], json!("queued"));
        assert_eq!(exit_for("queued"), EXIT_PENDING);
        let v = message_status(d, id, 2000).unwrap();
        assert_eq!(v["state"], json!("expired"));
        assert_eq!(exit_for("expired"), EXIT_NOT_DELIVERED);
        fs::remove_file(d.join("pending").join(format!("{}.json", id))).unwrap();
        write(&d.join("inflight").join(format!("{}.json", id)), json!({"id": id, "session_id": LANE, "expires_at": 2000}));
        assert_eq!(message_status(d, id, 1000).unwrap()["state"], json!("waiting"));
        write(&d.join("inflight").join(format!("{}.interrupted", id)), json!(1000));
        assert_eq!(message_status(d, id, 1000).unwrap()["state"], json!("interrupting"));
        for f in ["json", "interrupted"] {
            fs::remove_file(d.join("inflight").join(format!("{}.{}", id, f))).unwrap();
        }
        write(&d.join("receipts").join(format!("{}.json", id)), json!({"id": id, "state": "accepted", "at": 1100}));
        let v = message_status(d, id, 1200).unwrap();
        assert_eq!(v["state"], json!("delivered"));
        assert!(settled(&v, Until::Delivered));
        assert!(!settled(&v, Until::Answered));
        write(&d.join("receipts").join(format!("{}.answered.json", id)),
              json!({"id": id, "state": "answered", "at": 1300, "tail": "Done.", "turn_open": true}));
        let v = message_status(d, id, 1400).unwrap();
        assert_eq!(v["state"], json!("answered"));
        assert_eq!(v["tail"], json!("Done."));
        assert_eq!(v["turn_open"], json!(true));
        assert!(settled(&v, Until::Answered));
        assert_eq!(exit_for("answered"), 0);
    }

    #[test]
    fn spawn_receipts_merge_the_spawned_file() {
        let dir = tempfile::tempdir().unwrap();
        let d = dir.path();
        let id = "99999999-8888-4777-8666-555555555555";
        write(&d.join("receipts").join(format!("{}.json", id)),
              json!({"id": id, "state": "accepted", "kind": "spawn", "outcome": "new"}));
        let v = message_status(d, id, 1000).unwrap();
        assert_eq!(v["state"], json!("launching"));
        assert_eq!(exit_for("launching"), EXIT_PENDING);
        assert!(!settled(&v, Until::Delivered));
        write(&d.join("receipts").join(format!("{}.spawned.json", id)),
              json!({"id": id, "session_id": LANE, "buffer": "*Claude: us/lane-07*", "outcome": "new"}));
        let v = message_status(d, id, 1000).unwrap();
        assert_eq!(v["state"], json!("spawned"));
        assert_eq!(v["session_id"], json!(LANE));
        assert_eq!(v["buffer"], json!("*Claude: us/lane-07*"));
        assert!(settled(&v, Until::Delivered));
        assert_eq!(exit_for("spawned"), 0);
        fs::write(d.join("receipts").join(format!("{}.spawned.json", id)),
                  serde_json::to_vec(&json!({"id": id, "state": "spawn-failed", "reason": "timeout"})).unwrap()).unwrap();
        let v = message_status(d, id, 1000).unwrap();
        assert_eq!(v["state"], json!("spawn-failed"));
        assert_eq!(v["reason"], json!("timeout"));
        assert_eq!(exit_for("spawn-failed"), EXIT_NOT_DELIVERED);
    }

    #[test]
    fn retire_and_control_receipts_name_their_outcome() {
        let dir = tempfile::tempdir().unwrap();
        let d = dir.path();
        let id = "99999999-8888-4777-8666-555555555555";
        write(&d.join("receipts").join(format!("{}.json", id)),
              json!({"id": id, "state": "accepted", "kind": "retire", "outcome": "retired"}));
        assert_eq!(message_status(d, id, 1000).unwrap()["state"], json!("retired"));
        assert_eq!(exit_for("retired"), 0);
        let id2 = "77777777-8888-4777-8666-555555555555";
        write(&d.join("receipts").join(format!("{}.json", id2)),
              json!({"id": id2, "state": "accepted", "kind": "dispatch", "outcome": "on"}));
        assert_eq!(message_status(d, id2, 1000).unwrap()["state"], json!("applied"));
        assert_eq!(exit_for("applied"), 0);
    }

    #[test]
    fn heartbeat_reads_arming_and_control() {
        let h = Heartbeat::from_value(&json!({"pid": 1, "at": 2, "receiver": true, "control": true,
                                              "armed_at": 3, "armed_by": "control:x", "remote_control": false})).unwrap();
        assert!(h.control);
        assert_eq!(h.armed_at, Some(3));
        assert_eq!(h.armed_by.as_deref(), Some("control:x"));
        assert_eq!(h.remote_control, Some(false));
        let old = Heartbeat::from_value(&json!({"pid": 1, "at": 2})).unwrap();
        assert!(!old.control && old.armed_by.is_none());
    }

    #[test]
    fn terminal_receipts_settle_any_wait() {
        let v = json!({"id": "x", "state": "rejected", "reason": "interrupt-not-allowed"});
        assert!(settled(&v, Until::Answered));
        assert_eq!(exit_for("rejected"), EXIT_NOT_DELIVERED);
        assert_eq!(exit_for("unknown"), EXIT_UNKNOWN);
    }

    #[test]
    fn wait_for_returns_once_settled() {
        let dir = tempfile::tempdir().unwrap();
        let d = dir.path();
        let id = "99999999-8888-4777-8666-555555555555".to_string();
        write(&d.join("receipts").join(format!("{}.json", id)), json!({"id": id, "state": "accepted"}));
        let code = wait_for(d, &[id.clone()], Until::Delivered, Duration::from_secs(1), Duration::from_millis(10), true).unwrap();
        assert_eq!(code, 0);
        let code = wait_for(d, &[id], Until::Answered, Duration::from_millis(30), Duration::from_millis(10), true).unwrap();
        assert_eq!(code, EXIT_TIMEOUT);
    }

    #[test]
    fn notices_are_listed_oldest_first() {
        let dir = tempfile::tempdir().unwrap();
        let d = dir.path();
        let n = d.join("notices").join(COORD);
        write(&n.join("2000-x-answered.json"), json!({"id": "x", "state": "answered"}));
        write(&n.join("1000-x-accepted.json"), json!({"id": "x", "state": "accepted"}));
        let got: Vec<String> = read_notices(d, COORD).iter().map(|(_, v)| str_of(v, "state").to_string()).collect();
        assert_eq!(got, vec!["accepted", "answered"]);
        assert!(read_notices(d, LANE).is_empty());
    }

    #[test]
    fn summary_line_shows_state_tool_and_tags() {
        let mut v = lane(LANE, "lane-buffer", "working", &["lane-1"], false);
        v["tool"] = json!({"name": "gradle test"});
        v["state_for"] = json!(120);
        v["quiet_for"] = json!(5);
        let s = summary_line(&v);
        assert!(s.contains("11111111") && s.contains("working") && s.contains("gradle test") && s.contains("[lane-1]"), "{}", s);
        v["stale"] = json!(true);
        assert!(summary_line(&v).contains("(stale)"));
    }
}
