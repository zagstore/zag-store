pub mod remote_v3;

use crate::auth::grandslam::GrandSlam;
use plist::Dictionary;
use plist_macro::plist;
use reqwest::header::HeaderMap;
use rootcause::prelude::*;
use serde::Deserialize;
use std::{collections::HashMap, sync::Arc};
use tokio::sync::RwLock;
use web_time::SystemTime;

#[derive(Deserialize, Debug, Clone)]
pub struct AnisetteClientInfo {
    pub client_info: String,
    pub user_agent: String,
}

#[derive(Clone)]
pub struct AnisetteData {
    machine_id: String,
    one_time_password: String,
    pub routing_info: String,
    _device_description: String,
    device_unique_identifier: String,
    _local_user_id: String,
    generated_at: SystemTime,
    local_headers: HashMap<String, String>,
}

/// Zag Store fork: the one-time password, machine and device identifiers
/// and routing info are never shown.
impl std::fmt::Debug for AnisetteData {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("AnisetteData")
            .field("values", &"<withheld>")
            .field("generated_at", &self.generated_at)
            .finish()
    }
}

impl AnisetteData {
    /// Adapts the clean-room apple-auth provider's local header snapshot.
    /// Accept only anisette fields and keep the client identity in GrandSlam.
    pub fn from_local_headers(headers: &HashMap<String, String>) -> Result<Self, Report> {
        let required = |name: &str| {
            let mut values = headers
                .iter()
                .filter(|(key, _)| key.eq_ignore_ascii_case(name));
            let value = values
                .next()
                .map(|(_, value)| value)
                .filter(|value| !value.is_empty() && value.len() <= 4096)
                .ok_or_else(|| report!("Missing local anisette header"))?;
            if values.next().is_some() || reqwest::header::HeaderValue::from_str(value).is_err() {
                bail!("Invalid local anisette header");
            }
            Ok::<_, Report>(value.clone())
        };
        let local_headers = [
            "X-Apple-I-MD-RINFO",
            "X-Apple-I-MD-LU",
            "X-Apple-I-Client-Time",
            "X-Apple-I-TimeZone",
            "X-Apple-Locale",
        ]
        .into_iter()
        .map(|name| Ok((name.to_string(), required(name)?)))
        .collect::<Result<HashMap<_, _>, Report>>()?;
        Ok(Self {
            machine_id: required("X-Apple-I-MD-M")?,
            one_time_password: required("X-Apple-I-MD")?,
            routing_info: local_headers["X-Apple-I-MD-RINFO"].clone(),
            _device_description: required("X-MMe-Client-Info")?,
            device_unique_identifier: required("X-Mme-Device-Id")?,
            _local_user_id: local_headers["X-Apple-I-MD-LU"].clone(),
            generated_at: SystemTime::now(),
            local_headers,
        })
    }

    pub fn get_headers(&self) -> HashMap<String, String> {
        //let dt: DateTime<Utc> = Utc::now().round_subsecs(0);

        let mut headers = HashMap::from_iter([
            // (
            //     "X-Apple-I-Client-Time".to_string(),
            //     dt.format("%+").to_string().replace("+00:00", "Z"),
            // ),
            // ("X-Apple-I-SRL-NO".to_string(), serial),
            // ("X-Apple-I-TimeZone".to_string(), "UTC".to_string()),
            // ("X-Apple-Locale".to_string(), "en_US".to_string()),
            // ("X-Apple-I-MD-RINFO".to_string(), self.routing_info.clone()),
            // ("X-Apple-I-MD-LU".to_string(), self.local_user_id.clone()),
            (
                "X-Mme-Device-Id".to_string(),
                self.device_unique_identifier.clone(),
            ),
            ("X-Apple-I-MD".to_string(), self.one_time_password.clone()),
            ("X-Apple-I-MD-M".to_string(), self.machine_id.clone()),
            // (
            //     "X-Mme-Client-Info".to_string(),
            //     self.device_description.clone(),
            // ),
        ]);
        headers.extend(self.local_headers.clone());
        headers
    }

    pub fn get_header_map(&self) -> Result<HeaderMap, Report> {
        let headers_map = self.get_headers();
        let mut header_map = HeaderMap::new();

        for (key, value) in headers_map {
            header_map.insert(
                reqwest::header::HeaderName::from_bytes(key.as_bytes())?,
                reqwest::header::HeaderValue::from_str(&value)?,
            );
        }

        Ok(header_map)
    }

    pub fn get_client_provided_data(&self) -> Dictionary {
        let headers = self.get_headers();

        let mut cpd = plist!(dict {
            "bootstrap": "true",
            "icscrec": "true",
            "loc": "en_US",
            "pbe": "false",
            "prkgen": "true",
            "svct": "iCloud"
        });

        for (key, value) in headers {
            cpd.insert(key.to_string(), plist::Value::String(value));
        }

        cpd
    }

    pub fn needs_refresh(&self) -> bool {
        let elapsed = self.generated_at.elapsed();
        match elapsed {
            Ok(elapsed) => elapsed.as_secs() > 60,
            Err(_) => {
                warn!("Unable to determine anisette data age, treating as expired");
                true
            }
        }
    }
}

#[derive(Debug, Clone)]
pub enum AnisetteDataResponse {
    Data(AnisetteData),
    NeedsProvisioning,
    IncorrectlyProvisioned,
}

#[async_trait::async_trait]
pub trait AnisetteProvider {
    async fn get_anisette_data(&self) -> Result<AnisetteDataResponse, Report>;

    async fn resync(&self, _sim: &str) -> Result<AnisetteDataResponse, Report> {
        Err(report!("anisette resync not supported by this provider"))
    }

    async fn get_client_info(&self) -> Result<AnisetteClientInfo, Report>;

    async fn provision(&mut self, gs: &Arc<GrandSlam>, force_recheck: bool) -> Result<(), Report>;
}

#[derive(Clone)]
pub struct AnisetteDataGenerator {
    provider: Arc<RwLock<dyn AnisetteProvider + Send + Sync>>,
    data: Option<Arc<AnisetteData>>,
}

impl AnisetteDataGenerator {
    pub fn new(provider: Arc<RwLock<dyn AnisetteProvider + Send + Sync>>) -> Self {
        AnisetteDataGenerator {
            provider,
            data: None,
        }
    }

    pub async fn get_anisette_data(
        &mut self,
        gs: Arc<GrandSlam>,
    ) -> Result<Arc<AnisetteData>, Report> {
        if let Some(data) = &self.data
            && !data.needs_refresh()
        {
            return Ok(data.clone());
        }

        // 3 attempts for the worst case: load anisette from storage, server says -45061 -> reprovision anisette -> get data
        let data = self.get_data_or_provision(&gs, 3).await?;
        let arc_data = Arc::new(data);
        self.data = Some(arc_data.clone());
        Ok(arc_data)
    }

    async fn get_data_or_provision(
        &mut self,
        gs: &Arc<GrandSlam>,
        max_iters: usize,
    ) -> Result<AnisetteData, Report> {
        if max_iters == 0 {
            bail!("Max anisette provisioning attempts reached");
        }
        // trying to avoid locking as write unless necessary for concurrency later on
        let provider = self.provider.read().await;
        match provider.get_anisette_data().await? {
            AnisetteDataResponse::Data(data) => Ok(data),
            AnisetteDataResponse::NeedsProvisioning
            | AnisetteDataResponse::IncorrectlyProvisioned => {
                drop(provider);
                let mut provider_write = self.provider.write().await;
                // Zag Store fork: clones of this generator share the provider.
                // Another caller may have provisioned while this one waited for
                // the lock; provisioning again would register a second device
                // with Apple (or reset the one just made), so check first. The
                // reset is decided by this answer, not the one before the wait.
                let status = provider_write.get_anisette_data().await?;
                if let AnisetteDataResponse::Data(data) = status {
                    return Ok(data);
                }
                provider_write
                    .provision(
                        gs,
                        matches!(status, AnisetteDataResponse::IncorrectlyProvisioned),
                    )
                    .await?;
                drop(provider_write);
                Box::pin(self.get_data_or_provision(gs, max_iters - 1)).await
            }
        }
    }

    pub async fn get_client_info(&self) -> Result<AnisetteClientInfo, Report> {
        let provider = self.provider.read().await;
        provider.get_client_info().await
    }

    /// Perform a login anisette resync with the server, returning corrected data.
    pub async fn resync(&mut self, sim: &str) -> Result<Arc<AnisetteData>, Report> {
        let provider = self.provider.read().await;
        let data = match provider.resync(sim).await? {
            AnisetteDataResponse::Data(data) => data,
            _ => {
                bail!("Anisette provider failed to provide data for resync, needs provisioning");
            }
        };
        let arc_data = Arc::new(data);
        self.data = Some(arc_data.clone());
        Ok(arc_data)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    /// Unprovisioned until `provision` runs, which takes a while (as the real
    /// exchange with Apple does).
    struct Counting {
        provisioned: bool,
        provisions: Arc<AtomicUsize>,
        incorrect_first: bool,
    }

    #[test]
    fn local_headers_are_validated_and_only_anisette_fields_are_forwarded() {
        let mut headers: HashMap<String, String> = [
            ("X-Apple-I-MD", "otp"),
            ("X-Apple-I-MD-M", "machine"),
            ("X-Mme-Device-Id", "device"),
            ("X-MMe-Client-Info", "identity"),
            ("X-Apple-I-MD-RINFO", "routing"),
            ("X-Apple-I-MD-LU", "local-user"),
            ("X-Apple-I-Client-Time", "time"),
            ("X-Apple-I-TimeZone", "UTC"),
            ("X-Apple-Locale", "en_US"),
            ("Authorization", "unexpected"),
        ]
        .into_iter()
        .map(|(key, value)| (key.into(), value.into()))
        .collect();
        let adapted = AnisetteData::from_local_headers(&headers)
            .unwrap()
            .get_headers();
        assert_eq!(adapted["X-Apple-I-MD-RINFO"], "routing");
        assert_eq!(adapted["X-Apple-I-MD-LU"], "local-user");
        assert!(!adapted.contains_key("Authorization"));
        assert!(!adapted.contains_key("X-MMe-Client-Info"));
        headers.insert("x-apple-i-md".into(), "other".into());
        assert!(AnisetteData::from_local_headers(&headers).is_err());
        headers.remove("x-apple-i-md");
        headers.remove("X-Apple-I-MD-M");
        assert!(AnisetteData::from_local_headers(&headers).is_err());
    }

    fn data() -> AnisetteData {
        AnisetteData {
            machine_id: "M".into(),
            one_time_password: "O".into(),
            routing_info: "0".into(),
            _device_description: String::new(),
            device_unique_identifier: "D".into(),
            _local_user_id: String::new(),
            generated_at: SystemTime::now(),
            local_headers: HashMap::new(),
        }
    }

    #[async_trait::async_trait]
    impl AnisetteProvider for Counting {
        async fn get_anisette_data(&self) -> Result<AnisetteDataResponse, Report> {
            // The real provider asks the anisette server here: callers overlap.
            tokio::time::sleep(std::time::Duration::from_millis(10)).await;
            Ok(match (self.provisioned, self.incorrect_first) {
                (true, _) => AnisetteDataResponse::Data(data()),
                (false, true) => AnisetteDataResponse::IncorrectlyProvisioned,
                (false, false) => AnisetteDataResponse::NeedsProvisioning,
            })
        }
        async fn get_client_info(&self) -> Result<AnisetteClientInfo, Report> {
            Ok(AnisetteClientInfo { client_info: String::new(), user_agent: String::new() })
        }
        async fn provision(&mut self, _: &Arc<GrandSlam>, _: bool) -> Result<(), Report> {
            self.provisions.fetch_add(1, Ordering::SeqCst);
            tokio::time::sleep(std::time::Duration::from_millis(50)).await;
            self.provisioned = true;
            Ok(())
        }
    }

    async fn concurrent_provisions(incorrect_first: bool) -> usize {
        let _ = rustls::crypto::ring::default_provider().install_default();
        let provisions = Arc::new(AtomicUsize::new(0));
        let provider = Counting { provisioned: false, provisions: provisions.clone(), incorrect_first };
        let generator = AnisetteDataGenerator::new(Arc::new(RwLock::new(provider)));
        let gs = Arc::new(GrandSlam::offline_for_tests());
        let (mut a, mut b, mut c) = (generator.clone(), generator.clone(), generator);
        let (ra, rb, rc) = tokio::join!(
            a.get_anisette_data(gs.clone()),
            b.get_anisette_data(gs.clone()),
            c.get_anisette_data(gs.clone())
        );
        assert!(ra.is_ok() && rb.is_ok() && rc.is_ok());
        provisions.load(Ordering::SeqCst)
    }

    /// Rejected (-45061) before the write lock, then merely unprovisioned
    /// after it (another caller cleared it): the reset must follow the newer
    /// answer.
    struct Changing {
        reads: std::sync::Mutex<Vec<AnisetteDataResponse>>,
        forced: Arc<std::sync::Mutex<Vec<bool>>>,
    }

    #[async_trait::async_trait]
    impl AnisetteProvider for Changing {
        async fn get_anisette_data(&self) -> Result<AnisetteDataResponse, Report> {
            let mut reads = self.reads.lock().unwrap();
            Ok(if reads.is_empty() { AnisetteDataResponse::Data(data()) } else { reads.remove(0) })
        }
        async fn get_client_info(&self) -> Result<AnisetteClientInfo, Report> {
            Ok(AnisetteClientInfo { client_info: String::new(), user_agent: String::new() })
        }
        async fn provision(&mut self, _: &Arc<GrandSlam>, force: bool) -> Result<(), Report> {
            self.forced.lock().unwrap().push(force);
            Ok(())
        }
    }

    #[tokio::test]
    async fn reset_follows_the_answer_after_the_wait() {
        for (after, expected) in [
            (AnisetteDataResponse::NeedsProvisioning, false),
            (AnisetteDataResponse::IncorrectlyProvisioned, true),
        ] {
            let forced = Arc::new(std::sync::Mutex::new(Vec::new()));
            let provider = Changing {
                reads: std::sync::Mutex::new(vec![AnisetteDataResponse::IncorrectlyProvisioned, after]),
                forced: forced.clone(),
            };
            let mut generator = AnisetteDataGenerator::new(Arc::new(RwLock::new(provider)));
            generator.get_anisette_data(Arc::new(GrandSlam::offline_for_tests())).await.unwrap();
            assert_eq!(*forced.lock().unwrap(), vec![expected]);
        }
    }

    #[test]
    fn debug_output_withholds_anisette_values() {
        let mut secret = data();
        secret.one_time_password = "OTP-SECRET".into();
        secret.machine_id = "MID-SECRET".into();
        secret.device_unique_identifier = "DEV-SECRET".into();
        secret.routing_info = "RINFO-SECRET".into();
        let rendered = format!("{secret:?}");
        assert!(!rendered.contains("SECRET"), "{rendered}");
        let state = remote_v3::state_for_tests([0xab; 16], Some(vec![0xcd; 4]));
        let rendered = format!("{state:?}");
        assert!(!rendered.to_lowercase().contains("ab") && !rendered.contains("171") && rendered.contains("provisioned: true"), "{rendered}");
    }

    #[tokio::test]
    async fn concurrent_callers_provision_once() {
        // Sign-in and the developer session share the provider: three callers
        // that all find it unprovisioned must register one device, not three.
        assert_eq!(concurrent_provisions(false).await, 1);
    }

    #[tokio::test]
    async fn concurrent_callers_reset_once() {
        // -45061 (incorrectly provisioned) resets the identity: a second reset
        // would throw away the device the first one just provisioned.
        assert_eq!(concurrent_provisions(true).await, 1);
    }
}
