//! Client metadata workflow for native provisioning: inspecting possible
//! sources, preparing the one private file that both provisioning and the
//! server's `/v3/client_info` read, and checking a provisioned state against
//! it. Nothing here invents a value or contacts a network.
//!
//! Trust levels, as reported to the operator:
//!   verified    the file's provenance says Apple accepted this exact pair
//!               (an operator statement; it cannot be checked offline)
//!   unverified  well-formed and sourced, never confirmed against Apple
//!   unusable    malformed, unsafe permissions, or no metadata at all
#[path = "../../../client_info_config.rs"]
pub(crate) mod client_info_config;
pub(crate) use client_info_config::{ClientMetadata, Provenance};
use std::fs;
use std::io::{self, Read, Write};
use std::path::Path;

/// Sourced reference values (upstream code at a pinned commit). Always
/// unverified; using one is an explicit operator choice.
const CANDIDATES: &str = include_str!("../../client-metadata-candidates.json");
pub(crate) const RECORD: &str = "client-identity.json";
const MAX_SOURCE_BYTES: u64 = 4096;

fn invalid(message: &'static str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message)
}

/// SHA-256 of the exact `/v3/client_info` body: identifies the pair.
pub(crate) fn fingerprint(metadata: &ClientMetadata) -> String {
    crate::provisioning_client::sha256_hex(metadata.response_json().as_bytes())
}

pub(crate) struct Candidate { pub(crate) id: String, pub(crate) metadata: ClientMetadata, pub(crate) status: String }

pub(crate) fn candidates() -> io::Result<Vec<Candidate>> {
    let list: Vec<serde_json::Map<String, serde_json::Value>> =
        serde_json::from_str(CANDIDATES).map_err(|_| invalid("invalid embedded candidates"))?;
    list.into_iter().map(|entry| {
        let text = |key: &str| entry.get(key).and_then(|v| v.as_str()).map(str::to_owned)
            .ok_or_else(|| invalid("invalid embedded candidate"));
        let metadata = client_info_config::parse(serde_json::json!({
            "client_info": text("client_info")?, "user_agent": text("user_agent")?,
            "provenance": {"source": text("source")?, "apple_verified": false},
        }).to_string().as_bytes())?;
        Ok(Candidate { id: text("id")?, metadata, status: text("status")? })
    }).collect()
}

/// What a file can contribute. Never carries identity values.
pub(crate) enum Source {
    Metadata(ClientMetadata),
    /// A provisioned state's record: the pair it was provisioned with.
    State(ClientMetadata),
    /// An identity file; its own client fields, if it has any.
    Identity(Option<ClientMetadata>),
}

/// Reads a private source file without following a symlink.
fn read_private(path: &Path) -> io::Result<Vec<u8>> {
    use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
    let file = fs::OpenOptions::new().read(true).custom_flags(libc::O_NOFOLLOW).open(path)?;
    let metadata = file.metadata()?;
    if !metadata.is_file() || metadata.uid() != unsafe { libc::geteuid() } || metadata.mode() & 0o077 != 0 {
        return Err(io::Error::new(io::ErrorKind::PermissionDenied, "not a private regular file owned by this user"));
    }
    let mut bytes = Vec::new();
    file.take(MAX_SOURCE_BYTES + 1).read_to_end(&mut bytes)?;
    if bytes.len() as u64 > MAX_SOURCE_BYTES { return Err(invalid("oversized source file")); }
    Ok(bytes)
}

/// Pulls client_info/user_agent (and the record's provenance) out of a
/// record or identity object, as a metadata value.
fn embedded(object: &serde_json::Map<String, serde_json::Value>, provenance: Option<Provenance>) -> io::Result<ClientMetadata> {
    let mut value = serde_json::json!({"client_info": object.get("client_info"), "user_agent": object.get("user_agent")});
    if let Some(p) = provenance { value["provenance"] = serde_json::json!({"source": p.source, "apple_verified": p.apple_verified}); }
    client_info_config::parse(value.to_string().as_bytes())
}

pub(crate) fn inspect(path: &Path) -> io::Result<Source> {
    let bytes = read_private(path)?;
    let value: serde_json::Value = serde_json::from_slice(&bytes).map_err(|_| invalid("not JSON"))?;
    let object = value.as_object().ok_or_else(|| invalid("not a JSON object"))?;
    let has = |key: &str| object.contains_key(key);
    if has("device_id") && has("local_user") && has("android_identifier") {
        let provenance = match (object.get("metadata_source").and_then(|v| v.as_str()),
                                object.get("metadata_apple_verified").and_then(|v| v.as_bool())) {
            (Some(source), Some(apple_verified)) => Some(Provenance { source: source.to_owned(), apple_verified }),
            _ => None,
        };
        let metadata = embedded(object, provenance)?;
        if object.get("metadata_sha256").and_then(|v| v.as_str()) != Some(fingerprint(&metadata).as_str()) {
            return Err(invalid("state record fingerprint does not match its client metadata"));
        }
        Ok(Source::State(metadata))
    } else if has("device_id") && has("local_user") {
        let blank = |key: &str| object.get(key).and_then(|v| v.as_str()).map_or(true, str::is_empty);
        if blank("client_info") && blank("user_agent") { return Ok(Source::Identity(None)); }
        embedded(object, Some(Provenance { source: "identity file".into(), apple_verified: false }))
            .map(|m| Source::Identity(Some(m)))
    } else {
        client_info_config::load(path).map(Source::Metadata)
    }
}

/// One report line for a source; never includes identity values.
pub(crate) fn describe(metadata: &ClientMetadata) -> String {
    let (trust, source) = match &metadata.provenance {
        Some(p) if p.apple_verified => ("verified", p.source.as_str()),
        Some(p) => ("unverified", p.source.as_str()),
        None => ("unverified", "provenance not recorded"),
    };
    format!("{trust} platform={} fingerprint={} source=\"{source}\"", metadata.platform(), &fingerprint(metadata)[..12])
}

/// Writes `metadata` (with provenance) to a new private file. Never
/// overwrites: an existing configuration is replaced only by the operator.
pub(crate) fn prepare(out: &Path, metadata: &ClientMetadata) -> io::Result<()> {
    use std::os::unix::fs::OpenOptionsExt;
    if metadata.provenance.is_none() { return Err(invalid("provenance is required")); }
    let text = metadata.file_json();
    client_info_config::parse(text.as_bytes())?;
    let mut file = fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(out)?;
    file.write_all(text.as_bytes())?;
    file.sync_all()?;
    // The written file must load exactly as provisioning will read it.
    if client_info_config::load(out)? != *metadata {
        let _ = fs::remove_file(out);
        return Err(invalid("prepared file does not read back identically"));
    }
    Ok(())
}

/// Refuses a provisioned state that was made with other client metadata:
/// headers from the configured pair would not belong to that state.
pub(crate) fn check_state(state_dir: &Path, configured: &ClientMetadata) -> io::Result<()> {
    match inspect(&state_dir.join(RECORD))? {
        Source::State(recorded) if fingerprint(&recorded) == fingerprint(configured) => Ok(()),
        Source::State(_) => Err(invalid("state was provisioned with different client metadata")),
        _ => Err(invalid("not a provisioned state record")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    fn dir() -> std::path::PathBuf {
        use std::sync::atomic::{AtomicU32, Ordering};
        static NEXT: AtomicU32 = AtomicU32::new(0);
        let dir = std::env::temp_dir().join(format!("zag-adi-metadata-{}-{}", std::process::id(), NEXT.fetch_add(1, Ordering::Relaxed)));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir(&dir).unwrap();
        fs::set_permissions(&dir, fs::Permissions::from_mode(0o700)).unwrap();
        dir
    }
    fn private(path: &Path, text: &str) {
        fs::write(path, text).unwrap();
        fs::set_permissions(path, fs::Permissions::from_mode(0o600)).unwrap();
    }

    #[test]
    fn embedded_candidates_are_sourced_valid_and_unverified() {
        let list = candidates().unwrap();
        assert!(!list.is_empty());
        for candidate in list {
            let provenance = candidate.metadata.provenance.as_ref().unwrap();
            assert!(!provenance.apple_verified);
            assert!(provenance.source.contains('@'), "pinned source required");
            assert!(candidate.status.contains("not verified"));
        }
    }

    #[test]
    fn prepared_file_serves_and_provisions_the_same_pair_and_is_never_overwritten() {
        let root = dir();
        let candidate = candidates().unwrap().remove(0);
        let out = root.join("client-info.json");
        prepare(&out, &candidate.metadata).unwrap();
        assert_eq!(fs::metadata(&out).unwrap().permissions().mode() & 0o777, 0o600);
        // /v3/client_info and provisioning read the same file to the same pair.
        let served: serde_json::Value = serde_json::from_str(&client_info_config::read_config(&out).unwrap()).unwrap();
        let loaded = client_info_config::load(&out).unwrap();
        assert_eq!(served, serde_json::json!({"client_info": loaded.client_info, "user_agent": loaded.user_agent}));
        assert_eq!(loaded, candidate.metadata);
        assert!(matches!(inspect(&out).unwrap(), Source::Metadata(m) if m == candidate.metadata));
        assert_eq!(prepare(&out, &candidate.metadata).unwrap_err().kind(), io::ErrorKind::AlreadyExists);
        let mut unsourced = candidate.metadata.clone();
        unsourced.provenance = None;
        assert!(prepare(&root.join("other.json"), &unsourced).is_err());
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn sources_are_classified_without_trusting_unsafe_or_inconsistent_files() {
        let root = dir();
        let metadata = candidates().unwrap().remove(0).metadata;
        // Identity files: blank placeholders hold no metadata.
        let identity = root.join("identity.json");
        private(&identity, r#"{"device_id":"d","local_user":"l","client_info":"","serial":""}"#);
        assert!(matches!(inspect(&identity).unwrap(), Source::Identity(None)));
        // A state record must carry the fingerprint of its own pair.
        let state = root.join("state");
        fs::create_dir(&state).unwrap();
        let mut record = serde_json::json!({
            "device_id": "d", "local_user": "l", "android_identifier": "A", "ds_id": -2,
            "client_info": metadata.client_info, "user_agent": metadata.user_agent,
            "metadata_sha256": fingerprint(&metadata), "metadata_source": "s", "metadata_apple_verified": false,
        });
        private(&state.join(RECORD), &record.to_string());
        assert!(matches!(inspect(&state.join(RECORD)).unwrap(), Source::State(_)));
        check_state(&state, &metadata).unwrap();
        let mut other = metadata.clone();
        other.user_agent = "akd/1.0 CFNetwork/1404.0.5 Darwin/22.3.0".into();
        assert!(check_state(&state, &other).is_err(), "mismatch must be refused");
        record["user_agent"] = other.user_agent.clone().into();
        private(&state.join(RECORD), &record.to_string());
        assert!(inspect(&state.join(RECORD)).is_err(), "edited record must be refused");
        // Readable by others or a symlink: never trusted.
        fs::set_permissions(&identity, fs::Permissions::from_mode(0o644)).unwrap();
        assert_eq!(inspect(&identity).err().unwrap().kind(), io::ErrorKind::PermissionDenied);
        std::os::unix::fs::symlink(&state.join(RECORD), root.join("link.json")).unwrap();
        assert!(inspect(&root.join("link.json")).is_err());
        fs::remove_dir_all(root).unwrap();
    }
}
