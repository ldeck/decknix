//! `decknix secrets`: keep credentials in the OS keychain, never in the flake dir.
//!
//! `~/.config/decknix` is the system flake. `decknix switch` passes it to Nix
//! as a `path:` flake, so every evaluation copies the WHOLE directory into the
//! world-readable `/nix/store`, raw 0600 files included: the mode does not
//! survive the copy. A secret anywhere under that directory is therefore
//! readable by every local user and outlives deletion until the store is
//! garbage-collected.
//!
//! Secrets are grouped per org and stored in one of three backends:
//!
//! * `keychain`: macOS Keychain through `/usr/bin/security`. Writes go through
//!   `security -i` with the value hex-encoded on stdin, so the value is never a
//!   command-line argument (argv is world-readable via `ps`). Reads and writes
//!   use the same binary, so the item's ACL trusts it and reads do not prompt.
//!   Items are local to the login keychain, not synced through iCloud.
//! * `libsecret`: the Linux session keyring through `secret-tool`, which takes
//!   the value on stdin.
//! * `file`: one 0600 file per secret under
//!   `$XDG_DATA_HOME/decknix/<org>/secrets/` (default `~/.local/share`), dir 0700.
//!   Refused if that would land inside the flake dir.
//!
//! `get` falls back to the legacy flake-dir files (`<org>/secrets/<name>`,
//! then `<org>/<name>`) with a deprecation warning, so readers keep working
//! until `migrate` has moved them.

use anyhow::{bail, Context, Result};
use clap::Subcommand;
use std::fs;
use std::io::{Read, Write};
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

const DEFAULT_ORG: &str = "local";

#[derive(Subcommand)]
pub enum SecretsAction {
    /// Store a secret, reading the value from stdin (or a hidden prompt on a terminal)
    Set {
        name: String,
        /// Org the secret belongs to (default $DECKNIX_SECRETS_ORG, else `local`)
        #[arg(long)]
        org: Option<String>,
    },
    /// Print a secret to stdout (no trailing newline unless stdout is a terminal)
    Get {
        name: String,
        #[arg(long)]
        org: Option<String>,
        /// Do not fall back to the deprecated file inside ~/.config/decknix
        #[arg(long)]
        no_legacy: bool,
    },
    /// List the secrets known for an org and whether each is set (never values)
    #[command(alias = "ls")]
    List {
        #[arg(long)]
        org: Option<String>,
    },
    /// Remove a secret from the backend
    #[command(alias = "remove")]
    Rm {
        name: String,
        #[arg(long)]
        org: Option<String>,
    },
    /// Run a command with the named secrets in ITS environment only
    Exec {
        #[arg(long)]
        org: Option<String>,
        /// Secret to inject, as NAME (variable NAME upper-snake-cased) or VAR=NAME; repeatable
        #[arg(long = "secret", value_name = "[VAR=]NAME", required = true)]
        secrets: Vec<String>,
        /// The command and its arguments, after `--`
        #[arg(last = true, required = true)]
        command: Vec<String>,
    },
    /// Show the backend and keychain service an org uses
    Backend {
        #[arg(long)]
        org: Option<String>,
    },
    /// Move raw secret files out of ~/.config/decknix into the backend
    Migrate {
        /// Org to migrate; reads ~/.config/decknix/<org>/secrets/ by default
        #[arg(long)]
        org: String,
        /// Also migrate one file, as PATH (name = file name) or NAME=PATH; repeatable
        #[arg(long = "file", value_name = "[NAME=]PATH")]
        files: Vec<String>,
        /// Also migrate a KEY=value env file; each KEY becomes a kebab-case name
        #[arg(long = "env-file", value_name = "PATH")]
        env_files: Vec<PathBuf>,
        /// Keep the old files after a verified copy
        #[arg(long)]
        keep: bool,
        /// Replace a value already in the backend that differs from the file
        #[arg(long)]
        overwrite: bool,
        /// Report what would move without writing or deleting anything
        #[arg(long)]
        dry_run: bool,
    },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Backend {
    Keychain,
    Libsecret,
    File,
}

impl Backend {
    fn parse(s: &str) -> Result<Backend> {
        match s {
            "keychain" => Ok(Backend::Keychain),
            "libsecret" => Ok(Backend::Libsecret),
            "file" => Ok(Backend::File),
            other => bail!("unknown secrets backend '{other}' (keychain, libsecret, file)"),
        }
    }
}

pub struct Store {
    pub org: String,
    pub service: String,
    pub backend: Backend,
    pub security_bin: PathBuf,
    pub secret_tool_bin: PathBuf,
    /// Root of the per-org data dirs: `<data_root>/<org>/secrets/<name>`.
    pub data_root: PathBuf,
    /// The flake dir, `~/.config/decknix`: legacy secrets live here.
    pub config_dir: PathBuf,
}

pub fn valid_name(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= 128
        && !s.starts_with(['.', '-'])
        && s.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-'))
}

/// `jira-token` -> `JIRA_TOKEN`.
pub fn env_var_for(name: &str) -> String {
    name.chars()
        .map(|c| if c.is_ascii_alphanumeric() { c.to_ascii_uppercase() } else { '_' })
        .collect()
}

/// `SLACK_MCP_XOXP` -> `slack-mcp-xoxp`.
pub fn name_for_env_var(var: &str) -> String {
    var.chars()
        .map(|c| if c == '_' { '-' } else { c.to_ascii_lowercase() })
        .collect()
}

/// Strip trailing CR/LF so `printf '%s\n'`, a here-doc and an editor-saved
/// file all store the same bytes.
pub fn normalise(mut v: Vec<u8>) -> Vec<u8> {
    while matches!(v.last(), Some(b'\n') | Some(b'\r')) {
        v.pop();
    }
    v
}

pub fn hex(v: &[u8]) -> String {
    v.iter().map(|b| format!("{b:02x}")).collect()
}

fn home() -> PathBuf {
    dirs::home_dir().unwrap_or_default()
}

fn settings_table(config_dir: &Path) -> Option<toml::Table> {
    fs::read_to_string(config_dir.join("settings.toml")).ok()?.parse().ok()
}

fn path_on_path(bin: &str) -> Option<PathBuf> {
    std::env::var_os("PATH").and_then(|p| {
        std::env::split_paths(&p).map(|d| d.join(bin)).find(|c| c.is_file())
    })
}

impl Store {
    /// The store for ORG on this machine: settings.toml `[secrets] backend`
    /// and `[secrets.services] <org>`, overridden by $DECKNIX_SECRETS_BACKEND
    /// and $DECKNIX_SECRETS_SERVICE.
    pub fn resolve(org: Option<String>) -> Result<Store> {
        let org = org
            .or_else(|| std::env::var("DECKNIX_SECRETS_ORG").ok().filter(|s| !s.is_empty()))
            .unwrap_or_else(|| DEFAULT_ORG.to_string());
        if !valid_name(&org) {
            bail!("invalid org name '{org}'");
        }
        let config_dir = home().join(".config/decknix");
        let settings = settings_table(&config_dir);
        let secrets_tbl = settings.as_ref().and_then(|t| t.get("secrets")).and_then(|v| v.as_table());

        let service = std::env::var("DECKNIX_SECRETS_SERVICE").ok().filter(|s| !s.is_empty())
            .or_else(|| secrets_tbl
                .and_then(|t| t.get("services")).and_then(|v| v.get(&org)).and_then(|v| v.as_str())
                .map(str::to_string))
            .unwrap_or_else(|| format!("decknix-{org}"));
        if !valid_name(&service) {
            bail!("invalid keychain service name '{service}'");
        }

        let security_bin = std::env::var_os("DECKNIX_SECURITY_BIN")
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from("/usr/bin/security"));
        let secret_tool_bin = std::env::var_os("DECKNIX_SECRET_TOOL_BIN")
            .map(PathBuf::from)
            .or_else(|| path_on_path("secret-tool"))
            .unwrap_or_else(|| PathBuf::from("secret-tool"));

        let backend = match std::env::var("DECKNIX_SECRETS_BACKEND").ok().filter(|s| !s.is_empty())
            .or_else(|| secrets_tbl.and_then(|t| t.get("backend")).and_then(|v| v.as_str()).map(str::to_string))
        {
            Some(b) => Backend::parse(&b)?,
            None if cfg!(target_os = "macos") && security_bin.is_file() => Backend::Keychain,
            None if path_on_path("secret-tool").is_some() => Backend::Libsecret,
            None => Backend::File,
        };

        let data_root = std::env::var_os("XDG_DATA_HOME")
            .filter(|s| !s.is_empty())
            .map(PathBuf::from)
            .unwrap_or_else(|| home().join(".local/share"))
            .join("decknix");

        Ok(Store { org, service, backend, security_bin, secret_tool_bin, data_root, config_dir })
    }

    pub fn label(&self) -> String {
        match self.backend {
            Backend::Keychain => format!("macOS Keychain (service {})", self.service),
            Backend::Libsecret => format!("libsecret keyring (service {})", self.service),
            Backend::File => format!("{} (0600 files)", self.file_dir().display()),
        }
    }

    fn org_data_dir(&self) -> PathBuf {
        self.data_root.join(&self.org)
    }

    fn file_dir(&self) -> PathBuf {
        self.org_data_dir().join("secrets")
    }

    fn index_path(&self) -> PathBuf {
        self.org_data_dir().join("secrets.index")
    }

    pub fn legacy_paths(&self, name: &str) -> [PathBuf; 2] {
        let org = self.config_dir.join(&self.org);
        [org.join("secrets").join(name), org.join(name)]
    }

    fn check_name(name: &str) -> Result<()> {
        if !valid_name(name) {
            bail!("invalid secret name '{name}' (letters, digits, '.', '_', '-')");
        }
        Ok(())
    }

    fn ensure_private_dir(&self, dir: &Path) -> Result<()> {
        if dir.starts_with(&self.config_dir) {
            bail!(
                "refusing to store secrets in {}: it is inside the flake dir {}, which is copied into /nix/store",
                dir.display(), self.config_dir.display()
            );
        }
        fs::create_dir_all(dir).with_context(|| format!("create {}", dir.display()))?;
        fs::set_permissions(dir, fs::Permissions::from_mode(0o700))?;
        Ok(())
    }

    /// Write VALUE to PATH as 0600 from creation, via a temp file and rename.
    fn write_private(&self, path: &Path, value: &[u8]) -> Result<()> {
        let dir = path.parent().context("secret path has no parent")?;
        self.ensure_private_dir(dir)?;
        let tmp = dir.join(format!(".{}.tmp-{}", path.file_name().unwrap().to_string_lossy(), std::process::id()));
        let _ = fs::remove_file(&tmp);
        let mut f = fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(&tmp)
            .with_context(|| format!("create {}", tmp.display()))?;
        f.write_all(value)?;
        f.sync_all()?;
        drop(f);
        fs::rename(&tmp, path)?;
        Ok(())
    }

    pub fn set(&self, name: &str, value: &[u8]) -> Result<()> {
        Self::check_name(name)?;
        let value = normalise(value.to_vec());
        if value.is_empty() {
            bail!("empty value, nothing stored");
        }
        match self.backend {
            Backend::Keychain => self.set_keychain(name, &value)?,
            Backend::Libsecret => self.set_libsecret(name, &value)?,
            Backend::File => self.write_private(&self.file_dir().join(name), &value)?,
        }
        match self.get(name)? {
            Some(back) if back == value => {}
            _ => bail!("{}: wrote {name} but could not read the same value back", self.label()),
        }
        self.index_update(name, true)
    }

    fn set_keychain(&self, name: &str, value: &[u8]) -> Result<()> {
        if value.iter().any(|b| *b < 0x20 || *b == 0x7f) {
            bail!("the keychain backend stores single-line values only; split '{name}' into one secret per line");
        }
        let mut child = Command::new(&self.security_bin)
            .arg("-i")
            .stdin(Stdio::piped()).stdout(Stdio::null()).stderr(Stdio::piped())
            .spawn()
            .with_context(|| format!("run {}", self.security_bin.display()))?;
        {
            let mut stdin = child.stdin.take().context("security stdin")?;
            writeln!(stdin, "add-generic-password -U -a {} -s {} -X {}", name, self.service, hex(value))?;
        }
        let out = child.wait_with_output()?;
        if !out.status.success() {
            bail!("security exited {}", out.status);
        }
        Ok(())
    }

    fn set_libsecret(&self, name: &str, value: &[u8]) -> Result<()> {
        let mut child = Command::new(&self.secret_tool_bin)
            .arg("store").arg(format!("--label={}: {}", self.service, name))
            .args(["service", &self.service, "account", name])
            .stdin(Stdio::piped()).stdout(Stdio::null()).stderr(Stdio::piped())
            .spawn()
            .with_context(|| format!("run {}", self.secret_tool_bin.display()))?;
        child.stdin.take().context("secret-tool stdin")?.write_all(value)?;
        let out = child.wait_with_output()?;
        if !out.status.success() {
            bail!("secret-tool store exited {}", out.status);
        }
        Ok(())
    }

    /// The value in the backend, or None when it is not there.
    pub fn get(&self, name: &str) -> Result<Option<Vec<u8>>> {
        Self::check_name(name)?;
        let v = match self.backend {
            Backend::Keychain => {
                let out = Command::new(&self.security_bin)
                    .args(["find-generic-password", "-a", name, "-s", &self.service, "-w"])
                    .stdin(Stdio::null()).stderr(Stdio::null())
                    .output()
                    .with_context(|| format!("run {}", self.security_bin.display()))?;
                if !out.status.success() { return Ok(None); }
                out.stdout
            }
            Backend::Libsecret => {
                let out = Command::new(&self.secret_tool_bin)
                    .args(["lookup", "service", &self.service, "account", name])
                    .stdin(Stdio::null()).stderr(Stdio::null())
                    .output()
                    .with_context(|| format!("run {}", self.secret_tool_bin.display()))?;
                if !out.status.success() { return Ok(None); }
                out.stdout
            }
            Backend::File => match fs::read(self.file_dir().join(name)) {
                Ok(v) => v,
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
                Err(e) => return Err(e.into()),
            },
        };
        let v = normalise(v);
        Ok(if v.is_empty() { None } else { Some(v) })
    }

    /// The backend value, else a legacy flake-dir file and its path.
    pub fn get_with_legacy(&self, name: &str) -> Result<Option<(Vec<u8>, Option<PathBuf>)>> {
        if let Some(v) = self.get(name)? {
            return Ok(Some((v, None)));
        }
        for p in self.legacy_paths(name) {
            if p.is_file() {
                let v = normalise(fs::read(&p)?);
                if !v.is_empty() {
                    return Ok(Some((v, Some(p))));
                }
            }
        }
        Ok(None)
    }

    pub fn rm(&self, name: &str) -> Result<bool> {
        Self::check_name(name)?;
        let removed = match self.backend {
            Backend::Keychain => Command::new(&self.security_bin)
                .args(["delete-generic-password", "-a", name, "-s", &self.service])
                .stdout(Stdio::null()).stderr(Stdio::null()).status()?.success(),
            Backend::Libsecret => {
                let had = self.get(name)?.is_some();
                Command::new(&self.secret_tool_bin)
                    .args(["clear", "service", &self.service, "account", name])
                    .stdout(Stdio::null()).stderr(Stdio::null()).status()?;
                had
            }
            Backend::File => fs::remove_file(self.file_dir().join(name)).is_ok(),
        };
        self.index_update(name, false)?;
        Ok(removed)
    }

    /// Names recorded by `set`. The keychain cannot be listed without dumping
    /// every app's items, so the store keeps its own names-only index.
    pub fn index(&self) -> Vec<String> {
        let mut names: Vec<String> = fs::read_to_string(self.index_path()).unwrap_or_default()
            .lines().map(str::trim).filter(|l| valid_name(l)).map(str::to_string).collect();
        if self.backend == Backend::File {
            if let Ok(rd) = fs::read_dir(self.file_dir()) {
                names.extend(rd.flatten().filter_map(|e| e.file_name().into_string().ok()).filter(|n| valid_name(n)));
            }
        }
        names.sort();
        names.dedup();
        names
    }

    fn index_update(&self, name: &str, present: bool) -> Result<()> {
        let mut names = self.index();
        names.retain(|n| n != name);
        if present {
            names.push(name.to_string());
            names.sort();
        }
        let mut text = names.join("\n");
        if !text.is_empty() { text.push('\n'); }
        self.write_private(&self.index_path(), text.as_bytes())
    }

    /// Names of legacy raw files in `<config>/<org>/secrets/`.
    pub fn legacy_names(&self) -> Vec<String> {
        let mut v: Vec<String> = fs::read_dir(self.config_dir.join(&self.org).join("secrets"))
            .map(|rd| rd.flatten()
                 .filter(|e| e.path().is_file())
                 .filter_map(|e| e.file_name().into_string().ok())
                 .filter(|n| valid_name(n))
                 .collect())
            .unwrap_or_default();
        v.sort();
        v
    }
}

// --------------------------------------------------------------------------
// Migration
// --------------------------------------------------------------------------

pub struct MigrateOpts {
    pub keep: bool,
    pub overwrite: bool,
    pub dry_run: bool,
}

/// One secret to move: its name, value, and the file it came from.
struct Item {
    name: String,
    value: Vec<u8>,
    origin: PathBuf,
}

fn unquote(v: &str) -> &str {
    let v = v.trim();
    for q in ['\'', '"'] {
        if v.len() >= 2 && v.starts_with(q) && v.ends_with(q) {
            return &v[1..v.len() - 1];
        }
    }
    v
}

/// KEY=value pairs from an env file: `export` prefixes, comments and quotes handled.
pub fn parse_env_file(text: &str) -> Vec<(String, String)> {
    text.lines()
        .map(str::trim)
        .filter(|l| !l.is_empty() && !l.starts_with('#'))
        .filter_map(|l| {
            let l = l.strip_prefix("export ").unwrap_or(l);
            let (k, v) = l.split_once('=')?;
            let k = k.trim();
            if k.is_empty() || !k.chars().all(|c| c.is_ascii_alphanumeric() || c == '_') {
                return None;
            }
            Some((k.to_string(), unquote(v).to_string()))
        })
        .filter(|(_, v)| !v.is_empty())
        .collect()
}

/// Move ITEMS into STORE, returning the report lines. A source file is
/// deleted only once every secret it held is verified in the backend.
fn migrate_items(store: &Store, items: Vec<Item>, opts: &MigrateOpts, out: &mut Vec<String>) -> Result<usize> {
    let mut failed_origins: Vec<PathBuf> = Vec::new();
    let mut origins: Vec<PathBuf> = Vec::new();
    let mut moved = 0;
    for it in items {
        if !origins.contains(&it.origin) { origins.push(it.origin.clone()); }
        let len = it.value.len();
        let existing = store.get(&it.name)?;
        let action = match &existing {
            Some(v) if *v == it.value => "already in backend",
            Some(_) if !opts.overwrite => {
                out.push(format!("  ! {} differs from the value already stored; left {} in place (use --overwrite)",
                                 it.name, it.origin.display()));
                failed_origins.push(it.origin);
                continue;
            }
            _ => "moved",
        };
        if opts.dry_run {
            out.push(format!("  would move {} ({len} bytes) from {}", it.name, it.origin.display()));
            continue;
        }
        if action == "moved" {
            if let Err(e) = store.set(&it.name, &it.value) {
                out.push(format!("  ! could not store {}: {e}; left {} in place", it.name, it.origin.display()));
                failed_origins.push(it.origin);
                continue;
            }
            moved += 1;
        } else {
            store.index_update(&it.name, true)?;
        }
        match store.get(&it.name)? {
            Some(v) if v.len() == len && v == it.value => {
                out.push(format!("  {action} {} ({len} bytes verified) -> {}", it.name, store.label()));
            }
            _ => {
                out.push(format!("  ! {} did not read back intact; left {} in place", it.name, it.origin.display()));
                failed_origins.push(it.origin);
            }
        }
    }
    if !opts.dry_run && !opts.keep {
        for o in origins.iter().filter(|o| !failed_origins.contains(o)) {
            fs::remove_file(o).with_context(|| format!("remove {}", o.display()))?;
            out.push(format!("  removed {}", o.display()));
        }
        let dir = store.config_dir.join(&store.org).join("secrets");
        if dir.is_dir() && fs::read_dir(&dir).map(|mut d| d.next().is_none()).unwrap_or(false) {
            fs::remove_dir(&dir)?;
            out.push(format!("  removed empty {}", dir.display()));
        }
    }
    Ok(moved)
}

pub fn migrate(store: &Store, files: &[String], env_files: &[PathBuf], opts: &MigrateOpts) -> Result<Vec<String>> {
    let mut items = Vec::new();
    let dir = store.config_dir.join(&store.org).join("secrets");
    for name in store.legacy_names() {
        let p = dir.join(&name);
        items.push(Item { value: normalise(fs::read(&p)?), name, origin: p });
    }
    for spec in files {
        let (name, path) = match spec.split_once('=') {
            Some((n, p)) => (n.to_string(), PathBuf::from(p)),
            None => {
                let p = PathBuf::from(spec);
                (p.file_name().and_then(|s| s.to_str()).unwrap_or_default().to_string(), p)
            }
        };
        Store::check_name(&name)?;
        items.push(Item { value: normalise(fs::read(&path).with_context(|| format!("read {}", path.display()))?), name, origin: path });
    }
    for path in env_files {
        let text = fs::read_to_string(path).with_context(|| format!("read {}", path.display()))?;
        for (k, v) in parse_env_file(&text) {
            items.push(Item { name: name_for_env_var(&k), value: v.into_bytes(), origin: path.clone() });
        }
    }
    let mut out = Vec::new();
    if items.is_empty() {
        out.push(format!("nothing to migrate for org {} (no files in {})", store.org, dir.display()));
        return Ok(out);
    }
    items.retain(|i| {
        if i.value.is_empty() { out.push(format!("  skipped {} (empty)", i.name)); false } else { true }
    });
    let moved = migrate_items(store, items, opts, &mut out)?;
    if moved > 0 {
        out.push(String::new());
        out.push("These values sat inside ~/.config/decknix, which every switch copies into the".into());
        out.push("world-readable /nix/store. Treat them as exposed: rotate each at its provider,".into());
        out.push(format!("store the new value with `decknix secrets set <name> --org {}`, then", store.org));
        out.push("garbage-collect the old store paths (`sudo nix-collect-garbage -d`).".into());
    }
    Ok(out)
}

// --------------------------------------------------------------------------
// Flake-dir audit (warned on every switch)
// --------------------------------------------------------------------------

fn looks_like_secret_file(name: &str) -> bool {
    let n = name.to_ascii_lowercase();
    if [".nix", ".el", ".eld", ".json", ".log", ".lock", ".md", ".toml"].iter().any(|s| n.ends_with(s)) {
        return false;
    }
    ["token", "secret", "api-key", "apikey", "password", "credential"].iter().any(|k| n.contains(k))
        || n.ends_with(".env") || n.contains(".env.")
}

/// Whether a `secrets.nix` LINE holds a credential literal rather than a path.
pub fn line_has_secret_literal(line: &str) -> bool {
    let l = line.trim_start();
    if l.starts_with('#') { return false; }
    let prefixed = regex::Regex::new(r"(ghp_|gho_|github_pat_|xox[abcdpr]-|sk-ant-|sk-[A-Za-z0-9]{20}|AIza|ATATT|glpat-)[A-Za-z0-9_\-]{8,}").unwrap();
    let assigned = regex::Regex::new(r#"(?i)(token|passw(or)?d|secret|api_?key)[A-Za-z0-9_]*"?\s*=\s*"[^"$/]{16,}""#).unwrap();
    prefixed.is_match(l) || assigned.is_match(l)
}

/// Paths (never contents) inside the flake dir that look like secrets.
pub fn flake_dir_findings(config_dir: &Path) -> Vec<String> {
    let mut found = Vec::new();
    let Ok(rd) = fs::read_dir(config_dir) else { return found };
    let mut dirs: Vec<PathBuf> = vec![config_dir.to_path_buf()];
    dirs.extend(rd.flatten().map(|e| e.path())
        .filter(|p| p.is_dir() && !p.is_symlink())
        .filter(|p| !p.file_name().is_some_and(|n| n.to_string_lossy().starts_with('.') || n == "result")));
    for d in dirs {
        let secrets = d.join("secrets");
        if secrets.is_dir() && fs::read_dir(&secrets).map(|mut r| r.next().is_some()).unwrap_or(false) {
            found.push(format!("{}/ holds raw secret files", secrets.display()));
        }
        let Ok(entries) = fs::read_dir(&d) else { continue };
        let mut files: Vec<PathBuf> = entries.flatten().map(|e| e.path()).filter(|p| p.is_file()).collect();
        files.sort();
        for f in files {
            let name = f.file_name().unwrap().to_string_lossy().to_string();
            if name == "secrets.nix" {
                let lines: Vec<usize> = fs::read_to_string(&f).unwrap_or_default().lines().enumerate()
                    .filter(|(_, l)| line_has_secret_literal(l)).map(|(i, _)| i + 1).collect();
                if !lines.is_empty() {
                    let ls: Vec<String> = lines.iter().map(|n| n.to_string()).collect();
                    found.push(format!("{} has what look like secret literals (lines {})", f.display(), ls.join(", ")));
                }
            } else if d != config_dir && looks_like_secret_file(&name) {
                found.push(format!("{} looks like a raw secret file", f.display()));
            }
        }
    }
    found
}

pub fn warn_flake_dir(config_dir: &Path) {
    let found = flake_dir_findings(config_dir);
    if found.is_empty() { return; }
    eprintln!("⚠️  Secrets inside {} are copied into the world-readable /nix/store on every switch:", config_dir.display());
    for f in &found {
        eprintln!("   - {f}");
    }
    eprintln!("   Move them with `decknix secrets migrate --org <org>` (see `decknix secrets --help`), then rotate them.");
}

// --------------------------------------------------------------------------
// CLI
// --------------------------------------------------------------------------

fn read_value(name: &str) -> Result<Vec<u8>> {
    if unsafe { libc::isatty(0) } == 1 {
        eprint!("Value for {name} (input hidden): ");
        std::io::stderr().flush()?;
        let mut tty = fs::OpenOptions::new().read(true).write(true).open("/dev/tty")?;
        let fd = std::os::unix::io::AsRawFd::as_raw_fd(&tty);
        let mut term: libc::termios = unsafe { std::mem::zeroed() };
        let have = unsafe { libc::tcgetattr(fd, &mut term) } == 0;
        let saved = term;
        if have {
            term.c_lflag &= !libc::ECHO;
            unsafe { libc::tcsetattr(fd, libc::TCSANOW, &term) };
        }
        let mut line = String::new();
        let res = std::io::BufRead::read_line(&mut std::io::BufReader::new(&mut tty), &mut line);
        if have {
            unsafe { libc::tcsetattr(fd, libc::TCSANOW, &saved) };
        }
        eprintln!();
        res?;
        Ok(line.into_bytes())
    } else {
        let mut v = Vec::new();
        std::io::stdin().read_to_end(&mut v)?;
        Ok(v)
    }
}

pub fn run(action: SecretsAction) -> Result<()> {
    match action {
        SecretsAction::Set { name, org } => {
            let store = Store::resolve(org)?;
            let value = read_value(&name)?;
            store.set(&name, &value)?;
            eprintln!("stored {name} for org {} in {}", store.org, store.label());
        }
        SecretsAction::Get { name, org, no_legacy } => {
            let store = Store::resolve(org)?;
            let found = if no_legacy { store.get(&name)?.map(|v| (v, None)) } else { store.get_with_legacy(&name)? };
            let Some((value, legacy)) = found else {
                eprintln!("decknix secrets: no secret '{name}' for org {} in {}", store.org, store.label());
                std::process::exit(1);
            };
            if let Some(p) = legacy {
                eprintln!(
                    "decknix secrets: warning: '{name}' read from {} (deprecated: inside the flake dir, copied into /nix/store). Run `decknix secrets migrate --org {}`.",
                    p.display(), store.org
                );
            }
            let mut so = std::io::stdout();
            so.write_all(&value)?;
            if unsafe { libc::isatty(1) } == 1 { so.write_all(b"\n")?; }
            so.flush()?;
        }
        SecretsAction::List { org } => {
            let store = Store::resolve(org)?;
            println!("org {}: {}", store.org, store.label());
            let mut names = store.index();
            let legacy = store.legacy_names();
            names.extend(legacy.iter().cloned());
            names.sort();
            names.dedup();
            for n in names {
                let state = match (store.get(&n)?.is_some(), legacy.contains(&n)) {
                    (true, true) => "set (old file still in flake dir)",
                    (true, false) => "set",
                    (false, true) => "legacy file only: run migrate",
                    (false, false) => "-",
                };
                println!("  {n:<32} {state}");
            }
        }
        SecretsAction::Rm { name, org } => {
            let store = Store::resolve(org)?;
            if store.rm(&name)? {
                eprintln!("removed {name} from {}", store.label());
            } else {
                eprintln!("{name} was not in {}", store.label());
            }
        }
        SecretsAction::Exec { org, secrets, command } => {
            let store = Store::resolve(org)?;
            let mut cmd = Command::new(&command[0]);
            cmd.args(&command[1..]);
            for spec in secrets {
                let (var, name) = match spec.split_once('=') {
                    Some((v, n)) => (v.to_string(), n.to_string()),
                    None => (env_var_for(&spec), spec.clone()),
                };
                if std::env::var_os(&var).is_some_and(|v| !v.is_empty()) {
                    continue;
                }
                match store.get_with_legacy(&name)? {
                    Some((v, legacy)) => {
                        if let Some(p) = legacy {
                            eprintln!("decknix secrets: warning: '{name}' read from deprecated {}", p.display());
                        }
                        cmd.env(&var, <std::ffi::OsStr as std::os::unix::ffi::OsStrExt>::from_bytes(&v));
                    }
                    None => bail!("no secret '{name}' for org {}", store.org),
                }
            }
            let err = std::os::unix::process::CommandExt::exec(&mut cmd);
            bail!("exec {}: {err}", command[0]);
        }
        SecretsAction::Backend { org } => {
            let store = Store::resolve(org)?;
            println!("{}", store.label());
        }
        SecretsAction::Migrate { org, files, env_files, keep, overwrite, dry_run } => {
            let store = Store::resolve(Some(org))?;
            for line in migrate(&store, &files, &env_files, &MigrateOpts { keep, overwrite, dry_run })? {
                println!("{line}");
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A `security` stand-in that keeps items as files and logs its argv, so
    /// tests can check the value never appeared on a command line.
    fn stub_security(dir: &Path) -> PathBuf {
        let bash = path_on_path("bash").expect("bash on PATH");
        let store = dir.join("kc");
        fs::create_dir_all(&store).unwrap();
        let script = format!(r#"#!{bash}
store='{store}'
printf '%s\n' "$*" >> '{log}'
item() {{ printf '%s/%s@%s' "$store" "$1" "$2"; }}
parse() {{
  acct=; svc=; hex=
  while [ $# -gt 0 ]; do
    case "$1" in -a) acct=$2; shift 2;; -s) svc=$2; shift 2;; -X) hex=$2; shift 2;; *) shift;; esac
  done
}}
case "$1" in
  -i)
    read -r line
    set -- $line
    [ "$1" = add-generic-password ] || exit 1
    parse "$@"
    printf "$(printf '%s' "$hex" | sed 's/../\\x&/g')" > "$(item "$svc" "$acct")" ;;
  find-generic-password)
    parse "$@"; f=$(item "$svc" "$acct"); [ -f "$f" ] || exit 44; cat "$f"; echo ;;
  delete-generic-password)
    parse "$@"; f=$(item "$svc" "$acct"); [ -f "$f" ] || exit 44; rm -f "$f" ;;
  *) exit 2 ;;
esac
"#, bash = bash.display(), store = store.display(), log = dir.join("argv.log").display());
        let p = dir.join("security");
        fs::write(&p, script).unwrap();
        fs::set_permissions(&p, fs::Permissions::from_mode(0o755)).unwrap();
        p
    }

    fn store(tmp: &Path, backend: Backend) -> Store {
        let config_dir = tmp.join("home/.config/decknix");
        fs::create_dir_all(&config_dir).unwrap();
        Store {
            org: "acme".into(),
            service: "decknix-acme".into(),
            backend,
            security_bin: stub_security(tmp),
            secret_tool_bin: PathBuf::from("/nonexistent/secret-tool"),
            data_root: tmp.join("home/.local/share/decknix"),
            config_dir,
        }
    }

    const TRICKY: &str = "ATATT3x $y \"z\" 'q' \\b|c;`id`";

    #[test]
    fn keychain_round_trip_keeps_shell_metacharacters_and_off_argv() {
        let tmp = tempfile::tempdir().unwrap();
        let s = store(tmp.path(), Backend::Keychain);
        s.set("jira-token", format!("{TRICKY}\n").as_bytes()).unwrap();
        assert_eq!(s.get("jira-token").unwrap().unwrap(), TRICKY.as_bytes());
        let argv = fs::read_to_string(tmp.path().join("argv.log")).unwrap();
        assert!(!argv.contains("ATATT"), "value leaked onto argv");
        assert!(!argv.contains(&hex(TRICKY.as_bytes())), "hex leaked onto argv");
        assert_eq!(s.index(), vec!["jira-token".to_string()]);
        assert!(s.rm("jira-token").unwrap());
        assert_eq!(s.get("jira-token").unwrap(), None);
        assert!(s.index().is_empty());
    }

    #[test]
    fn keychain_refuses_multiline_values() {
        let tmp = tempfile::tempdir().unwrap();
        let s = store(tmp.path(), Backend::Keychain);
        assert!(s.set("pem", b"line1\nline2").is_err());
    }

    #[test]
    fn file_backend_is_private_and_outside_flake_dir() {
        let tmp = tempfile::tempdir().unwrap();
        let s = store(tmp.path(), Backend::File);
        s.set("gemini-api-key", b"AIzaSecretValue\n").unwrap();
        let f = s.data_root.join("acme/secrets/gemini-api-key");
        assert_eq!(fs::metadata(&f).unwrap().permissions().mode() & 0o777, 0o600);
        assert_eq!(fs::metadata(f.parent().unwrap()).unwrap().permissions().mode() & 0o777, 0o700);
        assert_eq!(s.get("gemini-api-key").unwrap().unwrap(), b"AIzaSecretValue");

        let inside = Store { data_root: s.config_dir.join("data"), ..store(tmp.path(), Backend::File) };
        assert!(inside.set("x", b"v").is_err(), "must refuse a file store inside the flake dir");
    }

    #[test]
    fn get_falls_back_to_legacy_file() {
        let tmp = tempfile::tempdir().unwrap();
        let s = store(tmp.path(), Backend::Keychain);
        let legacy = s.config_dir.join("acme/secrets");
        fs::create_dir_all(&legacy).unwrap();
        fs::write(legacy.join("jira-token"), "old\n").unwrap();
        let (v, from) = s.get_with_legacy("jira-token").unwrap().unwrap();
        assert_eq!(v, b"old");
        assert_eq!(from.unwrap(), legacy.join("jira-token"));
        s.set("jira-token", b"new").unwrap();
        let (v, from) = s.get_with_legacy("jira-token").unwrap().unwrap();
        assert_eq!((v.as_slice(), from), (&b"new"[..], None));
    }

    #[test]
    fn migrate_moves_verifies_and_deletes() {
        let tmp = tempfile::tempdir().unwrap();
        let s = store(tmp.path(), Backend::Keychain);
        let dir = s.config_dir.join("acme/secrets");
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join("jira-token"), format!("{TRICKY}\n")).unwrap();
        fs::write(dir.join("gemini-api-key"), "AIzaAbc").unwrap();
        let env = s.config_dir.join("local/slack-mcp.env");
        fs::create_dir_all(env.parent().unwrap()).unwrap();
        fs::write(&env, "# c\nexport SLACK_MCP_XOXC='xoxc-1'\nSLACK_MCP_XOXD=\"xoxd-2\"\n").unwrap();

        let out = migrate(&s, &[], &[env.clone()], &MigrateOpts { keep: false, overwrite: false, dry_run: false }).unwrap();
        let text = out.join("\n");
        assert!(!text.contains("ATATT") && !text.contains("xoxc-1"), "report must not print values");
        assert!(text.contains(&format!("({} bytes verified)", TRICKY.len())));
        assert_eq!(s.get("jira-token").unwrap().unwrap(), TRICKY.as_bytes());
        assert_eq!(s.get("slack-mcp-xoxc").unwrap().unwrap(), b"xoxc-1");
        assert_eq!(s.get("slack-mcp-xoxd").unwrap().unwrap(), b"xoxd-2");
        assert!(!dir.exists(), "emptied legacy dir is removed");
        assert!(!env.exists());
        let argv = fs::read_to_string(tmp.path().join("argv.log")).unwrap();
        assert!(!argv.contains("ATATT") && !argv.contains("xoxc-1"));
    }

    #[test]
    fn migrate_keep_dry_run_and_conflicts() {
        let tmp = tempfile::tempdir().unwrap();
        let s = store(tmp.path(), Backend::File);
        let dir = s.config_dir.join("acme/secrets");
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join("a-token"), "one").unwrap();

        migrate(&s, &[], &[], &MigrateOpts { keep: false, overwrite: false, dry_run: true }).unwrap();
        assert!(dir.join("a-token").exists());
        assert_eq!(s.get("a-token").unwrap(), None);

        migrate(&s, &[], &[], &MigrateOpts { keep: true, overwrite: false, dry_run: false }).unwrap();
        assert!(dir.join("a-token").exists());
        assert_eq!(s.get("a-token").unwrap().unwrap(), b"one");

        fs::write(dir.join("a-token"), "two").unwrap();
        let out = migrate(&s, &[], &[], &MigrateOpts { keep: false, overwrite: false, dry_run: false }).unwrap();
        assert!(out.iter().any(|l| l.contains("differs")));
        assert!(dir.join("a-token").exists(), "a conflicting file is kept");
        assert_eq!(s.get("a-token").unwrap().unwrap(), b"one");

        migrate(&s, &[], &[], &MigrateOpts { keep: false, overwrite: true, dry_run: false }).unwrap();
        assert_eq!(s.get("a-token").unwrap().unwrap(), b"two");
        assert!(!dir.join("a-token").exists());
    }

    #[test]
    fn migrate_single_file_with_name() {
        let tmp = tempfile::tempdir().unwrap();
        let s = store(tmp.path(), Backend::File);
        let f = s.config_dir.join("local/jira-token");
        fs::create_dir_all(f.parent().unwrap()).unwrap();
        fs::write(&f, "tok").unwrap();
        migrate(&s, &[format!("jira-token={}", f.display())], &[], &MigrateOpts { keep: false, overwrite: false, dry_run: false }).unwrap();
        assert_eq!(s.get("jira-token").unwrap().unwrap(), b"tok");
        assert!(!f.exists());
    }

    #[test]
    fn names_and_env_vars() {
        assert_eq!(env_var_for("jira-token"), "JIRA_TOKEN");
        assert_eq!(name_for_env_var("SLACK_MCP_XOXP"), "slack-mcp-xoxp");
        assert!(valid_name("fub-acme.api_key"));
        for bad in ["", "-x", ".x", "a b", "a/b", "a;b"] {
            assert!(!valid_name(bad), "{bad}");
        }
    }

    #[test]
    fn flake_dir_audit_names_paths_only() {
        let tmp = tempfile::tempdir().unwrap();
        let c = tmp.path();
        fs::create_dir_all(c.join("acme/secrets")).unwrap();
        fs::write(c.join("acme/secrets/jira-token"), "ATATT123456789").unwrap();
        fs::create_dir_all(c.join("local")).unwrap();
        fs::write(c.join("local/slack-mcp.env"), "X=1").unwrap();
        fs::write(c.join("local/home.nix"), "{ }").unwrap();
        fs::write(c.join("local/secrets.nix"),
                  "{\n  # token = \"commented-out-value-here\";\n  x.token = \"abcdefghijklmnopqrstu\";\n  y.tokenFile = \"/Users/me/.local/share/t\";\n}\n").unwrap();
        fs::write(c.join("settings.toml"), "").unwrap();
        fs::create_dir_all(c.join("hub")).unwrap();
        fs::write(c.join("hub/token-quotas.json"), "{}").unwrap();
        let found = flake_dir_findings(c).join("\n");
        assert!(found.contains("acme/secrets/ holds raw secret files"), "{found}");
        assert!(found.contains("slack-mcp.env looks like a raw secret file"), "{found}");
        assert!(found.contains("secrets.nix has what look like secret literals (lines 3)"), "{found}");
        assert!(!found.contains("home.nix") && !found.contains("ATATT"), "{found}");
        assert!(!found.contains("token-quotas"), "{found}");
    }

    #[test]
    fn secret_literal_heuristic() {
        assert!(line_has_secret_literal(r#"  apiKey = "0123456789abcdef0123";"#));
        assert!(line_has_secret_literal(r#"  env.GH = "ghp_abcdefghijklmnop";"#));
        assert!(!line_has_secret_literal(r#"  tokenFile = "/Users/me/x/y/z/abcdefgh";"#));
        assert!(!line_has_secret_literal(r#"  token = "${config.x}";"#));
        assert!(!line_has_secret_literal(r#"  # apiKey = "0123456789abcdef0123";"#));
    }
}
