//! "Should we offer the Native beta right now?" — a pure decision.

use crate::manifest::Manifest;
use crate::version::is_newer;
use serde::{Deserialize, Serialize};

pub const NOT_NOW_SECS: u64 = 14 * 24 * 3600;

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Trigger {
    /// Right after the normal update flow.
    AfterUpdate,
    /// The user opened Settings > Beta.
    Settings,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OfferState {
    #[serde(default)]
    pub dismissed_forever: bool,
    #[serde(default)]
    pub not_now_at: Option<u64>,
    #[serde(default)]
    pub not_now_version: Option<String>,
    #[serde(default)]
    pub last_offered_version: Option<String>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct OfferInput<'a> {
    /// `Some` only when the signature already verified.
    pub manifest: Option<&'a Manifest>,
    pub classic_version: &'a str,
    pub installed_native: Option<&'a str>,
    pub state: &'a OfferState,
    pub now_unix: u64,
    pub trigger: Trigger,
}

#[derive(Debug, Clone, PartialEq)]
pub enum HideReason {
    NoValidManifest,
    ClassicTooOld,
    NotNewerThanInstalled,
    DismissedForever,
    NotNowRecent,
    AlreadyOfferedThisVersion,
}

#[derive(Debug, Clone, PartialEq)]
pub enum Offer {
    Hidden(HideReason),
    /// Show the dialog for this version.
    Show { version: String },
    /// This exact version (or newer) is already installed.
    AlreadyInstalled,
}

pub fn decide(i: &OfferInput) -> Offer {
    let Some(m) = i.manifest else { return Offer::Hidden(HideReason::NoValidManifest) };
    if is_newer(&m.min_classic_version, i.classic_version) {
        return Offer::Hidden(HideReason::ClassicTooOld);
    }
    if let Some(inst) = i.installed_native {
        if !is_newer(&m.version, inst) {
            return Offer::AlreadyInstalled;
        }
    }
    if i.trigger == Trigger::Settings {
        return Offer::Show { version: m.version.clone() };
    }
    if i.state.dismissed_forever {
        return Offer::Hidden(HideReason::DismissedForever);
    }
    if let (Some(at), Some(v)) = (i.state.not_now_at, i.state.not_now_version.as_deref()) {
        if v == m.version && i.now_unix.saturating_sub(at) < NOT_NOW_SECS {
            return Offer::Hidden(HideReason::NotNowRecent);
        }
    }
    if i.state.last_offered_version.as_deref() == Some(m.version.as_str()) {
        return Offer::Hidden(HideReason::AlreadyOfferedThisVersion);
    }
    Offer::Show { version: m.version.clone() }
}

/// State after the user answered the dialog.
pub fn after_answer(mut s: OfferState, version: &str, answer: Answer, now: u64) -> OfferState {
    s.last_offered_version = Some(version.to_string());
    match answer {
        Answer::TryIt => {}
        Answer::NotNow => {
            s.not_now_at = Some(now);
            s.not_now_version = Some(version.to_string());
        }
        Answer::DontAskAgain => s.dismissed_forever = true,
    }
    s
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Answer {
    TryIt,
    NotNow,
    DontAskAgain,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::manifest::{parse_unsigned, sample_json};

    fn m(v: &str) -> Manifest {
        parse_unsigned(sample_json(v).as_bytes()).unwrap()
    }
    fn input<'a>(m: Option<&'a Manifest>, s: &'a OfferState, t: Trigger) -> OfferInput<'a> {
        OfferInput { manifest: m, classic_version: "4.1.21", installed_native: None, state: s, now_unix: 1_000_000, trigger: t }
    }

    #[test]
    fn no_manifest_hides() {
        let s = OfferState::default();
        assert_eq!(decide(&input(None, &s, Trigger::AfterUpdate)), Offer::Hidden(HideReason::NoValidManifest));
    }
    #[test]
    fn classic_too_old_hides_even_in_settings() {
        let s = OfferState::default();
        let man = m("0.1.0");
        let mut i = input(Some(&man), &s, Trigger::Settings);
        i.classic_version = "4.1.20";
        assert_eq!(decide(&i), Offer::Hidden(HideReason::ClassicTooOld));
    }
    #[test]
    fn never_older_beta_than_installed() {
        let s = OfferState::default();
        let man = m("0.1.0");
        let mut i = input(Some(&man), &s, Trigger::AfterUpdate);
        i.installed_native = Some("0.1.0");
        assert_eq!(decide(&i), Offer::AlreadyInstalled);
        i.installed_native = Some("0.2.0");
        assert_eq!(decide(&i), Offer::AlreadyInstalled);
        i.installed_native = Some("0.0.9");
        assert_eq!(decide(&i), Offer::Show { version: "0.1.0".into() });
    }
    #[test]
    fn once_per_version() {
        let man = m("0.1.0");
        let s = after_answer(OfferState::default(), "0.1.0", Answer::TryIt, 5);
        assert_eq!(decide(&input(Some(&man), &s, Trigger::AfterUpdate)), Offer::Hidden(HideReason::AlreadyOfferedThisVersion));
        let man2 = m("0.2.0");
        assert_eq!(decide(&input(Some(&man2), &s, Trigger::AfterUpdate)), Offer::Show { version: "0.2.0".into() });
    }
    #[test]
    fn not_now_blocks_14_days_same_version() {
        let man = m("0.1.0");
        let mut s = OfferState::default();
        s.not_now_at = Some(1_000_000 - 100);
        s.not_now_version = Some("0.1.0".into());
        assert_eq!(decide(&input(Some(&man), &s, Trigger::AfterUpdate)), Offer::Hidden(HideReason::NotNowRecent));
        let mut i = input(Some(&man), &s, Trigger::AfterUpdate);
        i.now_unix = 1_000_000 + NOT_NOW_SECS;
        assert!(matches!(decide(&i), Offer::Show { .. }));
        // a new version breaks the not-now window
        let man2 = m("0.2.0");
        assert!(matches!(decide(&input(Some(&man2), &s, Trigger::AfterUpdate)), Offer::Show { .. }));
    }
    #[test]
    fn dismissed_forever_blocks_after_update_not_settings() {
        let man = m("0.1.0");
        let s = after_answer(OfferState::default(), "0.0.1", Answer::DontAskAgain, 1);
        assert_eq!(decide(&input(Some(&man), &s, Trigger::AfterUpdate)), Offer::Hidden(HideReason::DismissedForever));
        assert!(matches!(decide(&input(Some(&man), &s, Trigger::Settings)), Offer::Show { .. }));
    }
    #[test]
    fn settings_ignores_not_now_and_offered() {
        let man = m("0.1.0");
        let s = after_answer(OfferState::default(), "0.1.0", Answer::NotNow, 1_000_000 - 1);
        assert!(matches!(decide(&input(Some(&man), &s, Trigger::Settings)), Offer::Show { .. }));
    }
}
