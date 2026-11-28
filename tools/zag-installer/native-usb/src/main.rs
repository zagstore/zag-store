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


/// Handle only the existing, explicitly requested encrypted signing-setup
/// transport. No app installation, arbitrary file path, or other bundle access.
async fn handoff_command(args: &[String]) -> Result<serde_json::Value, Box<dyn std::error::Error>> {
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
    // same exact wired device, not to a network-discovered device.
    let addr = UsbmuxdAddr::default();
    let mut mux = addr.connect(1).await?;
    let devices: Vec<_> = mux.get_devices().await?.into_iter()
        .filter(|d| d.connection_type == Connection::Usb).collect();
    if devices.len() != 1 || !devices[0].udid.eq_ignore_ascii_case(expected_udid) {
        return Err("Signing handoff target is not the sole wired iPhone".into());
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
    let mut amfi = AmfiClient::connect(&provider).await?;
    if !amfi.get_developer_mode_status().await? {
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
async fn install_developer(args: &[String]) -> Result<serde_json::Value, Box<dyn std::error::Error>> {
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
    let team = plan.bundle_identifier.strip_prefix("app.zagstore.ios.")
        .ok_or("Invalid mapped Zag Store bundle")?;
    let observed = inspect("inventory", Some(team)).await?;
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

    // Reacquire sole USB device and pairing for the write-capable session;
    // installation::install_authorized independently checks destination
    // before and after staging as well as installed version/build readback.
    let addr = UsbmuxdAddr::default();
    let mut mux = addr.connect(1).await?;
    let devices: Vec<_> = mux.get_devices().await?.into_iter()
        .filter(|d| d.connection_type == Connection::Usb).collect();
    if devices.len() != 1 || !devices[0].udid.eq_ignore_ascii_case(&plan.device_udid) {
        return Err("The original, sole wired iPhone is no longer connected".into());
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
    let mut amfi = AmfiClient::connect(&provider).await?;
    if !amfi.get_developer_mode_status().await? {
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

#[tokio::main(flavor="current_thread")]
async fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    // Local capability query: never opens a device connection.
    if args.len() == 1 && args[0] == "capabilities" {
        println!("{}", json!({"native_install_dev": cfg!(feature = "native-install-dev")}));
        return;
    }
    #[cfg(feature = "native-install-dev")]
    if args.first().is_some_and(|a| a == "install-signed-dev") {
        // This feature is never compiled into default / GUI release builds.
        // No fixed short timeout on device installation: a large IPA can take
        // longer than a USB status poll; errors are still propagated.
        match install_developer(&args).await {
            Ok(result) => println!("{}", result),
            Err(err) => { eprintln!("Native developer installation failed: {err}");
                          std::process::exit(1); }
        }
        return;
    }
    if matches!(args.first().map(String::as_str), Some("handoff-read" | "handoff-write")) {
        let job = handoff_command(&args);
        match tokio::time::timeout(Duration::from_secs(45), job).await {
            Ok(Ok(result)) => println!("{}", result),
            _ => { eprintln!("Native signing handoff failed; verify USB trust and the exact Personal Team app");
                   std::process::exit(1); }
        }
        return;
    }
    if args.len() == 2 && args[0] == "inventory-team" {
        let team = &args[1];
        if team.len() != 10 || !team.bytes().all(|b| b.is_ascii_uppercase() || b.is_ascii_digit()) {
            eprintln!("Invalid Personal Team identifier");
            std::process::exit(2);
        }
        match tokio::time::timeout(Duration::from_secs(45), inspect("inventory", Some(team))).await {
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
        eprintln!("Signing transport: handoff-read|handoff-write UDID BUNDLE REMOTE LOCAL \"HANDOFF BUNDLE\"");
        std::process::exit(2);
    }
    match tokio::time::timeout(Duration::from_secs(30), inspect(&args[0], None)).await {
        Ok(Ok(result)) => println!("{}", result),
        _ => { eprintln!("Trusted USB inspection failed; check pairing, unlock and USB connection"); std::process::exit(1); }
    }
}
