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

#[derive(Debug, Clone)]
pub struct AnisetteData {
    machine_id: String,
    one_time_password: String,
    pub routing_info: String,
    _device_description: String,
    device_unique_identifier: String,
    _local_user_id: String,
    generated_at: SystemTime,
}

// Some headers don't seem to be required. I guess not including them is technically more efficient soooo
impl AnisetteData {
    pub fn get_headers(&self) -> HashMap<String, String> {
        //let dt: DateTime<Utc> = Utc::now().round_subsecs(0);

        HashMap::from_iter([
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
        ])
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
            status @ (AnisetteDataResponse::NeedsProvisioning
            | AnisetteDataResponse::IncorrectlyProvisioned) => {
                drop(provider);
                let mut provider_write = self.provider.write().await;
                // Zag Store fork: clones of this generator share the provider.
                // Another caller may have provisioned while this one waited for
                // the lock; provisioning again would register a second device
                // with Apple (or reset the one just made), so check first.
                if let AnisetteDataResponse::Data(data) = provider_write.get_anisette_data().await? {
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

    fn data() -> AnisetteData {
        AnisetteData {
            machine_id: "M".into(),
            one_time_password: "O".into(),
            routing_info: "0".into(),
            _device_description: String::new(),
            device_unique_identifier: "D".into(),
            _local_user_id: String::new(),
            generated_at: SystemTime::now(),
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
