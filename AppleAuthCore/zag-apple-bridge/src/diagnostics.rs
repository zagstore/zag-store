//! Zag Store fork: a structured, privacy-preserving diagnostic for a failed
//! Apple-account / anisette operation. It names the stage, the source, a safe
//! numeric code where one is typed or recognised from a known allowlist, an
//! HTTP status where present, a retryability class, and whether the failure
//! was before or after the anisette provider exchange.
//!
//! Every field is a small enum, an integer or an `Option` of one. It never
//! carries a message, token, identifier, serial number, provisioning blob,
//! response body or header — so it is safe to log or surface to Swift.
//!
//! This does not replace `FailureKind` or the authentication error classifier
//! (`live::classify`); it is an additional, read-only view derived from the
//! same typed errors, so the two stay consistent without being coupled.

use rootcause::Report;
use serde::Serialize;

use isideload::SideloadError;
use isideload::anisette::remote_v3::{ProvisioningFault, ProvisioningStage};
use isideload::net_policy::PolicyError;

/// The step at which a failure occurred.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum DiagnosticStage {
    Identifier,
    StartProvisioning,
    EndProvisioning,
    HeaderFetch,
    Authentication,
    Portal,
    Transport,
    Unknown,
}

/// Which layer produced the failure.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum DiagnosticSource {
    /// The anisette provider (its server or the provisioning exchange).
    AnisetteProvider,
    /// Apple GrandSlam authentication.
    AppleGrandSlam,
    /// The Apple developer portal.
    DeveloperPortal,
    /// The HTTP transport or the network policy.
    Transport,
    Unknown,
}

/// Whether retrying the same operation could plausibly succeed.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Retryability {
    Retryable,
    NotRetryable,
    Unknown,
}

/// A privacy-preserving description of a failure. Safe to log or surface.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProvisioningDiagnostic {
    pub stage: DiagnosticStage,
    pub source: DiagnosticSource,
    pub http_status: Option<u16>,
    /// A typed GSA/developer code, or a code recognised from the anisette
    /// known-code allowlist. `None` when none could be extracted safely.
    pub code: Option<i64>,
    pub retryable: Retryability,
    /// `Some(true)` if the failure was before the anisette provider exchange,
    /// `Some(false)` during or after it, `None` if not determinable.
    pub before_provider_exchange: Option<bool>,
}

impl ProvisioningDiagnostic {
    fn unknown() -> Self {
        ProvisioningDiagnostic {
            stage: DiagnosticStage::Unknown,
            source: DiagnosticSource::Unknown,
            http_status: None,
            code: None,
            retryable: Retryability::Unknown,
            before_provider_exchange: None,
        }
    }
}

fn stage_of(stage: ProvisioningStage) -> (DiagnosticStage, Option<bool>) {
    match stage {
        ProvisioningStage::Identifier => (DiagnosticStage::Identifier, Some(true)),
        ProvisioningStage::StartProvisioning => (DiagnosticStage::StartProvisioning, Some(false)),
        ProvisioningStage::EndProvisioning => (DiagnosticStage::EndProvisioning, Some(false)),
        ProvisioningStage::HeaderFetch => (DiagnosticStage::HeaderFetch, Some(false)),
    }
}

/// Derives a privacy-preserving diagnostic from a failure, reading only typed
/// error contexts — never message text. Returns the first recognised layer in
/// the report chain; `Unknown` when none matches.
pub fn diagnose(report: &Report) -> ProvisioningDiagnostic {
    for part in report.iter_reports() {
        if let Some(fault) = part.downcast_current_context::<ProvisioningFault>() {
            let (stage, before) = stage_of(fault.stage);
            return ProvisioningDiagnostic {
                stage,
                source: DiagnosticSource::AnisetteProvider,
                http_status: None,
                code: fault.code,
                retryable: match fault.code {
                    // "Device not provisioned" is recovered by re-provisioning.
                    Some(-45061) => Retryability::Retryable,
                    Some(_) => Retryability::NotRetryable,
                    None => Retryability::Unknown,
                },
                before_provider_exchange: before,
            };
        }
        if let Some(error) = part.downcast_current_context::<SideloadError>() {
            return match error {
                SideloadError::AuthWithMessage(code, _) => ProvisioningDiagnostic {
                    stage: DiagnosticStage::Authentication,
                    source: DiagnosticSource::AppleGrandSlam,
                    http_status: None,
                    code: Some(*code),
                    retryable: Retryability::NotRetryable,
                    before_provider_exchange: Some(true),
                },
                SideloadError::DeveloperError(code, _) => ProvisioningDiagnostic {
                    stage: DiagnosticStage::Portal,
                    source: DiagnosticSource::DeveloperPortal,
                    http_status: None,
                    code: Some(*code),
                    retryable: Retryability::NotRetryable,
                    before_provider_exchange: Some(false),
                },
                SideloadError::PlistParseError(_) | SideloadError::InvalidBundle(_) => {
                    ProvisioningDiagnostic::unknown()
                }
            };
        }
        if let Some(error) = part.downcast_current_context::<reqwest::Error>() {
            let status = error.status().map(|s| s.as_u16());
            return ProvisioningDiagnostic {
                stage: DiagnosticStage::Transport,
                source: DiagnosticSource::Transport,
                http_status: status,
                code: None,
                retryable: match status {
                    Some(429) | Some(500..=599) => Retryability::Retryable,
                    Some(400..=499) => Retryability::NotRetryable,
                    // A transport error with no HTTP status is usually transient.
                    _ => Retryability::Retryable,
                },
                before_provider_exchange: None,
            };
        }
        if part.downcast_current_context::<PolicyError>().is_some() {
            return ProvisioningDiagnostic {
                stage: DiagnosticStage::Transport,
                source: DiagnosticSource::Transport,
                http_status: None,
                code: None,
                retryable: Retryability::NotRetryable,
                before_provider_exchange: None,
            };
        }
    }
    ProvisioningDiagnostic::unknown()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn end_provisioning_mismatch_names_the_stage_and_known_code() {
        // -29003 at end-provisioning: the Android-ADI vs claimed-platform
        // mismatch. Stage and code are captured; no message is read.
        let report: Report = rootcause::report!("end provisioning error (48 bytes withheld)")
            .context(ProvisioningFault { stage: ProvisioningStage::EndProvisioning, code: Some(-29003) })
            .into();
        let d = diagnose(&report);
        assert_eq!(d.stage, DiagnosticStage::EndProvisioning);
        assert_eq!(d.source, DiagnosticSource::AnisetteProvider);
        assert_eq!(d.code, Some(-29003));
        assert_eq!(d.retryable, Retryability::NotRetryable);
        assert_eq!(d.before_provider_exchange, Some(false));
    }

    #[test]
    fn not_provisioned_is_retryable() {
        let report: Report = rootcause::report!("header fetch error")
            .context(ProvisioningFault { stage: ProvisioningStage::HeaderFetch, code: Some(-45061) })
            .into();
        assert_eq!(diagnose(&report).retryable, Retryability::Retryable);
    }

    #[test]
    fn a_provisioning_failure_without_a_known_code_is_unknown_not_fabricated() {
        let report: Report = rootcause::report!("start provisioning error (12 bytes withheld)")
            .context(ProvisioningFault { stage: ProvisioningStage::StartProvisioning, code: None })
            .into();
        let d = diagnose(&report);
        assert_eq!(d.stage, DiagnosticStage::StartProvisioning);
        assert_eq!(d.code, None, "an unextractable code is Unknown, not invented");
        assert_eq!(d.retryable, Retryability::Unknown);
    }

    #[test]
    fn authentication_rejection_carries_its_typed_code_and_is_distinct_from_malformed() {
        let report: Report = rootcause::report!(SideloadError::AuthWithMessage(-20101, "withheld".into())).into();
        let d = diagnose(&report);
        assert_eq!(d.stage, DiagnosticStage::Authentication);
        assert_eq!(d.source, DiagnosticSource::AppleGrandSlam);
        assert_eq!(d.code, Some(-20101));
        assert_eq!(d.retryable, Retryability::NotRetryable);
    }

    #[test]
    fn a_developer_portal_error_is_attributed_to_the_portal() {
        let report: Report = rootcause::report!(SideloadError::DeveloperError(35, "withheld".into())).into();
        let d = diagnose(&report);
        assert_eq!(d.stage, DiagnosticStage::Portal);
        assert_eq!(d.source, DiagnosticSource::DeveloperPortal);
        assert_eq!(d.code, Some(35));
    }

    #[test]
    fn a_policy_error_is_a_transport_failure() {
        let report: Report = rootcause::report!(PolicyError::HostNotAllowed).into();
        let d = diagnose(&report);
        assert_eq!(d.source, DiagnosticSource::Transport);
        assert_eq!(d.stage, DiagnosticStage::Transport);
    }

    #[test]
    fn an_unrecognised_failure_is_unknown() {
        let report = rootcause::report!("something else entirely");
        let d = diagnose(&report);
        assert_eq!(d.stage, DiagnosticStage::Unknown);
        assert_eq!(d.source, DiagnosticSource::Unknown);
        assert_eq!(d.code, None);
    }

    #[test]
    fn the_diagnostic_serialises_without_any_message_text() {
        let report: Report = rootcause::report!("end provisioning error (99 bytes withheld)")
            .context(ProvisioningFault { stage: ProvisioningStage::EndProvisioning, code: Some(-29003) })
            .into();
        let json = serde_json::to_string(&diagnose(&report)).unwrap();
        assert!(json.contains("endProvisioning") && json.contains("-29003"));
        assert!(!json.contains("withheld"), "no message text is ever serialised");
    }
}
