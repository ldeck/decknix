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

    /// Append-only raw ACP traffic log (bridge stdout, and stderr prefixed `!`).
    #[arg(long)]
    log: Option<PathBuf>,

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

fn mkparent(path: &PathBuf) {
    if let Some(dir) = path.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
}

#[tokio::main]
async fn main() {
    let args = Args::parse();

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
        tokio::spawn(async move {
            let mut buf = [0u8; 8192];
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
    std::process::exit(code);
}
