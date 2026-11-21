//! Operator-configured client metadata; never inferred or fabricated.
//! Only a private, regular JSON file owned by the current process may enable it.
use std::{fs, io::{self, Read}, path::Path};

pub(crate) fn read_config(path: &Path) -> io::Result<String> {
    use std::os::unix::fs::{MetadataExt, PermissionsExt, OpenOptionsExt};
    let mut file = fs::OpenOptions::new().read(true).custom_flags(libc::O_NOFOLLOW).open(path)?;
    let metadata = file.metadata()?;
    if !metadata.is_file() || metadata.uid() != unsafe { libc::geteuid() }
        || metadata.permissions().mode() & 0o077 != 0 || metadata.len() > 2048 {
        return Err(io::Error::new(io::ErrorKind::PermissionDenied, "unsafe client-info file"));
    }
    let mut bytes = Vec::new();
    file.take(2049).read_to_end(&mut bytes)?;
    if bytes.len() > 2048 { return Err(io::Error::new(io::ErrorKind::InvalidData, "oversized metadata")); }
    let value: serde_json::Value = serde_json::from_slice(&bytes)?;
    let object = value.as_object().ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "object required"))?;
    if object.len() != 2 || !object.contains_key("client_info") || !object.contains_key("user_agent") {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "two fields required"));
    }
    for key in ["client_info", "user_agent"] {
        let v = object[key].as_str().ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "string required"))?;
        if v.is_empty() || v.len() > 512 || v.chars().any(char::is_control) {
            return Err(io::Error::new(io::ErrorKind::InvalidData, "invalid client metadata"));
        }
    }
    Ok(serde_json::to_string(&value).map_err(io::Error::other)?)
}

pub(crate) fn configured_response() -> Option<String> {
    let path = std::env::var_os("ZAG_ANISETTE_CLIENT_INFO_FILE")?;
    read_config(Path::new(&path)).ok()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rejects_missing_and_invalid() {
        assert!(read_config(Path::new("/nonexistent-zag-client-info")).is_err());
        let path = std::env::temp_dir().join(format!("zag-client-info-test-{}", std::process::id()));
        fs::write(&path, r#"{"client_info":"valid","user_agent":"test"}"#).unwrap();
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();
        assert!(read_config(&path).is_ok());
        fs::write(&path, r#"{"client_info":"","user_agent":"test"}"#).unwrap();
        assert!(read_config(&path).is_err());
        fs::set_permissions(&path, fs::Permissions::from_mode(0o644)).unwrap();
        assert!(read_config(&path).is_err());
        fs::remove_file(&path).unwrap();
    }
}
