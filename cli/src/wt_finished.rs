//! `decknix wt finished`: remove worktrees whose PR is merged or closed.
//!
//! The other cleanup verbs judge a worktree from git alone, and missed both
//! kinds of finished work.  Of 34 worktrees, 9 belonged to PRs already merged
//! or closed and every verb kept them:
//!
//! - review worktrees (`...-worktrees/pr-N`) sit on a detached HEAD, so there
//!   is no branch for `branch --merged` or an upstream-gone check to look at;
//! - a squash or rebase merge writes new commits, so the branch's own
//!   commits never appear in main, and the branch usually still exists on
//!   origin; a PR closed unmerged passes neither test.
//!
//! GitHub's PR state answers the question directly.  A finished worktree is
//! removed only when nothing would be lost: no uncommitted change, and HEAD
//! is the PR's head or an ancestor of it, so every local commit was in the
//! PR.  A worktree a live session is working in is kept.

use serde::Serialize;
use std::path::{Path, PathBuf};
use std::process::Command;

#[derive(Debug, Clone, PartialEq, Serialize)]
pub enum Kind {
    Review,
    Own,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Pr {
    pub number: u64,
    pub state: String,
    pub head_oid: Option<String>,
}

/// What the local checkout holds, as far as safety is concerned.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct Local {
    /// `git status --porcelain` lines, excluding agent-shell transcripts.
    pub changes: usize,
    /// Only agent-shell transcripts are untracked; removal needs --force.
    pub only_transcripts: bool,
    /// HEAD is the PR head or an ancestor of it.  None: could not tell.
    pub head_in_pr: Option<bool>,
    pub session_open: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(tag = "action", content = "reason", rename_all = "lowercase")]
pub enum Decision {
    Remove(String),
    Keep(String),
    Skip(String),
}

/// Decide what to do with one worktree.  Pure.
pub fn decide(kind: &Kind, pr: Option<&Pr>, local: &Local) -> Decision {
    let Some(pr) = pr else {
        return Decision::Skip("no PR found for it".into());
    };
    let finished = match pr.state.as_str() {
        "MERGED" => "merged",
        "CLOSED" => "closed",
        _ => return Decision::Skip(format!("#{} is still open", pr.number)),
    };
    let what = match kind {
        Kind::Review => format!("review of #{} ({finished})", pr.number),
        Kind::Own => format!("#{} {finished}", pr.number),
    };
    if local.session_open {
        return Decision::Keep(format!("{what}, but a session is open in it"));
    }
    if local.changes > 0 {
        return Decision::Keep(format!("{what}, but it has {} uncommitted change(s)", local.changes));
    }
    match local.head_in_pr {
        Some(true) => Decision::Remove(what),
        Some(false) => Decision::Keep(format!("{what}, but it has commits that were not in the PR")),
        None => Decision::Keep(format!("{what}, but its commits could not be checked against the PR")),
    }
}

/// The PR number a review worktree's directory names (`pr-N`), if any.
pub fn review_number(path: &Path) -> Option<u64> {
    path.file_name()?.to_str()?.strip_prefix("pr-")?.parse().ok()
}

/// Count `git status --porcelain` lines, ignoring agent-shell transcripts.
pub fn count_changes(porcelain: &str) -> (usize, bool) {
    let lines: Vec<&str> = porcelain.lines().filter(|l| !l.trim().is_empty()).collect();
    let real = lines.iter().filter(|l| !l.contains(".agent-shell/")).count();
    (real, real == 0 && !lines.is_empty())
}

fn git(dir: &Path, args: &[&str]) -> Option<String> {
    let out = Command::new("git").args(args).current_dir(dir).output().ok()?;
    out.status.success().then(|| String::from_utf8_lossy(&out.stdout).into_owned())
}

fn gh_json(args: &[&str]) -> Option<serde_json::Value> {
    let out = Command::new("gh").args(args).output().ok()?;
    if !out.status.success() {
        return None;
    }
    serde_json::from_slice(&out.stdout).ok()
}

fn to_pr(v: &serde_json::Value) -> Option<Pr> {
    Some(Pr {
        number: v.get("number")?.as_u64()?,
        state: v.get("state")?.as_str()?.to_string(),
        head_oid: v.get("headRefOid").and_then(|x| x.as_str()).map(str::to_string),
    })
}

/// Look the worktree's PR up on GitHub: by number for a review worktree,
/// by head branch for one of my own.
fn lookup_pr(repo: &str, kind: &Kind, branch: &str, path: &Path) -> Option<Pr> {
    match kind {
        Kind::Review => {
            let n = review_number(path)?.to_string();
            to_pr(&gh_json(&["pr", "view", &n, "-R", repo, "--json", "number,state,headRefOid"])?)
        }
        Kind::Own => {
            let v = gh_json(&[
                "pr", "list", "-R", repo, "--head", branch, "--state", "all",
                "--json", "number,state,headRefOid", "--limit", "1",
            ])?;
            to_pr(v.as_array()?.first()?)
        }
    }
}

fn head_in_pr(path: &Path, pr: &Pr) -> Option<bool> {
    let head = git(path, &["rev-parse", "HEAD"])?.trim().to_string();
    let oid = pr.head_oid.as_deref()?;
    if head == oid {
        return Some(true);
    }
    let out = Command::new("git")
        .args(["merge-base", "--is-ancestor", &head, oid])
        .current_dir(path)
        .output()
        .ok()?;
    match out.status.code() {
        Some(0) => Some(true),
        Some(1) => Some(false),
        _ => None, // PR head not in this clone
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct Plan {
    pub repo: String,
    pub path: PathBuf,
    pub branch: String,
    pub kind: Kind,
    pub decision: Decision,
    #[serde(skip)]
    pub primary: PathBuf,
    #[serde(skip)]
    pub force: bool,
}

/// Build the plan for every worktree, looking PRs up in parallel.
pub fn plan(
    worktrees: Vec<(String, PathBuf, String, PathBuf)>,
    sessions: &std::collections::HashSet<PathBuf>,
) -> Vec<Plan> {
    let mut out = Vec::new();
    for chunk in worktrees.chunks(8) {
        let results: Vec<Plan> = std::thread::scope(|s| {
            let handles: Vec<_> = chunk
                .iter()
                .map(|(repo, primary, branch, path)| {
                    s.spawn(move || {
                        let kind = if review_number(path).is_some() { Kind::Review } else { Kind::Own };
                        let pr = lookup_pr(repo, &kind, branch, path);
                        let (changes, only_transcripts) =
                            count_changes(&git(path, &["status", "--porcelain"]).unwrap_or_default());
                        let local = Local {
                            changes,
                            only_transcripts,
                            head_in_pr: pr.as_ref().and_then(|p| head_in_pr(path, p)),
                            session_open: sessions.contains(path)
                                || sessions.contains(&PathBuf::from(path.to_string_lossy().trim_end_matches('/'))),
                        };
                        Plan {
                            repo: repo.clone(),
                            path: path.clone(),
                            branch: branch.clone(),
                            decision: decide(&kind, pr.as_ref(), &local),
                            kind,
                            primary: primary.clone(),
                            force: only_transcripts,
                        }
                    })
                })
                .collect();
            handles.into_iter().filter_map(|h| h.join().ok()).collect()
        });
        out.extend(results);
    }
    out
}

/// Remove one planned worktree, and for my own work its local branch.  The
/// branch on origin is kept, as the workspace rules ask.
pub fn remove(p: &Plan) -> Result<(), String> {
    let path = p.path.to_string_lossy().to_string();
    let mut args = vec!["worktree", "remove"];
    if p.force {
        args.push("--force");
    }
    args.push(&path);
    let out = Command::new("git").args(&args).current_dir(&p.primary).output()
        .map_err(|e| e.to_string())?;
    if !out.status.success() {
        return Err(String::from_utf8_lossy(&out.stderr).trim().to_string());
    }
    if p.kind == Kind::Own && !p.branch.is_empty() {
        let _ = Command::new("git").args(["branch", "-D", &p.branch]).current_dir(&p.primary).output();
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pr(state: &str) -> Pr {
        Pr { number: 81, state: state.into(), head_oid: Some("abc".into()) }
    }
    fn clean() -> Local {
        Local { head_in_pr: Some(true), ..Default::default() }
    }

    #[test]
    fn a_merged_review_worktree_is_removed() {
        // upside#20742: merged, detached at the PR head, nothing local.
        assert!(matches!(decide(&Kind::Review, Some(&pr("MERGED")), &clean()), Decision::Remove(_)));
    }

    #[test]
    fn a_squash_merged_or_closed_pr_of_mine_is_removed() {
        // The cases the git-only checks miss.
        assert!(matches!(decide(&Kind::Own, Some(&pr("MERGED")), &clean()), Decision::Remove(_)));
        assert!(matches!(decide(&Kind::Own, Some(&pr("CLOSED")), &clean()), Decision::Remove(_)));
    }

    #[test]
    fn an_open_pr_is_left_alone() {
        assert!(matches!(decide(&Kind::Own, Some(&pr("OPEN")), &clean()), Decision::Skip(_)));
    }

    #[test]
    fn no_pr_is_left_alone() {
        assert!(matches!(decide(&Kind::Own, None, &clean()), Decision::Skip(_)));
    }

    #[test]
    fn uncommitted_work_keeps_it() {
        let l = Local { changes: 2, ..clean() };
        assert_eq!(
            decide(&Kind::Own, Some(&pr("MERGED")), &l),
            Decision::Keep("#81 merged, but it has 2 uncommitted change(s)".into())
        );
    }

    #[test]
    fn commits_not_in_the_pr_keep_it() {
        let l = Local { head_in_pr: Some(false), ..clean() };
        assert!(matches!(decide(&Kind::Own, Some(&pr("MERGED")), &l), Decision::Keep(_)));
    }

    #[test]
    fn an_unverifiable_head_keeps_it() {
        let l = Local { head_in_pr: None, ..clean() };
        assert!(matches!(decide(&Kind::Own, Some(&pr("MERGED")), &l), Decision::Keep(_)));
    }

    #[test]
    fn an_open_session_keeps_it() {
        let l = Local { session_open: true, ..clean() };
        assert!(matches!(decide(&Kind::Review, Some(&pr("MERGED")), &l), Decision::Keep(_)));
    }

    #[test]
    fn transcripts_alone_are_not_changes() {
        // Every review worktree read dirty for agent-shell's own transcript.
        assert_eq!(count_changes("?? .agent-shell/transcripts/2026-09-04.md\n"), (0, true));
        assert_eq!(count_changes(" M src/a.kt\n?? .agent-shell/x.md\n"), (1, false));
        assert_eq!(count_changes(""), (0, false));
    }

    #[test]
    fn review_worktrees_are_recognised_by_directory() {
        assert_eq!(review_number(Path::new("/w/upside-worktrees/pr-20742")), Some(20742));
        assert_eq!(review_number(Path::new("/w/upside-worktrees/CONN-1006-x")), None);
        assert_eq!(review_number(Path::new("/w/upside-worktrees/pr-notanumber")), None);
    }
}
