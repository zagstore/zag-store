//! Zag Store fork: every connection this crate makes passes through here.
//!
//! - Live network access is compiled out unless the `live-network` feature
//!   is enabled. Zag Store does not enable it without the owner's approval.
//! - Only https (or wss for the anisette socket) to an allowlisted host on
//!   the default port; no credentials in URLs; redirects are not followed.
//! - Certificates are always verified: no switch exists to turn that off.

use reqwest::{ClientBuilder, Url, redirect};
use reqwest_middleware::{ClientBuilder as MwClientBuilder, ClientWithMiddleware, Middleware, Next};
use rootcause::prelude::*;

/// True only in a build that explicitly enables the `live-network` feature.
pub const LIVE_NETWORK: bool = cfg!(feature = "live-network");

/// Apple's hosts the retained sign-in and developer-portal code uses.
pub const APPLE_HOSTS: &[&str] = &["gsa.apple.com", "developerservices2.apple.com"];

pub fn apple_hosts() -> Vec<String> {
    APPLE_HOSTS.iter().map(|host| host.to_string()).collect()
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum PolicyError {
    #[error("Live network access is disabled in this build")]
    Disabled,
    #[error("Refused: the URL is not a secure URL")]
    NotSecure,
    #[error("Refused: the host is not on the allowlist")]
    HostNotAllowed,
    #[error("Refused: the URL is not valid")]
    InvalidUrl,
}

/// Checks a URL against the policy without the live-network switch, so the
/// allowlist itself can be tested in a build that cannot connect.
pub fn check_url(url: &Url, allowed: &[String], scheme: &str) -> Result<(), PolicyError> {
    if url.scheme() != scheme {
        return Err(PolicyError::NotSecure);
    }
    if !url.username().is_empty() || url.password().is_some() {
        return Err(PolicyError::InvalidUrl);
    }
    if url.port().is_some() {
        return Err(PolicyError::HostNotAllowed);
    }
    let Some(host) = url.host_str() else {
        return Err(PolicyError::InvalidUrl);
    };
    if allowed.iter().any(|allowed| allowed.eq_ignore_ascii_case(host)) {
        Ok(())
    } else {
        Err(PolicyError::HostNotAllowed)
    }
}

/// The full check made before any request or socket connection.
pub fn permit(url: &Url, allowed: &[String], scheme: &str) -> Result<(), PolicyError> {
    if !LIVE_NETWORK {
        return Err(PolicyError::Disabled);
    }
    check_url(url, allowed, scheme)
}

/// The host of an https URL, which then becomes that client's only host.
pub fn host_of(url: &str) -> Result<String, Report> {
    let parsed = Url::parse(url).map_err(|_| report!(PolicyError::InvalidUrl))?;
    if parsed.scheme() != "https" {
        bail!(PolicyError::NotSecure);
    }
    match parsed.host_str() {
        Some(host) => Ok(host.to_string()),
        None => bail!(PolicyError::InvalidUrl),
    }
}

/// Adds the policy to an HTTP client: https only, no redirects, and the
/// allowlist checked on every request.
pub fn guarded_client(builder: ClientBuilder, allowed: Vec<String>) -> Result<ClientWithMiddleware, Report> {
    let client = builder
        .https_only(true)
        .redirect(redirect::Policy::none())
        .build()?;
    Ok(MwClientBuilder::new(client).with(Guard { allowed }).build())
}

struct Guard {
    allowed: Vec<String>,
}

#[async_trait::async_trait]
impl Middleware for Guard {
    async fn handle(
        &self,
        req: reqwest::Request,
        extensions: &mut http::Extensions,
        next: Next<'_>,
    ) -> reqwest_middleware::Result<reqwest::Response> {
        permit(req.url(), &self.allowed, "https").map_err(reqwest_middleware::Error::middleware)?;
        next.run(req, extensions).await
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn url(s: &str) -> Url {
        Url::parse(s).unwrap()
    }

    #[test]
    fn disabled_without_the_feature() {
        if !LIVE_NETWORK {
            assert_eq!(permit(&url("https://gsa.apple.com/x"), &apple_hosts(), "https"), Err(PolicyError::Disabled));
        }
    }

    #[test]
    fn allowlist() {
        let apple = apple_hosts();
        assert_eq!(check_url(&url("https://gsa.apple.com/grandslam"), &apple, "https"), Ok(()));
        assert_eq!(check_url(&url("https://GSA.apple.com/"), &apple, "https"), Ok(()));
        assert_eq!(check_url(&url("https://developerservices2.apple.com/services"), &apple, "https"), Ok(()));
        assert_eq!(check_url(&url("http://gsa.apple.com/"), &apple, "https"), Err(PolicyError::NotSecure));
        assert_eq!(check_url(&url("https://gsa.apple.com.example.com/"), &apple, "https"), Err(PolicyError::HostNotAllowed));
        assert_eq!(check_url(&url("https://evil.example/"), &apple, "https"), Err(PolicyError::HostNotAllowed));
        assert_eq!(check_url(&url("https://gsa.apple.com:8443/"), &apple, "https"), Err(PolicyError::HostNotAllowed));
        assert_eq!(check_url(&url("https://user:pw@gsa.apple.com/"), &apple, "https"), Err(PolicyError::InvalidUrl));
        let anisette = vec!["anisette.example".to_string()];
        assert_eq!(check_url(&url("wss://anisette.example/v3/x"), &anisette, "wss"), Ok(()));
        assert_eq!(check_url(&url("ws://anisette.example/v3/x"), &anisette, "wss"), Err(PolicyError::NotSecure));
        assert!(host_of("http://anisette.example").is_err());
        assert_eq!(host_of("https://anisette.example").unwrap(), "anisette.example");
    }
}
