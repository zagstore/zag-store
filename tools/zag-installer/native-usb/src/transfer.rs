//! Native IPA staging. Not exposed by the preview CLI.
use idevice::{IdeviceService, afc::{AfcClient, opcode::AfcFopenMode}, provider::IdeviceProvider};
use sha2::{Digest, Sha256};
use tokio::io::AsyncReadExt;
use std::path::Path;

const MAX_IPA: u64 = 512 * 1024 * 1024;
const CHUNK: usize = 256 * 1024;

pub(crate) fn valid_token(token: &str) -> bool {
    token.len() == 32 && token.bytes().all(|b| b.is_ascii_hexdigit())
}

#[allow(dead_code)]
pub async fn stage_and_verify(provider: &dyn IdeviceProvider, local: &Path,
    token: &str, expected: [u8; 32]) -> Result<String, Box<dyn std::error::Error>> {
    if !valid_token(token) { return Err("Invalid staging token".into()); }
    let metadata = tokio::fs::symlink_metadata(local).await?;
    if !metadata.is_file() || metadata.len() == 0 || metadata.len() > MAX_IPA {
        return Err("Invalid IPA source".into());
    }
    let mut source = tokio::fs::File::open(local).await?;
    let mut afc = AfcClient::connect(provider).await?;
    // Create AFC's public staging root only when absent. This must be
    // provisioned separately from our per-job exclusive directory.
    if afc.get_file_info("PublicStaging").await.is_err() {
        afc.mk_dir("PublicStaging").await?;
    }
    let directory = format!("PublicStaging/zag-{token}");
    // Exclusive directory creation; never overwrite an existing staging job.
    afc.mk_dir(&directory).await?;
    let remote = format!("{directory}/package.ipa");
    let result: Result<(), Box<dyn std::error::Error>> = async {
        let mut file = afc.open(&remote, AfcFopenMode::WrOnly).await?;
        let mut buf = vec![0; CHUNK];
        let mut digest = Sha256::new();
        let mut total = 0u64;
        loop {
            let n = source.read(&mut buf).await?;
            if n == 0 { break; }
            total += n as u64;
            if total > metadata.len() { return Err("IPA changed during transfer".into()); }
            digest.update(&buf[..n]);
            file.write_entire(&buf[..n]).await?;
        }
        file.close().await?;
        if total != metadata.len() || <[u8;32]>::from(digest.finalize()) != expected {
            return Err("Source IPA integrity mismatch".into());
        }
        let info = afc.get_file_info(&remote).await?;
        if info.size as u64 != total || info.st_ifmt != "S_IFREG" {
            return Err("Remote IPA metadata mismatch".into());
        }
        let mut file = afc.open(&remote, AfcFopenMode::RdOnly).await?;
        let mut digest = Sha256::new();
        let mut remaining = total;
        while remaining > 0 {
            let bytes = file.read_n(remaining.min(CHUNK as u64) as usize).await?;
            if bytes.is_empty() || bytes.len() as u64 > remaining {
                return Err("Remote IPA readback length mismatch".into());
            }
            remaining -= bytes.len() as u64;
            digest.update(&bytes);
        }
        file.close().await?;
        if <[u8;32]>::from(digest.finalize()) != expected {
            return Err("Remote IPA integrity mismatch".into());
        }
        Ok(())
    }.await;
    if let Err(error) = result {
        // Only clean our own newly created staging directory.
        let _ = afc.remove(&remote).await;
        let _ = afc.remove(&directory).await;
        return Err(error);
    }
    Ok(remote)
}

/// Clean up only our job-specific directory, never the global PublicStaging root.
/// The installation service may already have removed the package; both cases
/// are accepted. Caller uses an unguessable 32-digit random staging token.
#[allow(dead_code)]
pub async fn cleanup_stage(
    provider: &dyn IdeviceProvider,
    token: &str,
) -> Result<(), Box<dyn std::error::Error>> {
    if !valid_token(token) { return Err("Invalid staging token".into()); }
    let mut afc = AfcClient::connect(provider).await?;
    let directory = format!("PublicStaging/zag-{token}");
    let file = format!("{directory}/package.ipa");
    if afc.get_file_info(&file).await.is_ok() {
        afc.remove(&file).await?;
    }
    if afc.get_file_info(&directory).await.is_ok() {
        afc.remove(&directory).await?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn staging_token_is_strict() {
        assert!(valid_token("0123456789abcdef0123456789abcdef"));
        for bad in ["", "../other", "0123456789abcdef0123456789abcdeg"] {
            assert!(!valid_token(bad));
        }
    }
}
