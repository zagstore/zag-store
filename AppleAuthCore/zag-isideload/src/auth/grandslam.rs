// Provenance note (Zag Store fork): parts of this file closely match code in
// SideStore/apple-private-apis (icloud-auth/src/client.rs), which is licensed under the
// Mozilla Public License 2.0. Until an independent licence review decides,
// this file is treated as MPL-2.0 (see PROVENANCE.md and LICENSE-MPL-2.0):
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

use plist::Dictionary;
use plist_macro::plist_to_xml_string;
use reqwest::{
    ClientBuilder,
    header::{HeaderMap, HeaderValue},
};
use rootcause::prelude::*;

use crate::{SideloadError, anisette::AnisetteClientInfo, util::plist::PlistDataExtract};

const APPLE_ROOT: &[u8] = include_bytes!("../assets/apple_root.cer");

pub(crate) const URL_BAG: &str = "https://gsa.apple.com/grandslam/GsService2/lookup";

pub struct GrandSlam {
    pub client: reqwest_middleware::ClientWithMiddleware,
    pub client_info: AnisetteClientInfo,
    url_bag: Dictionary,
}

impl GrandSlam {
    /// Create a new GrandSlam instance
    ///
    /// # Arguments
    /// - `client`: The reqwest client to use for requests
    pub async fn new(
        client_info: AnisetteClientInfo,
    ) -> Result<Self, Report> {
        let client = Self::build_reqwest_client().context("Failed to build HTTP client")?;
        let base_headers = Self::base_headers(&client_info, false)?;
        let url_bag = Self::fetch_url_bag(&client, base_headers).await?;
        Ok(Self {
            client,
            client_info,
            url_bag,
        })
    }

    /// Fetch the URL bag from GrandSlam and cache it
    pub async fn fetch_url_bag(
        client: &reqwest_middleware::ClientWithMiddleware,
        mut base_headers: HeaderMap,
    ) -> Result<Dictionary, Report> {
        debug!("Fetching URL bag from GrandSlam");
        let resp = client
            .get(URL_BAG)
            .headers(base_headers)
            .send()
            .await
            .context("Failed to fetch URL Bag")?
            .text()
            .await
            .context("Failed to read URL Bag response text")?;

        let dict: Dictionary =
            plist::from_bytes(resp.as_bytes()).context("Failed to parse URL Bag plist")?;
        let urls = dict
            .get("urls")
            .and_then(|v| v.as_dictionary())
            .cloned()
            .ok_or_else(|| report!("URL Bag plist missing 'urls' dictionary"))?;

        Ok(urls)
    }

    /// A client with an empty URL bag, for tests that must not fetch one.
    #[cfg(test)]
    pub(crate) fn offline_for_tests() -> Self {
        let _ = rustls::crypto::ring::default_provider().install_default();
        Self {
            client: Self::build_reqwest_client().expect("client"),
            client_info: AnisetteClientInfo { client_info: String::new(), user_agent: String::new() },
            url_bag: Dictionary::new(),
        }
    }

    pub fn get_url(&self, key: &str) -> Result<String, Report> {
        let url = self
            .url_bag
            .get_string(key)
            .context("Unable to find key in URL bag")?;
        Ok(url)
    }

    pub fn get(&self, url: &str) -> Result<reqwest_middleware::RequestBuilder, Report> {
        let builder = self
            .client
            .get(url)
            .headers(Self::base_headers(&self.client_info, false)?);

        Ok(builder)
    }

    pub fn get_sms(&self, url: &str) -> Result<reqwest_middleware::RequestBuilder, Report> {
        let builder = self
            .client
            .get(url)
            .headers(Self::base_headers(&self.client_info, true)?);

        Ok(builder)
    }

    pub fn put_sms(&self, url: &str) -> Result<reqwest_middleware::RequestBuilder, Report> {
        let builder = self
            .client
            .put(url)
            .headers(Self::base_headers(&self.client_info, true)?);

        Ok(builder)
    }

    pub fn post(&self, url: &str) -> Result<reqwest_middleware::RequestBuilder, Report> {
        let builder = self
            .client
            .post(url)
            .headers(Self::base_headers(&self.client_info, false)?);

        Ok(builder)
    }

    pub fn post_sms(&self, url: &str) -> Result<reqwest_middleware::RequestBuilder, Report> {
        let builder = self
            .client
            .post(url)
            .headers(Self::base_headers(&self.client_info, true)?);

        Ok(builder)
    }

    pub fn patch(&self, url: &str) -> Result<reqwest_middleware::RequestBuilder, Report> {
        let builder = self
            .client
            .patch(url)
            .headers(Self::base_headers(&self.client_info, false)?);

        Ok(builder)
    }

    pub async fn plist_request(
        &self,
        url: &str,
        body: &Dictionary,
        additional_headers: Option<HeaderMap>,
        retry_limit: Option<u32>,
    ) -> Result<Dictionary, Report> {
        // Zag Store fork: retries after 429 (off unless the caller sets a
        // limit) wait before each attempt, as `retry_delay` says, rather than
        // resending at once into the limit.
        let mut retries_left = retry_limit;
        let mut attempt = 0u32;
        let result = loop {
            let result = self
                .post(url)?
                .headers(
                    additional_headers
                        .clone()
                        .unwrap_or_else(reqwest::header::HeaderMap::new),
                )
                .body(plist_to_xml_string(body))
                .send()
                .await
                .context("Failed to send grandslam request")?;

            if let Some(retries) = retries_left
                && result.status() == reqwest::StatusCode::TOO_MANY_REQUESTS
            {
                if retries == 0 {
                    bail!("Received 429 Too Many Requests, no retries left");
                }
                let delay = retry_delay(attempt, result.headers().get(reqwest::header::RETRY_AFTER));
                warn!("Received 429 Too Many Requests, retrying in {:?} ({} retries left)", delay, retries);
                tokio::time::sleep(delay).await;
                retries_left = Some(retries - 1);
                attempt += 1;
                continue;
            }
            break result;
        };

        let resp = result
            .error_for_status()
            .context("Received error response from grandslam")?
            .text()
            .await
            .context("Failed to read grandslam response as text")?;

        let dict = crate::util::plist::parse_response_plist(&resp, "grandslam response")?;

        let response_plist = dict
            .get("Response")
            .and_then(|v| v.as_dictionary())
            .cloned()
            .ok_or_else(|| {
                report!("grandslam response missing 'Response'")
                    .attach(crate::util::plist::SensitivePlistAttachment::new(dict.clone()))
            })?;

        Ok(response_plist)
    }

    fn base_headers(
        client_info: &AnisetteClientInfo,
        sms: bool,
    ) -> Result<reqwest::header::HeaderMap, Report> {
        let mut headers = reqwest::header::HeaderMap::new();
        if !sms {
            headers.insert("Content-Type", HeaderValue::from_static("text/x-xml-plist"));
            headers.insert("Accept", HeaderValue::from_static("text/x-xml-plist"));
        } else {
            headers.insert("Content-Type", HeaderValue::from_static("application/json"));
            headers.insert("Accept", HeaderValue::from_static("application/json"));
        }
        headers.insert(
            "X-Mme-Client-Info",
            HeaderValue::from_str(&client_info.client_info)?,
        );
        headers.insert(
            "User-Agent",
            HeaderValue::from_str(&client_info.user_agent)?,
        );
        headers.insert(
            "X-Xcode-Version",
            HeaderValue::from_static("27.0 (27A5218g)"),
        );
        headers.insert(
            "X-Apple-App-Info",
            HeaderValue::from_static("com.apple.gs.xcode.auth"),
        );
        headers.insert(
            reqwest::header::CONNECTION,
            HeaderValue::from_static("close"),
        );

        Ok(headers)
    }

    /// Build the HTTP client for Apple's services: the system roots plus
    /// Apple's root, certificates always verified, https only, no redirects,
    /// and only Apple's allowlisted hosts (`net_policy`).
    ///
    /// Zag Store fork: upstream's `debug` switch, which disabled certificate
    /// verification, and its request proxy are removed.
    pub fn build_reqwest_client() -> Result<reqwest_middleware::ClientWithMiddleware, Report> {
        let builder = ClientBuilder::new()
            .add_root_certificate(reqwest::Certificate::from_der(APPLE_ROOT)?)
            .http1_title_case_headers();
        crate::net_policy::guarded_client(builder, crate::net_policy::apple_hosts())
    }
}

/// The wait before retry `attempt` (0-based) after a 429: Apple's
/// `Retry-After` in seconds when given, at most `MAX_RETRY_AFTER`; otherwise
/// 2, 4, 8 … seconds, at most `MAX_BACKOFF`.
pub(crate) fn retry_delay(attempt: u32, retry_after: Option<&HeaderValue>) -> std::time::Duration {
    const MAX_RETRY_AFTER: u64 = 120;
    const MAX_BACKOFF: u64 = 32;
    let given = retry_after
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.trim().parse::<u64>().ok());
    let seconds = match given {
        Some(seconds) => seconds.clamp(1, MAX_RETRY_AFTER),
        None => 2u64.saturating_pow(attempt.saturating_add(1)).min(MAX_BACKOFF),
    };
    std::time::Duration::from_secs(seconds)
}

pub trait GrandSlamErrorChecker {
    fn check_grandslam_error(self) -> Result<Dictionary, Report<SideloadError>>;
}

impl GrandSlamErrorChecker for Dictionary {
    fn check_grandslam_error(self) -> Result<Self, Report<SideloadError>> {
        let result = match self.get("Status") {
            Some(plist::Value::Dictionary(d)) => d,
            _ => &self,
        };

        if result.get_signed_integer("ec").unwrap_or(0) != 0 {
            bail!(SideloadError::AuthWithMessage(
                result.get_signed_integer("ec").unwrap_or(-1),
                result.get_str("em").unwrap_or("Unknown error").to_string(),
            ))
        }

        Ok(self)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    #[test]
    fn retries_back_off() {
        assert_eq!(retry_delay(0, None), Duration::from_secs(2));
        assert_eq!(retry_delay(1, None), Duration::from_secs(4));
        assert_eq!(retry_delay(2, None), Duration::from_secs(8));
        assert_eq!(retry_delay(10, None), Duration::from_secs(32), "capped");
        assert_eq!(retry_delay(u32::MAX, None), Duration::from_secs(32), "no overflow");
    }

    #[test]
    fn retry_after_is_honoured_within_bounds() {
        let header = |v: &'static str| HeaderValue::from_static(v);
        assert_eq!(retry_delay(0, Some(&header("30"))), Duration::from_secs(30));
        assert_eq!(retry_delay(0, Some(&header("0"))), Duration::from_secs(1), "never at once");
        assert_eq!(retry_delay(0, Some(&header("86400"))), Duration::from_secs(120), "capped");
        assert_eq!(retry_delay(1, Some(&header("Wed, 21 Oct 2026 07:28:00 GMT"))), Duration::from_secs(4), "dates fall back to backoff");
    }

    #[test]
    fn retries_stay_off_by_default() {
        let source = include_str!("builder.rs");
        assert!(source.contains("err_429_retries: None,"));
    }
}
