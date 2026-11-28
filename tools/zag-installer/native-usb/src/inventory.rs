//! Cross-check read-only iOS application inventories, never enumerate other app
//! identities in output. Lookup(User), Lookup(Any) and Browse can differ on iOS.
use std::{collections::BTreeMap, error::Error};
use idevice::services::installation_proxy::InstallationProxyClient;
use plist::Value;
use serde_json::{json, Value as JsonValue};

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AppEntry {
    pub bundle: String,
    pub version: String,
    pub build: String,
}

pub const APPTESTERS_LEGACY: &str = "com.cwd43.gu29";

pub fn zag_bundle(bundle: &str) -> bool {
    if bundle == "app.zagstore.ios" { return true; }
    let Some(team) = bundle.strip_prefix("app.zagstore.ios.") else { return false; };
    team.len() == 10 && team.bytes().all(|c| c.is_ascii_uppercase() || c.is_ascii_digit())
}

fn decode(bundle: &str, info: &Value) -> Result<Option<AppEntry>, Box<dyn Error>> {
    if !zag_bundle(bundle) { return Ok(None); }
    let dict = info.as_dictionary().ok_or("Malformed Zag Store inventory record")?;
    let version = dict.get("CFBundleShortVersionString")
        .and_then(Value::as_string).ok_or("Missing Zag Store version")?;
    let build = dict.get("CFBundleVersion")
        .and_then(Value::as_string).ok_or("Missing Zag Store build")?;
    if version.is_empty() || build.is_empty() || version.len() > 64 || build.len() > 64 {
        return Err("Invalid Zag Store version/build in inventory".into());
    }
    Ok(Some(AppEntry {
        bundle: bundle.to_owned(),
        version: version.to_owned(),
        build: build.to_owned(),
    }))
}

fn decode_legacy(info: &Value) -> Result<Option<AppEntry>, Box<dyn Error>> {
    // Reuse the same strict metadata validation, but do not ever add this to
    // the Personal Team installation target map.
    let value = info.as_dictionary().ok_or("Malformed legacy app metadata")?;
    let version = value.get("CFBundleShortVersionString").and_then(Value::as_string)
        .ok_or("Legacy Zag Store version missing")?;
    let build = value.get("CFBundleVersion").and_then(Value::as_string)
        .ok_or("Legacy Zag Store build missing")?;
    if version.is_empty() || build.is_empty() || version.len() > 64 || build.len() > 64 {
        return Err("Invalid legacy Zag Store version/build".into());
    }
    Ok(Some(AppEntry {
        bundle: APPTESTERS_LEGACY.to_owned(),
        version: version.to_owned(),
        build: build.to_owned()
    }))
}

fn merge(
    entries: &mut BTreeMap<String, AppEntry>,
    bundle: &str,
    info: &Value,
) -> Result<(), Box<dyn Error>> {
    if let Some(app) = decode(bundle, info)? {
        if let Some(previous) = entries.get(bundle) {
            if previous != &app {
                return Err("Conflicting Zag Store inventory across Apple services".into());
            }
        } else {
            entries.insert(bundle.to_owned(), app);
        }
    }
    Ok(())
}

pub struct Snapshot {
    pub apps: BTreeMap<String, AppEntry>,
    pub user_count: usize,
    pub all_count: usize,
    pub browse_count: usize,
    pub user_matches: usize,
    pub all_matches: usize,
    pub browse_matches: usize,
    /// Only a targeted, affirmative response confirms an installed destination.
    /// This is NOT inferred from a zero-match full-device scan.
    pub targeted: BTreeMap<String, AppEntry>,
    pub targeted_checked: bool,
    pub legacy_app: Option<AppEntry>,
}

impl Snapshot {
    pub fn as_json(&self) -> JsonValue {
        let zag_apps: Vec<JsonValue> = self.apps.values().map(|app|
            json!({"bundleIdentifier":app.bundle,"version":app.version,"bundleVersion":app.build})
        ).collect();
        json!({
            "zag_apps": zag_apps,
            "inventory_sources": {
                "lookup_user": {"total":self.user_count,"zag_matches":self.user_matches},
                "lookup_any": {"total":self.all_count,"zag_matches":self.all_matches},
                "browse": {"total":self.browse_count,"zag_matches":self.browse_matches}
            },
            "inventory_note": if self.apps.is_empty() {
                "No Zag Store identifier reported by the three inventory queries; this does not independently establish absence"
            } else {
                "At least one inventory source reported the listed Zag Store identifier"
            },
            "legacy_app":self.legacy_app.as_ref().map(|app| json!({
                "bundleIdentifier":app.bundle,
                "version":app.version,
                "bundleVersion":app.build,
                "signing_class":"AppTesters legacy"
            })),
            "targeted_checked":self.targeted_checked,
            "targeted_apps": self.targeted.values().map(|app|
                json!({"bundleIdentifier":app.bundle,"version":app.version,"bundleVersion":app.build})
            ).collect::<Vec<_>>()
        })
    }
}

/// A narrowly scoped, read-only lookup for the known Personal Team destination.
/// The filter is advisory; the returned keys are independently validated.
pub async fn targeted_lookup(
    proxy: &mut InstallationProxyClient, team: &str
) -> Result<BTreeMap<String, AppEntry>, Box<dyn Error>> {
    if team.len() != 10 || !team.bytes().all(|b| b.is_ascii_uppercase() || b.is_ascii_digit()) {
        return Err("Invalid Personal Team identifier".into());
    }
    let bundle = format!("app.zagstore.ios.{team}");
    let mut result = BTreeMap::new();
    for kind in ["User", "Any"] {
        let values = proxy.get_apps(Some(kind), Some(vec![bundle.clone()])).await?;
        for (id, info) in &values {
            if id != &bundle {
                return Err("Targeted lookup returned an unrelated app".into());
            }
            merge(&mut result, id, info)?;
        }
    }
    Ok(result)
}

/// All three queries must succeed; an error is not treated as an empty library.
pub async fn inspect(proxy: &mut InstallationProxyClient, team: Option<&str>) -> Result<Snapshot, Box<dyn Error>> {
    let user = proxy.get_apps(Some("User"), None).await?;
    let all = proxy.get_apps(Some("Any"), None).await?;
    let browse = proxy.browse(None).await?;

    let mut apps = BTreeMap::new();
    let mut counts = [0usize; 3];
    for (which, lookup) in [(0, &user), (1, &all)] {
        for (bundle, info) in lookup {
            if zag_bundle(bundle) { counts[which] += 1; }
            merge(&mut apps, bundle, info)?;
        }
    }
    for info in &browse {
        let Some(dict) = info.as_dictionary() else { continue; };
        let Some(bundle) = dict.get("CFBundleIdentifier").and_then(Value::as_string) else { continue; };
        if zag_bundle(bundle) { counts[2] += 1; }
        merge(&mut apps, bundle, info)?;
    }
    // The AppTesters copy uses a different bundle identifier. Report it
    // separately: it is never an authorised Personal Team upgrade target.
    let mut legacy_app: Option<AppEntry> = None;
    for source in [&user, &all] {
        if let Some(info) = source.get(APPTESTERS_LEGACY) {
            if let Some(candidate) = decode_legacy(info)? {
                if legacy_app.as_ref().is_some_and(|old| old != &candidate) {
                    return Err("Conflicting AppTesters inventory record".into());
                }
                legacy_app = Some(candidate);
            }
        }
    }
    for info in &browse {
        let Some(dict) = info.as_dictionary() else { continue };
        if dict.get("CFBundleIdentifier").and_then(Value::as_string) == Some(APPTESTERS_LEGACY) {
            if let Some(candidate) = decode_legacy(info)? {
                if legacy_app.as_ref().is_some_and(|old| old != &candidate) {
                    return Err("Conflicting AppTesters browse record".into());
                }
                legacy_app = Some(candidate);
            }
        }
    }
    let targeted = match team {
        Some(value) => targeted_lookup(proxy, value).await?,
        None => BTreeMap::new()
    };
    for (bundle, entry) in &targeted {
        if let Some(existing) = apps.get(bundle) {
            if existing != entry { return Err("Targeted and broad inventories conflict".into()); }
        } else {
            apps.insert(bundle.clone(), entry.clone());
        }
    }
    Ok(Snapshot {
        apps, user_count:user.len(), all_count:all.len(), browse_count:browse.len(),
        user_matches:counts[0], all_matches:counts[1], browse_matches:counts[2],
        targeted, targeted_checked: team.is_some(), legacy_app
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    fn info(version: &str, build: &str) -> Value {
        let mut data = plist::Dictionary::new();
        data.insert("CFBundleShortVersionString".into(), Value::String(version.into()));
        data.insert("CFBundleVersion".into(), Value::String(build.into()));
        Value::Dictionary(data)
    }
    #[test]
    fn only_zag_bundle_identifiers_accepted() {
        assert!(zag_bundle("app.zagstore.ios"));
        assert!(zag_bundle("app.zagstore.ios.FTB8PRW638"));
        assert!(!zag_bundle("app.zagstore.ios.FTB8PRW638.test"));
        assert!(!zag_bundle("com.cwd43.gu29"));
        assert!(!zag_bundle("other.app.zagstore.ios.FTB8PRW638"));
    }
    #[test]
    fn browser_and_lookup_matches_merge_without_duplicates() {
        let mut apps = BTreeMap::new();
        let id = "app.zagstore.ios.FTB8PRW638";
        merge(&mut apps, id, &info("1.0.0","5")).unwrap();
        merge(&mut apps, id, &info("1.0.0","5")).unwrap();
        merge(&mut apps, "com.other.app", &info("1.0.0","1")).unwrap();
        assert_eq!(apps.len(), 1);
    }
    #[test]
    fn apptesters_legacy_is_diagnostic_not_personal_team() {
        assert!(!zag_bundle(APPTESTERS_LEGACY));
        let old = decode_legacy(&info("1.0.0", "1")).unwrap().unwrap();
        assert_eq!(old.bundle, "com.cwd43.gu29");
        assert_eq!(old.version, "1.0.0");
        assert_eq!(old.build, "1");
        let mut personal = BTreeMap::new();
        merge(&mut personal, APPTESTERS_LEGACY, &info("1.0.0", "1")).unwrap();
        assert!(personal.is_empty());
    }

    #[test]
    fn team_identifier_must_be_exactly_ten_ascii_characters() {
        for valid in ["FTB8PRW638", "0123456789"] {
            assert!(valid.len() == 10 && valid.bytes().all(|b| b.is_ascii_uppercase() || b.is_ascii_digit()));
        }
        for bad in ["", "abcdefghij", "../foo", "FTB8PRW638.extra"] {
            assert!(!(bad.len() == 10 && bad.bytes().all(|b| b.is_ascii_uppercase() || b.is_ascii_digit())));
        }
    }

    #[test]
    fn conflicting_or_incomplete_versions_fail_closed() {
        let mut apps = BTreeMap::new();
        let id = "app.zagstore.ios.FTB8PRW638";
        merge(&mut apps, id, &info("1.0.0","5")).unwrap();
        assert!(merge(&mut apps, id, &info("1.0.0","6")).is_err());
        assert!(merge(&mut apps, id, &Value::Dictionary(plist::Dictionary::new())).is_err());
    }
}
