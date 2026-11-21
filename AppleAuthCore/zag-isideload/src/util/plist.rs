use plist::Dictionary;
use rootcause::prelude::*;
use serde::de::DeserializeOwned;

/// What an error report may say about a plist: its top-level key names.
/// Zag Store fork: values (tokens, session data, provisioning material) are
/// never kept, so no report can show them; upstream's `DEBUG_SENSITIVE`
/// switch, which printed the whole plist, is removed.
pub struct SensitivePlistAttachment {
    keys: Vec<String>,
}

impl SensitivePlistAttachment {
    pub fn new(plist: Dictionary) -> Self {
        let mut keys: Vec<String> = plist.keys().take(64).cloned().collect();
        keys.sort();
        SensitivePlistAttachment { keys }
    }

    pub fn from_text(text: &str) -> Self {
        match plist::from_bytes::<Dictionary>(text.as_bytes()) {
            Ok(d) => SensitivePlistAttachment::new(d),
            Err(_) => SensitivePlistAttachment::new(Dictionary::new()),
        }
    }

    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        writeln!(f, "<plist values withheld; keys: {}>", self.keys.join(", "))
    }
}

impl std::fmt::Display for SensitivePlistAttachment {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        self.fmt(f)
    }
}

impl std::fmt::Debug for SensitivePlistAttachment {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        self.fmt(f)
    }
}

/// Parses a response body as a plist. Zag Store fork: on failure the report
/// says how long the body was, never what it held.
pub fn parse_response_plist(body: &str, what: &'static str) -> Result<Dictionary, Report> {
    plist::from_bytes(body.as_bytes())
        .map_err(|_| report!("Failed to parse {} plist ({} bytes withheld)", what, body.len()))
}

pub trait PlistDataExtract {
    fn get_data(&self, key: &str) -> Result<&[u8], Report>;
    fn get_str(&self, key: &str) -> Result<&str, Report>;
    fn get_string(&self, key: &str) -> Result<String, Report>;
    fn get_signed_integer(&self, key: &str) -> Result<i64, Report>;
    fn get_dict(&self, key: &str) -> Result<&Dictionary, Report>;
    fn get_bool(&self, key: &str) -> Result<bool, Report>;
    fn get_struct<T: DeserializeOwned>(&self, key: &str) -> Result<T, Report>;
}

impl PlistDataExtract for Dictionary {
    fn get_data(&self, key: &str) -> Result<&[u8], Report> {
        self.get(key).and_then(|v| v.as_data()).ok_or_else(|| {
            report!("Plist missing data for key '{}'", key)
                .attach(SensitivePlistAttachment::new(self.clone()))
        })
    }

    fn get_str(&self, key: &str) -> Result<&str, Report> {
        self.get(key).and_then(|v| v.as_string()).ok_or_else(|| {
            report!("Plist missing string for key '{}'", key)
                .attach(SensitivePlistAttachment::new(self.clone()))
        })
    }

    fn get_string(&self, key: &str) -> Result<String, Report> {
        self.get(key)
            .and_then(|v| v.as_string())
            .map(|s| s.to_string())
            .ok_or_else(|| {
                report!("Plist missing string for key '{}'", key)
                    .attach(SensitivePlistAttachment::new(self.clone()))
            })
    }

    fn get_signed_integer(&self, key: &str) -> Result<i64, Report> {
        self.get(key)
            .and_then(|v| v.as_signed_integer())
            .ok_or_else(|| {
                report!("Plist missing signed integer for key '{}'", key)
                    .attach(SensitivePlistAttachment::new(self.clone()))
            })
    }

    fn get_dict(&self, key: &str) -> Result<&Dictionary, Report> {
        self.get(key)
            .and_then(|v| v.as_dictionary())
            .ok_or_else(|| {
                report!("Plist missing dictionary for key '{}'", key)
                    .attach(SensitivePlistAttachment::new(self.clone()))
            })
    }

    fn get_struct<T: DeserializeOwned>(&self, key: &str) -> Result<T, Report> {
        let dict = self.get(key);
        let dict = dict.ok_or_else(|| {
            report!("Plist missing dictionary for key '{}'", key)
                .attach(SensitivePlistAttachment::new(self.clone()))
        })?;
        let struct_data: T = plist::from_value(dict).map_err(|e| {
            report!(
                "Failed to deserialize plist struct for key '{}': {:?}",
                key,
                e
            )
            .attach(SensitivePlistAttachment::new(
                dict.as_dictionary().cloned().unwrap_or_default(),
            ))
        })?;
        Ok(struct_data)
    }

    fn get_bool(&self, key: &str) -> Result<bool, Report> {
        self.get(key).and_then(|v| v.as_boolean()).ok_or_else(|| {
            report!("Plist missing boolean for key '{}'", key)
                .attach(SensitivePlistAttachment::new(self.clone()))
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const SECRET: &str = "SECRET-TOKEN-VALUE";

    fn sensitive() -> Dictionary {
        let mut dict = Dictionary::new();
        dict.insert("GsIdmsToken".into(), plist::Value::String(SECRET.into()));
        dict.insert("adsid".into(), plist::Value::String(SECRET.into()));
        dict
    }

    #[test]
    fn reports_name_keys_but_never_show_values() {
        let report = sensitive().get_str("missing").unwrap_err();
        for rendered in [format!("{report}"), format!("{report:?}")] {
            assert!(!rendered.contains(SECRET), "{rendered}");
            assert!(rendered.contains("GsIdmsToken"), "key names stay, for protocol changes");
        }
        let attachment = format!("{}", SensitivePlistAttachment::new(sensitive()));
        assert!(!attachment.contains(SECRET));
    }

    #[test]
    fn unparseable_bodies_are_not_reported() {
        let body = format!("<html>{SECRET}</html>");
        let report = parse_response_plist(&body, "test").unwrap_err();
        for rendered in [format!("{report}"), format!("{report:?}")] {
            assert!(!rendered.contains(SECRET), "{rendered}");
        }
        assert!(parse_response_plist("<plist><dict/></plist>", "test").is_ok());
    }
}
