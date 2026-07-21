//! `decknix session` — workspace/tag-aware find, create, and resume for coding
//! agents, from a terminal.
//!
//! Sessions and tags stay consistent with agent-shell (Emacs) because we share
//! its contracts:
//!
//!   * The tag/workspace/model store `~/.config/decknix/agent-sessions.json`.
//!     A "conversation" groups session UUIDs under a *conv-key* with `tags`,
//!     `sessions`, `model`, `workspace`, `lastAccessed`. This store is
//!     provider-agnostic.
//!   * conv-key = first 16 lowercase hex chars of `sha256(first 200 chars of the
//!     first user message)`. The *hash* is shared; the *first-message* string is
//!     extracted per provider (each has its own session format), mirroring the
//!     `:session-jq-filter` in agent-shell.nix. A root `_canonicalKeyVersion`
//!     guards the algorithm.
//!
//! Providers are pluggable via the [`Provider`] trait + [`registry`]. Two are
//! implemented today — `claude` and `auggie`; the ACP agents with no shared
//! session schema (pi/gemini/opencode/goose/qwen) are intentionally omitted
//! until they have on-disk sessions to read.

use anyhow::{anyhow, bail, Context, Result};
use clap::Subcommand;
use regex::Regex;
use serde_json::{json, Map, Value};
use sha2::{Digest, Sha256};
use std::fs;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::time::SystemTime;

/// conv-key canonicalisation length — matches `decknix--agent-conv-key-canonical-length`.
const CONV_KEY_CANONICAL_LEN: usize = 200;
/// conv-key algorithm version we implement — matches `decknix--agent-tags-canonical-key-version`.
const CONV_KEY_VERSION: i64 = 1;
/// Bounded prefix we read from an auggie session file (its chatHistory[0] fields
/// — first message + workspace — live in the first few KB even of a 200MB file).
const AUGGIE_PREFIX_BYTES: usize = 1 << 20; // 1 MiB
/// Newest-first cap on how many auggie files a single `list` inspects (auggie
/// has thousands of multi-MB files). Mirrors Emacs's `-session-cache-max-files`.
const AUGGIE_SCAN_CAP: usize = 400;
/// Sentinel prefix auggie uses for system/warning request messages (⚠, U+26A0);
/// its jq filter skips these when picking the first user message.
const AUGGIE_WARN_PREFIX: char = '\u{26a0}';

#[derive(Subcommand)]
pub enum SessionAction {
    /// List sessions in a workspace (default: current directory)
    #[command(alias = "ls")]
    List {
        /// Which agent(s): claude, auggie, or all
        #[arg(long, default_value = "all")]
        agent: String,
        /// Workspace to list (default: current directory)
        #[arg(long)]
        workspace: Option<String>,
        /// List across every workspace instead of just one
        #[arg(long)]
        all: bool,
        /// Only sessions carrying this tag (repeatable; all must match)
        #[arg(long = "tag")]
        tags: Vec<String>,
        /// Only sessions whose transcript matches this regex
        #[arg(long)]
        grep: Option<String>,
        /// Only sessions touched within this window (e.g. 7d, 12h, 30m)
        #[arg(long)]
        since: Option<String>,
        /// Cap the number of rows
        #[arg(long)]
        limit: Option<usize>,
        /// Emit JSON instead of aligned columns
        #[arg(long)]
        json: bool,
    },
    /// Resume a session (exec into the agent by default)
    Resume {
        /// Session id or unique prefix
        id: Option<String>,
        /// Which agent(s) to resolve within: claude, auggie, or all
        #[arg(long, default_value = "all")]
        agent: String,
        /// Resume the latest session carrying this tag (repeatable; all must match)
        #[arg(long = "tag")]
        tags: Vec<String>,
        /// Resume the most recently touched session in scope
        #[arg(long)]
        last: bool,
        /// Workspace to resolve within (default: current directory)
        #[arg(long)]
        workspace: Option<String>,
        /// Resolve across every workspace
        #[arg(long)]
        all: bool,
        /// Print the resolved command instead of exec-ing it
        #[arg(long, short = 'n')]
        print: bool,
    },
    /// Start a new session (exec into the agent by default)
    New {
        /// Which agent: claude or auggie
        #[arg(long, default_value = "claude")]
        agent: String,
        /// Pre-tag the conversation (requires an initial prompt to key it)
        #[arg(long = "tag")]
        tags: Vec<String>,
        /// Workspace to start in (default: current directory)
        #[arg(long)]
        workspace: Option<String>,
        /// Per-conversation model override
        #[arg(long)]
        model: Option<String>,
        /// Print the resolved command instead of exec-ing it
        #[arg(long, short = 'n')]
        print: bool,
        /// Initial prompt (everything after `--`)
        #[arg(last = true)]
        prompt: Vec<String>,
    },
    /// Add or remove tags on a session's conversation
    Tag {
        /// Session id or unique prefix
        id: String,
        /// Which agent(s) to resolve within: claude, auggie, or all
        #[arg(long, default_value = "all")]
        agent: String,
        /// Tag to add (repeatable)
        #[arg(long = "add")]
        add: Vec<String>,
        /// Tag to remove (repeatable)
        #[arg(long = "remove")]
        remove: Vec<String>,
    },
    /// List all known tags with usage counts
    Tags {
        /// Emit JSON instead of aligned columns
        #[arg(long)]
        json: bool,
    },
}

pub fn run(action: SessionAction) -> Result<()> {
    let paths = Paths::resolve()?;
    match action {
        SessionAction::List { agent, workspace, all, tags, grep, since, limit, json } => {
            cmd_list(&paths, &agent, workspace, all, tags, grep, since, limit, json)
        }
        SessionAction::Resume { id, agent, tags, last, workspace, all, print } => {
            cmd_resume(&paths, &agent, id, tags, last, workspace, all, print)
        }
        SessionAction::New { agent, tags, workspace, model, print, prompt } => {
            cmd_new(&paths, &agent, tags, workspace, model, print, prompt)
        }
        SessionAction::Tag { id, agent, add, remove } => cmd_tag(&paths, &agent, id, add, remove),
        SessionAction::Tags { json } => cmd_tags(&paths, json),
    }
}

// ---------------------------------------------------------------------------
// Paths
// ---------------------------------------------------------------------------

struct Paths {
    store: PathBuf,
}

impl Paths {
    fn resolve() -> Result<Self> {
        let home = dirs::home_dir().ok_or_else(|| anyhow!("cannot determine home directory"))?;
        Ok(Paths { store: home.join(".config/decknix/agent-sessions.json") })
    }
}

fn home() -> PathBuf {
    dirs::home_dir().unwrap_or_default()
}

// ---------------------------------------------------------------------------
// conv-key (shared hash; per-provider message extraction)
// ---------------------------------------------------------------------------

/// Derive the raw conversation key from a first-message string. `None` for an
/// empty message. First 200 Unicode chars → first 16 hex of the SHA-256 digest.
fn conv_key(first_message: &str) -> Option<String> {
    if first_message.is_empty() {
        return None;
    }
    let canonical: String = first_message.chars().take(CONV_KEY_CANONICAL_LEN).collect();
    let digest = Sha256::digest(canonical.as_bytes());
    let hex: String = digest.iter().map(|b| format!("{:02x}", b)).collect();
    Some(hex[..16].to_string())
}

/// Encode an absolute workspace path the way Claude Code names its project
/// directory: strip a trailing slash, then replace every non-alphanumeric char
/// with `-` (1:1, no collapsing).
fn slug(workspace: &str) -> String {
    let trimmed = workspace.strip_suffix('/').unwrap_or(workspace);
    trimmed
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() { c } else { '-' })
        .collect()
}

// ---------------------------------------------------------------------------
// Store (agent-sessions.json) — load / mutate / atomic save
// ---------------------------------------------------------------------------

fn load_store(path: &Path) -> Result<Value> {
    match fs::read_to_string(path) {
        Ok(s) if s.trim().is_empty() => Ok(json!({})),
        Ok(s) => serde_json::from_str(&s).with_context(|| format!("parsing {}", path.display())),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(json!({})),
        Err(e) => Err(e).with_context(|| format!("reading {}", path.display())),
    }
}

/// Atomic write (temp + rename) with 0600, preserving every untouched key.
fn save_store(path: &Path, value: &Value) -> Result<()> {
    use std::os::unix::fs::PermissionsExt;
    if let Some(dir) = path.parent() {
        fs::create_dir_all(dir).ok();
    }
    let body = serde_json::to_string_pretty(value)?;
    let tmp = path.with_extension("json.tmp");
    fs::write(&tmp, body).with_context(|| format!("writing {}", tmp.display()))?;
    fs::set_permissions(&tmp, fs::Permissions::from_mode(0o600)).ok();
    fs::rename(&tmp, path).with_context(|| format!("renaming into {}", path.display()))?;
    Ok(())
}

fn conversations(store: &Value) -> Option<&Map<String, Value>> {
    store.get("conversations").and_then(Value::as_object)
}

fn conversations_mut(store: &mut Value) -> &mut Map<String, Value> {
    let obj = store.as_object_mut().expect("store is a JSON object");
    obj.entry("conversations")
        .or_insert_with(|| json!({}))
        .as_object_mut()
        .expect("conversations is a JSON object")
}

/// Follow `mergedInto` redirects to the canonical conv-key (cap 5 hops).
fn resolve_merged(convs: &Map<String, Value>, key: &str) -> String {
    let mut key = key.to_string();
    for _ in 0..5 {
        match convs.get(&key).and_then(|e| e.get("mergedInto")).and_then(Value::as_str) {
            Some(target) => key = target.to_string(),
            None => break,
        }
    }
    key
}

fn conv_key_writes_ok(store: &Value) -> bool {
    match store.get("_canonicalKeyVersion") {
        None => true,
        Some(v) => v.as_i64() == Some(CONV_KEY_VERSION),
    }
}

fn entry_tags(entry: &Value) -> Vec<String> {
    entry
        .get("tags")
        .and_then(Value::as_array)
        .map(|a| a.iter().filter_map(|v| v.as_str().map(str::to_string)).collect())
        .unwrap_or_default()
}

/// `session-id -> tags` from every conversation's `sessions[]` membership.
fn session_tag_index(store: &Value) -> Map<String, Value> {
    let mut idx = Map::new();
    if let Some(convs) = conversations(store) {
        for entry in convs.values() {
            let tags = entry.get("tags").cloned().unwrap_or(Value::Null);
            if let Some(sessions) = entry.get("sessions").and_then(Value::as_array) {
                for sid in sessions.iter().filter_map(Value::as_str) {
                    idx.insert(sid.to_string(), tags.clone());
                }
            }
        }
    }
    idx
}

/// Per-conversation model recorded for a session-id, if any.
fn store_model_for(store: &Value, sid: &str) -> Option<String> {
    conversations(store)?.values().find_map(|e| {
        let has = e
            .get("sessions")
            .and_then(Value::as_array)
            .map(|a| a.iter().any(|s| s.as_str() == Some(sid)))
            .unwrap_or(false);
        if has {
            e.get("model").and_then(Value::as_str).map(str::to_string)
        } else {
            None
        }
    })
}

// ---------------------------------------------------------------------------
// SessionMeta + Provider trait + registry
// ---------------------------------------------------------------------------

pub struct SessionMeta {
    id: String,
    provider: &'static str,
    glyph: &'static str,
    workspace: Option<PathBuf>,
    first_message: String,
    mtime: SystemTime,
    path: PathBuf,
}

struct LaunchPlan {
    program: String,
    args: Vec<String>,
    cwd: PathBuf,
    /// Some when we pre-assigned the session id (so `new` can pre-tag it).
    session_id: Option<String>,
}

trait Provider {
    fn id(&self) -> &'static str;
    /// List sessions, scoped to `workspace` (None = every workspace).
    /// Returns (rows, truncated) — `truncated` is true when a scan cap dropped files.
    fn list(&self, workspace: Option<&Path>) -> (Vec<SessionMeta>, bool);
    /// (id, path) for every session file — filenames only, no content parse.
    fn session_files(&self) -> Vec<(String, PathBuf)>;
    /// Build the full meta for a single session file.
    fn meta_for(&self, id: &str, path: &Path) -> SessionMeta;
    /// The first-message string used for conv-key derivation (provider jq semantics).
    fn conv_key_message(&self, path: &Path) -> Option<String>;
    /// True when the session's content (best-effort) matches `re`.
    fn grep(&self, path: &Path, re: &Regex) -> bool;
    /// Command to resume `meta`.
    fn resume_cmd(&self, meta: &SessionMeta, model: Option<&str>) -> LaunchPlan;
    /// Command to start a new session in `workspace`.
    fn new_cmd(&self, workspace: &Path, model: Option<&str>, prompt: Option<&str>) -> LaunchPlan;
}

fn registry() -> Vec<Box<dyn Provider>> {
    vec![Box::new(ClaudeProvider), Box::new(AuggieProvider)]
}

/// Resolve `--agent` to the providers it selects. "all" → every provider.
fn select_providers(agent: &str) -> Result<Vec<Box<dyn Provider>>> {
    let all = registry();
    if agent == "all" {
        return Ok(all);
    }
    let picked: Vec<Box<dyn Provider>> = all.into_iter().filter(|p| p.id() == agent).collect();
    if picked.is_empty() {
        bail!("unknown --agent '{}' (known: claude, auggie, all)", agent);
    }
    Ok(picked)
}

fn one_provider(agent: &str) -> Result<Box<dyn Provider>> {
    registry()
        .into_iter()
        .find(|p| p.id() == agent)
        .ok_or_else(|| anyhow!("--agent must be a specific agent (claude or auggie), got '{}'", agent))
}

// ---------------------------------------------------------------------------
// Claude provider
// ---------------------------------------------------------------------------

struct ClaudeProvider;

fn claude_projects() -> PathBuf {
    home().join(".claude/projects")
}

/// Readable first-user-message for display: first `type=="user"` text that is
/// non-empty and not a `<`-prefixed tool/command envelope; array parts joined.
fn claude_first_message_display(path: &Path) -> Option<String> {
    let content = fs::read_to_string(path).ok()?;
    for line in content.lines() {
        let v: Value = match serde_json::from_str(line) {
            Ok(v) => v,
            Err(_) => continue,
        };
        if v.get("type").and_then(Value::as_str) != Some("user") {
            continue;
        }
        let msg = v.get("message");
        let text = match msg.and_then(|m| m.get("content")).or(msg) {
            Some(Value::String(s)) => s.clone(),
            Some(Value::Array(parts)) => parts
                .iter()
                .filter(|p| p.get("type").and_then(Value::as_str) == Some("text"))
                .filter_map(|p| p.get("text").and_then(Value::as_str))
                .collect::<Vec<_>>()
                .join(" "),
            _ => continue,
        };
        let trimmed = text.trim();
        if !trimmed.is_empty() && !trimmed.starts_with('<') {
            return Some(trimmed.to_string());
        }
    }
    None
}

/// First-user-message EXACTLY as agent-shell's claude jq derives it (the first
/// non-empty user text block in document order — array → first `text` block,
/// NOT joined; string → the string — with NO `<`-skip, no trim). Used for conv-key.
fn claude_first_message_for_key(path: &Path) -> Option<String> {
    let content = fs::read_to_string(path).ok()?;
    for line in content.lines() {
        let v: Value = match serde_json::from_str(line) {
            Ok(v) => v,
            Err(_) => continue,
        };
        if v.get("type").and_then(Value::as_str) != Some("user") {
            continue;
        }
        match v.get("message").and_then(|m| m.get("content")) {
            Some(Value::String(s)) if !s.is_empty() => return Some(s.clone()),
            Some(Value::Array(parts)) => {
                for p in parts {
                    if p.get("type").and_then(Value::as_str) == Some("text") {
                        if let Some(t) = p.get("text").and_then(Value::as_str) {
                            if !t.is_empty() {
                                return Some(t.to_string());
                            }
                        }
                    }
                }
            }
            _ => {}
        }
    }
    None
}

/// Launch cwd a claude transcript recorded (its `cwd` field).
fn claude_cwd(path: &Path) -> Option<PathBuf> {
    let content = fs::read_to_string(path).ok()?;
    for line in content.lines() {
        if let Ok(v) = serde_json::from_str::<Value>(line) {
            if let Some(cwd) = v.get("cwd").and_then(Value::as_str) {
                return Some(PathBuf::from(cwd));
            }
        }
    }
    None
}

fn mtime_of(path: &Path) -> SystemTime {
    fs::metadata(path).and_then(|m| m.modified()).unwrap_or(SystemTime::UNIX_EPOCH)
}

impl Provider for ClaudeProvider {
    fn id(&self) -> &'static str {
        "claude"
    }

    fn list(&self, workspace: Option<&Path>) -> (Vec<SessionMeta>, bool) {
        let projects = claude_projects();
        // Directories to scan: one slug dir when scoped, else every project dir.
        let dirs: Vec<PathBuf> = match workspace {
            Some(ws) => vec![projects.join(slug(&ws.to_string_lossy()))],
            None => fs::read_dir(&projects)
                .into_iter()
                .flatten()
                .flatten()
                .map(|e| e.path())
                .filter(|p| p.is_dir())
                .collect(),
        };
        let mut rows = Vec::new();
        for dir in dirs {
            for (id, path) in jsonl_files(&dir) {
                rows.push(self.meta_for(&id, &path));
            }
        }
        (rows, false)
    }

    fn session_files(&self) -> Vec<(String, PathBuf)> {
        let projects = claude_projects();
        let mut out = Vec::new();
        if let Ok(dirs) = fs::read_dir(&projects) {
            for d in dirs.flatten() {
                if d.path().is_dir() {
                    out.extend(jsonl_files(&d.path()));
                }
            }
        }
        out
    }

    fn meta_for(&self, id: &str, path: &Path) -> SessionMeta {
        SessionMeta {
            id: id.to_string(),
            provider: "claude",
            glyph: "C",
            workspace: claude_cwd(path),
            first_message: claude_first_message_display(path).unwrap_or_else(|| "(no prompt)".into()),
            mtime: mtime_of(path),
            path: path.to_path_buf(),
        }
    }

    fn conv_key_message(&self, path: &Path) -> Option<String> {
        claude_first_message_for_key(path)
    }

    fn grep(&self, path: &Path, re: &Regex) -> bool {
        fs::read_to_string(path).map(|s| re.is_match(&s)).unwrap_or(false)
    }

    fn resume_cmd(&self, meta: &SessionMeta, _model: Option<&str>) -> LaunchPlan {
        // claude replays model over ACP; the terminal CLI uses its own default.
        LaunchPlan {
            program: "claude".into(),
            args: vec!["--resume".into(), meta.id.clone()],
            cwd: meta.workspace.clone().unwrap_or_else(|| std::env::current_dir().unwrap_or_default()),
            session_id: None,
        }
    }

    fn new_cmd(&self, workspace: &Path, model: Option<&str>, prompt: Option<&str>) -> LaunchPlan {
        let uuid = new_uuid_v4().unwrap_or_default();
        let mut args = vec!["--session-id".into(), uuid.clone()];
        if let Some(m) = model {
            args.push("--model".into());
            args.push(m.into());
        }
        if let Some(p) = prompt {
            if !p.is_empty() {
                args.push(p.into());
            }
        }
        LaunchPlan { program: "claude".into(), args, cwd: workspace.to_path_buf(), session_id: Some(uuid) }
    }
}

/// (stem, path) for every `*.jsonl` in a directory.
fn jsonl_files(dir: &Path) -> Vec<(String, PathBuf)> {
    let mut out = Vec::new();
    if let Ok(entries) = fs::read_dir(dir) {
        for e in entries.flatten() {
            let path = e.path();
            if path.extension().and_then(|x| x.to_str()) == Some("jsonl") {
                if let Some(stem) = path.file_stem().and_then(|s| s.to_str()) {
                    out.push((stem.to_string(), path));
                }
            }
        }
    }
    out
}

// ---------------------------------------------------------------------------
// Auggie provider (bounded prefix parsing of large session files)
// ---------------------------------------------------------------------------

struct AuggieProvider;

fn auggie_dir() -> PathBuf {
    home().join(".augment/sessions")
}

/// Read up to `n` bytes from the start of a file.
fn read_prefix(path: &Path, n: usize) -> Option<Vec<u8>> {
    let mut f = fs::File::open(path).ok()?;
    let mut buf = vec![0u8; n];
    let mut filled = 0;
    while filled < n {
        match f.read(&mut buf[filled..]) {
            Ok(0) => break,
            Ok(k) => filled += k,
            Err(_) => break,
        }
    }
    buf.truncate(filled);
    Some(buf)
}

/// Decode a JSON string literal starting at `b[start] == '"'`; returns the
/// decoded value and the index just past the closing quote. `None` if the quote
/// is unterminated within the buffer (a truncated prefix).
fn parse_json_string(b: &[u8], start: usize) -> Option<(String, usize)> {
    let mut i = start + 1;
    let mut out: Vec<u8> = Vec::new();
    while i < b.len() {
        match b[i] {
            b'"' => return Some((String::from_utf8_lossy(&out).into_owned(), i + 1)),
            b'\\' => {
                i += 1;
                if i >= b.len() {
                    return None;
                }
                match b[i] {
                    b'"' => out.push(b'"'),
                    b'\\' => out.push(b'\\'),
                    b'/' => out.push(b'/'),
                    b'n' => out.push(b'\n'),
                    b't' => out.push(b'\t'),
                    b'r' => out.push(b'\r'),
                    b'b' => out.push(0x08),
                    b'f' => out.push(0x0C),
                    b'u' => {
                        if i + 4 >= b.len() {
                            return None;
                        }
                        let hex = std::str::from_utf8(&b[i + 1..i + 5]).ok()?;
                        if let Some(ch) = u32::from_str_radix(hex, 16).ok().and_then(char::from_u32) {
                            let mut tmp = [0u8; 4];
                            out.extend_from_slice(ch.encode_utf8(&mut tmp).as_bytes());
                        }
                        i += 4;
                    }
                    _ => return None,
                }
                i += 1;
            }
            c => {
                out.push(c);
                i += 1;
            }
        }
    }
    None
}

/// Every JSON string value that follows a `"key":` in `buf`, in order. Used to
/// pull `request_message` / workspace fields out of a bounded prefix.
fn json_string_values_after(buf: &[u8], key: &str) -> Vec<String> {
    let needle = format!("\"{}\"", key);
    let nb = needle.as_bytes();
    let mut out = Vec::new();
    let mut i = 0;
    while i + nb.len() <= buf.len() {
        if &buf[i..i + nb.len()] == nb {
            let mut j = i + nb.len();
            while j < buf.len() && (buf[j] as char).is_whitespace() {
                j += 1;
            }
            if j < buf.len() && buf[j] == b':' {
                j += 1;
                while j < buf.len() && (buf[j] as char).is_whitespace() {
                    j += 1;
                }
                if j < buf.len() && buf[j] == b'"' {
                    if let Some((s, end)) = parse_json_string(buf, j) {
                        out.push(s);
                        i = end;
                        continue;
                    }
                }
            }
            i = j;
        } else {
            i += 1;
        }
    }
    out
}

/// First-user-message EXACTLY as agent-shell's auggie jq derives it: the first
/// `chatHistory[].exchange.request_message` that is non-null, non-empty, and not
/// `⚠`-prefixed. Read from a bounded prefix.
fn auggie_first_message(path: &Path) -> Option<String> {
    let buf = read_prefix(path, AUGGIE_PREFIX_BYTES)?;
    json_string_values_after(&buf, "request_message")
        .into_iter()
        .find(|s| !s.is_empty() && !s.starts_with(AUGGIE_WARN_PREFIX))
}

/// Workspace an auggie session recorded, from its first exchange's IDE state.
/// Prefers the concrete cwd, then repository/folder roots.
fn auggie_workspace(path: &Path) -> Option<PathBuf> {
    let buf = read_prefix(path, AUGGIE_PREFIX_BYTES)?;
    for key in ["current_working_directory", "repository_root", "folder_root"] {
        if let Some(p) = json_string_values_after(&buf, key).into_iter().find(|s| s.starts_with('/')) {
            return Some(PathBuf::from(p));
        }
    }
    None
}

/// (stem, path, mtime) for auggie session files, newest first.
fn auggie_files_sorted() -> Vec<(String, PathBuf, SystemTime)> {
    let mut files: Vec<(String, PathBuf, SystemTime)> = Vec::new();
    if let Ok(entries) = fs::read_dir(auggie_dir()) {
        for e in entries.flatten() {
            let path = e.path();
            if path.extension().and_then(|x| x.to_str()) == Some("json") {
                if let Some(stem) = path.file_stem().and_then(|s| s.to_str()) {
                    let mtime = e.metadata().and_then(|m| m.modified()).unwrap_or(SystemTime::UNIX_EPOCH);
                    files.push((stem.to_string(), path, mtime));
                }
            }
        }
    }
    files.sort_by(|a, b| b.2.cmp(&a.2));
    files
}

impl Provider for AuggieProvider {
    fn id(&self) -> &'static str {
        "auggie"
    }

    fn list(&self, workspace: Option<&Path>) -> (Vec<SessionMeta>, bool) {
        let files = auggie_files_sorted();
        let truncated = files.len() > AUGGIE_SCAN_CAP;
        let want = workspace.map(canonical);
        let mut rows = Vec::new();
        for (id, path, mtime) in files.into_iter().take(AUGGIE_SCAN_CAP) {
            let ws = auggie_workspace(&path);
            if let Some(target) = &want {
                if ws.as_ref().map(|w| canonical(w)) != Some(target.clone()) {
                    continue;
                }
            }
            let first = auggie_first_message(&path).unwrap_or_else(|| "(no prompt)".into());
            rows.push(SessionMeta {
                id,
                provider: "auggie",
                glyph: "A",
                workspace: ws,
                first_message: first,
                mtime,
                path,
            });
        }
        (rows, truncated)
    }

    fn session_files(&self) -> Vec<(String, PathBuf)> {
        auggie_files_sorted().into_iter().map(|(id, p, _)| (id, p)).collect()
    }

    fn meta_for(&self, id: &str, path: &Path) -> SessionMeta {
        SessionMeta {
            id: id.to_string(),
            provider: "auggie",
            glyph: "A",
            workspace: auggie_workspace(path),
            first_message: auggie_first_message(path).unwrap_or_else(|| "(no prompt)".into()),
            mtime: mtime_of(path),
            path: path.to_path_buf(),
        }
    }

    fn conv_key_message(&self, path: &Path) -> Option<String> {
        auggie_first_message(path)
    }

    fn grep(&self, path: &Path, re: &Regex) -> bool {
        // Best-effort: auggie files can be hundreds of MB, so search the prefix.
        read_prefix(path, AUGGIE_PREFIX_BYTES)
            .map(|b| re.is_match(&String::from_utf8_lossy(&b)))
            .unwrap_or(false)
    }

    fn resume_cmd(&self, meta: &SessionMeta, model: Option<&str>) -> LaunchPlan {
        let cwd = meta.workspace.clone().unwrap_or_else(|| std::env::current_dir().unwrap_or_default());
        let mut args = vec!["--resume".into(), meta.id.clone()];
        // auggie pins the model on the command line on resume.
        if let Some(m) = model {
            args.push("--model".into());
            args.push(m.into());
        }
        args.push("--workspace-root".into());
        args.push(cwd.to_string_lossy().into_owned());
        LaunchPlan { program: "auggie".into(), args, cwd, session_id: None }
    }

    fn new_cmd(&self, workspace: &Path, model: Option<&str>, prompt: Option<&str>) -> LaunchPlan {
        // auggie has no --session-id, so we cannot pre-assign/pre-tag an id.
        let mut args =
            vec!["--workspace-root".into(), workspace.to_string_lossy().into_owned()];
        if let Some(m) = model {
            args.push("--model".into());
            args.push(m.into());
        }
        if let Some(p) = prompt {
            if !p.is_empty() {
                args.push(p.into());
            }
        }
        LaunchPlan { program: "auggie".into(), args, cwd: workspace.to_path_buf(), session_id: None }
    }
}

fn canonical(p: &Path) -> PathBuf {
    p.canonicalize().unwrap_or_else(|_| p.to_path_buf())
}

// ---------------------------------------------------------------------------
// Commands
// ---------------------------------------------------------------------------

fn resolve_workspace(workspace: &Option<String>) -> Result<PathBuf> {
    let raw = match workspace {
        Some(w) => {
            if let Some(rest) = w.strip_prefix("~/") {
                home().join(rest)
            } else {
                PathBuf::from(w)
            }
        }
        None => std::env::current_dir()?,
    };
    Ok(canonical(&raw))
}

fn now_iso() -> String {
    chrono::Utc::now().format("%Y-%m-%dT%H:%M:%S%.3fZ").to_string()
}

fn fmt_mtime(t: SystemTime) -> String {
    let utc: chrono::DateTime<chrono::Utc> = t.into();
    utc.with_timezone(&chrono::Local).format("%Y-%m-%d %H:%M").to_string()
}

fn short(id: &str) -> &str {
    id.get(..8).unwrap_or(id)
}

fn tags_for(idx: &Map<String, Value>, id: &str) -> Vec<String> {
    idx.get(id)
        .and_then(Value::as_array)
        .map(|a| a.iter().filter_map(|v| v.as_str().map(str::to_string)).collect())
        .unwrap_or_default()
}

#[allow(clippy::too_many_arguments)]
fn cmd_list(
    paths: &Paths,
    agent: &str,
    workspace: Option<String>,
    all: bool,
    tags: Vec<String>,
    grep: Option<String>,
    since: Option<String>,
    limit: Option<usize>,
    json: bool,
) -> Result<()> {
    let store = load_store(&paths.store)?;
    let idx = session_tag_index(&store);
    let providers = select_providers(agent)?;
    let re = match &grep {
        Some(p) => Some(Regex::new(p).map_err(|e| anyhow!("invalid --grep {:?}: {}", p, e))?),
        None => None,
    };
    let min_since = match &since {
        Some(s) => Some(crate::parse_duration(s)?),
        None => None,
    };
    let now = SystemTime::now();
    let ws = if all { None } else { Some(resolve_workspace(&workspace)?) };

    let mut rows: Vec<SessionMeta> = Vec::new();
    for p in &providers {
        let (r, truncated) = p.list(ws.as_deref());
        if truncated {
            eprintln!(
                "note: {} has more than {} sessions; showing the newest {} (use --workspace to narrow)",
                p.id(),
                AUGGIE_SCAN_CAP,
                AUGGIE_SCAN_CAP
            );
        }
        rows.extend(r);
    }

    rows.retain(|r| {
        let rtags = tags_for(&idx, &r.id);
        if !tags.is_empty() && !tags.iter().all(|t| rtags.iter().any(|x| x == t)) {
            return false;
        }
        if let Some(re) = &re {
            let prov = providers.iter().find(|p| p.id() == r.provider);
            if !prov.map(|p| p.grep(&r.path, re)).unwrap_or(false) {
                return false;
            }
        }
        if let Some(min) = min_since {
            if now.duration_since(r.mtime).map(|d| d > min).unwrap_or(true) {
                return false;
            }
        }
        true
    });
    rows.sort_by(|a, b| b.mtime.cmp(&a.mtime));
    if let Some(n) = limit {
        rows.truncate(n);
    }

    if json {
        let arr: Vec<Value> = rows
            .iter()
            .map(|r| {
                json!({
                    "id": r.id,
                    "agent": r.provider,
                    "workspace": r.workspace,
                    "tags": tags_for(&idx, &r.id),
                    "firstMessage": r.first_message,
                    "lastModified": fmt_mtime(r.mtime),
                })
            })
            .collect();
        println!("{}", serde_json::to_string_pretty(&arr)?);
        return Ok(());
    }

    if rows.is_empty() {
        eprintln!("No sessions found.");
        return Ok(());
    }
    for r in &rows {
        let rtags = tags_for(&idx, &r.id);
        let tagstr = if rtags.is_empty() { String::new() } else { format!("[{}] ", rtags.join(",")) };
        let prompt: String = r.first_message.chars().take(64).collect();
        let prompt = prompt.replace('\n', " ");
        println!(
            "{} {}  {}  {}{}",
            crate::styled_str(r.glyph, &[crate::Style::Dim]),
            crate::styled_str(&fmt_mtime(r.mtime), &[crate::Style::Dim]),
            crate::styled_str(short(&r.id), &[crate::Style::Cyan]),
            crate::styled_str(&tagstr, &[crate::Style::Yellow]),
            prompt,
        );
    }
    Ok(())
}

/// A located session file (by filename) plus which provider owns it.
struct Located {
    provider_id: &'static str,
    id: String,
    path: PathBuf,
}

/// Resolve an id/prefix to exactly one session across the selected providers,
/// matching filenames only (cheap).
fn locate_id(providers: &[Box<dyn Provider>], id: &str) -> Result<Located> {
    let mut exact: Vec<Located> = Vec::new();
    let mut prefix: Vec<Located> = Vec::new();
    for p in providers {
        for (sid, path) in p.session_files() {
            if sid == id {
                exact.push(Located { provider_id: p.id(), id: sid, path });
            } else if sid.starts_with(id) {
                prefix.push(Located { provider_id: p.id(), id: sid, path });
            }
        }
    }
    if exact.len() == 1 {
        return Ok(exact.pop().unwrap());
    }
    match prefix.len() {
        1 => Ok(prefix.pop().unwrap()),
        0 => bail!("no session matches id/prefix '{}'", id),
        _ => {
            let mut msg = format!("ambiguous id/prefix '{}' matches {} sessions:\n", id, prefix.len());
            for l in prefix.iter().take(12) {
                msg.push_str(&format!("  [{}] {}\n", l.provider_id, l.id));
            }
            bail!(msg)
        }
    }
}

#[allow(clippy::too_many_arguments)]
fn cmd_resume(
    paths: &Paths,
    agent: &str,
    id: Option<String>,
    tags: Vec<String>,
    last: bool,
    workspace: Option<String>,
    all: bool,
    print: bool,
) -> Result<()> {
    let store = load_store(&paths.store)?;
    let providers = select_providers(agent)?;

    let (provider, meta) = if let Some(id) = &id {
        let loc = locate_id(&providers, id)?;
        let p = providers.iter().find(|p| p.id() == loc.provider_id).unwrap();
        (p, p.meta_for(&loc.id, &loc.path))
    } else if !tags.is_empty() || last {
        // Scan the selected providers in scope and pick the newest match.
        let idx = session_tag_index(&store);
        let ws = if all { None } else { Some(resolve_workspace(&workspace)?) };
        let mut best: Option<(&Box<dyn Provider>, SessionMeta)> = None;
        for p in &providers {
            let (rows, _) = p.list(ws.as_deref());
            for m in rows {
                if !tags.is_empty() {
                    let mtags = tags_for(&idx, &m.id);
                    if !tags.iter().all(|t| mtags.iter().any(|x| x == t)) {
                        continue;
                    }
                }
                let newer = best.as_ref().map(|(_, b)| m.mtime > b.mtime).unwrap_or(true);
                if newer {
                    best = Some((p, m));
                }
            }
        }
        let (p, m) = best.ok_or_else(|| anyhow!("no session matches the given tag(s) in scope"))?;
        (p, m)
    } else {
        bail!("specify a session id, --tag <t>, or --last");
    };

    let model = store_model_for(&store, &meta.id);
    let plan = provider.resume_cmd(&meta, model.as_deref());
    dispatch(plan, print)
}

fn cmd_new(
    paths: &Paths,
    agent: &str,
    tags: Vec<String>,
    workspace: Option<String>,
    model: Option<String>,
    print: bool,
    prompt: Vec<String>,
) -> Result<()> {
    let provider = one_provider(agent)?;
    let ws = resolve_workspace(&workspace)?;
    let prompt_str = prompt.join(" ");
    let prompt_opt = if prompt_str.is_empty() { None } else { Some(prompt_str.as_str()) };
    let plan = provider.new_cmd(&ws, model.as_deref(), prompt_opt);

    // Pre-tag only when the provider gave us a session id AND we have a prompt to key.
    if !tags.is_empty() {
        match (&plan.session_id, prompt_opt) {
            (Some(uuid), Some(p)) => {
                let mut store = load_store(&paths.store)?;
                if !conv_key_writes_ok(&store) {
                    eprintln!("note: store _canonicalKeyVersion differs from this decknix; starting untagged (update decknix).");
                } else if let Some(key) = conv_key(p) {
                    upsert_conversation(&mut store, &key, uuid, &tags, &model, &ws.to_string_lossy());
                    save_store(&paths.store, &store)?;
                }
            }
            _ => {
                eprintln!(
                    "note: {} can't pre-tag this session (needs a pre-assignable id + an initial prompt).\n      after the first message, run: decknix session tag <id> --add {}",
                    provider.id(),
                    tags.join(" --add ")
                );
            }
        }
    }
    dispatch(plan, print)
}

fn upsert_conversation(
    store: &mut Value,
    key: &str,
    uuid: &str,
    tags: &[String],
    model: &Option<String>,
    workspace: &str,
) {
    let convs = conversations_mut(store);
    let canonical = {
        let snapshot = convs.clone();
        resolve_merged(&snapshot, key)
    };
    let entry = convs.entry(canonical).or_insert_with(|| json!({})).as_object_mut().unwrap();

    let mut merged: Vec<String> = entry
        .get("tags")
        .and_then(Value::as_array)
        .map(|a| a.iter().filter_map(|v| v.as_str().map(str::to_string)).collect())
        .unwrap_or_default();
    for t in tags {
        if !merged.iter().any(|x| x == t) {
            merged.push(t.clone());
        }
    }
    entry.insert("tags".into(), json!(merged));

    let mut sessions: Vec<String> = entry
        .get("sessions")
        .and_then(Value::as_array)
        .map(|a| a.iter().filter_map(|v| v.as_str().map(str::to_string)).collect())
        .unwrap_or_default();
    if !sessions.iter().any(|s| s == uuid) {
        sessions.push(uuid.to_string());
    }
    entry.insert("sessions".into(), json!(sessions));

    if let Some(m) = model {
        entry.insert("model".into(), json!(m));
    }
    let ws = if workspace.ends_with('/') { workspace.to_string() } else { format!("{}/", workspace) };
    entry.insert("workspace".into(), json!(ws));
    entry.insert("lastAccessed".into(), json!(now_iso()));
}

fn cmd_tag(paths: &Paths, agent: &str, id: String, add: Vec<String>, remove: Vec<String>) -> Result<()> {
    if add.is_empty() && remove.is_empty() {
        bail!("nothing to do: pass --add <tag> and/or --remove <tag>");
    }
    let mut store = load_store(&paths.store)?;
    let providers = select_providers(agent)?;

    let (full_id, provider_id, path) = match locate_id(&providers, &id) {
        Ok(l) => (l.id, Some(l.provider_id), Some(l.path)),
        Err(_) if looks_like_uuid(&id) => (id.clone(), None, None),
        Err(e) => return Err(e),
    };

    let owning_key = conversations(&store).and_then(|convs| {
        convs.iter().find_map(|(k, e)| {
            let has = e
                .get("sessions")
                .and_then(Value::as_array)
                .map(|a| a.iter().any(|s| s.as_str() == Some(full_id.as_str())))
                .unwrap_or(false);
            if has { Some(k.clone()) } else { None }
        })
    });

    let key = match owning_key {
        Some(k) => k,
        None => {
            if !conv_key_writes_ok(&store) {
                bail!("store _canonicalKeyVersion differs from this decknix; cannot mint a new conversation entry (update decknix)");
            }
            let path = path.ok_or_else(|| {
                anyhow!("session '{}' has no transcript to derive a conversation key from", full_id)
            })?;
            let provider = providers.iter().find(|p| Some(p.id()) == provider_id).ok_or_else(|| {
                anyhow!("could not determine the agent that owns '{}'", full_id)
            })?;
            let first = provider
                .conv_key_message(&path)
                .ok_or_else(|| anyhow!("cannot read a first user message for '{}'", full_id))?;
            let key = conv_key(&first).ok_or_else(|| anyhow!("empty first message; cannot key conversation"))?;
            let convs = conversations(&store).cloned().unwrap_or_default();
            resolve_merged(&convs, &key)
        }
    };

    {
        let convs = conversations_mut(&mut store);
        let entry = convs.entry(key.clone()).or_insert_with(|| json!({})).as_object_mut().unwrap();
        let mut tags: Vec<String> = entry
            .get("tags")
            .and_then(Value::as_array)
            .map(|a| a.iter().filter_map(|v| v.as_str().map(str::to_string)).collect())
            .unwrap_or_default();
        for t in &add {
            if !tags.iter().any(|x| x == t) {
                tags.push(t.clone());
            }
        }
        tags.retain(|t| !remove.iter().any(|r| r == t));
        entry.insert("tags".into(), json!(tags));

        let mut sessions: Vec<String> = entry
            .get("sessions")
            .and_then(Value::as_array)
            .map(|a| a.iter().filter_map(|v| v.as_str().map(str::to_string)).collect())
            .unwrap_or_default();
        if !sessions.iter().any(|s| s == &full_id) {
            sessions.push(full_id.clone());
            entry.insert("sessions".into(), json!(sessions));
        }
    }

    save_store(&paths.store, &store)?;
    let final_tags = conversations(&store).and_then(|c| c.get(&key)).map(entry_tags).unwrap_or_default();
    println!("{}  tags: [{}]", short(&full_id), final_tags.join(","));
    Ok(())
}

fn cmd_tags(paths: &Paths, json: bool) -> Result<()> {
    let store = load_store(&paths.store)?;
    let mut counts: std::collections::BTreeMap<String, usize> = std::collections::BTreeMap::new();
    if let Some(convs) = conversations(&store) {
        for e in convs.values() {
            for t in entry_tags(e) {
                *counts.entry(t).or_insert(0) += 1;
            }
        }
    }
    if json {
        println!("{}", serde_json::to_string_pretty(&counts)?);
        return Ok(());
    }
    let mut pairs: Vec<(String, usize)> = counts.into_iter().collect();
    pairs.sort_by(|a, b| b.1.cmp(&a.1).then(a.0.cmp(&b.0)));
    for (t, n) in pairs {
        println!("{:>4}  {}", n, t);
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// Launch (exec or print)
// ---------------------------------------------------------------------------

fn dispatch(plan: LaunchPlan, print: bool) -> Result<()> {
    if print {
        let args: Vec<String> = plan.args.iter().map(|a| shell_quote(a)).collect();
        println!("cd {} && {} {}", shell_quote(&plan.cwd.to_string_lossy()), plan.program, args.join(" "));
        return Ok(());
    }
    use std::os::unix::process::CommandExt;
    let err = std::process::Command::new(&plan.program).current_dir(&plan.cwd).args(&plan.args).exec();
    Err(anyhow!("failed to exec {}: {}", plan.program, err))
}

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

fn looks_like_uuid(s: &str) -> bool {
    let b = s.as_bytes();
    b.len() == 36
        && b.iter().enumerate().all(|(i, &c)| match i {
            8 | 13 | 18 | 23 => c == b'-',
            _ => c.is_ascii_hexdigit(),
        })
}

fn new_uuid_v4() -> Result<String> {
    let mut b = [0u8; 16];
    fs::File::open("/dev/urandom")?.read_exact(&mut b)?;
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    Ok(format!(
        "{:02x}{:02x}{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}{:02x}{:02x}{:02x}{:02x}",
        b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]
    ))
}

fn shell_quote(s: &str) -> String {
    if !s.is_empty() && s.chars().all(|c| c.is_ascii_alphanumeric() || "-_./=:".contains(c)) {
        s.to_string()
    } else {
        format!("'{}'", s.replace('\'', "'\\''"))
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn slug_replaces_non_alnum_and_strips_trailing_slash() {
        assert_eq!(slug("/Users/ldeck/Code/nurturecloud"), "-Users-ldeck-Code-nurturecloud");
        assert_eq!(slug("/Users/ldeck/Code/nurturecloud/"), "-Users-ldeck-Code-nurturecloud");
        assert_eq!(slug("/a/.b_c"), "-a--b-c");
    }

    #[test]
    fn conv_key_known_answer() {
        assert_eq!(conv_key("abc").unwrap(), "ba7816bf8f01cfea");
    }

    #[test]
    fn conv_key_empty_is_none() {
        assert_eq!(conv_key(""), None);
    }

    #[test]
    fn conv_key_truncates_at_200_chars() {
        let s200: String = std::iter::repeat('a').take(200).collect();
        let s250: String = std::iter::repeat('a').take(250).collect();
        assert_eq!(conv_key(&s200), conv_key(&s250));
        let s199: String = std::iter::repeat('a').take(199).collect();
        assert_ne!(conv_key(&s199), conv_key(&s200));
    }

    #[test]
    fn store_roundtrip_preserves_unknown_fields() {
        let store = json!({
            "_canonicalKeyVersion": 1,
            "bookmarks": {"sid": {"label": "x"}},
            "conversations": {"abc123def4567890": {"tags": ["decknix"], "model": "sonnet", "mode": "auto"}}
        });
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("agent-sessions.json");
        save_store(&path, &store).unwrap();
        let back = load_store(&path).unwrap();
        assert_eq!(back["bookmarks"]["sid"]["label"], json!("x"));
        assert_eq!(back["conversations"]["abc123def4567890"]["mode"], json!("auto"));
    }

    #[test]
    fn resolve_merged_follows_redirect() {
        let store = json!({"conversations": {
            "aaaaaaaaaaaaaaaa": {"mergedInto": "bbbbbbbbbbbbbbbb"},
            "bbbbbbbbbbbbbbbb": {"tags": ["real"]}
        }});
        let convs = conversations(&store).unwrap();
        assert_eq!(resolve_merged(convs, "aaaaaaaaaaaaaaaa"), "bbbbbbbbbbbbbbbb");
    }

    #[test]
    fn conv_key_writes_gated_by_version() {
        assert!(conv_key_writes_ok(&json!({"_canonicalKeyVersion": 1})));
        assert!(conv_key_writes_ok(&json!({})));
        assert!(!conv_key_writes_ok(&json!({"_canonicalKeyVersion": 2})));
    }

    #[test]
    fn claude_first_message_for_key_matches_emacs_semantics() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("s.jsonl");
        let body = [
            r#"{"type":"queue-operation"}"#,
            r#"{"type":"user","message":{"content":[{"type":"text","text":"<cmd>foo</cmd>"},{"type":"text","text":"second"}]}}"#,
        ]
        .join("\n");
        fs::write(&path, body).unwrap();
        // key path keeps the '<' wrapper and takes only the FIRST text block
        assert_eq!(claude_first_message_for_key(&path).unwrap(), "<cmd>foo</cmd>");
        // display path skips '<' wrappers
        assert_eq!(claude_first_message_display(&path), None);
    }

    #[test]
    fn parse_json_string_handles_escapes_and_utf8() {
        let raw = r#""a\"b\n⚠ é end" trailing"#.as_bytes();
        let (s, end) = parse_json_string(raw, 0).unwrap();
        assert_eq!(s, "a\"b\n\u{26a0} \u{e9} end");
        assert_eq!(raw[end], b' ');
    }

    #[test]
    fn parse_json_string_none_when_truncated() {
        let raw = br#""unterminated prefix"#;
        assert!(parse_json_string(raw, 0).is_none());
    }

    #[test]
    fn auggie_first_message_skips_warning_prefix_and_reads_prefix() {
        // Mimic an auggie file whose first request_message is a ⚠ system note.
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("a.json");
        let body = format!(
            r#"{{"chatHistory":[{{"exchange":{{"request_message":"{}system"}}}},{{"exchange":{{"request_message":"real first prompt"}}}}]}}"#,
            AUGGIE_WARN_PREFIX
        );
        fs::write(&path, body).unwrap();
        assert_eq!(auggie_first_message(&path).unwrap(), "real first prompt");
    }

    #[test]
    fn auggie_workspace_prefers_cwd_then_roots() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("a.json");
        let body = r#"{"chatHistory":[{"exchange":{"request_nodes":[{"ide_state_node":{"workspace_folders":[{"repository_root":"/Users/x/repo"}],"current_terminal":{"current_working_directory":"/Users/x/repo/sub"}}}]}}]}"#;
        fs::write(&path, body).unwrap();
        assert_eq!(auggie_workspace(&path), Some(PathBuf::from("/Users/x/repo/sub")));
    }

    #[test]
    fn auggie_conv_key_message_matches_hash_of_first_prompt() {
        // conv-key(first prompt) must equal sha256(first 200)[:16].
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("a.json");
        fs::write(&path, r#"{"chatHistory":[{"exchange":{"request_message":"abc"}}]}"#).unwrap();
        let msg = auggie_first_message(&path).unwrap();
        assert_eq!(conv_key(&msg).unwrap(), "ba7816bf8f01cfea");
    }

    #[test]
    fn looks_like_uuid_validates_shape() {
        assert!(looks_like_uuid("d946df26-6eb1-4813-89c3-ef7984f9ba39"));
        assert!(!looks_like_uuid("d946df26"));
    }

    #[test]
    fn shell_quote_escapes_spaces_and_quotes() {
        assert_eq!(shell_quote("/Users/x/repo"), "/Users/x/repo");
        assert_eq!(shell_quote("has space"), "'has space'");
        assert_eq!(shell_quote("it's"), "'it'\\''s'");
    }

    #[test]
    fn registry_has_claude_and_auggie() {
        let ids: Vec<&str> = registry().iter().map(|p| p.id()).collect();
        assert!(ids.contains(&"claude"));
        assert!(ids.contains(&"auggie"));
        assert!(select_providers("all").unwrap().len() >= 2);
        assert_eq!(select_providers("auggie").unwrap().len(), 1);
        assert!(select_providers("bogus").is_err());
    }
}
