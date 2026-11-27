mod transfer;
use idevice::{IdeviceService, lockdown::LockdownClient, provider::{IdeviceProvider, UsbmuxdProvider}, usbmuxd::{Connection, UsbmuxdAddr}, installation_proxy::InstallationProxyClient, amfi::AmfiClient};
use serde_json::json;
use std::time::Duration;

async fn inspect(mode: &str) -> Result<serde_json::Value, Box<dyn std::error::Error>> {
    let addr = UsbmuxdAddr::default();
    let mut mux = addr.connect(1).await?;
    let devices: Vec<_> = mux.get_devices().await?.into_iter()
        .filter(|d| d.connection_type == Connection::Usb).collect();
    if devices.len() != 1 { return Err("Exactly one wired device required".into()); }
    let d = &devices[0];
    let provider = UsbmuxdProvider { addr, tag: 2, udid: d.udid.clone(), device_id: d.device_id, label: "Zag Installer".into() };
    let pairing = provider.get_pairing_file().await?;
    let mut lockdown = LockdownClient::connect(&provider).await?;
    lockdown.start_session(&pairing).await?;
    let mut info = serde_json::Map::new();
    for key in ["DeviceName", "ProductType", "ProductVersion", "DeviceClass"] {
        let value = lockdown.get_value(Some(key), None).await?;
        let value = value.as_string().ok_or("Unexpected device metadata")?;
        info.insert(key.into(), json!(value));
    }
    if info.get("DeviceClass").and_then(|v| v.as_str()) != Some("iPhone") {
        return Err("Expected iPhone".into());
    }
    let mut amfi = AmfiClient::connect(&provider).await?;
    let developer_mode = amfi.get_developer_mode_status().await?;
    let mut result = json!({"transport":"system-usbmuxd","trust_verified":true,
        "developer_mode":developer_mode,"device":info});
    // Lightweight authenticated status for the GUI poller. No app enumeration.
    if mode == "status" { return Ok(result); }
    let mut proxy = InstallationProxyClient::connect(&provider).await?;
    let apps = proxy.get_apps(Some("User"), None).await?;
    result["user_app_count"] = json!(apps.len());
    if mode == "inventory" {
        let mut zag_apps = Vec::new();
        for (bundle, data) in &apps {
            let owned = bundle == "app.zagstore.ios" ||
                bundle.strip_prefix("app.zagstore.ios.").is_some_and(|suffix|
                    suffix.len() == 10 && suffix.bytes().all(|b| b.is_ascii_uppercase() || b.is_ascii_digit()));
            if !owned { continue; }
            let dict = data.as_dictionary();
            let version = dict.and_then(|d| d.get("CFBundleShortVersionString"))
                              .and_then(|v| v.as_string());
            let build = dict.and_then(|d| d.get("CFBundleVersion"))
                            .and_then(|v| v.as_string());
            zag_apps.push(json!({"bundleIdentifier":bundle, "version":version, "bundleVersion":build}));
        }
        zag_apps.sort_by(|a,b| a["bundleIdentifier"].as_str().cmp(&b["bundleIdentifier"].as_str()));
        result["zag_apps"] = json!(zag_apps);
    }
    Ok(result)
}

#[tokio::main(flavor="current_thread")]
async fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.len() != 1 || !matches!(args[0].as_str(), "inspect" | "status" | "inventory") {
        eprintln!("Usage: zag-usb inspect|status|inventory"); std::process::exit(2);
    }
    match tokio::time::timeout(Duration::from_secs(30), inspect(&args[0])).await {
        Ok(Ok(result)) => println!("{}", result),
        _ => { eprintln!("Trusted USB inspection failed; check pairing, unlock and USB connection"); std::process::exit(1); }
    }
}
