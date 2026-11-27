//! Installation Proxy integration behind a deliberately inactive CLI boundary.
//!
//! This module accepts only an already-validated signed Zag Store IPA. The
//! Python signer verifies profile, executable signature, certificate ownership,
//! bundle, version and build BEFORE this function can be called in production.
//! No install command is exported by the current zag-usb CLI.
use std::{error::Error, path::Path};
use idevice::{IdeviceService, installation_proxy::InstallationProxyClient, provider::IdeviceProvider};
use crate::inventory;

use crate::transfer;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VersionStamp {
    pub version: String,
    pub build: String,
}

#[derive(Debug, Clone)]
pub struct AuthorizedInstall<'a> {
    pub ipa: &'a Path,
    pub sha256: [u8; 32],
    pub job_token: &'a str,
    pub bundle: &'a str,
    pub expected: VersionStamp,
    /// None -> fresh install. Some -> upgrade exact prior version/build.
    pub previous: Option<VersionStamp>,
}

pub fn is_personal_team_bundle(bundle: &str) -> bool {
    let Some(team) = bundle.strip_prefix("app.zagstore.ios.") else { return false; };
    team.len() == 10 && team.bytes().all(|b| b.is_ascii_uppercase() || b.is_ascii_digit())
}

async fn installed(
    proxy: &mut InstallationProxyClient,
    bundle: &str,
) -> Result<Option<VersionStamp>, Box<dyn Error>> {
    let snapshot = inventory::inspect(proxy).await?;
    // This union is cross-checked across Lookup(User), Lookup(Any), and Browse.
    Ok(snapshot.apps.get(bundle).map(|app| VersionStamp {
        version: app.version.clone(), build: app.build.clone()
    }))
}

/// Verified IPA staging, exact destination checks, install/upgrade, and
/// independent readback. This function CAN modify an iPhone, so it is kept
/// unexposed until end-to-end verification and explicit user opt-in.
#[allow(dead_code)]
pub async fn install_authorized(
    provider: &dyn IdeviceProvider,
    request: &AuthorizedInstall<'_>,
) -> Result<VersionStamp, Box<dyn Error>> {
    if !is_personal_team_bundle(request.bundle) {
        return Err("Only a mapped Zag Store Personal Team bundle is allowed".into());
    }
    let valid_version = |value: &str| !value.is_empty() && value.len() <= 64 &&
        value.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'.' || b == b'-' || b == b'_');
    if !valid_version(&request.expected.version) || !valid_version(&request.expected.build) {
        return Err("Invalid requested version or build".into());
    }
    let mut proxy = InstallationProxyClient::connect(provider).await?;
    if installed(&mut proxy, request.bundle).await? != request.previous {
        return Err("Destination inventory changed before installation".into());
    }
    // This call verifies both local and remote SHA256 before returning.
    let remote = transfer::stage_and_verify(
        provider, request.ipa, request.job_token, request.sha256
    ).await?;
    let result: Result<VersionStamp, Box<dyn Error>> = async {
        if installed(&mut proxy, request.bundle).await? != request.previous {
            return Err("Destination inventory changed during transfer".into());
        }
        if request.previous.is_some() {
            proxy.upgrade(remote, None).await?;
        } else {
            proxy.install(remote, None).await?;
        }
        let observed = installed(&mut proxy, request.bundle).await?;
        if observed.as_ref() != Some(&request.expected) {
            return Err("Installation completed without matching bundle version and build".into());
        }
        observed.ok_or_else(|| "Installed Zag Store app is missing".into())
    }.await;
    let cleanup = transfer::cleanup_stage(provider, request.job_token).await;
    match (result, cleanup) {
        (Ok(v), Ok(())) => Ok(v),
        (Ok(_), Err(_)) => Err("Installation succeeded but staging cleanup requires attention".into()),
        (Err(err), _) => Err(err),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn bundle_identifier_restricted_to_zag_personal_team() {
        assert!(is_personal_team_bundle("app.zagstore.ios.FTB8PRW638"));
        for bad in ["app.zagstore.ios", "app.zagstore.ios.BAD", "app.zagstore.ios.FTB8PRW638.extra",
            "app.zagstore.ios.0123456789/", "com.other.app.FTB8PRW638", "app.zagstore.ios.abcdefghij"] {
            assert!(!is_personal_team_bundle(bad));
        }
    }
}
