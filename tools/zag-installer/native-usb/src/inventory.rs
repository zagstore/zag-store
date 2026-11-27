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
            }
        })
    }
}

/// All three queries must succeed; an error is not treated as an empty library.
pub async fn inspect(proxy: &mut InstallationProxyClient) -> Result<Snapshot, Box<dyn Error>> {
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
    Ok(Snapshot {
        apps, user_count:user.len(), all_count:all.len(), browse_count:browse.len(),
        user_matches:counts[0], all_matches:counts[1], browse_matches:counts[2]
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
    fn conflicting_or_incomplete_versions_fail_closed() {
        let mut apps = BTreeMap::new();
        let id = "app.zagstore.ios.FTB8PRW638";
        merge(&mut apps, id, &info("1.0.0","5")).unwrap();
        assert!(merge(&mut apps, id, &info("1.0.0","6")).is_err());
        assert!(merge(&mut apps, id, &Value::Dictionary(plist::Dictionary::new())).is_err());
    }
}
