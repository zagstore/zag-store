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
        let url = req.url().clone();
        permit_observed(&url, &self.allowed, "https", req.method().as_str()).map_err(reqwest_middleware::Error::middleware)?;
        let response = next.run(req, extensions).await?;
        if let (Some(host), Some(date)) = (url.host_str(), response.headers().get(http::header::DATE)) {
            observe::note_server_date(host, date.to_str().unwrap_or(""));
        }
        Ok(response)
    }
}

/// The same check as `permit`, with the decision recorded for Zag Store's
/// experiment diagnostics (`observe`). The decision is made first and is not
/// changed by recording it.
pub fn permit_observed(url: &Url, allowed: &[String], scheme: &str, method: &str) -> Result<(), PolicyError> {
    let decision = permit(url, allowed, scheme);
    observe::record(url, scheme, method, &decision);
    decision
}

/// Zag Store G5: observation only. Each policy decision (host, path without
/// the query, method, allowed or the refusal) is queued for the experiment's
/// typed diagnostic log, which templates paths and never logs queries or
/// bodies; and the `Date` header of the latest response from an Apple host
/// (received over verified TLS) is kept as the authenticated time the
/// experiment checks its authorisation window against. Nothing here takes
/// part in deciding whether a request is allowed.
pub mod observe {
    use std::collections::VecDeque;
    use std::sync::Mutex;
    use std::sync::atomic::{AtomicI64, Ordering};

    use reqwest::Url;

    use super::{APPLE_HOSTS, PolicyError};

    #[derive(Debug, Clone, PartialEq, Eq)]
    pub struct Decision {
        pub host: String,
        pub path: String,
        pub method: String,
        pub scheme: String,
        pub allowed: bool,
        pub reason: Option<&'static str>,
    }

    const CAPACITY: usize = 256;
    static DECISIONS: Mutex<VecDeque<Decision>> = Mutex::new(VecDeque::new());
    static LAST_APPLE_DATE: AtomicI64 = AtomicI64::new(0);

    /// Recording happens only in a live-network build (and the crate's own
    /// tests); every other build keeps nothing.
    const RECORDS: bool = super::LIVE_NETWORK || cfg!(test);

    pub(super) fn record(url: &Url, scheme: &str, method: &str, decision: &Result<(), PolicyError>) {
        if !RECORDS {
            return;
        }
        let reason = match decision {
            Ok(()) => None,
            Err(PolicyError::Disabled) => Some("disabled"),
            Err(PolicyError::NotSecure) => Some("notSecure"),
            Err(PolicyError::HostNotAllowed) if url.port().is_some() => Some("portInURL"),
            Err(PolicyError::HostNotAllowed) => Some("hostNotAllowed"),
            Err(PolicyError::InvalidUrl) if !url.username().is_empty() || url.password().is_some() => Some("credentialsInURL"),
            Err(PolicyError::InvalidUrl) => Some("invalidURL"),
        };
        let entry = Decision {
            host: url.host_str().unwrap_or("").to_ascii_lowercase(),
            path: url.path().to_string(),
            method: method.to_ascii_uppercase(),
            scheme: scheme.to_string(),
            allowed: decision.is_ok(),
            reason,
        };
        let mut queue = DECISIONS.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        if queue.len() == CAPACITY {
            queue.pop_front();
        }
        queue.push_back(entry);
    }

    /// Every decision recorded since the last call, oldest first.
    pub fn take() -> Vec<Decision> {
        let mut queue = DECISIONS.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        queue.drain(..).collect()
    }

    /// Seconds since 1970 of the latest Apple `Date` header, or 0.
    pub fn last_apple_date() -> i64 {
        LAST_APPLE_DATE.load(Ordering::SeqCst)
    }

    pub(super) fn note_server_date(host: &str, value: &str) {
        if !RECORDS || !APPLE_HOSTS.iter().any(|apple| apple.eq_ignore_ascii_case(host)) {
            return;
        }
        if let Some(seconds) = parse_http_date(value) {
            LAST_APPLE_DATE.store(seconds, Ordering::SeqCst);
        }
    }

    /// RFC 9110 IMF-fixdate only ("Sun, 06 Nov 1994 08:49:37 GMT").
    pub fn parse_http_date(value: &str) -> Option<i64> {
        let parts: Vec<&str> = value.split_whitespace().collect();
        if parts.len() != 6 || parts[5] != "GMT" || !parts[0].ends_with(',') {
            return None;
        }
        let day: i64 = parts[1].parse().ok().filter(|d| (1..=31).contains(d))?;
        let month = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
            .iter()
            .position(|m| *m == parts[2])? as i64
            + 1;
        let year: i64 = parts[3].parse().ok().filter(|y| (1970..=9999).contains(y))?;
        let time: Vec<i64> = parts[4].split(':').map(|p| p.parse().ok()).collect::<Option<Vec<_>>>()?;
        if time.len() != 3 || time[0] > 23 || time[1] > 59 || time[2] > 60 {
            return None;
        }
        // Days from civil (Howard Hinnant's algorithm).
        let (y, m) = if month <= 2 { (year - 1, month + 9) } else { (year, month - 3) };
        let era = y.div_euclid(400);
        let yoe = y - era * 400;
        let doy = (153 * m + 2) / 5 + day - 1;
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
        let days = era * 146_097 + doe - 719_468;
        Some(days * 86_400 + time[0] * 3_600 + time[1] * 60 + time[2])
    }

    #[cfg(test)]
    pub(super) fn reset() {
        take();
        LAST_APPLE_DATE.store(0, Ordering::SeqCst);
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

    /// The observer's queue and date are process-wide; its tests take turns.
    static OBSERVE_TESTS: std::sync::Mutex<()> = std::sync::Mutex::new(());

    /// G5: recording a decision never changes it, and records no query.
    #[test]
    fn observed_decisions_match_permit_and_drop_queries() {
        let _turn = OBSERVE_TESTS.lock().unwrap_or_else(|p| p.into_inner());
        observe::reset();
        let apple = apple_hosts();
        for (u, scheme) in [
            ("https://gsa.apple.com/grandslam/GsService2?x=secret", "https"),
            ("https://idmsa.apple.com/appleauth/auth/devices", "https"),
            ("https://gsa.apple.com:8443/", "https"),
            ("https://user:pw@gsa.apple.com/", "https"),
            ("http://gsa.apple.com/", "https"),
        ] {
            let parsed = url(u);
            assert_eq!(permit_observed(&parsed, &apple, scheme, "post"), permit(&parsed, &apple, scheme));
        }
        let taken = observe::take();
        assert_eq!(taken.len(), 5);
        assert!(taken.iter().all(|d| !d.path.contains('?') && !d.path.contains("secret") && d.method == "POST"));
        if !LIVE_NETWORK {
            assert!(taken.iter().all(|d| !d.allowed));
            assert_eq!(taken[0].reason, Some("disabled"));
        } else {
            assert!(taken[0].allowed);
            assert_eq!(taken[1].reason, Some("hostNotAllowed"));
            assert_eq!(taken[2].reason, Some("portInURL"));
            assert_eq!(taken[3].reason, Some("credentialsInURL"));
            assert_eq!(taken[4].reason, Some("notSecure"));
        }
        assert!(observe::take().is_empty());
    }

    #[test]
    fn apple_dates_are_parsed_and_kept_only_for_apple_hosts() {
        let _turn = OBSERVE_TESTS.lock().unwrap_or_else(|p| p.into_inner());
        observe::reset();
        assert_eq!(observe::parse_http_date("Sun, 06 Nov 1994 08:49:37 GMT"), Some(784_111_777));
        assert_eq!(observe::parse_http_date("Thu, 19 Nov 2026 12:00:00 GMT"), Some(1_795_089_600));
        for bad in ["", "Sun, 06 Nov 1994 08:49:37 UTC", "Sunday, 06-Nov-94 08:49:37 GMT", "Sun, 32 Nov 1994 08:49:37 GMT", "Sun, 06 Foo 1994 08:49:37 GMT"] {
            assert_eq!(observe::parse_http_date(bad), None, "{bad}");
        }
        observe::note_server_date("anisette.example", "Sun, 06 Nov 1994 08:49:37 GMT");
        assert_eq!(observe::last_apple_date(), 0);
        observe::note_server_date("GSA.apple.com", "Thu, 19 Nov 2026 12:00:00 GMT");
        assert_eq!(observe::last_apple_date(), 1_795_089_600);
        observe::reset();
    }
}
