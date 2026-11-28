mod transfer;
mod installation;
mod inventory;
mod preflight;
mod app_container;
use idevice::{IdeviceService, lockdown::LockdownClient, provider::{IdeviceProvider, UsbmuxdProvider}, usbmuxd::{Connection, UsbmuxdAddr}, installation_proxy::InstallationProxyClient, amfi::AmfiClient};
use serde_json::json;
use std::time::Duration;

async fn inspect(mode: &str, team: Option<&str>) -> Result<serde_json::Value, Box<dyn std::error::Error>> {
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
        "developer_mode":developer_mode,"udid":d.udid,"device":info});
    // Lightweight authenticated status for the GUI poller. No app enumeration.
    if mode == "status" { return Ok(result); }
    let mut proxy = InstallationProxyClient::connect(&provider).await?;
    if mode == "inspect" {
        // Keep the original low-cost inspection contract.
        let apps = proxy.get_apps(Some("User"), None).await?;
        result["user_app_count"] = json!(apps.len());
    } else {
        let snapshot = inventory::inspect(&mut proxy, team).await?;
        result["user_app_count"] = json!(snapshot.user_count);
        let diagnostics = snapshot.as_json();
        result["zag_apps"] = diagnostics["zag_apps"].clone();
        result["inventory_sources"] = diagnostics["inventory_sources"].clone();
        result["inventory_note"] = diagnostics["inventory_note"].clone();
        result["legacy_app"] = diagnostics["legacy_app"].clone();
        result["targeted_apps"] = diagnostics["targeted_apps"].clone();
        result["targeted_checked"] = diagnostics["targeted_checked"].clone();
    }
    Ok(result)
}

#[tokio::main(flavor="current_thread")]
async fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.len() == 2 && args[0] == "preflight" {
        // Read-only, bounded digest and USB identity check. The plan is
        // untrusted input and never authorizes a device installation.
        let job = async {
            let plan = preflight::verify(std::path::Path::new(&args[1])).await?;
            let team = plan.bundle_identifier.strip_prefix("app.zagstore.ios.").ok_or("Invalid destination")?;
            let status = inspect("inventory", Some(team)).await?;
            let mut report = preflight::device_binding(&plan, &status)?;
            let apps = status["zag_apps"].as_array().ok_or("Missing inventory")?;
            let existing = apps.iter().find(|app| app["bundleIdentifier"].as_str() == Some(plan.bundle_identifier.as_str()));
            report["destination_state"] = match (existing, &plan.previous) {
                (Some(app), Some(prior)) if app["version"].as_str() == Some(prior.version.as_str()) &&
                    app["bundleVersion"].as_str() == Some(prior.build.as_str()) => json!("expected_upgrade_detected"),
                (Some(_), _) => return Err("Destination already occupied or changed".into()),
                (None, Some(_)) => return Err("Expected upgrade destination missing".into()),
                (None, None) => json!("not_reported_by_inventory"),
            };
            report["legacy_app"] = status["legacy_app"].clone();
            Ok::<_, Box<dyn std::error::Error>>(report)
        };
        match tokio::time::timeout(Duration::from_secs(90), job).await {
            Ok(Ok(result)) => println!("{}", result),
            _ => { eprintln!("Native IPA preflight failed; no device writes performed"); std::process::exit(1); }
        }
        return;
    }
    if args.len() != 1 || !matches!(args[0].as_str(), "inspect" | "status" | "inventory") {
        eprintln!("Usage: zag-usb inspect|status|inventory|preflight PLAN.json");
        std::process::exit(2);
    }
    match tokio::time::timeout(Duration::from_secs(30), inspect(&args[0], None)).await {
        Ok(Ok(result)) => println!("{}", result),
        _ => { eprintln!("Trusted USB inspection failed; check pairing, unlock and USB connection"); std::process::exit(1); }
    }
}
