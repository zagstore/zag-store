//! Zag Store fork: the HTTP clients this crate builds refuse to connect.
//! These tests never reach the network: every request is refused by the
//! policy before a connection is opened.

use isideload::auth::grandslam::GrandSlam;

fn install_crypto() {
    let _ = rustls::crypto::ring::default_provider().install_default();
}

#[cfg(not(feature = "live-network"))]
#[tokio::test]
async fn apple_requests_are_refused_without_live_network() {
    install_crypto();
    let client = GrandSlam::build_reqwest_client().unwrap();
    let error = client.get("https://gsa.apple.com/").send().await.unwrap_err();
    assert!(error.to_string().contains("disabled"), "{error}");
}

#[tokio::test]
async fn other_hosts_and_plain_http_are_refused() {
    install_crypto();
    let client = GrandSlam::build_reqwest_client().unwrap();
    for url in ["https://example.invalid/", "https://gsa.apple.com.example.invalid/", "http://gsa.apple.com/"] {
        assert!(client.get(url).send().await.is_err(), "{url} was not refused");
    }
}
