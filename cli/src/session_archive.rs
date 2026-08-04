//! Session archive store: zstd-compressed session files + a lightweight JSONL
//! metadata index, under `~/.local/state/decknix/session-archive/<agent>/`.
//!
//! The index lets `decknix session list --archived` and the Emacs picker show
//! archived sessions (id, first message, tags, workspace) with **no
//! decompression**; the compressed blob is only touched on `restore`.
//!
//! All primitives take an explicit `root` so tests can point at a tempdir; the
//! CLI passes [`archive_root`].

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::{Path, PathBuf};

/// One archived session's metadata (one JSONL line in `<agent>/index.jsonl`).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ArchiveEntry {
    pub id: String,
    pub provider: String,
    /// Path relative to the provider's sessions root, so restore lands correctly
    /// (claude: `<slug>/<id>.jsonl`; auggie/pi: `<id>.<ext>`).
    pub orig_rel_path: String,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub workspace: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub first_message: Option<String>,
    #[serde(default)]
    pub tags: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub created: Option<String>,
    pub modified: String,
    pub archived_at: String,
    pub orig_size: u64,
    pub compressed_size: u64,
}

/// Base of the archive store. Bulk data lives under XDG state, not `~/.config`.
pub fn archive_root() -> PathBuf {
    dirs::home_dir()
        .unwrap_or_default()
        .join(".local/state/decknix/session-archive")
}

pub fn agent_dir(root: &Path, provider: &str) -> PathBuf {
    root.join(provider)
}

pub fn index_path(root: &Path, provider: &str) -> PathBuf {
    agent_dir(root, provider).join("index.jsonl")
}

/// `<agent>/<id>.<orig_ext>.zst` — the compressed blob for a session.
pub fn compressed_path(root: &Path, provider: &str, id: &str, orig_ext: &str) -> PathBuf {
    agent_dir(root, provider).join(format!("{}.{}.zst", id, orig_ext))
}

/// Read a provider's index (empty when the file is absent).
pub fn read_index(root: &Path, provider: &str) -> Vec<ArchiveEntry> {
    let path = index_path(root, provider);
    let content = match fs::read_to_string(&path) {
        Ok(c) => c,
        Err(_) => return Vec::new(),
    };
    content
        .lines()
        .filter(|l| !l.trim().is_empty())
        .filter_map(|l| serde_json::from_str::<ArchiveEntry>(l).ok())
        .collect()
}

/// Read every provider's index under `root` (for cross-agent `list --archived`).
pub fn read_all_indexes(root: &Path) -> Vec<ArchiveEntry> {
    let mut out = Vec::new();
    if let Ok(entries) = fs::read_dir(root) {
        for e in entries.flatten() {
            if e.path().is_dir() {
                if let Some(provider) = e.file_name().to_str() {
                    out.extend(read_index(root, provider));
                }
            }
        }
    }
    out
}

/// Append one entry to a provider's index (creating the dir/file as needed).
pub fn append_entry(root: &Path, provider: &str, entry: &ArchiveEntry) -> Result<()> {
    use std::io::Write;
    let dir = agent_dir(root, provider);
    fs::create_dir_all(&dir).with_context(|| format!("creating {}", dir.display()))?;
    let path = index_path(root, provider);
    let line = serde_json::to_string(entry)?;
    let mut f = fs::OpenOptions::new().create(true).append(true).open(&path)?;
    writeln!(f, "{}", line)?;
    Ok(())
}

/// Rewrite a provider's index (used by restore/trash to drop entries).
/// Atomic: temp file + rename.
pub fn write_index(root: &Path, provider: &str, entries: &[ArchiveEntry]) -> Result<()> {
    let dir = agent_dir(root, provider);
    fs::create_dir_all(&dir)?;
    let path = index_path(root, provider);
    let body: String = entries
        .iter()
        .map(|e| serde_json::to_string(e).unwrap_or_default())
        .collect::<Vec<_>>()
        .join("\n");
    let body = if body.is_empty() { body } else { format!("{}\n", body) };
    let tmp = path.with_extension("jsonl.tmp");
    fs::write(&tmp, body)?;
    fs::rename(&tmp, &path)?;
    Ok(())
}

/// zstd-compress `src` → `dst`, returning `(orig_size, compressed_size)`.
pub fn compress_file(src: &Path, dst: &Path, level: i32) -> Result<(u64, u64)> {
    if let Some(parent) = dst.parent() {
        fs::create_dir_all(parent)?;
    }
    let orig_size = fs::metadata(src)?.len();
    let reader = fs::File::open(src).with_context(|| format!("opening {}", src.display()))?;
    let writer = fs::File::create(dst).with_context(|| format!("creating {}", dst.display()))?;
    zstd::stream::copy_encode(reader, writer, level)
        .with_context(|| format!("zstd-compressing {}", src.display()))?;
    let compressed_size = fs::metadata(dst)?.len();
    Ok((orig_size, compressed_size))
}

/// zstd-decompress `src` (a `.zst`) → `dst` (creating parent dirs).
pub fn decompress_file(src: &Path, dst: &Path) -> Result<()> {
    if let Some(parent) = dst.parent() {
        fs::create_dir_all(parent)?;
    }
    let reader = fs::File::open(src).with_context(|| format!("opening {}", src.display()))?;
    let writer = fs::File::create(dst).with_context(|| format!("creating {}", dst.display()))?;
    zstd::stream::copy_decode(reader, writer)
        .with_context(|| format!("zstd-decompressing {}", src.display()))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample_entry(id: &str) -> ArchiveEntry {
        ArchiveEntry {
            id: id.into(),
            provider: "auggie".into(),
            orig_rel_path: format!("{}.json", id),
            workspace: Some("/Users/x/repo".into()),
            first_message: Some("hello".into()),
            tags: vec!["a".into(), "b".into()],
            created: None,
            modified: "2026-01-01T00:00:00Z".into(),
            archived_at: "2026-02-01T00:00:00Z".into(),
            orig_size: 100,
            compressed_size: 20,
        }
    }

    #[test]
    fn compress_decompress_roundtrip_is_byte_identical() {
        let dir = tempfile::tempdir().unwrap();
        let src = dir.path().join("s.json");
        let payload: Vec<u8> = (0..200_000u32).map(|i| (i % 251) as u8).collect();
        fs::write(&src, &payload).unwrap();
        let zst = dir.path().join("s.json.zst");
        let (orig, comp) = compress_file(&src, &zst, 19).unwrap();
        assert_eq!(orig, payload.len() as u64);
        assert!(comp > 0);
        let back = dir.path().join("s.back.json");
        decompress_file(&zst, &back).unwrap();
        assert_eq!(fs::read(&back).unwrap(), payload);
    }

    #[test]
    fn index_append_then_read_roundtrips() {
        let root = tempfile::tempdir().unwrap();
        append_entry(root.path(), "auggie", &sample_entry("11111111")).unwrap();
        append_entry(root.path(), "auggie", &sample_entry("22222222")).unwrap();
        let got = read_index(root.path(), "auggie");
        assert_eq!(got.len(), 2);
        assert_eq!(got[0], sample_entry("11111111"));
        assert_eq!(got[1].id, "22222222");
    }

    #[test]
    fn write_index_rewrites_and_can_drop_entries() {
        let root = tempfile::tempdir().unwrap();
        append_entry(root.path(), "auggie", &sample_entry("aaaa")).unwrap();
        append_entry(root.path(), "auggie", &sample_entry("bbbb")).unwrap();
        // drop "aaaa"
        let kept: Vec<ArchiveEntry> = read_index(root.path(), "auggie")
            .into_iter()
            .filter(|e| e.id != "aaaa")
            .collect();
        write_index(root.path(), "auggie", &kept).unwrap();
        let got = read_index(root.path(), "auggie");
        assert_eq!(got.len(), 1);
        assert_eq!(got[0].id, "bbbb");
    }

    #[test]
    fn read_all_indexes_spans_providers() {
        let root = tempfile::tempdir().unwrap();
        append_entry(root.path(), "auggie", &sample_entry("aa")).unwrap();
        let mut claude = sample_entry("cc");
        claude.provider = "claude".into();
        append_entry(root.path(), "claude", &claude).unwrap();
        let all = read_all_indexes(root.path());
        assert_eq!(all.len(), 2);
        assert!(all.iter().any(|e| e.provider == "claude"));
        assert!(all.iter().any(|e| e.provider == "auggie"));
    }

    #[test]
    fn compressed_path_shape() {
        let p = compressed_path(Path::new("/root"), "auggie", "abc", "json");
        assert_eq!(p, PathBuf::from("/root/auggie/abc.json.zst"));
    }
}
