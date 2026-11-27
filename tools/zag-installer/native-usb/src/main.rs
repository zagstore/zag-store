use idevice::{IdeviceService, lockdown::LockdownClient, provider::{IdeviceProvider, UsbmuxdProvider}, usbmuxd::{Connection, UsbmuxdAddr}, installation_proxy::InstallationProxyClient, amfi::AmfiClient};
use serde_json::json;
use std::time::Duration;

async fn inspect() -> Result<serde_json::Value, Box<dyn std::error::Error>> {
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
    let mut proxy = InstallationProxyClient::connect(&provider).await?;
    let apps = proxy.get_apps(Some("User"), None).await?;
    Ok(json!({"transport":"system-usbmuxd","trust_verified":true,
        "developer_mode":developer_mode,"device":info,"user_app_count":apps.len()}))
}

#[tokio::main(flavor="current_thread")]
async fn main() {
    if std::env::args().skip(1).collect::<Vec<_>>() != ["inspect"] {
        eprintln!("Usage: zag-usb inspect"); std::process::exit(2);
    }
    match tokio::time::timeout(Duration::from_secs(30), inspect()).await {
        Ok(Ok(result)) => println!("{}", result),
        _ => { eprintln!("Trusted USB inspection failed; check pairing, unlock and USB connection"); std::process::exit(1); }
    }
}
