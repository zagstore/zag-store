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
        let host = url.host_str().unwrap_or("").to_string();
        time_gate::before_request(&host, req.method().as_str(), url.path()).map_err(reqwest_middleware::Error::middleware)?;
        let response = next.run(req, extensions).await?;
        let date = response.headers().get(http::header::DATE).map(|d| d.to_str().unwrap_or(""));
        if let Some(date) = date {
            observe::note_server_date(&host, date);
        }
        time_gate::after_response(&host, date, time_gate::device_now()).map_err(reqwest_middleware::Error::middleware)?;
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

/// Zag Store G5 (C5, fail-closed): when the experiment configures a window,
/// every response from an Apple host must carry a `Date` (received over the
/// verified TLS connection) inside the window and within the allowed skew of
/// the device clock. Until one has, the only request allowed to an Apple host
/// is the credential-free URL-bag lookup (`grandslam::URL_BAG`), which is the
/// first Apple request of a sign-in; the SRP `init` (Apple ID) and `complete`
/// (password proof) requests come after it. A failed check refuses that
/// response and every later Apple request in the process. Unconfigured, the
/// gate does nothing (production and G4 behaviour are unchanged).
pub mod time_gate {
    use std::sync::Mutex;
    use std::time::{SystemTime, UNIX_EPOCH};

    use super::{APPLE_HOSTS, observe};

    /// The only Apple request allowed before the time is verified.
    pub const FIRST_REQUEST: (&str, &str, &str) = ("GET", "gsa.apple.com", "/grandslam/GsService2/lookup");

    #[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error)]
    pub enum TimeRefusal {
        #[error("Refused: Apple's time has not been verified yet")]
        NotYetVerified,
        #[error("Refused: the Apple response has no Date")]
        Missing,
        #[error("Refused: the Apple response's Date is malformed")]
        Malformed,
        #[error("Refused: Apple's time is before the authorised window")]
        Premature,
        #[error("Refused: Apple's time is after the authorised window")]
        Expired,
        #[error("Refused: Apple's time differs too much from the device clock")]
        Skew,
        #[error("Refused: an earlier time check failed")]
        Refused,
    }

    impl TimeRefusal {
        /// Stable codes for the bridge (`zag_bridge_time_gate_status`).
        pub fn code(self) -> i32 {
            match self {
                TimeRefusal::NotYetVerified => 2,
                TimeRefusal::Missing => 3,
                TimeRefusal::Malformed => 4,
                TimeRefusal::Premature => 5,
                TimeRefusal::Expired => 6,
                TimeRefusal::Skew => 7,
                TimeRefusal::Refused => 8,
            }
        }
    }

    #[derive(Debug, Clone, Copy, PartialEq, Eq)]
    pub struct Window {
        pub not_before: i64,
        pub not_after: i64,
        pub max_skew: i64,
    }

    #[derive(Debug, Clone, Copy, PartialEq, Eq)]
    enum Phase {
        Pending,
        Verified,
        Refused(TimeRefusal),
    }

    struct State {
        window: Option<Window>,
        phase: Phase,
    }

    static STATE: Mutex<State> = Mutex::new(State { window: None, phase: Phase::Pending });

    fn state() -> std::sync::MutexGuard<'static, State> {
        STATE.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    fn is_apple(host: &str) -> bool {
        APPLE_HOSTS.iter().any(|apple| apple.eq_ignore_ascii_case(host))
    }

    /// Sets the window once. A second, different window is refused, and a
    /// gate that has refused stays refused.
    pub fn configure(window: Window) -> bool {
        if window.not_before >= window.not_after || window.max_skew < 0 {
            return false;
        }
        let mut state = state();
        match state.window {
            Some(existing) => existing == window,
            None => {
                state.window = Some(window);
                true
            }
        }
    }

    /// 0: not configured; 1: verified; 2: configured, not yet verified;
    /// 3–8: refused (`TimeRefusal::code`).
    pub fn status() -> i32 {
        let state = state();
        match (state.window, state.phase) {
            (None, _) => 0,
            (Some(_), Phase::Verified) => 1,
            (Some(_), Phase::Pending) => 2,
            (Some(_), Phase::Refused(reason)) => reason.code(),
        }
    }

    pub fn device_now() -> i64 {
        SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0)
    }

    pub fn before_request(host: &str, method: &str, path: &str) -> Result<(), TimeRefusal> {
        let state = state();
        if state.window.is_none() || !is_apple(host) {
            return Ok(());
        }
        match state.phase {
            Phase::Verified => Ok(()),
            Phase::Refused(_) => Err(TimeRefusal::Refused),
            Phase::Pending => {
                let first = method.eq_ignore_ascii_case(FIRST_REQUEST.0) && host.eq_ignore_ascii_case(FIRST_REQUEST.1) && path == FIRST_REQUEST.2;
                if first { Ok(()) } else { Err(TimeRefusal::NotYetVerified) }
            }
        }
    }

    pub fn after_response(host: &str, date: Option<&str>, device_now: i64) -> Result<(), TimeRefusal> {
        let mut state = state();
        let Some(window) = state.window else { return Ok(()) };
        if !is_apple(host) {
            return Ok(());
        }
        if let Phase::Refused(_) = state.phase {
            return Err(TimeRefusal::Refused);
        }
        let verdict = match date {
            None => Err(TimeRefusal::Missing),
            Some(value) => match observe::parse_http_date(value) {
                None => Err(TimeRefusal::Malformed),
                Some(t) if t < window.not_before => Err(TimeRefusal::Premature),
                Some(t) if t >= window.not_after => Err(TimeRefusal::Expired),
                Some(t) if (t - device_now).abs() > window.max_skew => Err(TimeRefusal::Skew),
                Some(_) => Ok(()),
            },
        };
        state.phase = match verdict {
            Ok(()) => Phase::Verified,
            Err(reason) => Phase::Refused(reason),
        };
        verdict
    }

    #[cfg(test)]
    pub(super) fn reset() {
        let mut state = state();
        state.window = None;
        state.phase = Phase::Pending;
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

    // C5 (G5): the authenticated-time gate.
    const NOV_19_NOON: i64 = 1_795_089_600; // Thu, 19 Nov 2026 12:00:00 GMT
    const GOOD_DATE: &str = "Thu, 19 Nov 2026 12:00:00 GMT";

    fn window() -> time_gate::Window {
        time_gate::Window { not_before: NOV_19_NOON - 3_600, not_after: NOV_19_NOON + 72 * 3_600, max_skew: 600 }
    }

    #[test]
    fn time_gate_refuses_every_bad_date_and_then_everything() {
        use time_gate::TimeRefusal::*;
        let _turn = OBSERVE_TESTS.lock().unwrap_or_else(|p| p.into_inner());
        let cases: [(Option<&str>, i64, Result<(), time_gate::TimeRefusal>); 8] = [
            (Some(GOOD_DATE), NOV_19_NOON, Ok(())),
            (Some(GOOD_DATE), NOV_19_NOON + 599, Ok(())),
            (None, NOV_19_NOON, Err(Missing)),
            (Some("19 Nov 2026 12:00:00"), NOV_19_NOON, Err(Malformed)),
            (Some("Thu, 19 Nov 2026 25:00:00 GMT"), NOV_19_NOON, Err(Malformed)),
            (Some("Wed, 18 Nov 2026 10:00:00 GMT"), NOV_19_NOON - 26 * 3_600, Err(Premature)),
            (Some("Mon, 23 Nov 2026 12:00:00 GMT"), NOV_19_NOON + 96 * 3_600, Err(Expired)),
            (Some(GOOD_DATE), NOV_19_NOON + 601, Err(Skew)),
        ];
        for (date, now, expected) in cases {
            time_gate::reset();
            assert!(time_gate::configure(window()));
            assert_eq!(time_gate::status(), 2);
            assert_eq!(time_gate::before_request("gsa.apple.com", "GET", "/grandslam/GsService2/lookup"), Ok(()));
            assert_eq!(time_gate::after_response("gsa.apple.com", date, now), expected, "{date:?}");
            match expected {
                Ok(()) => {
                    assert_eq!(time_gate::status(), 1);
                    assert_eq!(time_gate::before_request("gsa.apple.com", "POST", "/grandslam/GsService2"), Ok(()));
                }
                Err(reason) => {
                    assert_eq!(time_gate::status(), reason.code());
                    // Nothing more reaches Apple: not the SRP init, not the
                    // portal, not even another lookup; a later good Date
                    // cannot undo the refusal.
                    for (host, method, path) in [("gsa.apple.com", "POST", "/grandslam/GsService2"), ("gsa.apple.com", "GET", "/grandslam/GsService2/lookup"),
                                                 ("developerservices2.apple.com", "POST", "/services/QH65B2/listTeams.action")] {
                        assert_eq!(time_gate::before_request(host, method, path), Err(Refused));
                    }
                    assert_eq!(time_gate::after_response("gsa.apple.com", Some(GOOD_DATE), NOV_19_NOON), Err(Refused));
                    // The anisette provider is not Apple and is not gated.
                    assert_eq!(time_gate::before_request("anisette.example", "GET", "/v3/client_info"), Ok(()));
                }
            }
        }
        time_gate::reset();
    }

    #[test]
    fn time_gate_allows_only_the_url_bag_before_verification() {
        let _turn = OBSERVE_TESTS.lock().unwrap_or_else(|p| p.into_inner());
        time_gate::reset();
        // Unconfigured (production, G4): no effect at all.
        assert_eq!(time_gate::status(), 0);
        assert_eq!(time_gate::before_request("gsa.apple.com", "POST", "/grandslam/GsService2"), Ok(()));
        assert_eq!(time_gate::after_response("gsa.apple.com", None, 0), Ok(()));
        assert!(time_gate::configure(window()));
        assert!(time_gate::configure(window()), "the same window again is accepted");
        assert!(!time_gate::configure(time_gate::Window { not_after: NOV_19_NOON, ..window() }), "a different window is refused");
        assert!(!time_gate::configure(time_gate::Window { not_before: 10, not_after: 10, max_skew: 0 }));
        // The SRP init (Apple ID), complete (password proof) and the portal
        // are refused until a verified Date; so is the lookup by any other
        // method or path.
        for (host, method, path) in [("gsa.apple.com", "POST", "/grandslam/GsService2"), ("gsa.apple.com", "POST", "/grandslam/GsService2/lookup"),
                                     ("gsa.apple.com", "GET", "/grandslam/GsService2/lookup/x"), ("developerservices2.apple.com", "GET", "/grandslam/GsService2/lookup")] {
            assert_eq!(time_gate::before_request(host, method, path), Err(time_gate::TimeRefusal::NotYetVerified), "{method} {host}{path}");
        }
        // The gate's first request is the code's URL bag.
        let bag = Url::parse(crate::auth::grandslam::URL_BAG).unwrap();
        assert_eq!((bag.host_str().unwrap(), bag.path()), (time_gate::FIRST_REQUEST.1, time_gate::FIRST_REQUEST.2));
        time_gate::reset();
    }

    /// End to end through the real Guard and the real URL-bag fetch, with a
    /// recording transport behind the Guard instead of the network: when C5
    /// refuses the lookup's Date, the request carrying the Apple ID and the
    /// password proof never reaches the transport.
    #[cfg(feature = "live-network")]
    #[tokio::test]
    async fn time_gate_refusal_sends_no_credentials() {
        use std::sync::{Arc, Mutex};

        struct Recorder {
            seen: Arc<Mutex<Vec<(String, String, Vec<u8>)>>>,
            date: Option<&'static str>,
        }
        #[async_trait::async_trait]
        impl Middleware for Recorder {
            async fn handle(&self, req: reqwest::Request, _: &mut http::Extensions, _: Next<'_>) -> reqwest_middleware::Result<reqwest::Response> {
                let body = req.body().and_then(|b| b.as_bytes()).map(<[u8]>::to_vec).unwrap_or_default();
                self.seen.lock().unwrap().push((req.method().to_string(), req.url().to_string(), body));
                let plist = "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>urls</key><dict><key>gsService</key><string>https://gsa.apple.com/grandslam/GsService2</string></dict></dict></plist>";
                let mut response = http::Response::builder().status(200);
                if let Some(date) = self.date {
                    response = response.header(http::header::DATE, date);
                }
                Ok(reqwest::Response::from(response.body(plist.as_bytes().to_vec()).unwrap()))
            }
        }

        let _turn = OBSERVE_TESTS.lock().unwrap_or_else(|p| p.into_inner());
        let _ = rustls::crypto::ring::default_provider().install_default();
        let device_now = time_gate::device_now();
        let fmt = |t: i64| {
            // Any valid IMF-fixdate for `t` (the weekday is not checked).
            let days = t.div_euclid(86_400);
            let secs = t.rem_euclid(86_400);
            let z = days + 719_468;
            let era = z.div_euclid(146_097);
            let doe = z - era * 146_097;
            let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365;
            let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
            let mp = (5 * doy + 2) / 153;
            let day = doy - (153 * mp + 2) / 5 + 1;
            let month = if mp < 10 { mp + 3 } else { mp - 9 };
            let year = yoe + era * 400 + if month <= 2 { 1 } else { 0 };
            let names = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
            Box::leak(format!("Thu, {:02} {} {} {:02}:{:02}:{:02} GMT", day, names[(month - 1) as usize], year, secs / 3_600, secs % 3_600 / 60, secs % 60).into_boxed_str()) as &'static str
        };
        let live = time_gate::Window { not_before: device_now - 3_600, not_after: device_now + 3_600, max_skew: 600 };
        let cases: [(Option<&'static str>, bool); 6] = [
            (Some(fmt(device_now)), true),
            (None, false),
            (Some("not a date"), false),
            (Some(fmt(device_now - 7_200)), false),
            (Some(fmt(device_now + 7_200)), false),
            (Some(fmt(device_now + 1_200)), false),
        ];
        for (date, passes) in cases {
            time_gate::reset();
            assert!(time_gate::configure(live));
            let seen = Arc::new(Mutex::new(Vec::new()));
            let client = reqwest::Client::builder().https_only(true).redirect(redirect::Policy::none()).build().unwrap();
            let client = MwClientBuilder::new(client)
                .with(Guard { allowed: apple_hosts() })
                .with(Recorder { seen: seen.clone(), date })
                .build();
            let bag = crate::auth::grandslam::GrandSlam::fetch_url_bag(&client, http::HeaderMap::new()).await;
            assert_eq!(bag.is_ok(), passes, "{date:?}");
            let init = client.post("https://gsa.apple.com/grandslam/GsService2")
                .body("<plist><dict><key>u</key><string>owner@example.invalid</string><key>M1</key><data>UEFTU1dPUkQtUFJPT0Y=</data></dict></plist>")
                .send()
                .await;
            assert_eq!(init.is_ok(), passes, "{date:?}");
            let seen = seen.lock().unwrap();
            if passes {
                assert_eq!(seen.len(), 2);
            } else {
                // Only the credential-free lookup went out.
                assert_eq!(seen.len(), 1, "{date:?}");
                assert_eq!((seen[0].0.as_str(), seen[0].1.as_str()), ("GET", "https://gsa.apple.com/grandslam/GsService2/lookup"));
                assert!(seen.iter().all(|(_, _, body)| !String::from_utf8_lossy(body).contains("owner@example.invalid") && !String::from_utf8_lossy(body).contains("UEFTU1dPUkQtUFJPT0Y")));
            }
        }
        time_gate::reset();
    }
}
