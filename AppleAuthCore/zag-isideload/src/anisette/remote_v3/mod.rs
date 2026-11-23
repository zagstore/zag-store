// Provenance note (Zag Store fork): parts of this file closely match code in
// SideStore/apple-private-apis (omnisette/src/remote_anisette_v3.rs), which is licensed under the
// Mozilla Public License 2.0. Until an independent licence review decides,
// this file is treated as MPL-2.0 (see PROVENANCE.md and LICENSE-MPL-2.0):
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

mod state;
mod websocket;

use std::sync::Arc;
use web_time::SystemTime;

use base64::prelude::*;
use plist_macro::plist;
use reqwest::{
    ClientBuilder,
    header::{CONTENT_TYPE, HeaderMap, HeaderValue},
};
use rootcause::prelude::*;
use serde::Deserialize;
use sha2::{Digest, Sha256};

use crate::anisette::remote_v3::websocket::AppWebSocket;
use crate::anisette::{AnisetteClientInfo, AnisetteData, AnisetteProvider};
use crate::anisette::{
    AnisetteDataResponse,
    remote_v3::{state::AnisetteState, websocket::WsMessage},
};
use crate::auth::grandslam::GrandSlam;
use crate::util::plist::{PlistDataExtract, decode_json};
use crate::util::storage::SideloadingStorage;

pub const ANISETTE_STATE_KEY: &str = "anisette_state";

/// Zag Store fork: records which provider/client identity owns the legacy
/// `anisette_state` slot. A device provisioned (ADI) against one anisette
/// provider or client identity is not valid for another, so a different
/// identity for the same account must not reuse (or overwrite) that stored
/// state. Holds only a non-secret fingerprint; never an identifier or
/// provisioning material. This is isolation hardening of local storage only:
/// it has no bearing on Apple's own authentication or provisioning decisions.
pub const ANISETTE_IDENTITY_KEY: &str = "anisette_identity";

/// Zag Store fork: normalises an anisette endpoint for identity comparison
/// only. It never relaxes the endpoint validation the HTTP client enforces;
/// it just makes trivially different spellings of one endpoint compare equal.
fn normalize_endpoint(url: &str) -> String {
    match reqwest::Url::parse(url) {
        Ok(parsed) => {
            let scheme = parsed.scheme().to_ascii_lowercase();
            let host = parsed.host_str().unwrap_or_default().to_ascii_lowercase();
            let port = parsed.port().map(|p| format!(":{p}")).unwrap_or_default();
            let path = parsed.path().trim_end_matches('/');
            format!("{scheme}://{host}{port}{path}")
        }
        Err(_) => url.trim_end_matches('/').to_ascii_lowercase(),
    }
}

/// Zag Store fork: normalises an effective client-identity string for
/// comparison. Only whitespace is collapsed — the one change that is provably
/// non-semantic. Everything else is compared verbatim, because without an
/// authoritative description of how Apple's ADI provisioning binds to the
/// client identity we cannot classify a sub-field change as cosmetic, and the
/// safe default for an unprovable change is isolation, not reuse.
fn normalize_client_identity(info: &str) -> String {
    info.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// Zag Store fork: the stage of the anisette provisioning exchange at which a
/// failure occurred. Carries no message, identifier or blob — only which step
/// failed, so a diagnostic can be actionable without exposing Apple's response.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProvisioningStage {
    /// The server asked for, or rejected, the device identifier.
    Identifier,
    /// The start-provisioning (`spim`) exchange.
    StartProvisioning,
    /// The end-provisioning (`cpim`/`ptm`/`tk`) exchange — where an Android-ADI
    /// vs. claimed-platform mismatch (-29003) surfaces.
    EndProvisioning,
    /// Fetching anisette headers for an already-provisioned device.
    HeaderFetch,
}

/// Zag Store fork: a privacy-preserving, typed hint attached to a provisioning
/// failure. The caller reads the stage and, when present, a recognised numeric
/// code — never the withheld message.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ProvisioningFault {
    pub stage: ProvisioningStage,
    /// A recognised code from `KNOWN_ADI_CODES`, matched as an exact substring
    /// of the server's message; `None` when none of the known codes is present.
    /// Never arbitrary text parsed out of the message.
    pub code: Option<i64>,
}

/// Safe to display: only the stage name and a recognised numeric code.
impl std::fmt::Display for ProvisioningFault {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self.code {
            Some(code) => write!(f, "provisioning fault at {:?} (code {code})", self.stage),
            None => write!(f, "provisioning fault at {:?}", self.stage),
        }
    }
}

/// Zag Store fork: the fixed set of anisette/ADI numeric error codes a
/// diagnostic may recognise. Extended only as codes are confirmed; recognition
/// is by whole numeric token against this list, so no other text can ever leak.
/// -45061: device not provisioned. -29003: ADI environment/identity mismatch.
pub const KNOWN_ADI_CODES: &[i64] = &[-45061, -29003];

/// Zag Store fork: recognises a known ADI code appearing as a complete numeric
/// token in a provisioning message, returning only a value from
/// `KNOWN_ADI_CODES` and never any surrounding text.
///
/// The provisioning protocol does not expose a structured numeric field for
/// these messages (only an opaque string), so this scans for whole integer
/// tokens and matches them against the allow-list. A token is a maximal run of
/// ASCII digits, taking an immediately preceding `-` as its sign only when that
/// `-` is not itself glued to a digit. This rejects a code embedded in a longer
/// number — `-290030` is the single token -290030, never -29003 — and a bare
/// positive `29003` never matches the negative code. This is deliberately not a
/// general error-text parser.
pub fn known_adi_code(message: &str) -> Option<i64> {
    let b = message.as_bytes();
    let mut i = 0;
    while i < b.len() {
        if !b[i].is_ascii_digit() {
            i += 1;
            continue;
        }
        // Maximal run of digits: [start, i).
        let start = i;
        while i < b.len() && b[i].is_ascii_digit() {
            i += 1;
        }
        // Include a leading '-' as a sign only when it is not glued to a digit
        // (so "5-29003" does not read as a sign on 29003).
        let token_start =
            if start > 0 && b[start - 1] == b'-' && (start < 2 || !b[start - 2].is_ascii_digit()) {
                start - 1
            } else {
                start
            };
        if let Ok(value) = message[token_start..i].parse::<i64>()
            && KNOWN_ADI_CODES.contains(&value)
        {
            return Some(value);
        }
    }
    None
}

#[cfg(test)]
mod known_adi_code_tests {
    use super::{known_adi_code, KNOWN_ADI_CODES};

    #[test]
    fn recognises_a_known_code_as_a_bounded_token() {
        assert_eq!(known_adi_code("error GsService -29003 (akd)"), Some(-29003));
        assert_eq!(known_adi_code("Device not provisioned: -45061"), Some(-45061));
        // Adjacent to punctuation (not digits) still recognised.
        assert_eq!(known_adi_code("(-29003)"), Some(-29003));
        assert_eq!(known_adi_code("ec=-45061."), Some(-45061));
        assert_eq!(known_adi_code("-29003"), Some(-29003));
    }

    #[test]
    fn rejects_a_known_code_embedded_in_a_longer_number() {
        // The whole token differs from the allow-listed code.
        assert_eq!(known_adi_code("-290030"), None, "trailing digit");
        assert_eq!(known_adi_code("-450610"), None, "trailing digit");
        assert_eq!(known_adi_code("-129003"), None, "leading digit");
        assert_eq!(known_adi_code("code -290031 akd"), None);
        assert_eq!(known_adi_code("ref 1234506129003 end"), None, "code buried mid-number");
    }

    #[test]
    fn a_bare_positive_number_is_not_a_negative_code() {
        assert_eq!(known_adi_code("29003"), None);
        assert_eq!(known_adi_code("status 45061 ok"), None);
    }

    #[test]
    fn returns_none_for_an_unknown_code_rather_than_inventing_one() {
        assert_eq!(known_adi_code("error -12345 something"), None);
        assert_eq!(known_adi_code("a long opaque server message with no known code"), None);
        assert_eq!(known_adi_code(""), None);
    }

    #[test]
    fn handles_ambiguous_and_malformed_messages_without_false_positives() {
        // A digit glued before the sign must not read as a bounded code.
        assert_eq!(known_adi_code("5-29003"), None);
        // Multiple tokens: the first bounded match wins, unknowns are skipped.
        assert_eq!(known_adi_code("tries=3 then -45061"), Some(-45061));
        assert_eq!(known_adi_code("-290030 then -29003"), Some(-29003));
    }

    #[test]
    fn only_ever_returns_a_value_from_the_allowlist() {
        // Whatever the input, the result is one of the fixed known codes or None.
        for message in ["-29003", "-45061", "noise", "", "code=0", "-290030", "99999"] {
            assert!(known_adi_code(message).is_none_or(|c| KNOWN_ADI_CODES.contains(&c)));
        }
    }
}

#[cfg(test)]
pub(crate) fn state_for_tests(keychain_identifier: [u8; 16], adi_pb: Option<Vec<u8>>) -> AnisetteState {
    AnisetteState { keychain_identifier, adi_pb }
}

/// What happened to the stored device state. Data-free: no identifier or
/// provisioning material is ever part of it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StateChange {
    /// The stored, provisioned state was used.
    Loaded,
    /// Another provider for the same scope had provisioned (or reset) it
    /// meanwhile: its device was adopted instead of making another.
    Adopted,
    /// There was no stored state: a new device was made.
    Created,
    /// The stored state could not be parsed: it was replaced by a new device.
    ReplacedCorrupt,
    /// The anisette server reported the device as not provisioned (-45061):
    /// a new device was made.
    Reset,
}

/// Process-wide counts of `StateChange`s, for diagnostics.
pub mod diagnostics {
    use super::StateChange;
    use std::sync::atomic::{AtomicU64, Ordering};

    static COUNTS: [AtomicU64; 5] = [const { AtomicU64::new(0) }; 5];

    fn index(change: StateChange) -> usize {
        match change {
            StateChange::Loaded => 0,
            StateChange::Adopted => 1,
            StateChange::Created => 2,
            StateChange::ReplacedCorrupt => 3,
            StateChange::Reset => 4,
        }
    }

    pub(super) fn record(change: StateChange) {
        COUNTS[index(change)].fetch_add(1, Ordering::Relaxed);
    }

    /// How many times `change` has happened in this process.
    pub fn count(change: StateChange) -> u64 {
        COUNTS[index(change)].load(Ordering::Relaxed)
    }
}

/// One lock per state scope, shared by every provider in the process.
mod coordination {
    use std::collections::HashMap;
    use std::sync::{Arc, Mutex, OnceLock, Weak};

    type Lock = Arc<tokio::sync::Mutex<()>>;

    fn locks() -> &'static Mutex<HashMap<String, Weak<tokio::sync::Mutex<()>>>> {
        static LOCKS: OnceLock<Mutex<HashMap<String, Weak<tokio::sync::Mutex<()>>>>> = OnceLock::new();
        LOCKS.get_or_init(Default::default)
    }

    /// The scope's lock; without a scope, a lock of its own. Entries no
    /// provider holds any more are dropped, so the map stays small.
    pub(super) fn lock(scope: Option<&str>) -> Lock {
        let Some(scope) = scope else { return Lock::default() };
        let mut locks = locks().lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        if let Some(lock) = locks.get(scope).and_then(Weak::upgrade) {
            return lock;
        }
        locks.retain(|_, lock| lock.strong_count() > 0);
        let lock = Lock::default();
        locks.insert(scope.to_string(), Arc::downgrade(&lock));
        lock
    }
}

pub struct RemoteV3AnisetteProvider {
    pub state: Option<AnisetteState>,
    url: String,
    storage: Box<dyn SideloadingStorage>,
    serial_number: String,
    client: reqwest_middleware::ClientWithMiddleware,
    client_info_override: Option<AnisetteClientInfo>,
    /// Zag Store fork: the effective `/v3/client_info` identity, captured
    /// before provisioning (outside the storage lock) so it can be recorded
    /// against the stored state without a network call inside coordination.
    effective_client_info: Option<String>,
    /// The account whose stored state this provider uses: providers with the
    /// same scope provision one at a time (`coordination`). `None`: only this
    /// provider's own calls are serialised.
    state_scope: Option<String>,
    /// Tests: replaces the exchange with the anisette server and Apple.
    #[cfg(test)]
    test_exchange: Option<fn(&mut AnisetteState) -> Result<(), Report>>,
}

impl RemoteV3AnisetteProvider {
    /// Create a new RemoteV3AnisetteProvider with the given URL and config path
    ///
    /// # Arguments
    /// - `url`: The URL of the remote anisette service
    /// - `storage`: The storage backend for anisette data
    /// - `serial_number`: The serial number of the device
    pub fn new(
        url: &str,
        storage: Box<dyn SideloadingStorage>,
        serial_number: String,
    ) -> Result<Self, Report> {
        Ok(Self {
            state: None,
            url: url.to_string(),
            storage,
            serial_number,
            client: Self::build_reqwest_client(url)?,
            client_info_override: None,
            effective_client_info: None,
            state_scope: None,
            #[cfg(test)]
            test_exchange: None,
        })
    }

    /// Zag Store fork: the provider's own HTTP client may reach only the
    /// anisette server it was created for (https, verified certificates,
    /// no redirects). There is no default server, and requests are never relayed.
    fn build_reqwest_client(url: &str) -> Result<reqwest_middleware::ClientWithMiddleware, Report> {
        crate::net_policy::guarded_client(ClientBuilder::new(), vec![crate::net_policy::host_of(url)?])
    }

    pub fn set_storage(mut self, storage: Box<dyn SideloadingStorage>) -> RemoteV3AnisetteProvider {
        self.storage = storage;
        self
    }

    pub fn set_serial_number(mut self, serial_number: String) -> RemoteV3AnisetteProvider {
        self.serial_number = serial_number;
        self
    }

    /// Names the stored state's scope (Zag Store: the account's anisette
    /// scope). Every provider over the same stored state must use the same.
    pub fn set_state_scope(mut self, scope: &str) -> RemoteV3AnisetteProvider {
        self.state_scope = Some(scope.to_string());
        self
    }

    pub fn set_client_info_override(
        mut self,
        client_info_override: Option<AnisetteClientInfo>,
    ) -> RemoteV3AnisetteProvider {
        self.client_info_override = client_info_override;
        self
    }

    /// Zag Store fork: the effective client identity this provider is using —
    /// the captured `/v3/client_info` value, or the explicit override when one
    /// is set and the fetch has not run (e.g. tests). `None` when not yet
    /// known.
    fn effective_identity(&self) -> Option<String> {
        self.effective_client_info
            .clone()
            .or_else(|| self.client_info_override.as_ref().map(|info| info.client_info.clone()))
    }

    /// Zag Store fork: a stable, non-secret fingerprint of this provider's
    /// anisette endpoint and effective client identity — the discriminator for
    /// which stored-state slot it may use. The endpoint is normalised
    /// (lowercased scheme and host, no trailing slash); the client identity is
    /// normalised only for whitespace (the one provably non-semantic case) and
    /// otherwise compared verbatim, so a change that cannot be shown to
    /// preserve the provisioning identity routes to a different slot rather
    /// than reusing possibly-incompatible state. No secret, device identifier
    /// or provisioning blob is ever part of it.
    fn identity_fingerprint(&self) -> String {
        let mut hasher = Sha256::new();
        hasher.update(normalize_endpoint(&self.url).as_bytes());
        if let Some(identity) = self.effective_identity() {
            hasher.update([0]);
            hasher.update(normalize_client_identity(&identity).as_bytes());
        }
        hex::encode(&hasher.finalize()[..16])
    }

    /// Zag Store fork: the storage key for this identity's state, and the
    /// fingerprint to record if the legacy slot is still unclaimed. The
    /// identity that owns the legacy slot (a pre-existing install, or the
    /// first use) keeps it, so no existing session is invalidated; any other
    /// provider or client identity gets a separate slot and never reads or
    /// overwrites another's device. Fail-closed: a marker that cannot be read
    /// stops the caller rather than being treated as an unclaimed slot, which
    /// would let a different identity reuse or overwrite another's device.
    fn resolve_state_slot(&self) -> Result<(String, Option<String>), Report> {
        let fingerprint = self.identity_fingerprint();
        let owner = self
            .storage
            .retrieve_data(ANISETTE_IDENTITY_KEY)
            .context("Failed to read the anisette identity marker")?
            .map(|bytes| String::from_utf8_lossy(&bytes).into_owned());
        match owner {
            Some(owner) if owner == fingerprint => Ok((ANISETTE_STATE_KEY.to_string(), None)),
            None => Ok((ANISETTE_STATE_KEY.to_string(), Some(fingerprint))),
            Some(_) => Ok((format!("{fingerprint}.{ANISETTE_STATE_KEY}"), None)),
        }
    }

    /// Zag Store fork: records this identity as the owner of the legacy slot,
    /// so a later, different identity gets its own slot. Written before the
    /// state (see get_state) and only on a path that reaches a usable state,
    /// never on a failed or cancelled provisioning.
    fn claim_state_slot(&self, claim: &Option<String>) -> Result<(), Report> {
        if let Some(fingerprint) = claim {
            self.storage
                .store_data(ANISETTE_IDENTITY_KEY, fingerprint.as_bytes())
                .context("Failed to record the anisette identity marker")?;
        }
        Ok(())
    }

}

#[async_trait::async_trait]
impl AnisetteProvider for RemoteV3AnisetteProvider {
    async fn get_anisette_data(&self) -> Result<AnisetteDataResponse, Report> {
        self.fetch_headers(None).await
    }

    async fn resync(&self, sim: &str) -> Result<AnisetteDataResponse, Report> {
        self.fetch_headers(Some(sim)).await
    }

    async fn get_client_info(&self) -> Result<AnisetteClientInfo, Report> {
        if let Some(client_info_override) = self.client_info_override.as_ref() {
            return Ok(client_info_override.clone());
        }
        let info = self
            .client
            .get(format!("{}/v3/client_info", self.url))
            .send()
            .await
            .context("Failed to request /v3/client_info from anisette server")?
            .error_for_status()
            .context("anisette server returned an error for /v3/client_info")?
            .text()
            .await
            .context("Failed to read /v3/client_info response")?;
        decode_json::<AnisetteClientInfo>(&info, "/v3/client_info response")
    }

    async fn provision(&mut self, gs: &Arc<GrandSlam>, force_reset: bool) -> Result<(), Report> {
        // Zag Store fork: capture the effective client-info identity here,
        // before get_state takes the storage lock, so the slot's state can be
        // bound to it without any network call inside coordination.
        let client_info = self.get_client_info().await?;
        self.effective_client_info = Some(client_info.client_info);
        self.get_state(gs, force_reset).await?;
        Ok(())
    }
}

impl RemoteV3AnisetteProvider {
    async fn fetch_headers(&self, sim: Option<&str>) -> Result<AnisetteDataResponse, Report> {
        let Some(state) = self.state.as_ref() else {
            return Ok(AnisetteDataResponse::NeedsProvisioning);
        };

        let Some(adi_pb) = state.adi_pb.as_ref() else {
            return Ok(AnisetteDataResponse::NeedsProvisioning);
        };

        let client_info = self.get_client_info().await?;

        let mut body = serde_json::json!({
            "identifier": BASE64_STANDARD.encode(state.keychain_identifier),
            "adi_pb": BASE64_STANDARD.encode(adi_pb),
        });
        if let Some(sim) = sim {
            body["sim"] = serde_json::Value::String(sim.to_string());
            body["device_id"] = serde_json::Value::String(state.get_device_id());
            body["md_lu"] = serde_json::Value::String(hex::encode(state.get_md_lu()));
        }

        let headers = self
            .client
            .post(format!("{}/v3/get_headers", self.url))
            .header(CONTENT_TYPE, "application/json")
            .body(body.to_string())
            .send()
            .await?
            .error_for_status()?
            .text()
            .await?;
        let headers = decode_json::<AnisetteHeaders>(&headers, "/v3/get_headers response")?;

        match headers {
            AnisetteHeaders::Headers {
                machine_id,
                one_time_password,
                routing_info,
            } => Ok(AnisetteDataResponse::Data(AnisetteData {
                machine_id,
                one_time_password,
                routing_info,
                _device_description: client_info.client_info.clone(),
                device_unique_identifier: state.get_device_id(),
                _local_user_id: hex::encode(state.get_md_lu()),
                generated_at: SystemTime::now(),
            })),
            AnisetteHeaders::GetHeadersError { message } => {
                if message.contains("-45061") {
                    warn!("Server says anisette not provisioned");
                    return Ok(AnisetteDataResponse::IncorrectlyProvisioned);
                }
                Err(report!("Failed to get anisette headers ({} bytes withheld)", message.len())
                    .context(ProvisioningFault { stage: ProvisioningStage::HeaderFetch, code: known_adi_code(&message) })
                    .into())
            }
        }
    }

    /// The device state to use, provisioned. Zag Store fork: the whole
    /// decision runs under the lock of this provider's state scope, and the
    /// stored state is read again under it. Another provider for the same
    /// account (another bridge session) may have provisioned or reset while
    /// this one waited, and its device is then adopted, never replaced.
    async fn get_state(
        &mut self,
        gs: &Arc<GrandSlam>,
        force_reset: bool,
    ) -> Result<&mut AnisetteState, Report> {
        let lock = coordination::lock(self.state_scope.as_deref());
        let _guard = lock.lock().await;

        // A storage that cannot be read is not an absent state. Starting
        // fresh there would provision a new device with Apple and then
        // overwrite the stored identity, so it stops instead.
        // Zag Store fork: resolve which stored-state slot this provider's
        // identity may use, keeping the legacy slot for the identity that owns
        // it and giving any other provider or client identity a separate one.
        let (state_key, claim) = self.resolve_state_slot()?;
        let stored = self
            .storage
            .retrieve_data(&state_key)
            .context("Failed to read stored anisette state")?;
        let (stored, corrupt) = match stored {
            Some(bytes) => match plist::from_bytes::<AnisetteState>(&bytes) {
                Ok(state) => (Some(state), false),
                Err(_) => (None, true),
            },
            None => (None, false),
        };
        // On a reset, the device being rejected is this provider's own.
        let rejected = force_reset.then(|| self.state.as_ref().map(|s| s.keychain_identifier)).flatten();

        if let Some(state) = stored.filter(|s| s.is_provisioned() && Some(s.keychain_identifier) != rejected) {
            let adopted = self.state.as_ref().is_some_and(|own| own.keychain_identifier != state.keychain_identifier);
            diagnostics::record(if adopted { StateChange::Adopted } else { StateChange::Loaded });
            info!("Using stored anisette state");
            // Zag Store fork: adopting pre-existing, unmarked legacy state is a
            // one-time migration to this identity. It is recorded, not silent;
            // after it, any different identity is routed to its own slot.
            if claim.is_some() && state_key == ANISETTE_STATE_KEY {
                warn!("Migrating unmarked legacy anisette state to this provider/client identity");
            }
            self.claim_state_slot(&claim)?;
            return Ok(self.state.insert(state));
        }

        let mut state = if force_reset {
            warn!("Resetting anisette state");
            diagnostics::record(StateChange::Reset);
            AnisetteState::new()
        } else {
            // Cloned, not taken: if this call is cancelled during the exchange,
            // the provider keeps its identity rather than losing it.
            match self.state.clone() {
                // An earlier attempt of this provider: keep its identity.
                Some(own) => own,
                None => {
                    diagnostics::record(if corrupt { StateChange::ReplacedCorrupt } else { StateChange::Created });
                    AnisetteState::new()
                }
            }
        };

        if !state.is_provisioned() {
            info!("Provisioning required...");
            let result = self.exchange(&mut state, gs).await;
            if let Err(error) = result {
                self.state = Some(state);
                return Err(error.context("Failed to provision").into());
            }
        }
        let mut bytes = Vec::new();
        plist::to_writer_xml(&mut bytes, &state)?;
        // Zag Store fork: write the ownership marker BEFORE the state, so a
        // failure between the two writes can only leave a marked slot with no
        // state (the owner re-provisions) — never state without a marker, which
        // a different provider could then adopt.
        self.claim_state_slot(&claim)?;
        self.storage.store_data(&state_key, &bytes)?;
        let state = self.state.insert(state);
        Ok(state)
    }

    async fn exchange(&self, state: &mut AnisetteState, gs: &Arc<GrandSlam>) -> Result<(), Report> {
        #[cfg(test)]
        if let Some(exchange) = self.test_exchange {
            tokio::time::sleep(std::time::Duration::from_millis(30)).await;
            return exchange(state);
        }
        Self::provision(state, gs, &self.url).await
    }

    async fn provisioning_headers(state: &AnisetteState) -> Result<HeaderMap, Report> {
        let mut headers = HeaderMap::new();
        headers.insert(
            "X-Apple-I-MD-LU",
            HeaderValue::from_str(&hex::encode(state.get_md_lu()))?,
        );
        // headers.insert(
        //     "X-Apple-I-Client-Time",
        //     HeaderValue::from_str(
        //         &Utc::now()
        //             .round_subsecs(0)
        //             .format("%+")
        //             .to_string()
        //             .replace("+00:00", "Z"),
        //     )?,
        // );
        // headers.insert("X-Apple-I-TimeZone", HeaderValue::from_static("UTC"));
        // headers.insert("X-Apple-Locale", HeaderValue::from_static("en_US"));
        headers.insert(
            "X-Mme-Device-Id",
            HeaderValue::from_str(&state.get_device_id())?,
        );

        Ok(headers)
    }
    async fn provision(
        state: &mut AnisetteState,
        gs: &Arc<GrandSlam>,
        url: &str,
    ) -> Result<(), Report> {
        let start_provisioning = gs.get_url("midStartProvisioning")?;
        let end_provisioning = gs.get_url("midFinishProvisioning")?;

        let websocket_url = format!("{}/v3/provisioning_session", url)
            .replacen("https://", "wss://", 1);

        debug!("Starting provisioning at {}", websocket_url);
        // let (mut ws_stream, _) = timeout(
        //     Duration::from_secs(30),
        //     tokio_tungstenite::connect_async(&websocket_url),
        // )
        // .await
        // .map_err(|_| {
        //     report!("Timed out connecting to provisioning socket. Try a different anisette server.")
        // })
        // .context("Failed to connect to provisioning socket")?
        // .context("Failed to connect to provisioning socket")?;

        let mut ws = AppWebSocket::connect(&websocket_url, url)
            .await
            .context("Failed to connect to provisioning socket")?;

        debug!("Connected to provisioning socket");

        loop {
            // Zag Store fork: an ended stream returns None at once, every
            // time; continuing would spin without yielding (uncancellable).
            let Some(msg) = ws.next().await else { bail!("Provisioning socket ended unexpectedly") };
            let msg = msg?;

            let text = match msg {
                WsMessage::Close => bail!("Provisioning socket closed unexpectedly"),
                WsMessage::Text(t) => t,
            };

            // Provisioning messages may carry CPIM, PTM, TK, or ADI state.
            // Never log raw payloads, even at debug level.
            let provision_msg: ProvisioningMessage = decode_json(&text, "provisioning message")?;

            match provision_msg {
                ProvisioningMessage::GiveIdentifier => {
                    ws.send_text(
                        serde_json::json!({
                            "identifier": BASE64_STANDARD.encode(state.keychain_identifier),
                        })
                        .to_string()
                        .into(),
                    )
                    .await
                    .context("Failed to send identifier")?;
                }
                ProvisioningMessage::GiveStartProvisioningData => {
                    let body = plist!(dict {
                        "Header": {},
                        "Request": {}
                    });

                    let response = gs
                        .plist_request(
                            &start_provisioning,
                            &body,
                            Some(Self::provisioning_headers(state).await?),
                            None,
                        )
                        .await
                        // Zag Store fork: tag the boundary so a diagnostic can tell a
                        // failure of our own call to Apple's midStartProvisioning
                        // (e.g. an HTTP 401) from a server-side StartProvisioningError.
                        .context(ProvisioningFault { stage: ProvisioningStage::StartProvisioning, code: None })
                        .context("Failed to send start provisioning request")?;

                    let spim = response
                        .get_str("spim")
                        .context("Start provisioning response missing spim")?;

                    ws.send_text(
                        serde_json::json!({
                            "spim": spim,
                        })
                        .to_string()
                        .into(),
                    )
                    .await
                    .context("Failed to send start provisioning data")?;
                }
                ProvisioningMessage::GiveEndProvisioningData { cpim } => {
                    let body = plist!(dict {
                        "Header": {},
                        "Request": {
                            "cpim": cpim,
                        }
                    });

                    let response = gs
                        .plist_request(
                            &end_provisioning,
                            &body,
                            Some(Self::provisioning_headers(state).await?),
                            None,
                        )
                        .await
                        // Zag Store fork: tag the boundary so a diagnostic can tell a
                        // failure of our own call to Apple's midFinishProvisioning
                        // (the ecosystem-wide HTTP 401 since 2026-11-17) from a
                        // server-side EndProvisioningError.
                        .context(ProvisioningFault { stage: ProvisioningStage::EndProvisioning, code: None })
                        .context("Failed to send end provisioning request")?;

                    ws.send_text(
                        serde_json::json!({
                            "ptm": response
                                .get_str("ptm")
                                .context("End provisioning response missing ptm")?,
                            "tk": response
                                .get_str("tk")
                                .context("End provisioning response missing tk")?,
                        })
                        .to_string()
                        .into(),
                    )
                    .await
                    .context("Failed to send start provisioning data")?;
                }
                ProvisioningMessage::ProvisioningSuccess { adi_pb } => {
                    state.adi_pb = Some(
                        BASE64_STANDARD
                            .decode(adi_pb)
                            .map_err(|_| report!("Provisioning result is not valid base64"))?,
                    );
                    // Zag Store fork: provisioning is complete; a failed close
                    // must not discard it before it is stored.
                    let _ = ws.close().await;
                    info!("Provisioning successful");
                    break;
                }
                ProvisioningMessage::Timeout => bail!("Anisette provisioning timed out"),
                ProvisioningMessage::InvalidIdentifier => {
                    return Err(report!("Anisette provisioning failed: invalid identifier")
                        .context(ProvisioningFault { stage: ProvisioningStage::Identifier, code: None })
                        .into());
                }
                // Zag Store fork: the server's message may echo Apple's
                // response; only its length is reported.
                ProvisioningMessage::StartProvisioningError { message } => {
                    return Err(report!("Anisette provisioning failed: start provisioning error ({} bytes withheld)", message.len())
                        .context(ProvisioningFault { stage: ProvisioningStage::StartProvisioning, code: known_adi_code(&message) })
                        .into());
                }
                ProvisioningMessage::EndProvisioningError { message } => {
                    return Err(report!("Anisette provisioning failed: end provisioning error ({} bytes withheld)", message.len())
                        .context(ProvisioningFault { stage: ProvisioningStage::EndProvisioning, code: known_adi_code(&message) })
                        .into());
                }
            }
        }

        Ok(())
    }
}

#[derive(Deserialize)]
#[serde(tag = "result")]
enum ProvisioningMessage {
    GiveIdentifier,
    GiveStartProvisioningData,
    GiveEndProvisioningData { cpim: String },
    ProvisioningSuccess { adi_pb: String },
    Timeout,
    InvalidIdentifier,
    StartProvisioningError { message: String },
    EndProvisioningError { message: String },
}

#[derive(Deserialize)]
#[serde(tag = "result")]
enum AnisetteHeaders {
    GetHeadersError {
        message: String,
    },
    Headers {
        #[serde(rename = "X-Apple-I-MD-M")]
        machine_id: String,
        #[serde(rename = "X-Apple-I-MD")]
        one_time_password: String,
        #[serde(rename = "X-Apple-I-MD-RINFO")]
        routing_info: String,
    },
}

#[cfg(test)]
mod persistence_tests {
    use super::*;
    use std::sync::Mutex;

    /// Records writes; reads return `read` (an error when `None`).
    struct Recording {
        read: Option<Option<Vec<u8>>>,
        writes: Arc<Mutex<Vec<Vec<u8>>>>,
    }

    impl SideloadingStorage for Recording {
        fn store(&self, _: &str, _: &str) -> Result<(), Report> {
            unreachable!("state is stored as data")
        }
        fn retrieve(&self, _: &str) -> Result<Option<String>, Report> {
            unreachable!("state is read as data")
        }
        fn store_data(&self, _: &str, value: &[u8]) -> Result<(), Report> {
            self.writes.lock().unwrap().push(value.to_vec());
            Ok(())
        }
        fn retrieve_data(&self, _: &str) -> Result<Option<Vec<u8>>, Report> {
            self.read.clone().ok_or_else(|| report!("Keychain unavailable"))
        }
    }

    fn provider(read: Option<Option<Vec<u8>>>) -> (RemoteV3AnisetteProvider, Arc<Mutex<Vec<Vec<u8>>>>) {
        let _ = rustls::crypto::ring::default_provider().install_default();
        let writes = Arc::new(Mutex::new(Vec::new()));
        let storage = Recording { read, writes: writes.clone() };
        let provider = RemoteV3AnisetteProvider::new("https://anisette.example", Box::new(storage), "S".into()).unwrap();
        (provider, writes)
    }

    fn stored(state: &AnisetteState) -> Vec<u8> {
        let mut bytes = Vec::new();
        plist::to_writer_xml(&mut bytes, state).unwrap();
        bytes
    }

    #[tokio::test]
    async fn unreadable_storage_never_replaces_the_identity() {
        // A Keychain read that fails (not "not found") must stop: starting
        // fresh would register a new device with Apple and overwrite the
        // stored one.
        let (mut provider, writes) = provider(None);
        let gs = Arc::new(GrandSlam::offline_for_tests());
        assert!(provider.get_state(&gs, false).await.is_err());
        assert!(provider.state.is_none());
        assert!(writes.lock().unwrap().is_empty());
    }

    #[tokio::test]
    async fn stored_identity_is_reused_without_provisioning() {
        let state = AnisetteState { keychain_identifier: [7; 16], adi_pb: Some(vec![1, 2, 3]) };
        let (mut provider, writes) = provider(Some(Some(stored(&state))));
        // The URL bag is empty: any attempt to provision would fail.
        let gs = Arc::new(GrandSlam::offline_for_tests());
        let loaded = provider.get_state(&gs, false).await.unwrap();
        assert_eq!(loaded.keychain_identifier, [7; 16]);
        assert_eq!(loaded.adi_pb.as_deref(), Some(&[1u8, 2, 3][..]));
        assert!(writes.lock().unwrap().is_empty(), "an unchanged state is not written again");
    }

    /// One Keychain, as two bridge sessions for the same account see it.
    struct Shared(Arc<crate::util::storage::InMemoryStorage>);

    impl SideloadingStorage for Shared {
        fn store(&self, key: &str, value: &str) -> Result<(), Report> {
            self.0.store(key, value)
        }
        fn retrieve(&self, key: &str) -> Result<Option<String>, Report> {
            self.0.retrieve(key)
        }
    }

    fn sharing(storage: &Arc<crate::util::storage::InMemoryStorage>, scope: &str, exchange: fn(&mut AnisetteState) -> Result<(), Report>) -> RemoteV3AnisetteProvider {
        let _ = rustls::crypto::ring::default_provider().install_default();
        let mut provider = RemoteV3AnisetteProvider::new("https://anisette.example", Box::new(Shared(storage.clone())), "S".into())
            .unwrap()
            .set_state_scope(scope);
        provider.test_exchange = Some(exchange);
        provider
    }

    fn stored_identity(storage: &crate::util::storage::InMemoryStorage) -> [u8; 16] {
        let bytes = storage.retrieve_data(ANISETTE_STATE_KEY).unwrap().unwrap();
        plist::from_bytes::<AnisetteState>(&bytes).unwrap().keychain_identifier
    }

    static FIRST_EXCHANGES: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
    fn first_exchange(state: &mut AnisetteState) -> Result<(), Report> {
        FIRST_EXCHANGES.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        state.adi_pb = Some(vec![9]);
        Ok(())
    }

    #[tokio::test]
    async fn two_sessions_for_one_account_provision_one_device() {
        // Two independent providers (two bridge sessions) over one stored
        // state, both finding none: one provisions, the other adopts it.
        let storage = Arc::new(crate::util::storage::InMemoryStorage::new());
        let gs = Arc::new(GrandSlam::offline_for_tests());
        let (mut a, mut b) = (sharing(&storage, "test-first", first_exchange), sharing(&storage, "test-first", first_exchange));
        let (ra, rb) = tokio::join!(a.get_state(&gs, false), b.get_state(&gs, false));
        let (ia, ib) = (ra.unwrap().keychain_identifier, rb.unwrap().keychain_identifier);
        assert_eq!(FIRST_EXCHANGES.load(std::sync::atomic::Ordering::SeqCst), 1, "one device registered, not two");
        assert_eq!(ia, ib);
        assert_eq!(stored_identity(&storage), ia, "the stored identity is the one both use");
    }

    static RESET_EXCHANGES: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
    fn reset_exchange(state: &mut AnisetteState) -> Result<(), Report> {
        RESET_EXCHANGES.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        state.adi_pb = Some(vec![8]);
        Ok(())
    }

    #[tokio::test]
    async fn two_sessions_resetting_one_device_reset_it_once() {
        // Both sessions use device X; the server rejects it (-45061) for both.
        // The second must adopt the first's replacement, not reset it again.
        let storage = Arc::new(crate::util::storage::InMemoryStorage::new());
        let old = AnisetteState { keychain_identifier: [3; 16], adi_pb: Some(vec![1]) };
        storage.store_data(ANISETTE_STATE_KEY, &stored(&old)).unwrap();
        let gs = Arc::new(GrandSlam::offline_for_tests());
        let (mut a, mut b) = (sharing(&storage, "test-reset", reset_exchange), sharing(&storage, "test-reset", reset_exchange));
        assert_eq!(a.get_state(&gs, false).await.unwrap().keychain_identifier, [3; 16]);
        assert_eq!(b.get_state(&gs, false).await.unwrap().keychain_identifier, [3; 16]);
        let (ra, rb) = tokio::join!(a.get_state(&gs, true), b.get_state(&gs, true));
        let (ia, ib) = (ra.unwrap().keychain_identifier, rb.unwrap().keychain_identifier);
        assert_eq!(RESET_EXCHANGES.load(std::sync::atomic::Ordering::SeqCst), 1, "reset once");
        assert_eq!(ia, ib);
        assert_ne!(ia, [3; 16], "the rejected device is not kept");
        assert_eq!(stored_identity(&storage), ia);
    }

    fn never_exchange(_: &mut AnisetteState) -> Result<(), Report> {
        panic!("must not provision")
    }

    #[tokio::test]
    async fn reset_adopts_a_replacement_another_session_made() {
        // This provider's device X was rejected (-45061), but storage already
        // holds Y, made by another session: Y is adopted, nothing provisioned.
        let storage = Arc::new(crate::util::storage::InMemoryStorage::new());
        let y = AnisetteState { keychain_identifier: [5; 16], adi_pb: Some(vec![5]) };
        storage.store_data(ANISETTE_STATE_KEY, &stored(&y)).unwrap();
        let gs = Arc::new(GrandSlam::offline_for_tests());
        let mut provider = sharing(&storage, "test-adopt-reset", never_exchange);
        provider.state = Some(AnisetteState { keychain_identifier: [4; 16], adi_pb: Some(vec![4]) });
        let before = diagnostics::count(StateChange::Adopted);
        assert_eq!(provider.get_state(&gs, true).await.unwrap().keychain_identifier, [5; 16]);
        assert!(diagnostics::count(StateChange::Adopted) > before);
    }

    #[tokio::test]
    async fn reset_of_the_stored_device_replaces_it() {
        let storage = Arc::new(crate::util::storage::InMemoryStorage::new());
        let x = AnisetteState { keychain_identifier: [6; 16], adi_pb: Some(vec![6]) };
        storage.store_data(ANISETTE_STATE_KEY, &stored(&x)).unwrap();
        let gs = Arc::new(GrandSlam::offline_for_tests());
        let mut provider = sharing(&storage, "test-reset-own", corrupt_exchange);
        provider.state = Some(x);
        let identity = provider.get_state(&gs, true).await.unwrap().keychain_identifier;
        assert_ne!(identity, [6; 16], "the rejected device is not adopted back");
        assert_eq!(stored_identity(&storage), identity);
    }

    fn slow_exchange(state: &mut AnisetteState) -> Result<(), Report> {
        state.adi_pb = Some(vec![1]);
        Ok(())
    }

    #[tokio::test]
    async fn cancelled_provisioning_releases_the_lock_and_stores_nothing() {
        // The sign-in is cancelled mid-exchange (the future is dropped): the
        // scope's lock is released, nothing is stored, and the provider keeps
        // its in-memory identity.
        let storage = Arc::new(crate::util::storage::InMemoryStorage::new());
        let gs = Arc::new(GrandSlam::offline_for_tests());
        let mut a = sharing(&storage, "test-cancel", slow_exchange);
        a.state = Some(AnisetteState { keychain_identifier: [2; 16], adi_pb: None });
        // The test exchange waits 30 ms first; 5 ms cancels it inside.
        assert!(tokio::time::timeout(std::time::Duration::from_millis(5), a.get_state(&gs, false)).await.is_err());
        assert!(storage.retrieve_data(ANISETTE_STATE_KEY).unwrap().is_none());
        assert_eq!(a.state.as_ref().map(|s| s.keychain_identifier), Some([2; 16]));
        let mut b = sharing(&storage, "test-cancel", slow_exchange);
        let done = tokio::time::timeout(std::time::Duration::from_secs(2), b.get_state(&gs, false)).await;
        assert!(done.expect("the lock was released").is_ok());
    }

    #[tokio::test]
    async fn accounts_do_not_wait_for_each_other() {
        // Holding one account's lock blocks only that account.
        let held = coordination::lock(Some("test-account-a"));
        let _guard = held.lock().await;
        let gs = Arc::new(GrandSlam::offline_for_tests());
        let other = Arc::new(crate::util::storage::InMemoryStorage::new());
        let mut b = sharing(&other, "test-account-b", slow_exchange);
        let quick = std::time::Duration::from_millis(500);
        assert!(tokio::time::timeout(quick, b.get_state(&gs, false)).await.expect("another account is not blocked").is_ok());
        let same = Arc::new(crate::util::storage::InMemoryStorage::new());
        let mut a = sharing(&same, "test-account-a", slow_exchange);
        assert!(tokio::time::timeout(quick, a.get_state(&gs, false)).await.is_err(), "the same account waits");
        // A provider without a scope has a lock of its own.
        assert!(!Arc::ptr_eq(&coordination::lock(None), &coordination::lock(None)));
        assert!(Arc::ptr_eq(&held, &coordination::lock(Some("test-account-a"))));
    }

    fn corrupt_exchange(state: &mut AnisetteState) -> Result<(), Report> {
        state.adi_pb = Some(vec![7]);
        Ok(())
    }

    #[tokio::test]
    async fn corrupted_state_is_replaced_and_counted_without_data() {
        let storage = Arc::new(crate::util::storage::InMemoryStorage::new());
        storage.store_data(ANISETTE_STATE_KEY, b"not a plist").unwrap();
        let before = diagnostics::count(StateChange::ReplacedCorrupt);
        let gs = Arc::new(GrandSlam::offline_for_tests());
        let mut provider = sharing(&storage, "test-corrupt", corrupt_exchange);
        let identity = provider.get_state(&gs, false).await.unwrap().keychain_identifier;
        assert_eq!(stored_identity(&storage), identity, "recovered: a new, provisioned device is stored");
        assert!(diagnostics::count(StateChange::ReplacedCorrupt) > before, "the replacement is recorded");
        // The diagnostic is a variant and a number: nothing else exists to leak.
        assert_eq!(format!("{:?}", StateChange::ReplacedCorrupt), "ReplacedCorrupt");
    }

    #[tokio::test]
    async fn failed_provisioning_stores_nothing() {
        // Absent state: a fresh identity is provisioned. When that fails, the
        // half-made identity is never stored.
        let (mut provider, writes) = provider(Some(None));
        let gs = Arc::new(GrandSlam::offline_for_tests());
        assert!(provider.get_state(&gs, false).await.is_err());
        assert!(writes.lock().unwrap().is_empty());
        assert!(!provider.state.as_ref().unwrap().is_provisioned());
    }

    // --- Zag Store fork: provider / client-identity isolation of stored state.
    // Local-storage hardening only. None of this affects Apple's own
    // authentication or provisioning decisions (HTTP 401/503, ADI -29003).

    fn provision_exchange(state: &mut AnisetteState) -> Result<(), Report> {
        state.adi_pb = Some(vec![1]);
        Ok(())
    }

    /// A provider over one account's Keychain, for a named anisette endpoint.
    fn sharing_url(
        storage: &Arc<crate::util::storage::InMemoryStorage>,
        scope: &str,
        url: &str,
        exchange: fn(&mut AnisetteState) -> Result<(), Report>,
    ) -> RemoteV3AnisetteProvider {
        let _ = rustls::crypto::ring::default_provider().install_default();
        let mut provider = RemoteV3AnisetteProvider::new(url, Box::new(Shared(storage.clone())), "S".into())
            .unwrap()
            .set_state_scope(scope);
        provider.test_exchange = Some(exchange);
        provider
    }

    #[tokio::test]
    async fn a_different_provider_keeps_its_own_device_and_preserves_the_other() {
        // One account, two anisette endpoints. The second must not read or
        // overwrite the first's device: each keeps its own across reloads.
        let storage = Arc::new(crate::util::storage::InMemoryStorage::new());
        let gs = Arc::new(GrandSlam::offline_for_tests());
        let mut a = sharing_url(&storage, "acct", "https://a.example", provision_exchange);
        let ia = a.get_state(&gs, false).await.unwrap().keychain_identifier;
        let legacy_after_a = storage.retrieve_data(ANISETTE_STATE_KEY).unwrap().unwrap();

        let mut b = sharing_url(&storage, "acct", "https://b.example", provision_exchange);
        let _ib = b.get_state(&gs, false).await.unwrap().keychain_identifier;
        assert_eq!(
            storage.retrieve_data(ANISETTE_STATE_KEY).unwrap().unwrap(),
            legacy_after_a,
            "a different provider never overwrites the legacy slot",
        );

        // Reloading each, with provisioning forbidden, must find its own device.
        let mut a2 = sharing_url(&storage, "acct", "https://a.example", never_exchange);
        assert_eq!(a2.get_state(&gs, false).await.unwrap().keychain_identifier, ia, "A still has its own device");
        let mut b2 = sharing_url(&storage, "acct", "https://b.example", never_exchange);
        assert_eq!(b2.get_state(&gs, false).await.unwrap().keychain_identifier, _ib, "B keeps its own device");
    }

    #[tokio::test]
    async fn legacy_state_without_a_marker_is_kept_not_reprovisioned() {
        // A pre-upgrade install: state under the legacy slot, no marker. The
        // current provider adopts it (no re-provisioning, no invalidation) and
        // claims the slot, so a later different provider gets its own slot.
        let storage = Arc::new(crate::util::storage::InMemoryStorage::new());
        let legacy = AnisetteState { keychain_identifier: [11; 16], adi_pb: Some(vec![1, 2]) };
        storage.store_data(ANISETTE_STATE_KEY, &stored(&legacy)).unwrap();
        let gs = Arc::new(GrandSlam::offline_for_tests());

        let mut p = sharing_url(&storage, "acct", "https://a.example", never_exchange);
        assert_eq!(p.get_state(&gs, false).await.unwrap().keychain_identifier, [11; 16], "the existing device is kept");

        let mut other = sharing_url(&storage, "acct", "https://b.example", corrupt_exchange);
        let other_id = other.get_state(&gs, false).await.unwrap().keychain_identifier;
        assert_ne!(other_id, [11; 16], "a different provider does not adopt the legacy device");
        assert_eq!(stored_identity(&storage), [11; 16], "the legacy device remains under the legacy slot");
    }

    /// A Keychain whose identity-marker read fails, while state reads succeed.
    struct FailMarker(Arc<crate::util::storage::InMemoryStorage>);
    impl SideloadingStorage for FailMarker {
        fn store(&self, key: &str, value: &str) -> Result<(), Report> {
            self.0.store(key, value)
        }
        fn retrieve(&self, key: &str) -> Result<Option<String>, Report> {
            if key == ANISETTE_IDENTITY_KEY {
                return Err(report!("identity marker unreadable"));
            }
            self.0.retrieve(key)
        }
    }

    #[tokio::test]
    async fn an_unreadable_identity_marker_stops_rather_than_reusing_state() {
        // A marker that cannot be read is not an unclaimed slot: the provider
        // stops rather than risk reusing or overwriting another identity's
        // device.
        let storage = Arc::new(crate::util::storage::InMemoryStorage::new());
        storage
            .store_data(ANISETTE_STATE_KEY, &stored(&AnisetteState { keychain_identifier: [1; 16], adi_pb: Some(vec![9]) }))
            .unwrap();
        let gs = Arc::new(GrandSlam::offline_for_tests());
        let _ = rustls::crypto::ring::default_provider().install_default();
        let mut p = RemoteV3AnisetteProvider::new("https://a.example", Box::new(FailMarker(storage.clone())), "S".into())
            .unwrap()
            .set_state_scope("acct");
        p.test_exchange = Some(never_exchange);
        assert!(p.get_state(&gs, false).await.is_err(), "an unreadable marker is fail-closed");
    }

    #[tokio::test]
    async fn endpoints_differing_only_in_case_or_trailing_slash_share_a_slot() {
        // One endpoint written two ways is one identity: the device is reused,
        // not re-provisioned.
        let storage = Arc::new(crate::util::storage::InMemoryStorage::new());
        let gs = Arc::new(GrandSlam::offline_for_tests());
        let mut a = sharing_url(&storage, "acct", "https://A.Example/", provision_exchange);
        let id = a.get_state(&gs, false).await.unwrap().keychain_identifier;
        let mut b = sharing_url(&storage, "acct", "https://a.example", never_exchange);
        assert_eq!(b.get_state(&gs, false).await.unwrap().keychain_identifier, id, "normalised to the same identity");
    }

    // --- Follow-up hardening (PR #54 review): effective client identity,
    // conservative legacy ownership, and partial-write safety.

    /// A provider over one account's Keychain, for a named endpoint AND a
    /// named effective client identity.
    fn sharing_client(
        storage: &Arc<crate::util::storage::InMemoryStorage>,
        scope: &str,
        url: &str,
        client_info: &str,
        exchange: fn(&mut AnisetteState) -> Result<(), Report>,
    ) -> RemoteV3AnisetteProvider {
        let mut provider = sharing_url(storage, scope, url, exchange);
        provider.effective_client_info = Some(client_info.to_string());
        provider
    }

    #[tokio::test]
    async fn same_client_identity_reuses_state() {
        // Scenario 1: same provider and unchanged client identity → reuse.
        let storage = Arc::new(crate::util::storage::InMemoryStorage::new());
        let gs = Arc::new(GrandSlam::offline_for_tests());
        let info = "iPhone16,2 <macOS;15.0;24A1> <akd/1>";
        let mut a = sharing_client(&storage, "acct", "https://a.example", info, provision_exchange);
        let id = a.get_state(&gs, false).await.unwrap().keychain_identifier;
        let mut b = sharing_client(&storage, "acct", "https://a.example", info, never_exchange);
        assert_eq!(b.get_state(&gs, false).await.unwrap().keychain_identifier, id, "the same client identity reuses the device");
    }

    #[tokio::test]
    async fn whitespace_equivalent_client_identity_reuses_state() {
        // Scenario 2: semantically equivalent metadata (whitespace only) →
        // reuse, because whitespace is the one provably non-semantic change.
        let storage = Arc::new(crate::util::storage::InMemoryStorage::new());
        let gs = Arc::new(GrandSlam::offline_for_tests());
        let mut a = sharing_client(&storage, "acct", "https://a.example", "iPhone16,2 <macOS;15.0;24A1>", provision_exchange);
        let id = a.get_state(&gs, false).await.unwrap().keychain_identifier;
        let mut b = sharing_client(&storage, "acct", "https://a.example", "  iPhone16,2   <macOS;15.0;24A1> ", never_exchange);
        assert_eq!(b.get_state(&gs, false).await.unwrap().keychain_identifier, id, "whitespace-only differences reuse the device");
    }

    #[tokio::test]
    async fn materially_different_client_identity_is_isolated_and_each_recovers() {
        // Scenarios 3/4 (material or unprovable change → no silent reuse) and
        // 5 (switching back recovers the original state).
        let storage = Arc::new(crate::util::storage::InMemoryStorage::new());
        let gs = Arc::new(GrandSlam::offline_for_tests());
        let mut x = sharing_client(&storage, "acct", "https://a.example", "iPhone16,2 <macOS;15.0;24A1>", provision_exchange);
        let id_x = x.get_state(&gs, false).await.unwrap().keychain_identifier;
        // A materially different client identity (different model) on the same
        // endpoint must provision its own device, not reuse X's.
        let mut y = sharing_client(&storage, "acct", "https://a.example", "iPad14,1 <macOS;15.0;24A1>", corrupt_exchange);
        let id_y = y.get_state(&gs, false).await.unwrap().keychain_identifier;
        assert_eq!(stored_identity(&storage), id_x, "X's state (the legacy slot) is preserved, not overwritten");

        // Each identity recovers its own state on a later run (no re-provision).
        let mut x2 = sharing_client(&storage, "acct", "https://a.example", "iPhone16,2 <macOS;15.0;24A1>", never_exchange);
        assert_eq!(x2.get_state(&gs, false).await.unwrap().keychain_identifier, id_x, "X recovers its own device");
        let mut y2 = sharing_client(&storage, "acct", "https://a.example", "iPad14,1 <macOS;15.0;24A1>", never_exchange);
        assert_eq!(y2.get_state(&gs, false).await.unwrap().keychain_identifier, id_y, "Y recovers its own device");
    }

    #[tokio::test]
    async fn provider_switch_during_upgrade_preserves_legacy_and_isolates_the_new_provider() {
        // Pre-upgrade: legacy state under the legacy slot, no marker.
        let storage = Arc::new(crate::util::storage::InMemoryStorage::new());
        let legacy = AnisetteState { keychain_identifier: [21; 16], adi_pb: Some(vec![4, 2]) };
        storage.store_data(ANISETTE_STATE_KEY, &stored(&legacy)).unwrap();
        let gs = Arc::new(GrandSlam::offline_for_tests());

        // First post-upgrade run keeps the same endpoint: the legacy device is
        // migrated to it, not re-provisioned (no session is invalidated).
        let mut original = sharing_url(&storage, "acct", "https://a.example", never_exchange);
        assert_eq!(original.get_state(&gs, false).await.unwrap().keychain_identifier, [21; 16]);

        // The user then switches to a different anisette provider: it must not
        // reuse or overwrite the original's device.
        let mut switched = sharing_url(&storage, "acct", "https://b.example", corrupt_exchange);
        let switched_id = switched.get_state(&gs, false).await.unwrap().keychain_identifier;
        assert_ne!(switched_id, [21; 16], "the switched provider provisions its own device");
        assert_eq!(stored_identity(&storage), [21; 16], "the original provider's legacy device is preserved");
    }

    /// A Keychain that fails to write the state blob but allows other writes,
    /// to model a crash between the marker write and the state write.
    struct FailStateWrite(Arc<crate::util::storage::InMemoryStorage>);
    impl SideloadingStorage for FailStateWrite {
        fn store(&self, key: &str, value: &str) -> Result<(), Report> {
            if key == ANISETTE_STATE_KEY {
                return Err(report!("state write failed"));
            }
            self.0.store(key, value)
        }
        fn retrieve(&self, key: &str) -> Result<Option<String>, Report> {
            self.0.retrieve(key)
        }
    }

    #[tokio::test]
    async fn a_failure_between_marker_and_state_writes_leaves_no_adoptable_unmarked_state() {
        // The marker is written before the state. If the state write then
        // fails, the slot is marked but empty (the owner re-provisions) — there
        // is never state without a marker for another provider to adopt.
        let backing = Arc::new(crate::util::storage::InMemoryStorage::new());
        let gs = Arc::new(GrandSlam::offline_for_tests());
        let _ = rustls::crypto::ring::default_provider().install_default();
        let mut a = RemoteV3AnisetteProvider::new("https://a.example", Box::new(FailStateWrite(backing.clone())), "S".into())
            .unwrap()
            .set_state_scope("acct");
        a.test_exchange = Some(provision_exchange);
        assert!(a.get_state(&gs, false).await.is_err(), "the state write failed");
        assert!(backing.retrieve_data(ANISETTE_STATE_KEY).unwrap().is_none(), "no unmarked state remains at the legacy slot");
        assert!(backing.retrieve_data(ANISETTE_IDENTITY_KEY).unwrap().is_some(), "the slot is marked");

        // A different provider is routed to its own slot and never adopts the
        // legacy slot.
        let mut b = sharing_url(&backing, "acct", "https://b.example", provision_exchange);
        assert!(b.get_state(&gs, false).await.is_ok(), "a different provider provisions its own device");
        assert!(backing.retrieve_data(ANISETTE_STATE_KEY).unwrap().is_none(), "the legacy slot stays empty; nothing was adopted");
    }
}
