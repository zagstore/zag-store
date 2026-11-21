//! Operator-configured client metadata; never inferred or fabricated.
//!
//! The single source for both `/v3/client_info` (this server) and native
//! provisioning (tools/native-adi-loader-probe includes this file). Only a
//! private, regular JSON file owned by the current user may enable it:
//!
//! ```json
//! {"client_info": "<model> <os;version;build> <framework/version (process/version)>",
//!  "user_agent": "product/version ...",
//!  "provenance": {"source": "where this pair came from", "apple_verified": false}}
//! ```
//!
//! `provenance` is optional for compatibility with existing two-field files;
//! provisioning requires it. `apple_verified` is the operator's statement
//! that this exact pair was accepted by Apple; nothing here can check that.
//! Only `client_info` and `user_agent` are ever served to clients.
#![allow(dead_code)] // each including crate uses a different subset
use std::{fs, io::{self, Read}, path::Path};

const MAX_FILE_BYTES: u64 = 2048;

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Provenance { pub(crate) source: String, pub(crate) apple_verified: bool }

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct ClientMetadata {
    pub(crate) client_info: String,
    pub(crate) user_agent: String,
    pub(crate) provenance: Option<Provenance>,
}

fn invalid(message: &'static str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message)
}

/// Visible ASCII and single spaces only: a valid HTTP header value with no
/// control characters, no leading or trailing space.
fn header_text(value: &str, max: usize) -> bool {
    !value.is_empty() && value.len() <= max && value.bytes().all(|b| (0x20..0x7f).contains(&b))
        && !value.starts_with(' ') && !value.ends_with(' ') && !value.contains("  ")
}

/// `name/version`, both sides non-empty, no spaces or brackets.
fn product(token: &str) -> bool {
    token.split_once('/').is_some_and(|(name, version)| !name.is_empty() && !version.is_empty())
        && !token.contains([' ', '<', '>', '(', ')', ';'])
}

fn strip_apple(token: &str) -> &str { token.strip_prefix("com.apple.").unwrap_or(token) }

impl ClientMetadata {
    /// The platform field of client_info (`macOS`, `Windows`, ...).
    pub(crate) fn platform(&self) -> &str {
        self.client_info.split("> <").nth(1).and_then(|group| group.split(';').next()).unwrap_or("")
    }

    /// Checks the structure every known AuthKit client info shares,
    /// `<model> <platform;version;build> <framework/version (process/version)>`,
    /// and that the user agent's leading product names the same framework or
    /// process (`akd/1.0` with `(com.apple.akd/1.0)`), so the two headers
    /// describe one client.
    fn check(&self) -> io::Result<()> {
        if !header_text(&self.client_info, 512) || !header_text(&self.user_agent, 512) {
            return Err(invalid("client metadata must be printable ASCII header text"));
        }
        let inner = self.client_info.strip_prefix('<').and_then(|rest| rest.strip_suffix('>'))
            .ok_or_else(|| invalid("client_info must be three <...> groups"))?;
        let groups: Vec<&str> = inner.split("> <").collect();
        if groups.len() != 3 || groups.iter().any(|g| g.is_empty() || g.contains(['<', '>'])) {
            return Err(invalid("client_info must be three <...> groups"));
        }
        let platform: Vec<&str> = groups[1].split(';').collect();
        if platform.len() != 3 || platform.iter().any(|field| field.is_empty()) {
            return Err(invalid("client_info platform group must be platform;version;build"));
        }
        let (framework, process) = groups[2].strip_suffix(')').and_then(|g| g.split_once(" ("))
            .ok_or_else(|| invalid("client_info last group must be framework/version (process/version)"))?;
        if !product(framework) || !product(process) {
            return Err(invalid("client_info last group must be framework/version (process/version)"));
        }
        let lead = self.user_agent.split(' ').next().unwrap_or("");
        if !product(lead) {
            return Err(invalid("user_agent must start with product/version"));
        }
        if ![framework, process].iter().any(|token| strip_apple(token) == strip_apple(lead)) {
            return Err(invalid("user_agent does not name the client_info framework or process"));
        }
        if let Some(provenance) = &self.provenance {
            if provenance.source.trim().is_empty() || !header_text(&provenance.source, 300) {
                return Err(invalid("provenance source must be printable text"));
            }
        }
        Ok(())
    }

    /// The exact `/v3/client_info` body: only the two client fields.
    pub(crate) fn response_json(&self) -> String {
        serde_json::json!({"client_info": self.client_info, "user_agent": self.user_agent}).to_string()
    }

    /// The file form, as `parse` reads it.
    pub(crate) fn file_json(&self) -> String {
        let mut value = serde_json::json!({"client_info": self.client_info, "user_agent": self.user_agent});
        if let Some(provenance) = &self.provenance {
            value["provenance"] = serde_json::json!({"source": provenance.source, "apple_verified": provenance.apple_verified});
        }
        serde_json::to_string_pretty(&value).unwrap_or_default() + "\n"
    }
}

/// Schema and syntax only; `load` adds the file checks.
pub(crate) fn parse(bytes: &[u8]) -> io::Result<ClientMetadata> {
    let value: serde_json::Value = serde_json::from_slice(bytes).map_err(|_| invalid("metadata is not JSON"))?;
    let object = value.as_object().ok_or_else(|| invalid("object required"))?;
    if !object.contains_key("client_info") || !object.contains_key("user_agent")
        || !object.keys().all(|key| matches!(key.as_str(), "client_info" | "user_agent" | "provenance")) {
        return Err(invalid("client_info, user_agent and optional provenance required"));
    }
    let text = |key: &str| object[key].as_str().map(str::to_owned).ok_or_else(|| invalid("string required"));
    let provenance = match object.get("provenance") {
        None => None,
        Some(serde_json::Value::Object(p)) => {
            if p.len() != 2 || !p.contains_key("source") || !p.contains_key("apple_verified") {
                return Err(invalid("provenance requires exactly source and apple_verified"));
            }
            Some(Provenance {
                source: p["source"].as_str().ok_or_else(|| invalid("provenance source must be a string"))?.to_owned(),
                apple_verified: p["apple_verified"].as_bool().ok_or_else(|| invalid("apple_verified must be a boolean"))?,
            })
        }
        Some(_) => return Err(invalid("provenance must be an object")),
    };
    let metadata = ClientMetadata { client_info: text("client_info")?, user_agent: text("user_agent")?, provenance };
    metadata.check()?;
    Ok(metadata)
}

/// A private (owner-only, owned by this user), regular, non-symlink file.
pub(crate) fn load(path: &Path) -> io::Result<ClientMetadata> {
    use std::os::unix::fs::{MetadataExt, PermissionsExt, OpenOptionsExt};
    let file = fs::OpenOptions::new().read(true).custom_flags(libc::O_NOFOLLOW).open(path)?;
    let metadata = file.metadata()?;
    if !metadata.is_file() || metadata.uid() != unsafe { libc::geteuid() }
        || metadata.permissions().mode() & 0o077 != 0 {
        return Err(io::Error::new(io::ErrorKind::PermissionDenied, "unsafe client-info file"));
    }
    let mut bytes = Vec::new();
    file.take(MAX_FILE_BYTES + 1).read_to_end(&mut bytes)?;
    if bytes.len() as u64 > MAX_FILE_BYTES { return Err(invalid("oversized metadata")); }
    parse(&bytes)
}

/// The `/v3/client_info` body for a metadata file.
pub(crate) fn read_config(path: &Path) -> io::Result<String> {
    load(path).map(|metadata| metadata.response_json())
}

pub(crate) fn configured_response() -> Option<String> {
    let path = std::env::var_os("ZAG_ANISETTE_CLIENT_INFO_FILE")?;
    read_config(Path::new(&path)).ok()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    const MAC: &str = "<MacBookPro13,2> <macOS;13.1;22C65> <com.apple.AuthKit/1 (com.apple.akd/1.0)>";
    const WIN: &str = "<PC> <Windows;6.2(0,0);9200> <com.apple.AuthKitWin/7.3 (com.apple.iCloud/15.10.0.39)>";

    fn file(contents: &str, mode: u32) -> std::path::PathBuf {
        use std::sync::atomic::{AtomicU32, Ordering};
        static NEXT: AtomicU32 = AtomicU32::new(0);
        let path = std::env::temp_dir().join(format!(
            "zag-client-info-test-{}-{}", std::process::id(), NEXT.fetch_add(1, Ordering::Relaxed)));
        fs::write(&path, contents).unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(mode)).unwrap();
        path
    }

    #[test]
    fn served_response_is_exactly_the_two_client_fields() {
        // An existing two-field file keeps working unchanged.
        let legacy = file(&format!(r#"{{"client_info":"{MAC}","user_agent":"akd/1.0 CFNetwork/808.1.4"}}"#), 0o600);
        let with_provenance = file(&format!(
            r#"{{"client_info":"{MAC}","user_agent":"akd/1.0 CFNetwork/808.1.4","provenance":{{"source":"upstream","apple_verified":false}}}}"#), 0o600);
        let a: serde_json::Value = serde_json::from_str(&read_config(&legacy).unwrap()).unwrap();
        let b: serde_json::Value = serde_json::from_str(&read_config(&with_provenance).unwrap()).unwrap();
        assert_eq!(a, b);
        assert_eq!(a.as_object().unwrap().len(), 2);
        assert_eq!(a["client_info"], MAC);
        // The file form round-trips.
        let loaded = load(&with_provenance).unwrap();
        assert_eq!(parse(loaded.file_json().as_bytes()).unwrap(), loaded);
        for path in [legacy, with_provenance] { fs::remove_file(path).unwrap(); }
    }

    #[test]
    fn rejects_unsafe_files_and_inconsistent_or_placeholder_metadata() {
        assert!(load(Path::new("/nonexistent-zag-client-info")).is_err());
        let good = format!(r#"{{"client_info":"{MAC}","user_agent":"akd/1.0 CFNetwork/808.1.4"}}"#);
        for mode in [0o644, 0o640, 0o604] {
            let path = file(&good, mode);
            assert_eq!(load(&path).unwrap_err().kind(), io::ErrorKind::PermissionDenied);
            fs::remove_file(path).unwrap();
        }
        let ok = |client_info: &str, user_agent: &str| parse(serde_json::json!(
            {"client_info": client_info, "user_agent": user_agent}).to_string().as_bytes()).is_ok();
        assert!(ok(MAC, "akd/1.0 CFNetwork/808.1.4"));
        assert!(ok(WIN, "com.apple.AuthKitWin/7.3"));
        // Placeholders and malformed values never pass.
        assert!(!ok("offline-preflight-only", "offline-preflight-only/0"));
        assert!(!ok("", "akd/1.0"));
        assert!(!ok("<MacBookPro13,2> <macOS;13.1> <com.apple.AuthKit/1 (com.apple.akd/1.0)>", "akd/1.0"));
        assert!(!ok(&MAC.replace(" (com.apple.akd/1.0)", ""), "akd/1.0"));
        assert!(!ok(&format!("{MAC}\r\nX-Injected: 1"), "akd/1.0"));
        // The two headers must describe one client.
        assert!(!ok(MAC, "com.apple.AuthKitWin/7.3"));
        assert!(!ok(WIN, "akd/1.0 CFNetwork/808.1.4"));
        for extra in [r#","extra":1"#, r#","provenance":{"source":"x"}"#, r#","provenance":{"source":"","apple_verified":false}"#] {
            let text = good.replace('}', &format!("{extra}}}"));
            assert!(parse(text.as_bytes()).is_err(), "{text}");
        }
    }
}
