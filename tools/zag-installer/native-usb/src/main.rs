mod transfer;
mod installation;
mod inventory;
mod preflight;
mod app_container;
use idevice::{IdeviceService, lockdown::LockdownClient, provider::{IdeviceProvider, UsbmuxdProvider}, usbmuxd::{Connection, UsbmuxdAddr}, installation_proxy::InstallationProxyClient, amfi::AmfiClient};
use serde_json::json;
use std::time::Duration;

fn diagnostic(code: &str) -> serde_json::Value {
    json!({"transport":"system-usbmuxd","trust_verified":false,"diagnostic":code})
}

// Explicit target is immutable for one installer operation. Legacy CLI stays sole-USB.
type Target<'a> = Option<(&'a str, &'a str)>;

fn connection_kind(connection: &Connection) -> Option<&'static str> {
    match connection {
        Connection::Usb => Some("usb"),
        Connection::Network(_) => Some("network"),
        _ => None,
    }
}

fn matches_target(udid: &str, connection: Option<&str>, target: Target<'_>) -> bool {
    match target {
        None => connection == Some("usb"),
        Some((id, transport)) => udid.eq_ignore_ascii_case(id)
            && connection == Some(transport),
    }
}

// Query the authenticated Lockdown domain first: the AMFI service may
// be unavailable over network transport. Never interpret absence as enabled.
async fn developer_mode_status(lockdown: &mut LockdownClient, provider: &UsbmuxdProvider) -> Option<bool> {
    if let Ok(value) = lockdown.get_value(Some("DeveloperModeStatus"), Some("com.apple.security.mac.amfi")).await {
        if let Some(enabled) = value.as_boolean() {
            return Some(enabled);
        }
    }
    match AmfiClient::connect(provider).await {
        Ok(mut amfi) => amfi.get_developer_mode_status().await.ok(),
        Err(_) => None,
    }
}

async fn inspect(mode: &str, team: Option<&str>, target: Target<'_>) -> Result<serde_json::Value, Box<dyn std::error::Error>> {
    let addr = UsbmuxdAddr::default();
    let mut mux = addr.connect(1).await?;
    let devices: Vec<_> = mux.get_devices().await?.into_iter()
        .filter(|d| matches_target(&d.udid, connection_kind(&d.connection_type), target)).collect();
    if devices.len() != 1 {
        if mode == "status" {
            return Ok(diagnostic(if devices.is_empty() { "no_device" } else { "multiple_devices" }));
        }
        return Err("Exactly one matching device required".into());
    }
    let d = &devices[0];
    let provider = UsbmuxdProvider { addr, tag: 2, udid: d.udid.clone(), device_id: d.device_id, label: "Zag Installer".into() };
    let pairing = match provider.get_pairing_file().await {
        Ok(value) => value,
        Err(_) if mode == "status" => return Ok(diagnostic("pairing_unavailable")),
        Err(err) => return Err(err.into()),
    };
    let mut lockdown = match LockdownClient::connect(&provider).await {
        Ok(value) => value,
        Err(_) if mode == "status" => return Ok(diagnostic("connection_failed")),
        Err(err) => return Err(err.into()),
    };
    if let Err(err) = lockdown.start_session(&pairing).await {
        if mode == "status" { return Ok(diagnostic("session_failed")); }
        return Err(err.into());
    }
    let mut info = serde_json::Map::new();
    for key in ["DeviceName", "ProductType", "ProductVersion", "DeviceClass"] {
        let value = lockdown.get_value(Some(key), None).await?;
        let value = value.as_string().ok_or("Unexpected device metadata")?;
        info.insert(key.into(), json!(value));
    }
    if info.get("DeviceClass").and_then(|v| v.as_str()) != Some("iPhone") {
        if mode == "status" { return Ok(diagnostic("unsupported_device")); }
        return Err("Expected iPhone".into());
    }
    let developer_mode = developer_mode_status(&mut lockdown, &provider).await;
    let mut result = json!({"transport":"system-usbmuxd","trust_verified":true,
        "developer_mode":developer_mode,"udid":d.udid,"device":info,
        "connection":connection_kind(&d.connection_type).ok_or("Unknown device connection")?});
    // Lightweight authenticated status for the GUI poller. No app enumeration.
    if mode == "status" { return Ok(result); }
    let mut proxy = InstallationProxyClient::connect(&provider).await?;
    if mode == "inspect" {
        // Keep the original low-cost inspection contract.
        let apps = proxy.get_apps(Some("User"), None).await?;
        result["user_app_count"] = json!(apps.len());
    } else if mode == "inventory-imported" {
        let bundle = team.ok_or("Missing imported destination")?;
        let entry = inventory::imported_lookup(&mut proxy, bundle).await?;
        let apps: Vec<_> = entry.into_iter().map(|app| json!({
            "bundleIdentifier":app.bundle, "version":app.version, "bundleVersion":app.build
        })).collect();
        result["targeted_checked"] = json!(true);
        result["targeted_apps"] = json!(apps);
        result["zag_apps"] = json!(apps);
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


/// Handle only the existing, explicitly requested encrypted signing-setup
/// transport. No app installation, arbitrary file path, or other bundle access.
async fn handoff_command(args: &[String], target: Target<'_>) -> Result<serde_json::Value, Box<dyn std::error::Error>> {
    use std::{fs, io::Write, os::unix::fs::{MetadataExt, OpenOptionsExt}, path::Path};
    use sha2::{Digest, Sha256};

    if args.len() != 6 || !matches!(args[0].as_str(), "handoff-read" | "handoff-write") {
        return Err("Expected handoff-read|handoff-write UDID BUNDLE REMOTE LOCAL".into());
    }
    let expected_udid = &args[1];
    let bundle = &args[2];
    let remote = &args[3];
    let local = Path::new(&args[4]);
    // The existing Python handoff workflow supplies this exact phrase only
    // after its user approval / on-device authenticated setup checks.
    if args[5] != format!("HANDOFF {}",bundle) {
        return Err("Missing exact signing handoff confirmation".into());
    }
    if !installation::is_personal_team_bundle(bundle) || !local.is_absolute() {
        return Err("Invalid signing destination or local file path".into());
    }
    if args[0] == "handoff-read" {
        app_container::Message::from_read_path(remote)?;
    } else {
        app_container::Message::from_write_path(remote)?;
    }

    // The provider, pairing session and installed bundle are all bound to the
    // same explicitly selected device and transport (or legacy sole USB).
    let addr = UsbmuxdAddr::default();
    let mut mux = addr.connect(1).await?;
    let devices: Vec<_> = mux.get_devices().await?.into_iter()
        .filter(|d| matches_target(&d.udid, connection_kind(&d.connection_type), target)).collect();
    if devices.len() != 1 || !devices[0].udid.eq_ignore_ascii_case(expected_udid) {
        return Err("Signing handoff target is unavailable or ambiguous".into());
    }
    let dev = &devices[0];
    let provider = UsbmuxdProvider { addr, tag: 2, udid: dev.udid.clone(),
        device_id: dev.device_id, label: "Zag Installer handoff".into() };
    let pairing = provider.get_pairing_file().await?;
    let mut lockdown = LockdownClient::connect(&provider).await?;
    lockdown.start_session(&pairing).await?;
    if lockdown.get_value(Some("DeviceClass"),None).await?.as_string() != Some("iPhone") {
        return Err("Signing handoff requires a trusted iPhone".into());
    }
    if developer_mode_status(&mut lockdown, &provider).await != Some(true) {
        return Err("Developer Mode is disabled".into());
    }
    let team = bundle.strip_prefix("app.zagstore.ios.").ok_or("Invalid team bundle")?;
    let mut proxy = InstallationProxyClient::connect(&provider).await?;
    let matches = inventory::targeted_lookup(&mut proxy, team).await?;
    if !matches.contains_key(bundle) {
        return Err("The Personal Team copy is not verified as installed".into());
    }

    if args[0] == "handoff-read" {
        // Never print any request contents or verification material to stdout.
        let data = app_container::read_message(&provider, bundle, remote).await?;
        let mut output = fs::OpenOptions::new().write(true).create_new(true)
            .mode(0o600).open(local)?;
        if let Err(err) = output.write_all(&data) {
            let _ = fs::remove_file(local);
            return Err(err.into());
        }
        output.sync_all()?;
        Ok(json!({"operation":"handoff-read","bundleIdentifier":bundle,
            "bytes":data.len(),"sha256":format!("{:x}",Sha256::digest(&data))}))
    } else {
        let meta = fs::symlink_metadata(local)?;
        if !meta.is_file() || meta.len() == 0 || meta.len() > 24 * 1024 ||
            meta.mode() & 0o077 != 0 {
            return Err("The encrypted handoff source must be a private regular file".into());
        }
        let data = fs::read(local)?;
        if data.len() != meta.len() as usize || data.is_empty() || data.len() > 24 * 1024 {
            return Err("Encrypted handoff file changed during read".into());
        }
        let digest = app_container::write_envelope(&provider, bundle, remote, &data).await?;
        Ok(json!({"operation":"handoff-write","bundleIdentifier":bundle,
            "bytes":data.len(),"sha256":digest.iter().map(|b|format!("{b:02x}")).collect::<String>()}))
    }
}


#[cfg(feature = "native-install-dev")]
fn install_dev_confirmation(bundle: &str, udid: &str, upgrading: bool) -> String {
    let action = if upgrading { "UPGRADE" } else { "INSTALL" };
    format!("{action} {bundle} ON {udid}")
}

#[cfg(feature = "native-install-dev")]
async fn install_developer(args: &[String], target: Target<'_>) -> Result<serde_json::Value, Box<dyn std::error::Error>> {
    // NEVER an ordinary release command: this developer-only entry point
    // assumes the calling macOS signer has already verified Apple's IPA
    // signature, certificate, profile, exact device and signed release.
    // An arbitrary JSON plan is NOT cryptographic proof of authorization.
    if args.len() != 4 || args[0] != "install-signed-dev" {
        return Err("Expected install-signed-dev PLAN.json STAGING_TOKEN CONFIRMATION".into());
    }
    if !transfer::valid_token(&args[2]) {
        return Err("Invalid native installation staging token".into());
    }
    let plan = preflight::verify(std::path::Path::new(&args[1])).await?;
    if args[3] != install_dev_confirmation(&plan.bundle_identifier, &plan.device_udid, plan.previous.is_some()) {
        return Err("Exact interactive installation confirmation is required".into());
    }
    let observed = if plan.schema == 2 {
        inspect("inventory-imported", Some(&plan.bundle_identifier), target).await?
    } else {
        let team = plan.bundle_identifier.strip_prefix("app.zagstore.ios.").ok_or("Invalid mapped Zag Store bundle")?;
        inspect("inventory", Some(team), target).await?
    };
    let _ = preflight::device_binding(&plan, &observed)?;
    let apps = observed["zag_apps"].as_array().ok_or("Native application inventory unavailable")?;
    let existing = apps.iter().find(|app|
        app["bundleIdentifier"].as_str() == Some(plan.bundle_identifier.as_str()));
    match (existing, &plan.previous) {
        (None, None) => (),
        (Some(app), Some(previous))
            if app["version"].as_str() == Some(previous.version.as_str())
            && app["bundleVersion"].as_str() == Some(previous.build.as_str()) => (),
        _ => return Err("Personal Team installation destination differs from signed plan".into()),
    }

    // Reacquire the exact selected transport and pairing for the write-capable session;
    // installation::install_authorized independently checks destination
    // before and after staging as well as installed version/build readback.
    let addr = UsbmuxdAddr::default();
    let mut mux = addr.connect(1).await?;
    let devices: Vec<_> = mux.get_devices().await?.into_iter()
        .filter(|d| matches_target(&d.udid, connection_kind(&d.connection_type), target)).collect();
    if devices.len() != 1 || !devices[0].udid.eq_ignore_ascii_case(&plan.device_udid) {
        return Err("The original device and transport are no longer available".into());
    }
    let device = &devices[0];
    let provider = UsbmuxdProvider {addr, tag:2, udid:device.udid.clone(),
        device_id:device.device_id, label:"Zag Installer native installation developer mode".into()};
    let pairing = provider.get_pairing_file().await?;
    let mut lockdown = LockdownClient::connect(&provider).await?;
    lockdown.start_session(&pairing).await?;
    if lockdown.get_value(Some("DeviceClass"), None).await?.as_string() != Some("iPhone") {
        return Err("Refusing to install on a non-iPhone device".into());
    }
    if developer_mode_status(&mut lockdown, &provider).await != Some(true) {
        return Err("Refusing to install without Developer Mode".into());
    }
    let hash_bytes = plan.ipa_sha256.as_bytes();
    let mut sha256 = [0u8;32];
    for (i, chunk) in hash_bytes.chunks_exact(2).enumerate() {
        // Use radix-16, not decimal, to match the validated SHA-256 hex.
        sha256[i] = u8::from_str_radix(std::str::from_utf8(chunk)?, 16)?;
    }
    let previous = plan.previous.as_ref().map(|old| installation::VersionStamp {
        version:old.version.clone(), build:old.build.clone()
    });
    let request = installation::AuthorizedInstall {
        ipa:std::path::Path::new(&plan.ipa_path),
        sha256, job_token:&args[2], bundle:&plan.bundle_identifier,
        expected:installation::VersionStamp {version:plan.version.clone(), build:plan.build.clone()},
        previous,
        // This is a developer-only trust assertion, NOT independently verified
        // release provenance. Do not enable this path in production.
        authorization_verified:true,
    };
    let result = installation::install_authorized(&provider, &request).await?;
    Ok(json!({"installed_bundle":plan.bundle_identifier,"version":result.version,
        "build":result.build,"mode":"native-install-dev","installed":true,
        "legacy_app_untouched":true}))
}

#[cfg(all(test, feature = "native-install-dev"))]
mod developer_install_gate_tests {
    use super::*;
    #[test]
    fn typed_confirmation_binds_exact_operation_bundle_and_device() {
        let bundle = "app.zagstore.ios.FTB8PRW638";
        let udid = "00000000-0000000000000000";
        assert_eq!(install_dev_confirmation(bundle, udid, false),
            format!("INSTALL {bundle} ON {udid}"));
        assert_eq!(install_dev_confirmation(bundle, udid, true),
            format!("UPGRADE {bundle} ON {udid}"));
        assert_ne!(install_dev_confirmation(bundle, udid, false),
            install_dev_confirmation(bundle, udid, true));
        assert_ne!(install_dev_confirmation(bundle, udid, false),
            install_dev_confirmation(bundle, "11111111-1111111111111111", false));
    }
}

fn group_transports(devices: impl IntoIterator<Item = (String, bool)>) -> Vec<serde_json::Value> {
    let mut grouped = std::collections::BTreeMap::<String, (bool, bool)>::new();
    for (udid, usb) in devices {
        let entry = grouped.entry(udid.to_ascii_lowercase()).or_default();
        if usb { entry.0 = true; } else { entry.1 = true; }
    }
    grouped.into_iter().map(|(udid, (usb, network))|
        json!({"udid":udid,"usb":usb,"network":network,
            "preferred_connection":if usb {"usb"} else {"network"}})).collect()
}

#[cfg(test)]
mod grouped_discovery_tests {
    use super::*;
    #[test]
    fn exact_binding_rejects_other_devices_and_transport_changes() {
        assert!(matches_target("ABC", Some("network"), Some(("abc", "network"))));
        assert!(!matches_target("ABC", Some("usb"), Some(("abc", "network"))));
        assert!(!matches_target("DEF", Some("network"), Some(("abc", "network"))));
        assert!(!matches_target("ABC", Some("network"), None));
        assert!(matches_target("ABC", Some("usb"), None));
        assert!(!matches_target("ABC", None, Some(("abc", "network"))));
        assert_eq!(connection_kind(&Connection::Unknown("other".into())), None);
    }
    #[test]
    fn merges_case_insensitive_identity_and_prefers_usb() {
        let rows = group_transports([("ABC".into(), false), ("abc".into(), true),
            ("ABC".into(), true), ("DEF".into(), false)]);
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0], json!({"udid":"abc","usb":true,"network":true,"preferred_connection":"usb"}));
        assert_eq!(rows[1], json!({"udid":"def","usb":false,"network":true,"preferred_connection":"network"}));
    }
}

#[tokio::main(flavor="current_thread")]
async fn main() {
    let mut args: Vec<String> = std::env::args().skip(1).collect();
    let binding = if args.first().is_some_and(|s| s == "--target") {
        if args.len() < 4 || !matches!(args[2].as_str(), "usb" | "network")
            || !((args[1].len() == 40 && args[1].bytes().all(|b| b.is_ascii_hexdigit()))
                || (args[1].len() == 25 && args[1].as_bytes()[8] == b'-'
                    && args[1].bytes().enumerate().all(|(i,b)| i == 8 || b.is_ascii_hexdigit()))) {
            eprintln!("Invalid explicit device binding");
            std::process::exit(2);
        }
        let prefix: Vec<_> = args.drain(..3).collect();
        Some((prefix[1].clone(), prefix[2].clone()))
    } else { None };
    let target = binding.as_ref().map(|(id, transport)| (id.as_str(), transport.as_str()));
    // Explicit read-only inspection of one advertised device. Never pair or install.
    if matches!(args.len(), 2 | 3) && args[0] == "device-status" {
        let requested = &args[1];
        let requested_transport = args.get(2).map(String::as_str);
        let job = async {
            let addr = UsbmuxdAddr::default();
            let mut mux = addr.connect(1).await?;
            let devices = mux.get_devices().await?;
            let d = devices.iter().filter(|d| d.udid.eq_ignore_ascii_case(requested)
                && connection_kind(&d.connection_type).is_some()
                && requested_transport.map_or(true, |t| matches_target(&d.udid, connection_kind(&d.connection_type), Some((requested.as_str(), t)))))
                .min_by_key(|d| if d.connection_type == Connection::Usb { 0 } else { 1 })
                .ok_or("Device no longer advertised")?;
            let connection = connection_kind(&d.connection_type).ok_or("Unknown device connection")?;
            let provider = UsbmuxdProvider { addr, tag: 2, udid: d.udid.clone(),
                device_id: d.device_id, label: "zLoader device status".into() };
            let pairing = provider.get_pairing_file().await?;
            let mut lockdown = LockdownClient::connect(&provider).await?;
            lockdown.start_session(&pairing).await?;
            let mut info = serde_json::Map::new();
            for key in ["DeviceName", "ProductType", "ProductVersion", "DeviceClass"] {
                let value = lockdown.get_value(Some(key), None).await?;
                info.insert(key.into(), json!(value.as_string().ok_or("Unexpected device metadata")?));
            }
            let developer_mode = developer_mode_status(&mut lockdown, &provider).await;
            Ok::<_, Box<dyn std::error::Error>>(json!({"connection":connection,
                "trust_verified":true,"developer_mode":developer_mode,"device":info}))
        };
        match tokio::time::timeout(Duration::from_secs(10), job).await {
            Ok(Ok(result)) => println!("{}", result),
            _ => println!("{}", json!({"trust_verified":false,"diagnostic":"session_unavailable"})),
        }
        return;
    }
    // Group transport advertisements by physical device identity.
    if args.len() == 1 && args[0] == "discover-grouped" {
        let job = async {
            let mut mux = UsbmuxdAddr::default().connect(1).await?;
            let devices = mux.get_devices().await?;
            let rows = group_transports(devices.into_iter().filter_map(|d| connection_kind(&d.connection_type).map(|kind| (d.udid, kind == "usb"))));
            Ok::<_, Box<dyn std::error::Error>>(json!({"devices":rows}))
        };
        match tokio::time::timeout(Duration::from_secs(10), job).await {
            Ok(Ok(result)) => println!("{}", result),
            _ => { eprintln!("Device discovery unavailable"); std::process::exit(1); }
        }
        return;
    }
    // Local capability query: never opens a device connection.
    // Read-only discovery of devices already advertised by the system mux.
    // No pairing creation, network scanning or write-capable service access.
    if args.len() == 1 && args[0] == "discover-devices" {
        let job = async {
            let mut mux = UsbmuxdAddr::default().connect(1).await?;
            let devices = mux.get_devices().await?;
            let rows: Vec<_> = devices.into_iter().filter_map(|d| {
                let connection = connection_kind(&d.connection_type)?;
                Some(json!({"udid": d.udid, "connection": connection}))
            }).collect();
            Ok::<_, Box<dyn std::error::Error>>(json!({"devices": rows}))
        };
        match tokio::time::timeout(Duration::from_secs(10), job).await {
            Ok(Ok(result)) => println!("{}", result),
            _ => { eprintln!("Device discovery unavailable"); std::process::exit(1); }
        }
        return;
    }
    if args.len() == 1 && args[0] == "capabilities" {
        println!("{}", json!({"native_install_dev": cfg!(feature = "native-install-dev")}));
        return;
    }
    #[cfg(feature = "native-install-dev")]
    if args.first().is_some_and(|a| a == "install-signed-dev") {
        // This feature is never compiled into default / GUI release builds.
        // No fixed short timeout on device installation: a large IPA can take
        // longer than a USB status poll; errors are still propagated.
        match install_developer(&args, target).await {
            Ok(result) => println!("{}", result),
            Err(err) => { eprintln!("Native developer installation failed: {err}");
                          std::process::exit(1); }
        }
        return;
    }
    if matches!(args.first().map(String::as_str), Some("handoff-read" | "handoff-write")) {
        let job = handoff_command(&args, target);
        match tokio::time::timeout(Duration::from_secs(45), job).await {
            Ok(Ok(result)) => println!("{}", result),
            _ => { eprintln!("Native signing handoff failed; verify USB trust and the exact Personal Team app");
                   std::process::exit(1); }
        }
        return;
    }
    if args.len() == 2 && args[0] == "inventory-imported" {
        match tokio::time::timeout(Duration::from_secs(45), inspect("inventory-imported", Some(&args[1]), target)).await {
            Ok(Ok(result)) => println!("{}", result),
            _ => { eprintln!("Imported destination inventory failed"); std::process::exit(1); }
        }
        return;
    }
    if args.len() == 2 && args[0] == "inventory-team" {
        let team = &args[1];
        if team.len() != 10 || !team.bytes().all(|b| b.is_ascii_uppercase() || b.is_ascii_digit()) {
            eprintln!("Invalid Personal Team identifier");
            std::process::exit(2);
        }
        match tokio::time::timeout(Duration::from_secs(45), inspect("inventory", Some(team), target)).await {
            Ok(Ok(result)) => println!("{}", result),
            _ => { eprintln!("Targeted native inventory failed; no device writes performed");
                   std::process::exit(1); }
        }
        return;
    }
    if args.len() == 2 && args[0] == "preflight" {
        // Read-only, bounded digest and USB identity check. The plan is
        // untrusted input and never authorizes a device installation.
        let job = async {
            let plan = preflight::verify(std::path::Path::new(&args[1])).await?;
            let status = if plan.schema == 2 {
                inspect("inventory-imported", Some(&plan.bundle_identifier), target).await?
            } else {
                let team = plan.bundle_identifier.strip_prefix("app.zagstore.ios.").ok_or("Invalid destination")?;
                inspect("inventory", Some(team), target).await?
            };
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
        eprintln!("Signing transport: handoff-read|handoff-write UDID BUNDLE REMOTE LOCAL \"HANDOFF BUNDLE\"");
        std::process::exit(2);
    }
    match tokio::time::timeout(Duration::from_secs(30), inspect(&args[0], None, target)).await {
        Ok(Ok(result)) => println!("{}", result),
        _ => { eprintln!("Trusted device inspection failed; check pairing, unlock and selected connection"); std::process::exit(1); }
    }
}
