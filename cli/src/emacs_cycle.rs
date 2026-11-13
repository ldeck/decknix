//! `decknix switch --restart-emacs`: switch, restart the Emacs daemon and
//! bring every window and agent session back without being asked.
//!
//! The command and the daemon talk only through files under the decknix
//! state dir, so no `emacsclient` call ever waits on work inside Emacs:
//!
//! 1. ask the running daemon to save (`decknix-layout-prepare-restart`
//!    returns at once and writes `switch-prepare.json` when the save is
//!    done); wait for that file here, with a timeout;
//! 2. run the switch; if it fails, stop: the daemon is left alone;
//! 3. write the one-shot `restart-restore` marker and restart the daemon
//!    with `launchctl kickstart -k`;
//! 4. wait until a daemon with a NEW pid answers on the server socket;
//! 5. open a GUI frame (`nix-open emacs`); its first frame consumes the
//!    marker and restores layout and sessions unprompted;
//! 6. wait for `restart-summary.json`, written once the broker reattach has
//!    settled, and report what came back and what did not.
//!
//! Every step is safe to rerun: a rerun with nothing switched and a daemon
//! already on the current config restarts nothing.

use std::fs;
use std::path::{Path, PathBuf};
use std::time::Duration;

pub const EMACS_LABEL: &str = "org.nixos.emacs-server";

/// The side effects the cycle needs, so the flow is testable without a
/// daemon, launchd or a GUI.
pub trait CycleEnv {
    /// Evaluate EXPR in the daemon, bounded by TIMEOUT.  None when it did
    /// not answer (not running, busy, or the call failed).
    fn eval(&mut self, expr: &str, timeout: Duration) -> Option<String>;
    /// `launchctl kickstart -k` the daemon.  False when launchd refused.
    fn kickstart(&mut self) -> bool;
    /// Open a GUI frame on the running daemon.
    fn open_frame(&mut self) -> bool;
    fn sleep(&mut self, d: Duration);
    /// Monotonic time since the env was made.
    fn elapsed(&self) -> Duration;
}

#[derive(Debug, Clone)]
pub struct CyclePaths {
    pub ready: PathBuf,
    pub marker: PathBuf,
    pub summary: PathBuf,
}

impl CyclePaths {
    pub fn in_dir(dir: &Path) -> Self {
        CyclePaths {
            ready: dir.join("switch-prepare.json"),
            marker: dir.join("restart-restore"),
            summary: dir.join("restart-summary.json"),
        }
    }
}

/// `$XDG_STATE_HOME/decknix`, else `~/.local/state/decknix`: the same dir
/// the Emacs side derives its marker and summary paths from.
pub fn state_dir() -> PathBuf {
    std::env::var_os("XDG_STATE_HOME")
        .map(PathBuf::from)
        .filter(|p| !p.as_os_str().is_empty())
        .unwrap_or_else(|| dirs::home_dir().unwrap_or_default().join(".local/state"))
        .join("decknix")
}

#[derive(Debug, Clone, Copy)]
pub struct CycleTimeouts {
    pub prepare: Duration,
    pub socket: Duration,
    pub summary: Duration,
    pub poll: Duration,
}

impl Default for CycleTimeouts {
    fn default() -> Self {
        CycleTimeouts {
            prepare: Duration::from_secs(15),
            socket: Duration::from_secs(180),
            summary: Duration::from_secs(120),
            poll: Duration::from_millis(500),
        }
    }
}

const EVAL_TIMEOUT: Duration = Duration::from_secs(5);
const PID_PROBE_TIMEOUT: Duration = Duration::from_secs(3);

/// Quote S as an Emacs Lisp string literal.
pub fn lisp_string(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for c in s.chars() {
        if c == '"' || c == '\\' {
            out.push('\\');
        }
        out.push(c);
    }
    out.push('"');
    out
}

/// The prepare request.  Returns at once inside Emacs.  A daemon from
/// before this command existed lacks `decknix-layout-prepare-restart`;
/// it still saves (from a timer) and writes the ready file, so the first
/// cycle after installing works too.
pub fn prepare_expr(ready: &Path) -> String {
    let p = lisp_string(&ready.to_string_lossy());
    format!(
        "(if (fboundp 'decknix-layout-prepare-restart) \
           (decknix-layout-prepare-restart {p}) \
           (run-with-timer 0 nil (lambda () \
             (when (fboundp 'decknix-layout-save) (decknix-layout-save t t)) \
             (with-temp-file {p} (insert \"{{\\\"saved\\\":true,\\\"legacy\\\":true}}\")))) \
           t)"
    )
}

fn parse_pid(reply: &str) -> Option<u32> {
    reply.trim().trim_matches('"').parse().ok()
}

fn wait_for_file<E: CycleEnv>(env: &mut E, path: &Path, timeout: Duration, poll: Duration) -> Option<String> {
    let start = env.elapsed();
    loop {
        if let Ok(s) = fs::read_to_string(path) {
            if !s.trim().is_empty() {
                return Some(s);
            }
        }
        if env.elapsed().saturating_sub(start) >= timeout {
            return None;
        }
        env.sleep(poll);
    }
}

#[derive(Debug, PartialEq)]
pub enum PrepareOutcome {
    /// The daemon saved; the payload is its one-line JSON report.
    Saved(String),
    /// No daemon answered, so there is nothing to save (the restart will
    /// still start one).
    NotRunning,
    /// It answered but did not finish in time.  `kill-emacs-hook` saves
    /// again on the restart's SIGTERM, so this is a warning, not a stop.
    TimedOut,
}

pub fn prepare<E: CycleEnv>(env: &mut E, paths: &CyclePaths, t: &CycleTimeouts) -> PrepareOutcome {
    let _ = fs::remove_file(&paths.ready);
    if let Some(parent) = paths.ready.parent() {
        let _ = fs::create_dir_all(parent);
    }
    if env.eval(&prepare_expr(&paths.ready), EVAL_TIMEOUT).is_none() {
        return PrepareOutcome::NotRunning;
    }
    match wait_for_file(env, &paths.ready, t.prepare, t.poll) {
        Some(s) => PrepareOutcome::Saved(s.trim().to_string()),
        None => PrepareOutcome::TimedOut,
    }
}

#[derive(Debug, PartialEq)]
pub enum CycleError {
    KickstartFailed,
    SocketTimeout(Duration),
}

impl std::fmt::Display for CycleError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            CycleError::KickstartFailed => write!(f, "launchctl kickstart of {EMACS_LABEL} failed"),
            CycleError::SocketTimeout(d) => write!(
                f,
                "the restarted Emacs daemon did not answer within {}s; it may still be starting \
                 (run `nix-open emacs`; the next frame restores automatically for 15 minutes)",
                d.as_secs()
            ),
        }
    }
}

impl std::error::Error for CycleError {}

#[derive(Debug, Default)]
pub struct RestartReport {
    pub old_pid: Option<u32>,
    pub new_pid: u32,
    pub frame_opened: bool,
    /// The daemon's own report, or None when it did not arrive in time.
    pub summary: Option<serde_json::Value>,
}

/// Steps 3 to 6.  The marker is written before the restart so the new
/// daemon's first frame cannot miss it, and removed again if launchd
/// refuses the restart so a later, unrelated start is not affected.
pub fn restart_and_restore<E: CycleEnv>(
    env: &mut E,
    paths: &CyclePaths,
    t: &CycleTimeouts,
) -> Result<RestartReport, CycleError> {
    let old_pid = env.eval("(emacs-pid)", PID_PROBE_TIMEOUT).and_then(|r| parse_pid(&r));
    if let Some(parent) = paths.marker.parent() {
        let _ = fs::create_dir_all(parent);
    }
    let _ = fs::remove_file(&paths.summary);
    let _ = fs::write(&paths.marker, format!("{}\n", std::process::id()));
    if !env.kickstart() {
        let _ = fs::remove_file(&paths.marker);
        return Err(CycleError::KickstartFailed);
    }
    let start = env.elapsed();
    let new_pid = loop {
        if let Some(pid) = env.eval("(emacs-pid)", PID_PROBE_TIMEOUT).and_then(|r| parse_pid(&r)) {
            if Some(pid) != old_pid {
                break pid;
            }
        }
        if env.elapsed().saturating_sub(start) >= t.socket {
            return Err(CycleError::SocketTimeout(t.socket));
        }
        env.sleep(t.poll);
    };
    let frame_opened = env.open_frame();
    let summary = wait_for_file(env, &paths.summary, t.summary, t.poll)
        .and_then(|s| serde_json::from_str(&s).ok());
    Ok(RestartReport { old_pid, new_pid, frame_opened, summary })
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum SwitchOutcome {
    UpToDate,
    Switched,
}

#[derive(Debug)]
pub enum CycleOutcome {
    /// Nothing switched and the daemon already runs the current config.
    NothingToRestart,
    Restarted(RestartReport),
}

/// The whole cycle.  SWITCH runs the system switch (an error stops the
/// cycle before anything is restarted); EMACS_STALE answers whether the
/// running daemon is behind the profile (None when it could not tell,
/// which restarts to be safe).
pub fn run_cycle<E, S, St>(
    env: &mut E,
    paths: &CyclePaths,
    t: &CycleTimeouts,
    switch: S,
    emacs_stale: St,
) -> anyhow::Result<CycleOutcome>
where
    E: CycleEnv,
    S: FnOnce(&mut E) -> anyhow::Result<SwitchOutcome>,
    St: FnOnce(&mut E) -> Option<bool>,
{
    match prepare(env, paths, t) {
        PrepareOutcome::Saved(report) => eprintln!("💾 Emacs layout saved: {}", describe_prepare(&report)),
        PrepareOutcome::NotRunning => eprintln!("ℹ️  No Emacs daemon answered; nothing to save."),
        PrepareOutcome::TimedOut => eprintln!(
            "⚠️  Emacs did not confirm the save within {}s; it saves again as it exits.",
            t.prepare.as_secs()
        ),
    }
    let outcome = switch(env)?;
    if outcome == SwitchOutcome::UpToDate && emacs_stale(env) == Some(false) {
        return Ok(CycleOutcome::NothingToRestart);
    }
    eprintln!("🔄 Restarting the Emacs daemon...");
    let report = restart_and_restore(env, paths, t)?;
    Ok(CycleOutcome::Restarted(report))
}

fn describe_prepare(report: &str) -> String {
    match serde_json::from_str::<serde_json::Value>(report) {
        Ok(v) => match (v.get("layout").and_then(|l| l.as_str()), v.get("legacy")) {
            (_, Some(_)) => "saved by the running (older) config".to_string(),
            (Some(layout), _) => layout.to_string(),
            _ => report.to_string(),
        },
        Err(_) => report.to_string(),
    }
}

fn plural(n: u64, word: &str) -> String {
    format!("{n} {word}{}", if n == 1 { "" } else { "s" })
}

/// Lines describing the daemon's restart summary.
pub fn format_summary(v: &serde_json::Value) -> Vec<String> {
    let num = |v: &serde_json::Value, k: &str| v.get(k).and_then(|x| x.as_u64()).unwrap_or(0);
    let mut out = Vec::new();
    match v.get("layout").and_then(|l| l.as_str()) {
        Some(layout) => out.push(format!("Restored {layout}.")),
        None => out.push("No recent saved layout to restore.".to_string()),
    }
    let sessions: Vec<&serde_json::Value> = v
        .get("sessions")
        .and_then(|s| s.as_array())
        .map(|a| a.iter().collect())
        .unwrap_or_default();
    let with_history = sessions.iter().filter(|s| s.get("historyTurns").and_then(|h| h.as_u64()).is_some()).count();
    let waiting = sessions.iter().filter(|s| s.get("permission").and_then(|p| p.as_bool()) == Some(true)).count();
    out.push(format!(
        "{} open: {} restored with history, {} waiting on a permission prompt.",
        plural(sessions.len() as u64, "session"),
        with_history,
        waiting
    ));
    for s in &sessions {
        let name = s.get("name").and_then(|n| n.as_str()).unwrap_or("?");
        let status = s.get("status").and_then(|n| n.as_str()).unwrap_or("unknown");
        let history = match s.get("historyTurns").and_then(|h| h.as_u64()) {
            Some(n) => format!(", {}", plural(n, "turn")),
            None => String::new(),
        };
        out.push(format!("  ✓ {name} ({status}{history})"));
    }
    if let Some(failed) = v.get("failed").and_then(|f| f.as_array()) {
        for f in failed {
            out.push(format!(
                "  ✗ {}: {}",
                f.get("name").and_then(|n| n.as_str()).unwrap_or("?"),
                f.get("reason").and_then(|n| n.as_str()).unwrap_or("unknown")
            ));
        }
    }
    if let Some(r) = v.get("reattach") {
        let mut skipped = Vec::new();
        if num(r, "noConversation") > 0 {
            skipped.push(format!("{} with no known conversation", num(r, "noConversation")));
        }
        if num(r, "noSessionId") > 0 {
            skipped.push(format!("{} with no session id", num(r, "noSessionId")));
        }
        if num(r, "dropped") > 0 {
            skipped.push(format!("{} whose agent had exited", num(r, "dropped")));
        }
        out.push(format!(
            "Brokers reattached at startup: {}{}.",
            num(r, "done"),
            if skipped.is_empty() { String::new() } else { format!("; not reattached: {}", skipped.join(", ")) }
        ));
    }
    out
}

/// The real environment: emacsclient on the `server` socket, launchd,
/// `nix-open`.
pub struct RealEnv {
    start: std::time::Instant,
}

impl RealEnv {
    pub fn new() -> Self {
        RealEnv { start: std::time::Instant::now() }
    }
}

impl CycleEnv for RealEnv {
    fn eval(&mut self, expr: &str, timeout: Duration) -> Option<String> {
        let out = std::process::Command::new("timeout")
            .arg(timeout.as_secs().max(1).to_string())
            .args(["emacsclient", "-s", "server", "-e", expr])
            .stderr(std::process::Stdio::null())
            .output()
            .ok()?;
        out.status.success().then(|| String::from_utf8_lossy(&out.stdout).trim().to_string())
    }

    fn kickstart(&mut self) -> bool {
        let uid = unsafe { libc::getuid() };
        std::process::Command::new("launchctl")
            .args(["kickstart", "-k", &format!("gui/{uid}/{EMACS_LABEL}")])
            .status()
            .map(|s| s.success())
            .unwrap_or(false)
    }

    fn open_frame(&mut self) -> bool {
        let ok = |c: &mut std::process::Command| c.status().map(|s| s.success()).unwrap_or(false);
        ok(std::process::Command::new("nix-open").arg("emacs"))
            || ok(std::process::Command::new("emacsclient").args(["-s", "server", "-c", "-n"]))
    }

    fn sleep(&mut self, d: Duration) {
        std::thread::sleep(d);
    }

    fn elapsed(&self) -> Duration {
        self.start.elapsed()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;
    use std::rc::Rc;

    /// A scripted daemon on a virtual clock.
    struct FakeEnv {
        now: Duration,
        pid: Option<u32>,
        /// After a kickstart the new daemon answers once this much time has passed.
        boot_time: Duration,
        restarted_at: Option<Duration>,
        new_pid: u32,
        kickstart_ok: bool,
        /// Files the fake daemon writes when asked to prepare / open a frame.
        on_prepare: Option<(PathBuf, String)>,
        on_frame: Option<(PathBuf, String)>,
        log: Rc<RefCell<Vec<String>>>,
        marker_seen_at_kickstart: Option<PathBuf>,
        marker_existed: bool,
    }

    impl FakeEnv {
        fn new(pid: Option<u32>) -> Self {
            FakeEnv {
                now: Duration::ZERO,
                pid,
                boot_time: Duration::from_secs(4),
                restarted_at: None,
                new_pid: 200,
                kickstart_ok: true,
                on_prepare: None,
                on_frame: None,
                log: Rc::new(RefCell::new(Vec::new())),
                marker_seen_at_kickstart: None,
                marker_existed: false,
            }
        }
        fn calls(&self) -> Vec<String> {
            self.log.borrow().clone()
        }
    }

    impl CycleEnv for FakeEnv {
        fn eval(&mut self, expr: &str, _t: Duration) -> Option<String> {
            if let Some(at) = self.restarted_at {
                if self.now < at + self.boot_time {
                    return None;
                }
                self.pid = Some(self.new_pid);
            }
            let pid = self.pid?;
            if expr.contains("prepare-restart") {
                self.log.borrow_mut().push("prepare".into());
                if let Some((p, c)) = &self.on_prepare {
                    fs::write(p, c).unwrap();
                }
                return Some("t".into());
            }
            Some(pid.to_string())
        }
        fn kickstart(&mut self) -> bool {
            self.log.borrow_mut().push("kickstart".into());
            if let Some(m) = &self.marker_seen_at_kickstart {
                self.marker_existed = m.exists();
            }
            if self.kickstart_ok {
                self.restarted_at = Some(self.now);
                self.pid = None;
            }
            self.kickstart_ok
        }
        fn open_frame(&mut self) -> bool {
            self.log.borrow_mut().push("frame".into());
            if let Some((p, c)) = &self.on_frame {
                fs::write(p, c).unwrap();
            }
            true
        }
        fn sleep(&mut self, d: Duration) {
            self.now += d;
        }
        fn elapsed(&self) -> Duration {
            self.now
        }
    }

    fn fast() -> CycleTimeouts {
        CycleTimeouts {
            prepare: Duration::from_secs(2),
            socket: Duration::from_secs(10),
            summary: Duration::from_secs(5),
            poll: Duration::from_millis(500),
        }
    }

    const SUMMARY: &str = r#"{"layout":"1 frame, 2 tabs, 2 sessions","resumed":2,"failed":[{"name":"*Claude: gone*","reason":"no session to resume"}],"sessions":[{"name":"*Claude: a*","status":"working","historyTurns":3,"permission":true}],"reattach":{"done":1,"noConversation":1,"noSessionId":0,"dropped":0}}"#;

    #[test]
    fn lisp_string_escapes_quotes_and_backslashes() {
        assert_eq!(lisp_string(r#"/a "b"\c"#), r#""/a \"b\"\\c""#);
    }

    #[test]
    fn prepare_expr_falls_back_for_an_older_daemon() {
        let e = prepare_expr(Path::new("/s/ready.json"));
        assert!(e.contains("(fboundp 'decknix-layout-prepare-restart)"));
        assert!(e.contains("(decknix-layout-save t t)"));
        assert!(e.contains("\"/s/ready.json\""));
    }

    #[test]
    fn prepare_waits_for_the_ready_file() {
        let dir = tempfile::tempdir().unwrap();
        let paths = CyclePaths::in_dir(dir.path());
        let mut env = FakeEnv::new(Some(100));
        env.on_prepare = Some((paths.ready.clone(), r#"{"saved":true,"layout":"x"}"#.into()));
        assert_eq!(prepare(&mut env, &paths, &fast()), PrepareOutcome::Saved(r#"{"saved":true,"layout":"x"}"#.into()));
    }

    #[test]
    fn prepare_without_a_daemon_or_a_reply() {
        let dir = tempfile::tempdir().unwrap();
        let paths = CyclePaths::in_dir(dir.path());
        assert_eq!(prepare(&mut FakeEnv::new(None), &paths, &fast()), PrepareOutcome::NotRunning);
        let mut silent = FakeEnv::new(Some(100));
        assert_eq!(prepare(&mut silent, &paths, &fast()), PrepareOutcome::TimedOut);
        assert!(silent.now >= fast().prepare, "waited the full timeout");
    }

    #[test]
    fn a_failed_switch_never_restarts_emacs() {
        let dir = tempfile::tempdir().unwrap();
        let paths = CyclePaths::in_dir(dir.path());
        let mut env = FakeEnv::new(Some(100));
        let r = run_cycle(&mut env, &paths, &fast(), |_| anyhow::bail!("darwin-rebuild failed"), |_| Some(true));
        assert!(r.is_err());
        assert!(!env.calls().contains(&"kickstart".to_string()));
        assert!(!paths.marker.exists());
    }

    #[test]
    fn nothing_switched_and_emacs_current_restarts_nothing() {
        let dir = tempfile::tempdir().unwrap();
        let paths = CyclePaths::in_dir(dir.path());
        let mut env = FakeEnv::new(Some(100));
        let r = run_cycle(&mut env, &paths, &fast(), |_| Ok(SwitchOutcome::UpToDate), |_| Some(false)).unwrap();
        assert!(matches!(r, CycleOutcome::NothingToRestart));
        assert!(!env.calls().contains(&"kickstart".to_string()));
    }

    #[test]
    fn unknown_staleness_restarts_to_be_safe() {
        let dir = tempfile::tempdir().unwrap();
        let paths = CyclePaths::in_dir(dir.path());
        let mut env = FakeEnv::new(Some(100));
        let r = run_cycle(&mut env, &paths, &fast(), |_| Ok(SwitchOutcome::UpToDate), |_| None).unwrap();
        assert!(matches!(r, CycleOutcome::Restarted(_)));
    }

    #[test]
    fn full_cycle_restarts_waits_for_the_new_daemon_and_reports() {
        let dir = tempfile::tempdir().unwrap();
        let paths = CyclePaths::in_dir(dir.path());
        let mut env = FakeEnv::new(Some(100));
        env.on_prepare = Some((paths.ready.clone(), r#"{"saved":true}"#.into()));
        env.on_frame = Some((paths.summary.clone(), SUMMARY.into()));
        env.marker_seen_at_kickstart = Some(paths.marker.clone());
        let r = run_cycle(&mut env, &paths, &fast(), |_| Ok(SwitchOutcome::Switched), |_| Some(true)).unwrap();
        let CycleOutcome::Restarted(report) = r else { panic!("expected a restart") };
        assert_eq!(env.calls(), vec!["prepare", "kickstart", "frame"]);
        assert!(env.marker_existed, "marker written before the restart");
        assert_eq!(report.old_pid, Some(100));
        assert_eq!(report.new_pid, 200);
        assert!(report.frame_opened);
        assert_eq!(report.summary.unwrap()["resumed"], 2);
    }

    #[test]
    fn a_daemon_that_never_answers_times_out_without_opening_a_frame() {
        let dir = tempfile::tempdir().unwrap();
        let paths = CyclePaths::in_dir(dir.path());
        let mut env = FakeEnv::new(Some(100));
        env.boot_time = Duration::from_secs(3600);
        let r = restart_and_restore(&mut env, &paths, &fast());
        assert_eq!(r.unwrap_err(), CycleError::SocketTimeout(fast().socket));
        assert!(!env.calls().contains(&"frame".to_string()));
    }

    #[test]
    fn the_old_daemon_answering_does_not_count_as_the_new_one() {
        let dir = tempfile::tempdir().unwrap();
        let paths = CyclePaths::in_dir(dir.path());
        let mut env = FakeEnv::new(Some(100));
        env.boot_time = Duration::ZERO;
        env.new_pid = 100;
        assert!(matches!(restart_and_restore(&mut env, &paths, &fast()), Err(CycleError::SocketTimeout(_))));
    }

    #[test]
    fn refused_kickstart_removes_the_marker() {
        let dir = tempfile::tempdir().unwrap();
        let paths = CyclePaths::in_dir(dir.path());
        let mut env = FakeEnv::new(Some(100));
        env.kickstart_ok = false;
        assert_eq!(restart_and_restore(&mut env, &paths, &fast()).unwrap_err(), CycleError::KickstartFailed);
        assert!(!paths.marker.exists());
    }

    #[test]
    fn missing_summary_is_reported_not_fatal() {
        let dir = tempfile::tempdir().unwrap();
        let paths = CyclePaths::in_dir(dir.path());
        let mut env = FakeEnv::new(Some(100));
        let report = restart_and_restore(&mut env, &paths, &fast()).unwrap();
        assert!(report.summary.is_none());
    }

    #[test]
    fn stale_summary_from_a_previous_cycle_is_not_reused() {
        let dir = tempfile::tempdir().unwrap();
        let paths = CyclePaths::in_dir(dir.path());
        fs::write(&paths.summary, SUMMARY).unwrap();
        let mut env = FakeEnv::new(Some(100));
        let report = restart_and_restore(&mut env, &paths, &fast()).unwrap();
        assert!(report.summary.is_none());
    }

    #[test]
    fn summary_lines_name_sessions_failures_and_reattach_skips() {
        let v: serde_json::Value = serde_json::from_str(SUMMARY).unwrap();
        let lines = format_summary(&v);
        assert_eq!(lines[0], "Restored 1 frame, 2 tabs, 2 sessions.");
        assert_eq!(lines[1], "1 session open: 1 restored with history, 1 waiting on a permission prompt.");
        assert!(lines.contains(&"  ✓ *Claude: a* (working, 3 turns)".to_string()));
        assert!(lines.contains(&"  ✗ *Claude: gone*: no session to resume".to_string()));
        assert_eq!(
            lines.last().unwrap(),
            "Brokers reattached at startup: 1; not reattached: 1 with no known conversation."
        );
    }
}
