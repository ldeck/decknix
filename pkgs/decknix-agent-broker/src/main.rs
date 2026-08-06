// decknix-agent-broker — a pipe-clean ACP broker (#151).
//
// Holds ONE agent bridge (e.g. `claude-agent-acp`) for its whole life, its
// stdio on plain pipes, and exposes a unix socket that a client (Emacs' acp.el,
// via `socat - UNIX-CONNECT:<sock>`) attaches to.  The bridge therefore sees a
// single, always-present stdio peer (the broker) and never experiences a client
// vanishing — Emacs attaching/detaching is invisible to it.  The bridge (and so
// the agent turn) survives `decknix switch`, Emacs restarts, and crashes.
//
// Reconnect is deliberately CHEAP: on attach the client gets the LIVE stream
// from that point on — no replay.  Bytes streamed while detached are captured
// in the raw log (and Claude's own transcript); a "walk history" command in the
// editor reviews past prompts/responses, so the broker stays a dumb relay.
//
//        socket (client: Emacs via socat)         raw ACP log
//                     │                                 ▲
//   ┌─────────────────┴─────────────────────────────────┴───┐
//   │  broker: relay client⇄bridge stdin/stdout, drain always │  ← survives Emacs
//   │            claude-agent-acp  ⇄  claude (model)           │
//   └─────────────────────────────────────────────────────────┘

use clap::Parser;
use std::path::PathBuf;
use std::process::Stdio;
use std::sync::Arc;
use tokio::fs::OpenOptions;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::unix::OwnedWriteHalf;
use tokio::net::UnixListener;
use tokio::process::Command;
use tokio::sync::Mutex;
use std::time::Duration;
use tokio::time::Instant as TokioInstant;

#[derive(Parser)]
#[command(
    about = "Pipe-clean ACP broker: hold an agent bridge, relay to a client over a unix socket (#151)"
)]
struct Args {
    /// Unix socket the client (Emacs via `socat - UNIX-CONNECT:<sock>`) attaches to.
    #[arg(long)]
    socket: PathBuf,

    /// Session id — recorded in the log header for identification.
    #[arg(long)]
    session_id: Option<String>,

    /// Detach from the caller (fork + setsid + fork) so the broker — and the
    /// agent turn it holds — survives Emacs dying / `decknix switch'.  Writes
    /// `<socket>.pid' for liveness checks; removed on exit alongside the socket.
    #[arg(long)]
    daemonize: bool,

    /// Append-only raw ACP traffic log (bridge stdout, and stderr prefixed `!`).
    #[arg(long)]
    log: Option<PathBuf>,

    /// Coalesce bridge->client output: buffer and flush at most every N ms (or
    /// on a ~32 KiB threshold) instead of forwarding each read immediately.
    /// Fewer, larger writes wake the attached client's reader less often — fewer
    /// Emacs process-filter/redisplay cycles during heavy streaming.  The log
    /// (source of truth) is still written immediately, so nothing is lost.
    /// 0 = off: forward each read immediately (the default and current
    /// behaviour, a byte-identical relay path).
    #[arg(long, default_value_t = 0)]
    coalesce_ms: u64,

    /// The bridge command and its args, after `--` (e.g. `-- claude-agent-acp`).
    #[arg(last = true, required = true, num_args = 1..)]
    command: Vec<String>,
}

/// The currently-attached client's write half (bridge → client), or None.
type SharedClient = Arc<Mutex<Option<OwnedWriteHalf>>>;

async fn log_write(log: &Option<PathBuf>, prefix: &[u8], bytes: &[u8]) {
    if let Some(path) = log {
        if let Ok(mut f) = OpenOptions::new().create(true).append(true).open(path).await {
            if !prefix.is_empty() {
                let _ = f.write_all(prefix).await;
            }
            let _ = f.write_all(bytes).await;
        }
    }
}

/// Write DATA to the currently-attached client, if any.  On any write/flush
/// error the client vanished mid-write; drop it (a later attach replaces it)
/// and keep draining the bridge.  Same semantics as the immediate relay path.
async fn flush_to_client(client: &SharedClient, data: &[u8]) {
    if data.is_empty() {
        return;
    }
    let mut guard = client.lock().await;
    if let Some(w) = guard.as_mut() {
        if w.write_all(data).await.is_err() || w.flush().await.is_err() {
            *guard = None;
        }
    }
}

/// Max bytes to buffer before forcing a coalesced flush regardless of the
/// time budget — bounds worst-case latency under a continuous stream.
const COALESCE_FLUSH_BYTES: usize = 32 * 1024;

/// Pure decision: with coalescing on, flush now when the buffered byte count
/// has reached the size threshold (the time-budget flush is handled by the
/// select! timer, not this predicate).  Extracted so the threshold logic is
/// unit-testable without a tokio runtime.
fn coalesce_should_flush_on_size(pending_len: usize) -> bool {
    pending_len >= COALESCE_FLUSH_BYTES
}

fn mkparent(path: &PathBuf) {
    if let Some(dir) = path.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
}

fn pidfile(socket: &PathBuf) -> PathBuf {
    let mut p = socket.clone();
    let name = format!("{}.pid", p.file_name().and_then(|n| n.to_str()).unwrap_or("broker"));
    p.set_file_name(name);
    p
}

/// Detach into our own session so signals to Emacs' process group don't reach
/// us. Fork (parent exits so we are not a group leader), setsid (new session,
/// drops the controlling terminal), fork again (can never re-acquire one).
/// Must run BEFORE the tokio runtime starts — no threads may exist across fork.
#[cfg(unix)]
fn daemonize() {
    unsafe {
        match libc::fork() {
            -1 => std::process::exit(1),
            0 => {}
            _ => std::process::exit(0),
        }
        if libc::setsid() == -1 {
            std::process::exit(1);
        }
        match libc::fork() {
            -1 => std::process::exit(1),
            0 => {}
            _ => std::process::exit(0),
        }
    }
}

fn main() {
    let args = Args::parse();

    if args.daemonize {
        #[cfg(unix)]
        daemonize();
    }

    // Runtime is built AFTER any fork, so no tokio thread crosses the fork.
    tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .expect("build tokio runtime")
        .block_on(run(args));
}

async fn run(args: Args) {
    mkparent(&args.socket);
    if let Some(l) = &args.log {
        mkparent(l);
    }
    // Drop a stale socket from a prior run so bind() succeeds.
    let _ = std::fs::remove_file(&args.socket);

    let mut child = match Command::new(&args.command[0])
        .args(&args.command[1..])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
    {
        Ok(c) => c,
        Err(e) => {
            eprintln!(
                "decknix-agent-broker: failed to spawn bridge {:?}: {e}",
                args.command
            );
            std::process::exit(1);
        }
    };

    let mut bridge_stdout = child.stdout.take().expect("bridge stdout piped");
    let mut bridge_stderr = child.stderr.take().expect("bridge stderr piped");
    let bridge_stdin = Arc::new(Mutex::new(child.stdin.take().expect("bridge stdin piped")));

    let listener = match UnixListener::bind(&args.socket) {
        Ok(l) => l,
        Err(e) => {
            eprintln!("decknix-agent-broker: failed to bind {:?}: {e}", args.socket);
            std::process::exit(1);
        }
    };

    // Liveness marker for the attach wrapper: `<socket>.pid'.
    let pid_path = pidfile(&args.socket);
    let _ = std::fs::write(&pid_path, format!("{}\n", std::process::id()));

    log_write(
        &args.log,
        b"",
        format!(
            "# broker up: session={} pid={} socket={}\n",
            args.session_id.as_deref().unwrap_or("-"),
            std::process::id(),
            args.socket.display()
        )
        .as_bytes(),
    )
    .await;

    let client: SharedClient = Arc::new(Mutex::new(None));

    // bridge stdout -> log + current client. ALWAYS drains, so the bridge never
    // blocks on a full pipe even with no client attached.
    let stdout_task = {
        let client = client.clone();
        let log = args.log.clone();
        let coalesce_ms = args.coalesce_ms;
        tokio::spawn(async move {
            let mut buf = [0u8; 8192];
            if coalesce_ms == 0 {
                // Immediate relay (default): forward each read straight away.
                loop {
                    match bridge_stdout.read(&mut buf).await {
                        Ok(0) | Err(_) => break, // bridge closed stdout -> exiting
                        Ok(n) => {
                            let chunk = &buf[..n];
                            log_write(&log, b"", chunk).await;
                            let mut guard = client.lock().await;
                            if let Some(w) = guard.as_mut() {
                                if w.write_all(chunk).await.is_err() || w.flush().await.is_err() {
                                    *guard = None; // client vanished mid-write; keep draining
                                }
                            }
                        }
                    }
                }
            } else {
                // Coalescing relay: still log every read immediately (source of
                // truth), but buffer client output and flush at most every
                // `coalesce_ms' (measured from the first buffered byte) or once
                // the buffer reaches COALESCE_FLUSH_BYTES — whichever comes
                // first.  Fewer, larger socket writes = fewer client wakeups.
                let mut pending: Vec<u8> = Vec::with_capacity(COALESCE_FLUSH_BYTES);
                let mut deadline: Option<TokioInstant> = None;
                loop {
                    tokio::select! {
                        biased;
                        r = bridge_stdout.read(&mut buf) => {
                            match r {
                                Ok(0) | Err(_) => {
                                    // Bridge closed: flush the tail, then exit.
                                    flush_to_client(&client, &pending).await;
                                    break;
                                }
                                Ok(n) => {
                                    let chunk = &buf[..n];
                                    log_write(&log, b"", chunk).await;
                                    pending.extend_from_slice(chunk);
                                    if deadline.is_none() {
                                        deadline = Some(TokioInstant::now()
                                            + Duration::from_millis(coalesce_ms));
                                    }
                                    if coalesce_should_flush_on_size(pending.len()) {
                                        flush_to_client(&client, &pending).await;
                                        pending.clear();
                                        deadline = None;
                                    }
                                }
                            }
                        }
                        // Fires only when a deadline is armed (pending non-empty).
                        _ = async {
                            match deadline {
                                Some(d) => tokio::time::sleep_until(d).await,
                                None => std::future::pending::<()>().await,
                            }
                        } => {
                            flush_to_client(&client, &pending).await;
                            pending.clear();
                            deadline = None;
                        }
                    }
                }
            }
        })
    };

    // bridge stderr -> log (prefixed `!`).
    {
        let log = args.log.clone();
        tokio::spawn(async move {
            let mut buf = [0u8; 4096];
            loop {
                match bridge_stderr.read(&mut buf).await {
                    Ok(0) | Err(_) => break,
                    Ok(n) => log_write(&log, b"!", &buf[..n]).await,
                }
            }
        });
    }

    // Accept loop: one client at a time; a new client replaces the old (its
    // reader task is aborted and its write half dropped, closing the old socket).
    let accept_task = {
        let client = client.clone();
        let bridge_stdin = bridge_stdin.clone();
        let log = args.log.clone();
        tokio::spawn(async move {
            let mut prev_reader: Option<tokio::task::JoinHandle<()>> = None;
            loop {
                let (stream, _addr) = match listener.accept().await {
                    Ok(v) => v,
                    Err(_) => break,
                };
                if let Some(h) = prev_reader.take() {
                    h.abort();
                }
                let (mut rd, wr) = stream.into_split();
                *client.lock().await = Some(wr);
                log_write(&log, b"", b"# client attached\n").await;

                let bridge_stdin = bridge_stdin.clone();
                let log2 = log.clone();
                prev_reader = Some(tokio::spawn(async move {
                    // client -> bridge stdin. On EOF/error the client detached;
                    // we do NOT touch the shared write half (a replacement may
                    // have set a new one, and a stale one self-heals on the next
                    // failed stdout write). The bridge is left running.
                    let mut buf = [0u8; 8192];
                    loop {
                        match rd.read(&mut buf).await {
                            Ok(0) | Err(_) => break,
                            Ok(n) => {
                                let mut si = bridge_stdin.lock().await;
                                if si.write_all(&buf[..n]).await.is_err() {
                                    break;
                                }
                                let _ = si.flush().await;
                            }
                        }
                    }
                    log_write(&log2, b"", b"# client detached\n").await;
                }));
            }
        })
    };

    // Live until the bridge exits (or we're signalled), then clean up the socket.
    // Handle SIGTERM too (the launcher/supervisor stops us with `kill`), so the
    // socket is always removed and the bridge is torn down with us.
    let mut sigterm =
        tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
            .expect("install SIGTERM handler");
    let code = tokio::select! {
        status = child.wait() => status.ok().and_then(|s| s.code()).unwrap_or(0),
        _ = tokio::signal::ctrl_c() => { let _ = child.start_kill(); let _ = child.wait().await; 130 }
        _ = sigterm.recv() => { let _ = child.start_kill(); let _ = child.wait().await; 143 }
        _ = stdout_task => { let _ = child.wait().await; 0 }
    };
    accept_task.abort();
    let _ = std::fs::remove_file(&args.socket);
    let _ = std::fs::remove_file(&pid_path);
    std::process::exit(code);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn coalesce_flush_on_size_at_threshold() {
        assert!(!coalesce_should_flush_on_size(0));
        assert!(!coalesce_should_flush_on_size(COALESCE_FLUSH_BYTES - 1));
        assert!(coalesce_should_flush_on_size(COALESCE_FLUSH_BYTES));
        assert!(coalesce_should_flush_on_size(COALESCE_FLUSH_BYTES + 1));
    }
}
