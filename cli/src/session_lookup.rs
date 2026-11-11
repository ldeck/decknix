//! One resolver for every `decknix session` command that names another
//! session: `find`, `status`, `send`, `resume`, `tag`, and the `--tag`
//! filters of `list`, `resume` and `archive`.
//!
//! Agents name sessions the way people do: by a tag in the wrong case
//! (`plat-1342` for `PLAT-1342`), without the zero (`lane-4`), with the `#` of
//! a PR tag, as the tag path a buffer name shows (`lane-04/PLAT-1342`), as
//! the whole buffer name, or by an id prefix. Each command used to accept a
//! different subset, and a miss said only "no match". This module accepts
//! all of them, prefers live sessions, and on a miss or a tie prints the
//! sessions it could have meant so the caller can pick one without
//! reaching for the tag store or Emacs.
//!
//! Resolution stages, first hit wins, run over live sessions before saved:
//!
//!   1. id: a full id, or a unique prefix of at least 6 hex characters
//!   2. buffer: a buffer name, with or without `*`, the agent prefix and a
//!      `<2>` suffix, so a bare tag path also matches the buffer it names
//!   3. workspace: an absolute or `~` path; sessions in it or below it
//!   4. tags: terms split on `,` `/` `+` or spaces, ALL of which must match a
//!      tag, a buffer-name segment or a review PR (`repo#123`). A term
//!      matches exactly, else case-insensitively, else loosely (no `#`,
//!      quotes, `-`, `_`, `.`, spaces or leading zeros: `Lane_04` = `lane-4`);
//!      when matches differ in strictness only the strictest are kept.

use anyhow::{anyhow, Result};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

use crate::session;
use crate::session_msg::{self, Dirs};

pub const EXIT_NO_MATCH: i32 = 20;
pub const EXIT_AMBIGUOUS: i32 = 21;
pub const EXIT_NOT_LIVE: i32 = 22;

const MIN_PREFIX: usize = 6;
const MAX_CANDIDATES: usize = 8;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Scope {
    /// Live sessions only.
    Live,
    /// Live sessions; saved ones only when no live session matches.
    Auto,
    /// Live and saved together.
    All,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum Tier {
    Exact,
    Case,
    Loose,
}

impl Tier {
    fn as_str(self) -> &'static str {
        match self {
            Tier::Exact => "exact",
            Tier::Case => "case-insensitive",
            Tier::Loose => "normalised",
        }
    }
}

#[derive(Clone, Debug, Default)]
pub struct Cand {
    pub id: String,
    /// Fresh export from a running Emacs and not dead.
    pub live: bool,
    /// Live state (`working`, `idle`, ...), `<state> (stale)`, or `saved`.
    pub state: String,
    pub buffer: Option<String>,
    pub tags: Vec<String>,
    pub review_prs: Vec<String>,
    pub workspace: Option<String>,
    pub agent: Option<String>,
    pub last_activity: Option<i64>,
    pub transcript: Option<PathBuf>,
    /// The enriched export, for `status` and `send`.
    pub export: Option<Value>,
}

// ---------------------------------------------------------------------------
// Normalisation (pure)
// ---------------------------------------------------------------------------

fn is_quote(c: char) -> bool {
    matches!(c, '"' | '\'' | '`' | '\u{2018}' | '\u{2019}' | '\u{201C}' | '\u{201D}')
}

/// Lowercase, no quotes, no leading `#`.
pub fn fold(s: &str) -> String {
    let s: String = s.chars().filter(|c| !is_quote(*c)).collect();
    s.trim().trim_start_matches('#').trim().to_lowercase()
}

/// [`fold`], then drop separators and leading zeros of each digit run.
pub fn loose(s: &str) -> String {
    let mut out = String::new();
    let mut in_digits = false;
    let mut pending_zero = false;
    for c in fold(s).chars() {
        if c == '#' || c == '-' || c == '_' || c == '.' || c == ':' || c.is_whitespace() {
            if pending_zero {
                out.push('0');
            }
            in_digits = false;
            pending_zero = false;
            continue;
        }
        if c.is_ascii_digit() {
            if !in_digits && c == '0' {
                pending_zero = true;
                continue;
            }
            if pending_zero && c == '0' {
                continue;
            }
            in_digits = true;
            pending_zero = false;
            out.push(c);
        } else {
            if pending_zero {
                out.push('0');
            }
            in_digits = false;
            pending_zero = false;
            out.push(c);
        }
    }
    if pending_zero {
        out.push('0');
    }
    out
}

/// The tag path of a buffer name: `*Claude: lane-04/PLAT-1342*<2>` gives
/// `lane-04/PLAT-1342`. A bare tag path comes back unchanged.
pub fn buffer_core(name: &str) -> String {
    let mut s = name.trim();
    if let Some(i) = s.rfind('<') {
        if s.ends_with('>') && s[i + 1..s.len() - 1].bytes().all(|b| b.is_ascii_digit()) && i + 2 < s.len() {
            s = s[..i].trim_end();
        }
    }
    let s = s.trim_matches('*').trim();
    match s.split_once(": ") {
        Some((agent, rest)) if !agent.is_empty() && agent.chars().all(|c| c.is_alphanumeric() || c == '-' || c == ' ') => rest.trim(),
        _ => s,
    }
    .to_string()
}

fn segments(core: &str) -> Vec<String> {
    core.split('/').map(str::trim).filter(|s| !s.is_empty()).map(str::to_string).collect()
}

/// Split a tag query into terms: `lane-04,PLAT-1342`, `lane-04/PLAT-1342`,
/// `lane-04 PLAT-1342` and a buffer name all give the same two terms.
pub fn terms(query: &str) -> Vec<String> {
    buffer_core(query)
        .split(|c: char| c == ',' || c == '/' || c == '+' || c.is_whitespace())
        .map(|t| t.trim().to_string())
        .filter(|t| !t.is_empty() && !fold(t).is_empty())
        .collect()
}

fn term_tier(term: &str, keys: &[String]) -> Option<Tier> {
    if keys.iter().any(|k| k == term) {
        return Some(Tier::Exact);
    }
    let f = fold(term);
    if keys.iter().any(|k| fold(k) == f) {
        return Some(Tier::Case);
    }
    let l = loose(term);
    if !l.is_empty() && keys.iter().any(|k| loose(k) == l) {
        return Some(Tier::Loose);
    }
    None
}

impl Cand {
    /// Everything a tag term may match: tags, buffer-name segments, review PRs.
    pub fn keys(&self) -> Vec<String> {
        let mut k = split_tags(&self.tags);
        if let Some(b) = &self.buffer {
            k.extend(segments(&buffer_core(b)));
        }
        k.extend(self.review_prs.iter().cloned());
        k
    }
}

/// TAGS plus the parts of any tag that was saved with commas in it
/// (`day4,dos,log`), which a picker once stored as one tag.
fn split_tags(tags: &[String]) -> Vec<String> {
    let mut k = tags.to_vec();
    for t in tags.iter().filter(|t| t.contains(',')) {
        k.extend(t.split(',').map(str::trim).filter(|p| !p.is_empty()).map(str::to_string));
    }
    k
}

/// True when every term of every filter matches CAND-TAGS at some tier.
/// Used by the `--tag` filters, which each may hold several terms.
pub fn tags_match(filters: &[String], tags: &[String]) -> bool {
    let keys = split_tags(tags);
    filters.iter().flat_map(|f| terms(f)).all(|t| term_tier(&t, &keys).is_some())
}

fn looks_hex_id(s: &str) -> bool {
    s.len() >= MIN_PREFIX && s.bytes().all(|c| c.is_ascii_hexdigit() || c == b'-') && s.bytes().any(|c| c.is_ascii_hexdigit())
}

fn expand_path(q: &str) -> Option<String> {
    let raw = if let Some(rest) = q.strip_prefix("~/") {
        dirs::home_dir()?.join(rest)
    } else if q == "~" {
        dirs::home_dir()?
    } else if q.starts_with('/') {
        PathBuf::from(q)
    } else {
        return None;
    };
    let p = raw.canonicalize().unwrap_or(raw);
    Some(p.to_string_lossy().trim_end_matches('/').to_string())
}

fn canon_ws(w: &str) -> String {
    let p = PathBuf::from(w);
    let p = p.canonicalize().unwrap_or(p);
    p.to_string_lossy().trim_end_matches('/').to_string()
}

// ---------------------------------------------------------------------------
// Resolution (pure over a candidate list)
// ---------------------------------------------------------------------------

#[derive(Clone, Debug, PartialEq)]
pub enum Outcome {
    Match,
    Ambiguous,
    NoMatch,
    /// Only saved sessions matched a command that needs a live one.
    NotLive,
}

#[derive(Clone, Debug)]
pub struct Resolution {
    pub query: String,
    pub scope: Scope,
    pub outcome: Outcome,
    /// Indexes into the candidate list, live first then most recent.
    pub matches: Vec<usize>,
    pub how: &'static str,
    pub tier: Option<Tier>,
    /// Closest sessions when nothing matched.
    pub candidates: Vec<usize>,
    pub note: Option<String>,
}

type Hits = (&'static str, Vec<(usize, Tier)>);

fn stage_hits(query: &str, cands: &[Cand], pool: &[usize]) -> Option<Hits> {
    let q = query.trim();
    let ql = q.to_lowercase();
    if session::looks_like_uuid(&ql) {
        let hits: Vec<(usize, Tier)> = pool.iter().copied().filter(|&i| cands[i].id == ql).map(|i| (i, Tier::Exact)).collect();
        if !hits.is_empty() {
            return Some(("id", hits));
        }
    } else if looks_hex_id(&ql) {
        let hits: Vec<(usize, Tier)> = pool.iter().copied().filter(|&i| cands[i].id.starts_with(&ql)).map(|i| (i, Tier::Exact)).collect();
        if !hits.is_empty() {
            return Some(("id-prefix", hits));
        }
    }

    let qcore = buffer_core(q);
    let qsegs: Vec<String> = segments(&qcore).iter().map(|s| loose(s)).collect();
    if !qsegs.is_empty() {
        let hits: Vec<(usize, Tier)> = pool
            .iter()
            .copied()
            .filter_map(|i| {
                let b = cands[i].buffer.as_deref()?;
                let bsegs: Vec<String> = segments(&buffer_core(b)).iter().map(|s| loose(s)).collect();
                if bsegs != qsegs {
                    return None;
                }
                let tier = if b == q || buffer_core(b) == qcore {
                    Tier::Exact
                } else if fold(&buffer_core(b)) == fold(&qcore) {
                    Tier::Case
                } else {
                    Tier::Loose
                };
                Some((i, tier))
            })
            .collect();
        if !hits.is_empty() {
            return Some(("buffer", hits));
        }
    }

    if let Some(path) = expand_path(q) {
        let under = format!("{}/", path);
        let hits: Vec<(usize, Tier)> = pool
            .iter()
            .copied()
            .filter_map(|i| {
                let w = canon_ws(cands[i].workspace.as_deref()?);
                if w == path {
                    Some((i, Tier::Exact))
                } else if w.starts_with(&under) {
                    Some((i, Tier::Loose))
                } else {
                    None
                }
            })
            .collect();
        return if hits.is_empty() { None } else { Some(("workspace", hits)) };
    }

    let ts = terms(q);
    if ts.is_empty() {
        return None;
    }
    let hits: Vec<(usize, Tier)> = pool
        .iter()
        .copied()
        .filter_map(|i| {
            let keys = cands[i].keys();
            ts.iter().map(|t| term_tier(t, &keys)).try_fold(Tier::Exact, |acc, t| t.map(|t| acc.max(t))).map(|t| (i, t))
        })
        .collect();
    if hits.is_empty() { None } else { Some(("tags", hits)) }
}

fn order(cands: &[Cand], idx: &mut [usize]) {
    idx.sort_by(|&a, &b| {
        cands[b].live.cmp(&cands[a].live).then(cands[b].last_activity.cmp(&cands[a].last_activity)).then(cands[a].id.cmp(&cands[b].id))
    });
}

/// Keep only the strictest tier present.
fn strictest(hits: Vec<(usize, Tier)>) -> (Vec<usize>, Option<Tier>, usize) {
    let best = hits.iter().map(|(_, t)| *t).min();
    let total = hits.len();
    let kept: Vec<usize> = hits.into_iter().filter(|(_, t)| Some(*t) == best).map(|(i, _)| i).collect();
    let dropped = total - kept.len();
    (kept, best, dropped)
}

pub fn resolve(query: &str, cands: &[Cand], scope: Scope) -> Resolution {
    let live: Vec<usize> = (0..cands.len()).filter(|&i| cands[i].live).collect();
    let saved: Vec<usize> = (0..cands.len()).filter(|&i| !cands[i].live).collect();
    let all: Vec<usize> = (0..cands.len()).collect();
    let mut note = None;
    let mut outcome_override = None;

    let picked: Option<Hits> = match scope {
        Scope::All => stage_hits(query, cands, &all),
        Scope::Live | Scope::Auto => match stage_hits(query, cands, &live) {
            Some(h) => {
                if let Some((_, s)) = stage_hits(query, cands, &saved) {
                    note = Some(format!("{} saved (not live) session(s) also match; add --all to see them", s.len()));
                }
                Some(h)
            }
            None => {
                let s = stage_hits(query, cands, &saved);
                if s.is_some() {
                    if scope == Scope::Live {
                        outcome_override = Some(Outcome::NotLive);
                        note = Some("no LIVE session matches; these saved sessions do (resume one first)".into());
                    } else {
                        note = Some("no live session matches; showing saved sessions".into());
                    }
                }
                s
            }
        },
    };

    let mut res = Resolution { query: query.to_string(), scope, outcome: Outcome::NoMatch, matches: vec![], how: "", tier: None, candidates: vec![], note };
    match picked {
        None => {
            res.candidates = closest(query, cands, scope);
        }
        Some((how, hits)) => {
            let (mut kept, tier, dropped) = strictest(hits);
            order(cands, &mut kept);
            if dropped > 0 {
                let extra = format!("{} looser match(es) set aside for {} ones", dropped, tier.map(Tier::as_str).unwrap_or(""));
                res.note = Some(match res.note.take() {
                    Some(n) => format!("{}; {}", n, extra),
                    None => extra,
                });
            }
            res.how = how;
            res.tier = tier;
            res.outcome = outcome_override.unwrap_or(if kept.len() == 1 { Outcome::Match } else { Outcome::Ambiguous });
            res.matches = kept;
        }
    }
    res
}

/// Levenshtein distance over chars.
pub fn edit_distance(a: &str, b: &str) -> usize {
    let a: Vec<char> = a.chars().collect();
    let b: Vec<char> = b.chars().collect();
    let mut prev: Vec<usize> = (0..=b.len()).collect();
    for (i, ca) in a.iter().enumerate() {
        let mut cur = vec![i + 1; b.len() + 1];
        for (j, cb) in b.iter().enumerate() {
            cur[j + 1] = (prev[j] + usize::from(ca != cb)).min(prev[j + 1] + 1).min(cur[j] + 1);
        }
        prev = cur;
    }
    prev[b.len()]
}

fn term_score(term: &str, keys: &[String]) -> Option<usize> {
    let t = loose(term);
    if t.is_empty() {
        return None;
    }
    keys.iter()
        .filter_map(|k| {
            let k = loose(k);
            if k.is_empty() {
                None
            } else if k == t {
                Some(0)
            } else if k.starts_with(&t) || t.starts_with(&k) {
                Some(1)
            } else if t.len() >= 2 && (k.contains(&t) || t.contains(&k)) {
                Some(2)
            } else {
                let d = edit_distance(&t, &k);
                (d <= (t.len().max(k.len()) / 3).max(1)).then_some(2 + d)
            }
        })
        .min()
}

/// Sessions closest to QUERY, for a miss: by prefix, substring and edit
/// distance over tags, buffer segments and review PRs, and by id prefix.
pub fn closest(query: &str, cands: &[Cand], scope: Scope) -> Vec<usize> {
    let ts = terms(query);
    let ql = query.trim().to_lowercase();
    let mut scored: Vec<(usize, usize)> = (0..cands.len())
        .filter(|&i| {
            let c = &cands[i];
            (c.live || scope != Scope::Live) && (c.live || !c.tags.is_empty() || c.buffer.is_some())
        })
        .filter_map(|i| {
            let c = &cands[i];
            if looks_hex_id(&ql) && ql.len() >= 4 {
                let common = c.id.chars().zip(ql.chars()).take_while(|(a, b)| a == b).count();
                if common >= 4 {
                    return Some((i, ql.len() - common.min(ql.len())));
                }
            }
            let keys = c.keys();
            let per: Vec<Option<usize>> = ts.iter().map(|t| term_score(t, &keys)).collect();
            if per.iter().all(Option::is_none) {
                return None;
            }
            Some((i, per.iter().map(|s| s.unwrap_or(10)).sum()))
        })
        .collect();
    scored.sort_by(|a, b| {
        a.1.cmp(&b.1).then(cands[b.0].live.cmp(&cands[a.0].live)).then(cands[b.0].last_activity.cmp(&cands[a.0].last_activity))
    });
    scored.into_iter().take(MAX_CANDIDATES).map(|(i, _)| i).collect()
}

// ---------------------------------------------------------------------------
// Loading candidates
// ---------------------------------------------------------------------------

fn now_secs() -> i64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0)
}

fn secs_of(t: SystemTime) -> Option<i64> {
    t.duration_since(UNIX_EPOCH).ok().map(|d| d.as_secs() as i64)
}

fn str_field(v: &Value, k: &str) -> Option<String> {
    v.get(k).and_then(Value::as_str).filter(|s| !s.is_empty()).map(str::to_string)
}

/// Merge the live exports, the tag store and the on-disk transcripts into
/// one candidate per session id. Pure, for tests.
pub fn merge(
    exports: &[Value],
    store: &HashMap<String, session::StoreSession>,
    transcripts: &[(String, &'static str, SystemTime, PathBuf)],
) -> Vec<Cand> {
    let mut by_id: HashMap<String, Cand> = HashMap::new();
    for v in exports {
        let Some(id) = str_field(v, "id") else { continue };
        let stale = v.get("stale").and_then(Value::as_bool).unwrap_or(true);
        let state = str_field(v, "state").unwrap_or_else(|| "unknown".into());
        let live = !stale && state != "dead";
        by_id.insert(
            id.clone(),
            Cand {
                id,
                live,
                state: if stale { format!("{} (stale)", state) } else { state },
                buffer: str_field(v, "buffer"),
                workspace: str_field(v, "cwd"),
                agent: str_field(v, "agent"),
                last_activity: v.get("last_activity").and_then(Value::as_i64),
                tags: v
                    .get("tags")
                    .and_then(Value::as_array)
                    .map(|a| a.iter().filter_map(|t| t.as_str().map(str::to_string)).collect())
                    .unwrap_or_default(),
                export: Some(v.clone()),
                ..Default::default()
            },
        );
    }
    for (id, s) in store {
        let c = by_id.entry(id.clone()).or_insert_with(|| Cand { id: id.clone(), state: "saved".into(), ..Default::default() });
        if c.tags.is_empty() {
            c.tags = s.tags.clone();
        }
        c.review_prs = s.review_prs.clone();
        if c.workspace.is_none() {
            c.workspace = s.workspace.clone();
        }
        let at = s.last_accessed.as_deref().and_then(|a| chrono::DateTime::parse_from_rfc3339(a).ok()).map(|d| d.timestamp());
        c.last_activity = c.last_activity.max(at);
    }
    for (id, agent, mtime, path) in transcripts {
        let c = by_id.entry(id.clone()).or_insert_with(|| Cand { id: id.clone(), state: "saved".into(), ..Default::default() });
        if c.agent.is_none() {
            c.agent = Some(agent.to_string());
        }
        if c.transcript.is_none() {
            c.transcript = Some(path.clone());
        }
        if c.export.is_none() {
            c.last_activity = c.last_activity.max(secs_of(*mtime));
        }
    }
    let mut out: Vec<Cand> = by_id.into_values().collect();
    out.sort_by(|a, b| a.id.cmp(&b.id));
    out
}

pub struct Loaded {
    pub cands: Vec<Cand>,
    pub live: session_msg::Live,
}

impl Loaded {
    /// Why nothing can be live right now, when that is the case.
    pub fn heartbeat_note(&self) -> Option<String> {
        match &self.live.heartbeat {
            None => Some("no Emacs heartbeat: live state is unavailable (is decknix-agent-session-export-mode on?), so every session reads as saved".into()),
            Some(_) if !self.live.fresh => Some("Emacs heartbeat is stale: live state is unavailable, so every session reads as saved".into()),
            _ => None,
        }
    }
}

pub fn load(dirs: &Dirs) -> Result<Loaded> {
    let live = session_msg::load_live(dirs, now_secs())?;
    let store = session::load_store(&dirs.store).unwrap_or_else(|_| json!({}));
    let cands = merge(&live.sessions, &session::session_index(&store), &session::transcript_index());
    Ok(Loaded { cands, live })
}

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------

fn self_id() -> Option<String> {
    std::env::var("DECKNIX_SESSION_ID").ok().or_else(|| std::env::var("CLAUDE_CODE_SESSION_ID").ok()).filter(|s| !s.is_empty())
}

fn ago(secs: Option<i64>) -> String {
    match secs {
        None => "-".into(),
        Some(s) if s < 90 => format!("{}s", s),
        Some(s) if s < 5400 => format!("{}m", s / 60),
        Some(s) if s < 172800 => format!("{}h", s / 3600),
        Some(s) => format!("{}d", s / 86400),
    }
}

fn short(id: &str) -> &str {
    id.get(..8).unwrap_or(id)
}

fn tilde(p: &str) -> String {
    match dirs::home_dir().map(|h| h.to_string_lossy().to_string()) {
        Some(h) if p.starts_with(&h) => format!("~{}", &p[h.len()..]),
        _ => p.to_string(),
    }
}

fn filled_workspace(c: &Cand) -> Option<String> {
    c.workspace.clone().or_else(|| {
        let p = c.transcript.as_ref()?;
        session::transcript_workspace(c.agent.as_deref()?, p)
    })
}

pub fn cand_json(c: &Cand, now: i64) -> Value {
    json!({
        "id": c.id,
        "short": short(&c.id),
        "live": c.live,
        "state": c.state,
        "buffer": c.buffer,
        "tags": c.tags,
        "review_prs": c.review_prs,
        "workspace": filled_workspace(c),
        "agent": c.agent,
        "last_activity": c.last_activity,
        "quiet_for": c.last_activity.map(|t| (now - t).max(0)),
        "transcript": c.transcript.as_ref().map(|p| p.to_string_lossy().into_owned()),
        "self": self_id().as_deref() == Some(c.id.as_str()),
    })
}

pub fn cand_line(c: &Cand, now: i64) -> String {
    let me = if self_id().as_deref() == Some(c.id.as_str()) { "  (you)" } else { "" };
    let tags = if c.tags.is_empty() { String::new() } else { format!("  [{}]", c.tags.join(",")) };
    format!(
        "{:<8}  {:<6}  {:<18}  {:>4}  {}{}  {}{}",
        short(&c.id),
        c.agent.as_deref().unwrap_or("-"),
        c.state,
        ago(c.last_activity.map(|t| (now - t).max(0))),
        c.buffer.as_deref().unwrap_or("-"),
        tags,
        filled_workspace(c).map(|w| tilde(&w)).unwrap_or_default(),
        me,
    )
}

pub fn resolution_json(r: &Resolution, cands: &[Cand], now: i64) -> Value {
    json!({
        "query": r.query,
        "scope": match r.scope { Scope::Live => "live", Scope::Auto => "auto", Scope::All => "all" },
        "result": match r.outcome { Outcome::Match => "match", Outcome::Ambiguous => "ambiguous", Outcome::NoMatch => "none", Outcome::NotLive => "not-live" },
        "matched_by": if r.how.is_empty() { Value::Null } else { json!(r.how) },
        "tier": r.tier.map(Tier::as_str),
        "note": r.note,
        "matches": r.matches.iter().map(|&i| cand_json(&cands[i], now)).collect::<Vec<_>>(),
        "candidates": r.candidates.iter().map(|&i| cand_json(&cands[i], now)).collect::<Vec<_>>(),
    })
}

fn scope_word(s: Scope) -> &'static str {
    match s {
        Scope::Live => "live session",
        Scope::Auto => "session",
        Scope::All => "live or saved session",
    }
}

/// Human report of a miss, a tie or a saved-only match, for stderr.
pub fn explain(r: &Resolution, cands: &[Cand], now: i64) -> String {
    let mut out = Vec::new();
    match r.outcome {
        Outcome::Match => {}
        Outcome::NoMatch => {
            out.push(format!("no {} matches {:?}", scope_word(r.scope), r.query));
            if r.candidates.is_empty() {
                out.push("nothing close either".into());
            } else {
                out.push("closest:".into());
                out.extend(r.candidates.iter().map(|&i| format!("  {}", cand_line(&cands[i], now))));
            }
        }
        Outcome::Ambiguous => {
            out.push(format!(
                "{:?} matches {} sessions (by {}); pass an id, or add a tag to narrow (e.g. `{},<tag>`):",
                r.query,
                r.matches.len(),
                r.how,
                r.query.trim()
            ));
            out.extend(r.matches.iter().map(|&i| format!("  {}", cand_line(&cands[i], now))));
        }
        Outcome::NotLive => {
            out.push(format!("{:?} matches no live session, only saved ones:", r.query));
            out.extend(r.matches.iter().map(|&i| format!("  {}", cand_line(&cands[i], now))));
            out.push("resume one (decknix session resume <id>) or open it in Emacs first".into());
        }
    }
    if let Some(n) = &r.note {
        out.push(format!("note: {}", n));
    }
    if r.outcome != Outcome::Match {
        out.push("vocabulary: decknix session tags --live   discovery: decknix session find <query> --all".into());
    }
    out.join("\n")
}

pub fn exit_code(o: &Outcome) -> i32 {
    match o {
        Outcome::Match => 0,
        Outcome::Ambiguous => EXIT_AMBIGUOUS,
        Outcome::NoMatch => EXIT_NO_MATCH,
        Outcome::NotLive => EXIT_NOT_LIVE,
    }
}

/// Resolve TARGET to exactly one LIVE session for `status` and `send`.
/// On failure prints the report (JSON on stdout with JSON_OUT) and returns
/// the exit code.
pub fn resolve_live(target: &str, loaded: &Loaded, json_out: bool) -> Result<std::result::Result<Value, i32>> {
    let now = now_secs();
    let r = resolve(target, &loaded.cands, Scope::Live);
    if r.outcome == Outcome::Match {
        let c = &loaded.cands[r.matches[0]];
        if let Some(n) = &r.note {
            eprintln!("note: {}", n);
        }
        return Ok(Ok(c.export.clone().ok_or_else(|| anyhow!("{} has no live state", c.id))?));
    }
    if json_out {
        let mut v = resolution_json(&r, &loaded.cands, now);
        v["heartbeat"] = json!(loaded.heartbeat_note());
        println!("{}", serde_json::to_string_pretty(&v)?);
    } else {
        eprintln!("{}", explain(&r, &loaded.cands, now));
        if let Some(n) = loaded.heartbeat_note() {
            eprintln!("note: {}", n);
        }
    }
    Ok(Err(exit_code(&r.outcome)))
}

/// Resolve QUERY to one session id among live AND saved sessions, for
/// commands that act on a transcript (`resume`, `tag`). Errors carry the
/// same report `find` prints.
pub fn resolve_saved_id(query: &str) -> Result<String> {
    let dirs = Dirs::resolve()?;
    let loaded = load(&dirs)?;
    let now = now_secs();
    let r = resolve(query, &loaded.cands, Scope::All);
    match r.outcome {
        Outcome::Match => Ok(loaded.cands[r.matches[0]].id.clone()),
        _ => Err(anyhow!("{}", explain(&r, &loaded.cands, now))),
    }
}

// ---------------------------------------------------------------------------
// Commands
// ---------------------------------------------------------------------------

/// `decknix session find <query...>`: every session matching, live first.
pub fn cmd_find(query: Vec<String>, live_only: bool, all: bool, id_only: bool, json_out: bool) -> Result<i32> {
    let q = query.join(",");
    let scope = if live_only { Scope::Live } else if all { Scope::All } else { Scope::Auto };
    let dirs = Dirs::resolve()?;
    let loaded = load(&dirs)?;
    let now = now_secs();
    let r = resolve(&q, &loaded.cands, scope);
    let code = match (&r.outcome, id_only) {
        (Outcome::Match, _) => 0,
        (Outcome::Ambiguous, false) => 0,
        (o, _) => exit_code(o),
    };
    if json_out {
        let mut v = resolution_json(&r, &loaded.cands, now);
        v["heartbeat"] = json!(loaded.heartbeat_note());
        println!("{}", serde_json::to_string_pretty(&v)?);
        return Ok(code);
    }
    if let Some(n) = loaded.heartbeat_note() {
        eprintln!("note: {}", n);
    }
    if id_only {
        if code == 0 {
            println!("{}", loaded.cands[r.matches[0]].id);
            if let Some(n) = &r.note {
                eprintln!("note: {}", n);
            }
        } else {
            eprintln!("{}", explain(&r, &loaded.cands, now));
        }
        return Ok(code);
    }
    match r.outcome {
        Outcome::Match | Outcome::Ambiguous => {
            for &i in &r.matches {
                println!("{}", cand_line(&loaded.cands[i], now));
            }
            let mut tail = format!("{} match(es) by {}", r.matches.len(), r.how);
            if let Some(t) = r.tier.filter(|t| *t != Tier::Exact) {
                tail.push_str(&format!(" ({})", t.as_str()));
            }
            eprintln!("{}", tail);
            if let Some(n) = &r.note {
                eprintln!("note: {}", n);
            }
        }
        _ => eprintln!("{}", explain(&r, &loaded.cands, now)),
    }
    Ok(code)
}

#[derive(Debug, Default)]
pub struct TagRow {
    pub tag: String,
    pub sessions: Vec<usize>,
    pub live: usize,
    /// Other spellings that normalise to the same tag.
    pub variants: Vec<String>,
}

/// Every tag with the sessions carrying it, grouped by normalised form so
/// `PLAT-1342` and `plat-1342` show up as one row with a variant. Pure.
pub fn tag_rows(cands: &[Cand], live_only: bool) -> Vec<TagRow> {
    let mut groups: HashMap<String, TagRow> = HashMap::new();
    let mut spellings: HashMap<String, HashMap<String, usize>> = HashMap::new();
    for (i, c) in cands.iter().enumerate() {
        if live_only && !c.live {
            continue;
        }
        for t in &c.tags {
            let k = loose(t);
            if k.is_empty() {
                continue;
            }
            let row = groups.entry(k.clone()).or_default();
            if !row.sessions.contains(&i) {
                row.sessions.push(i);
                if c.live {
                    row.live += 1;
                }
            }
            *spellings.entry(k).or_default().entry(t.clone()).or_insert(0) += 1;
        }
    }
    let mut rows: Vec<TagRow> = groups
        .into_iter()
        .map(|(k, mut row)| {
            let mut sp: Vec<(String, usize)> = spellings.remove(&k).unwrap_or_default().into_iter().collect();
            sp.sort_by(|a, b| b.1.cmp(&a.1).then(a.0.cmp(&b.0)));
            row.tag = sp[0].0.clone();
            row.variants = sp.into_iter().skip(1).map(|(s, _)| s).collect();
            order(cands, &mut row.sessions);
            row
        })
        .collect();
    rows.sort_by(|a, b| b.live.cmp(&a.live).then(b.sessions.len().cmp(&a.sessions.len())).then(a.tag.cmp(&b.tag)));
    rows
}

/// `decknix session tags [--live]`: the tag vocabulary with its sessions.
pub fn cmd_tags(live_only: bool, json_out: bool) -> Result<i32> {
    let dirs = Dirs::resolve()?;
    let loaded = load(&dirs)?;
    let now = now_secs();
    let rows = tag_rows(&loaded.cands, live_only);
    if json_out {
        let arr: Vec<Value> = rows
            .iter()
            .map(|r| {
                json!({
                    "tag": r.tag,
                    "variants": r.variants,
                    "count": r.sessions.len(),
                    "live": r.live,
                    "sessions": r.sessions.iter().map(|&i| {
                        let c = &loaded.cands[i];
                        json!({"id": c.id, "live": c.live, "state": c.state, "buffer": c.buffer})
                    }).collect::<Vec<_>>(),
                })
            })
            .collect();
        println!("{}", serde_json::to_string_pretty(&arr)?);
        return Ok(0);
    }
    if rows.is_empty() {
        eprintln!("{}", if live_only { "no live session carries a tag" } else { "no tags recorded" });
        return Ok(0);
    }
    for r in &rows {
        let ids: Vec<String> = r
            .sessions
            .iter()
            .take(4)
            .map(|&i| {
                let c = &loaded.cands[i];
                if c.live { format!("{}*", short(&c.id)) } else { short(&c.id).to_string() }
            })
            .collect();
        let more = if r.sessions.len() > 4 { format!(" +{}", r.sessions.len() - 4) } else { String::new() };
        let variants = if r.variants.is_empty() { String::new() } else { format!("  (also: {})", r.variants.join(", ")) };
        println!("{:>4} {:>4}  {:<28}  {}{}{}", r.sessions.len(), r.live, r.tag, ids.join(" "), more, variants);
    }
    let _ = now;
    eprintln!("columns: sessions, live, tag, ids (* = live)");
    Ok(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    const A: &str = "aaaaaaaa-1111-4222-8333-444444444444";
    const B: &str = "bbbbbbbb-1111-4222-8333-444444444444";
    const C: &str = "cccccccc-1111-4222-8333-444444444444";
    const D: &str = "abcdef12-1111-4222-8333-444444444444";

    fn live(id: &str, buffer: &str, tags: &[&str], at: i64) -> Cand {
        Cand {
            id: id.into(),
            live: true,
            state: "idle".into(),
            buffer: Some(buffer.into()),
            tags: tags.iter().map(|s| s.to_string()).collect(),
            workspace: Some("/tmp/ws-one".into()),
            last_activity: Some(at),
            export: Some(json!({"id": id, "buffer": buffer})),
            ..Default::default()
        }
    }

    fn saved(id: &str, tags: &[&str], at: i64) -> Cand {
        Cand { id: id.into(), state: "saved".into(), tags: tags.iter().map(|s| s.to_string()).collect(), last_activity: Some(at), ..Default::default() }
    }

    fn ids(r: &Resolution, cands: &[Cand]) -> Vec<String> {
        r.matches.iter().map(|&i| cands[i].id.clone()).collect()
    }

    fn fixture() -> Vec<Cand> {
        vec![
            live(A, "*Claude: lane-04/PLAT-1342/us*", &["lane-04", "PLAT-1342", "us"], 300),
            live(B, "*Claude: lane-05/PLAT-1400*", &["lane-05", "PLAT-1400", "us"], 200),
            saved(C, &["lane-09", "#1014", "review"], 100),
            saved(D, &["lane-04", "PLAT-1342"], 50),
        ]
    }

    #[test]
    fn normalisation() {
        assert_eq!(fold("  #PLAT-1342 "), "plat-1342");
        assert_eq!(fold("\u{201C}Lane-04\u{201D}"), "lane-04");
        assert_eq!(loose("Lane_04"), "lane4");
        assert_eq!(loose("lane-4"), "lane4");
        assert_eq!(loose("lane 04"), "lane4");
        assert_eq!(loose("#1014"), "1014");
        assert_eq!(loose("v1.0"), "v10");
        assert_eq!(loose("0"), "0");
        assert_eq!(loose("x-00"), "x0");
        assert_eq!(buffer_core("*Claude: lane-04/PLAT-1342*<2>"), "lane-04/PLAT-1342");
        assert_eq!(buffer_core("*Pi: my tag*"), "my tag");
        assert_eq!(buffer_core("lane-04/PLAT-1342"), "lane-04/PLAT-1342");
        assert_eq!(terms("*Claude: lane-04/PLAT-1342*"), vec!["lane-04", "PLAT-1342"]);
        assert_eq!(terms("lane-04, plat-1342"), vec!["lane-04", "plat-1342"]);
        assert_eq!(terms("lane-04+plat-1342"), vec!["lane-04", "plat-1342"]);
    }

    #[test]
    fn full_id_and_prefix() {
        let c = fixture();
        let r = resolve(A, &c, Scope::Live);
        assert_eq!((r.outcome.clone(), r.how), (Outcome::Match, "id"));
        assert_eq!(ids(&r, &c), vec![A]);
        let r = resolve(&A.to_uppercase(), &c, Scope::Live);
        assert_eq!(ids(&r, &c), vec![A]);
        let r = resolve("bbbbbb", &c, Scope::Live);
        assert_eq!((ids(&r, &c), r.how), (vec![B.to_string()], "id-prefix"));
        let r = resolve("abcdef", &c, Scope::All);
        assert_eq!(ids(&r, &c), vec![D]);
        let r = resolve("abcde", &c, Scope::All);
        assert_ne!(r.how, "id-prefix", "5 characters is too short to be an id prefix");
    }

    #[test]
    fn buffer_name_and_its_tag_path() {
        let c = fixture();
        for q in ["*Claude: lane-04/PLAT-1342/us*", "lane-04/PLAT-1342/us", "*claude: LANE-04/plat-1342/us*", "Claude: lane-04/PLAT-1342/us"] {
            let r = resolve(q, &c, Scope::Live);
            assert_eq!(ids(&r, &c), vec![A], "{}", q);
            assert_eq!(r.how, "buffer", "{}", q);
        }
    }

    #[test]
    fn tags_exact_case_loose_and_and() {
        let c = fixture();
        let r = resolve("PLAT-1342", &c, Scope::Live);
        assert_eq!((ids(&r, &c), r.tier), (vec![A.to_string()], Some(Tier::Exact)));
        let r = resolve("plat-1342", &c, Scope::Live);
        assert_eq!((ids(&r, &c), r.tier), (vec![A.to_string()], Some(Tier::Case)));
        let r = resolve("lane4", &c, Scope::Live);
        assert_eq!((ids(&r, &c), r.tier), (vec![A.to_string()], Some(Tier::Loose)));
        let r = resolve("Lane_04", &c, Scope::Live);
        assert_eq!(ids(&r, &c), vec![A]);
        let r = resolve("us,plat-1400", &c, Scope::Live);
        assert_eq!(ids(&r, &c), vec![B]);
        let r = resolve("lane-04/PLAT-1342", &c, Scope::Live);
        assert_eq!((ids(&r, &c), r.how), (vec![A.to_string()], "tags"));
        let r = resolve("lane-04 us", &c, Scope::Live);
        assert_eq!(ids(&r, &c), vec![A]);
    }

    #[test]
    fn strictest_tier_wins_and_says_so() {
        let mut c = fixture();
        c[1].tags.push("plat-1342".into());
        let r = resolve("plat-1342", &c, Scope::Live);
        assert_eq!(ids(&r, &c), vec![B]);
        assert_eq!(r.outcome, Outcome::Match);
        assert!(r.note.as_deref().unwrap_or("").contains("looser"), "{:?}", r.note);
    }

    #[test]
    fn ambiguity_lists_every_match_live_first_then_recent() {
        let c = fixture();
        let r = resolve("us", &c, Scope::Live);
        assert_eq!(r.outcome, Outcome::Ambiguous);
        assert_eq!(ids(&r, &c), vec![A, B]);
        let text = explain(&r, &c, 400);
        assert!(text.contains("matches 2 sessions") && text.contains("aaaaaaaa") && text.contains("bbbbbbbb"), "{}", text);
        assert_eq!(exit_code(&r.outcome), EXIT_AMBIGUOUS);
    }

    #[test]
    fn live_preferred_saved_on_request_or_fallback() {
        let c = fixture();
        let r = resolve("lane-04,PLAT-1342", &c, Scope::Auto);
        assert_eq!(ids(&r, &c), vec![A]);
        assert!(r.note.as_deref().unwrap_or("").contains("saved"), "{:?}", r.note);
        let r = resolve("lane-04,PLAT-1342", &c, Scope::All);
        assert_eq!(ids(&r, &c), vec![A, D]);
        let r = resolve("lane-09", &c, Scope::Auto);
        assert_eq!((r.outcome.clone(), ids(&r, &c)), (Outcome::Match, vec![C.to_string()]));
        assert!(r.note.as_deref().unwrap_or("").contains("no live session"));
        let r = resolve("lane-09", &c, Scope::Live);
        assert_eq!(r.outcome, Outcome::NotLive);
        assert_eq!(exit_code(&r.outcome), EXIT_NOT_LIVE);
        let r = resolve("1014", &c, Scope::Auto);
        assert_eq!(ids(&r, &c), vec![C], "a PR tag matches without its #");
    }

    #[test]
    fn workspace_path() {
        let mut c = fixture();
        c[1].workspace = Some("/tmp/ws-one/sub".into());
        let r = resolve("/tmp/ws-one", &c, Scope::Live);
        assert_eq!(ids(&r, &c), vec![A], "exact workspace is stricter than a subdirectory");
        let r = resolve("/tmp/ws-one/sub", &c, Scope::Live);
        assert_eq!(ids(&r, &c), vec![B]);
    }

    #[test]
    fn review_pr_matches() {
        let mut c = fixture();
        c[2].review_prs = vec!["example-repo#1014".into()];
        let r = resolve("example-repo#1014", &c, Scope::Auto);
        assert_eq!(ids(&r, &c), vec![C]);
    }

    #[test]
    fn miss_offers_closest_candidates() {
        let c = fixture();
        let r = resolve("lane-4x", &c, Scope::Live);
        assert_eq!(r.outcome, Outcome::NoMatch);
        assert_eq!(r.candidates.first().map(|&i| c[i].id.as_str()), Some(A));
        let r = resolve("plat-134", &c, Scope::Live);
        assert_eq!(r.candidates.first().map(|&i| c[i].id.as_str()), Some(A), "prefix of a tag");
        let r = resolve("lane-09x", &c, Scope::All);
        assert_eq!(r.candidates.first().map(|&i| c[i].id.as_str()), Some(C));
        let r = resolve("lane-09x", &c, Scope::Live);
        assert!(r.candidates.iter().all(|&i| c[i].live), "live scope suggests only live sessions");
        let text = explain(&resolve("zzzzqqq", &c, Scope::Live), &c, 400);
        assert!(text.contains("no live session matches") && text.contains("nothing close"), "{}", text);
        assert_eq!(edit_distance("lane-04", "lane-05"), 1);
        assert_eq!(edit_distance("", "abc"), 3);
    }

    #[test]
    fn json_shape() {
        let c = fixture();
        let v = resolution_json(&resolve("us", &c, Scope::Live), &c, 400);
        assert_eq!(v["result"], json!("ambiguous"));
        assert_eq!(v["scope"], json!("live"));
        assert_eq!(v["matched_by"], json!("tags"));
        let m = &v["matches"][0];
        for k in ["id", "short", "live", "state", "buffer", "tags", "review_prs", "workspace", "agent", "last_activity", "quiet_for", "transcript", "self"] {
            assert!(m.get(k).is_some(), "missing {}", k);
        }
        assert_eq!(m["quiet_for"], json!(100));
        let v = resolution_json(&resolve("nope-nope", &c, Scope::Live), &c, 400);
        assert_eq!(v["result"], json!("none"));
        assert!(v["matches"].as_array().unwrap().is_empty());
    }

    #[test]
    fn merge_combines_exports_store_and_transcripts() {
        let exports = vec![
            json!({"id": A, "buffer": "*Claude: lane-04*", "state": "working", "stale": false, "cwd": "/w", "last_activity": 10}),
            json!({"id": B, "buffer": "*Claude: gone*", "state": "dead", "stale": false}),
            json!({"id": C, "buffer": "*Claude: old*", "state": "idle", "stale": true, "tags": ["from-emacs"]}),
        ];
        let mut store = HashMap::new();
        store.insert(A.to_string(), session::StoreSession { tags: vec!["lane-04".into()], ..Default::default() });
        store.insert(C.to_string(), session::StoreSession { tags: vec!["from-store".into()], ..Default::default() });
        store.insert(D.to_string(), session::StoreSession { tags: vec!["x".into()], workspace: Some("/s".into()), last_accessed: Some("2026-01-01T00:00:00.000Z".into()), ..Default::default() });
        let pi = "eeeeeeee-1111-4222-8333-444444444444";
        let tr = vec![(pi.to_string(), "pi", UNIX_EPOCH, PathBuf::from("/p.jsonl"))];
        let m = merge(&exports, &store, &tr);
        let get = |id: &str| m.iter().find(|c| c.id == id).unwrap().clone();
        assert!(get(A).live && get(A).tags == vec!["lane-04"]);
        assert!(!get(B).live, "dead is not live");
        assert!(!get(C).live && get(C).state == "idle (stale)");
        assert_eq!(get(C).tags, vec!["from-emacs"], "exported tags win over the store's");
        assert_eq!((get(D).state.as_str(), get(D).workspace.as_deref()), ("saved", Some("/s")));
        assert_eq!(get(pi).agent.as_deref(), Some("pi"), "pi transcripts are candidates");
    }

    #[test]
    fn tag_rows_group_variants_and_count_live() {
        let mut c = fixture();
        c[3].tags = vec!["plat-1342".into()];
        let rows = tag_rows(&c, false);
        let hx = rows.iter().find(|r| loose(&r.tag) == "hx1342").unwrap();
        assert_eq!(hx.sessions.len(), 2);
        assert_eq!(hx.live, 1);
        assert_eq!(hx.variants.len(), 1);
        let us = rows.iter().find(|r| r.tag == "us").unwrap();
        assert_eq!((us.sessions.len(), us.live), (2, 2));
        assert!(tag_rows(&c, true).iter().all(|r| r.live == r.sessions.len()));
    }

    #[test]
    fn tag_filters_use_the_same_matching() {
        let tags: Vec<String> = vec!["lane-04".into(), "PLAT-1342".into()];
        assert!(tags_match(&["plat-1342".into()], &tags));
        assert!(tags_match(&["lane4,PLAT-1342".into()], &tags));
        assert!(tags_match(&["lane-04".into(), "#plat-1342".into()], &tags));
        assert!(!tags_match(&["lane-05".into()], &tags));
        let joined: Vec<String> = vec!["day4,dos,log".into()];
        assert!(tags_match(&["dos".into()], &joined), "a tag saved with commas still matches its parts");
    }
}
