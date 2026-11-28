//! Native application-container transport for Zag Store's existing encrypted
//! signing setup protocol. Deliberately not exposed in the executable CLI.
//!
//! House Arrest may deny access to a Personal Team app on newer iOS versions;
//! these operations return errors rather than falling back to another app's
//! container or to a host-side copy of the signing key.
use std::error::Error;
use idevice::{IdeviceService, house_arrest::HouseArrestClient,
    afc::{AfcClient, opcode::AfcFopenMode}, provider::IdeviceProvider};
use sha2::{Digest, Sha256};

const MAX_WIRE: usize = 24 * 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Message {
    ManualRequest,
    ManualResponse,
    SetupBootstrap,
    SetupRequest,
    SetupResponse,
    SetupAcknowledgement,
}

impl Message {
    pub fn path(self) -> &'static str {
        match self {
            Self::ManualRequest => "Documents/ZagIdentityHandoffRequest.json",
            Self::ManualResponse => "Documents/ZagIdentityHandoffResponse.json",
            Self::SetupBootstrap => "Library/Caches/ZagSetupBootstrap.json",
            Self::SetupRequest => "Library/Caches/ZagSetupRequest.json",
            Self::SetupResponse => "Library/Caches/ZagSetupResponse.json",
            Self::SetupAcknowledgement => "Library/Caches/ZagSetupAcknowledgement.json",
        }
    }

    pub fn from_read_path(path: &str) -> Result<Self, Box<dyn Error>> {
        match path {
            "Documents/ZagIdentityHandoffRequest.json" => Ok(Self::ManualRequest),
            "Library/Caches/ZagSetupRequest.json" => Ok(Self::SetupRequest),
            "Library/Caches/ZagSetupAcknowledgement.json" => Ok(Self::SetupAcknowledgement),
            _ => Err("This file is not a permitted inbound signing handoff message".into()),
        }
    }
    pub fn from_write_path(path: &str) -> Result<Self, Box<dyn Error>> {
        match path {
            "Documents/ZagIdentityHandoffResponse.json" => Ok(Self::ManualResponse),
            "Library/Caches/ZagSetupBootstrap.json" => Ok(Self::SetupBootstrap),
            "Library/Caches/ZagSetupResponse.json" => Ok(Self::SetupResponse),
            _ => Err("This file is not a permitted outbound signing handoff message".into()),
        }
    }
}

fn check_bundle(bundle: &str) -> Result<(), Box<dyn Error>> {
    if !crate::installation::is_personal_team_bundle(bundle) {
        return Err("App-container I/O requires an exact Zag Store Personal Team bundle".into());
    }
    Ok(())
}

async fn container(
    provider: &dyn IdeviceProvider, bundle: &str
) -> Result<AfcClient, Box<dyn Error>> {
    check_bundle(bundle)?;
    let arrest = HouseArrestClient::connect(provider).await?;
    Ok(arrest.vend_container(bundle.to_owned()).await?)
}

/// Read only a protocol-whitelisted request. Returned bytes remain private to
/// the caller and must still be authenticated by handoff.py before use.
#[allow(dead_code)]
pub async fn read_message(
    provider: &dyn IdeviceProvider, bundle: &str, remote: &str
) -> Result<Vec<u8>, Box<dyn Error>> {
    let path = Message::from_read_path(remote)?.path();
    let mut afc = container(provider, bundle).await?;
    let metadata = afc.get_file_info(path).await?;
    if metadata.st_ifmt != "S_IFREG" || metadata.st_link_target.is_some()
        || metadata.size == 0 || metadata.size > MAX_WIRE {
        return Err("Invalid or oversized iPhone handoff file".into());
    }
    let mut file = afc.open(path, AfcFopenMode::RdOnly).await?;
    let mut result = Vec::with_capacity(metadata.size);
    while result.len() < metadata.size {
        let bytes = file.read_n(metadata.size - result.len()).await?;
        if bytes.is_empty() { return Err("Truncated iPhone handoff message".into()); }
        if result.len() + bytes.len() > MAX_WIRE {
            return Err("Oversized iPhone handoff message".into());
        }
        result.extend_from_slice(&bytes);
    }
    file.close().await?;
    Ok(result)
}

/// Write only an already encrypted/authenticated protocol envelope. The
/// caller (handoff.py) must validate request identity, freshness, receipt,
/// certificate ownership and exact user approval before invoking this method.
/// The native transport never handles or persists plaintext private keys.
#[allow(dead_code)]
pub async fn write_envelope(
    provider: &dyn IdeviceProvider, bundle: &str, remote: &str,
    ciphertext: &[u8],
) -> Result<[u8;32], Box<dyn Error>> {
    let path = Message::from_write_path(remote)?.path();
    if ciphertext.is_empty() || ciphertext.len() > MAX_WIRE {
        return Err("Invalid encrypted handoff envelope size".into());
    }
    let mut afc = container(provider, bundle).await?;
    if let Ok(meta) = afc.get_file_info(path).await {
        if meta.st_ifmt != "S_IFREG" || meta.st_link_target.is_some() {
            return Err("Refusing to overwrite nonregular or linked handoff file".into());
        }
    }
    let mut file = afc.open(path, AfcFopenMode::WrOnly).await?;
    file.write_entire(ciphertext).await?;
    file.close().await?;
    let info = afc.get_file_info(path).await?;
    if info.st_ifmt != "S_IFREG" || info.st_link_target.is_some() ||
        info.size != ciphertext.len() {
        return Err("Encrypted handoff delivery size mismatch".into());
    }
    let mut written = afc.open(path, AfcFopenMode::RdOnly).await?;
    let mut contents = Vec::with_capacity(info.size);
    while contents.len() < info.size {
        let chunk = written.read_n(info.size - contents.len()).await?;
        if chunk.is_empty() { return Err("Encrypted handoff readback truncated".into()); }
        contents.extend_from_slice(&chunk);
    }
    written.close().await?;
    let expected: [u8;32] = Sha256::digest(ciphertext).into();
    let actual: [u8;32] = Sha256::digest(&contents).into();
    if actual != expected {
        return Err("Encrypted handoff delivery digest mismatch".into());
    }
    Ok(actual)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn only_existing_handoff_paths_are_supported() {
        for name in ["Documents/ZagIdentityHandoffRequest.json",
                     "Library/Caches/ZagSetupRequest.json",
                     "Library/Caches/ZagSetupAcknowledgement.json"] {
            assert!(Message::from_read_path(name).is_ok());
            assert!(Message::from_write_path(name).is_err());
        }
        for name in ["Documents/ZagIdentityHandoffResponse.json",
                     "Library/Caches/ZagSetupBootstrap.json",
                     "Library/Caches/ZagSetupResponse.json"] {
            assert!(Message::from_write_path(name).is_ok());
            assert!(Message::from_read_path(name).is_err());
        }
    }
    #[test]
    fn traversal_other_app_and_plaintext_key_paths_are_blocked() {
        for path in ["../Documents/ZagIdentityHandoffRequest.json",
                     "/Library/Caches/ZagSetupBootstrap.json",
                     "Library/Caches/key.pem",
                     "Documents/ZagIdentityHandoffRequest.json/../../secret",
                     "Library/Caches/ZagSetupResponse.json\0evil"] {
            assert!(Message::from_read_path(path).is_err());
            assert!(Message::from_write_path(path).is_err());
        }
        assert!(check_bundle("com.cwd43.gu29").is_err());
        assert!(check_bundle("com.other.app").is_err());
        assert!(check_bundle("app.zagstore.ios.FTB8PRW638").is_ok());
    }
}
