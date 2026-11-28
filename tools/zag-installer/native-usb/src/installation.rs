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
    /// A separately signed release authorization is required by the caller.
    /// This value alone is not an authorization credential.
    pub authorization_verified: bool,
}

pub fn is_personal_team_bundle(bundle: &str) -> bool {
    let Some(team) = bundle.strip_prefix("app.zagstore.ios.") else { return false; };
    team.len() == 10 && team.bytes().all(|b| b.is_ascii_uppercase() || b.is_ascii_digit())
}

async fn installed(
    proxy: &mut InstallationProxyClient,
    bundle: &str,
) -> Result<Option<VersionStamp>, Box<dyn Error>> {
    // Collect all three broad Apple inventory sources AND the exact targeted
    // User/Any lookup. All must succeed, with cross-source conflicts rejected.
    // A zero-match result is not absolute proof of vacancy; it is only
    // sufficient to attempt a separately approved fresh install of this exact
    // mapped bundle. Installation Proxy must still reject a collision.
    let team = bundle.strip_prefix("app.zagstore.ios.")
        .ok_or("Unexpected destination bundle")?;
    let snapshot = inventory::inspect(proxy, Some(team)).await?;
    if !snapshot.targeted_checked {
        return Err("Targeted destination query did not complete".into());
    }
    Ok(snapshot.apps.get(bundle).map(|entry| VersionStamp {
        version: entry.version.clone(), build: entry.build.clone()
    }))
}

/// A fresh destination is represented as None; any different observed
/// version or newly appearing app must abort before writing further.
fn require_destination(expected: Option<&VersionStamp>, observed: Option<&VersionStamp>)
    -> Result<(), Box<dyn Error>>
{
    if expected != observed {
        return Err("Personal Team destination changed or is unexpectedly occupied".into());
    }
    Ok(())
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
    if !request.authorization_verified {
        return Err("Signed release authorization has not been verified".into());
    }
    let valid_version = |value: &str| !value.is_empty() && value.len() <= 64 &&
        value.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'.' || b == b'-' || b == b'_');
    if !valid_version(&request.expected.version) || !valid_version(&request.expected.build) {
        return Err("Invalid requested version or build".into());
    }
    let mut proxy = InstallationProxyClient::connect(provider).await?;
    let before = installed(&mut proxy, request.bundle).await?;
    require_destination(request.previous.as_ref(), before.as_ref())?;
    // The fresh path is restricted to an exact mapped bundle; the unrelated
    // legacy AppTesters copy is never uninstalled, upgraded, or overwritten.
    // The caller's explicit INSTALL approval must occur before reaching here.
    // This call verifies both local and remote SHA256 before returning.
    let remote = transfer::stage_and_verify(
        provider, request.ipa, request.job_token, request.sha256
    ).await?;
    let result: Result<VersionStamp, Box<dyn Error>> = async {
        let during = installed(&mut proxy, request.bundle).await?;
        require_destination(request.previous.as_ref(), during.as_ref())?;
        transfer::report_progress("installing", 0);
        let callback = |(percent, ())| async move {
            transfer::report_progress("installing", percent);
        };
        if request.previous.is_some() {
            proxy.upgrade_with_callback(remote, None, callback, ()).await?;
        } else {
            proxy.install_with_callback(remote, None, callback, ()).await?;
        }
        transfer::report_progress("readback", 0);
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
    fn native_install_request_requires_explicit_verified_authorization() {
        // An arbitrary IPA path and checksum are not sufficient evidence
        // of a verified signed release or a valid Apple signing profile.
        let request = AuthorizedInstall {
            ipa: std::path::Path::new("/tmp/unsigned.ipa"),
            sha256: [0; 32],
            job_token: "0123456789abcdef0123456789abcdef",
            bundle: "app.zagstore.ios.FTB8PRW638",
            expected: VersionStamp {version:"1.0.0".into(), build:"4".into()},
            previous: None,
            authorization_verified: false,
        };
        assert!(!request.authorization_verified);
    }
    #[test]
    fn destination_transition_rejects_unexpected_app_and_changed_upgrade() {
        let previous = VersionStamp {version:"1.0.0".into(),build:"3".into()};
        let newer = VersionStamp {version:"1.0.0".into(),build:"4".into()};
        // Fresh installs can proceed only while *both* inventory checks
        // continue to report no mapped destination.
        assert!(require_destination(None, None).is_ok());
        assert!(require_destination(None, Some(&previous)).is_err());
        // Upgrades require the original exact version/build at both checks.
        assert!(require_destination(Some(&previous), Some(&previous)).is_ok());
        assert!(require_destination(Some(&previous), Some(&newer)).is_err());
        assert!(require_destination(Some(&previous), None).is_err());
    }
    #[test]
    fn bundle_identifier_restricted_to_zag_personal_team() {
        assert!(is_personal_team_bundle("app.zagstore.ios.FTB8PRW638"));
        for bad in ["app.zagstore.ios", "app.zagstore.ios.BAD", "app.zagstore.ios.FTB8PRW638.extra",
            "app.zagstore.ios.0123456789/", "com.other.app.FTB8PRW638", "app.zagstore.ios.abcdefghij"] {
            assert!(!is_personal_team_bundle(bad));
        }
    }
}
