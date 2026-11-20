//! Idempotency keys for typed deliveries (PRD AC25): `send_to_session` with `deliver:"muya"` or
//! `"keys"` retried with the same `idempotencyKey` types its text once, even when the daemon was
//! killed between the two attempts.
//!
//! The key is written to disk BEFORE the text is handed to the terminal (at-most-once: a crash in
//! that tiny window loses the message instead of typing it twice — the caller sees an error or no
//! reply and can resend with a NEW key). A failed hand-off gives the key back. The store keeps the
//! newest [`MAX_KEYS`] keys, each for at most [`TTL_MS`].

use std::path::{Path, PathBuf};
use std::sync::Mutex;

pub const MAX_KEYS: usize = 1000;
pub const TTL_MS: u64 = 24 * 60 * 60 * 1000;

pub struct DeliveryKeys {
    path: PathBuf,
    /// (key, claimed-at ms), oldest first.
    keys: Mutex<Vec<(String, u64)>>,
}

pub fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

impl DeliveryKeys {
    /// Loads (or starts) the store at `path`; a missing or corrupt file is an empty store.
    pub fn open(path: &Path) -> Self {
        let keys = std::fs::read_to_string(path)
            .ok()
            .and_then(|s| serde_json::from_str::<Vec<(String, u64)>>(&s).ok())
            .unwrap_or_default();
        Self {
            path: path.to_path_buf(),
            keys: Mutex::new(keys),
        }
    }

    /// Under `<claude dir>/muya-delivery-keys.json`.
    pub fn in_claude_dir(dir: &Path) -> Self {
        Self::open(&dir.join("muya-delivery-keys.json"))
    }

    /// `true` = first time this key is seen: it is persisted before this returns and the caller
    /// delivers. `false` = a retry: do NOT deliver again. Err = could not persist (do not deliver).
    pub fn claim(&self, key: &str, now: u64) -> Result<bool, String> {
        let mut keys = self.keys.lock().unwrap_or_else(|e| e.into_inner());
        keys.retain(|(_, at)| now.saturating_sub(*at) < TTL_MS);
        if keys.iter().any(|(k, _)| k == key) {
            return Ok(false);
        }
        keys.push((key.to_owned(), now));
        if keys.len() > MAX_KEYS {
            let drop = keys.len() - MAX_KEYS;
            keys.drain(..drop);
        }
        if let Err(e) = self.persist(&keys) {
            keys.pop();
            return Err(e);
        }
        Ok(true)
    }

    /// Gives a claimed key back (the hand-off failed, so a retry must be allowed to deliver).
    pub fn release(&self, key: &str) {
        let mut keys = self.keys.lock().unwrap_or_else(|e| e.into_inner());
        keys.retain(|(k, _)| k != key);
        let _ = self.persist(&keys);
    }

    fn persist(&self, keys: &[(String, u64)]) -> Result<(), String> {
        let bytes = serde_json::to_vec(keys).map_err(|e| e.to_string())?;
        if let Some(dir) = self.path.parent() {
            std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
        }
        crate::fsutil::atomic_write(&self.path, &bytes)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn store() -> (tempfile::TempDir, DeliveryKeys) {
        let d = tempfile::tempdir().unwrap();
        let s = DeliveryKeys::open(&d.path().join("k.json"));
        (d, s)
    }

    #[test]
    fn second_claim_of_the_same_key_is_a_retry() {
        let (_d, s) = store();
        assert_eq!(s.claim("a", 1), Ok(true));
        assert_eq!(s.claim("a", 2), Ok(false));
        assert_eq!(s.claim("b", 3), Ok(true));
    }

    #[test]
    fn keys_survive_a_restart() {
        let d = tempfile::tempdir().unwrap();
        let p = d.path().join("k.json");
        assert_eq!(DeliveryKeys::open(&p).claim("a", 1), Ok(true));
        assert_eq!(DeliveryKeys::open(&p).claim("a", 2), Ok(false));
    }

    #[test]
    fn release_allows_a_new_delivery() {
        let (_d, s) = store();
        assert_eq!(s.claim("a", 1), Ok(true));
        s.release("a");
        assert_eq!(s.claim("a", 2), Ok(true));
    }

    #[test]
    fn keys_expire_after_the_ttl() {
        let (_d, s) = store();
        assert_eq!(s.claim("a", 1), Ok(true));
        assert_eq!(s.claim("a", TTL_MS), Ok(false));
        assert_eq!(s.claim("a", 1 + TTL_MS), Ok(true));
    }

    #[test]
    fn only_the_newest_thousand_are_kept() {
        let (_d, s) = store();
        for i in 0..(MAX_KEYS + 5) {
            assert_eq!(s.claim(&format!("k{i}"), 10), Ok(true));
        }
        assert_eq!(s.claim("k0", 11), Ok(true), "oldest was evicted");
        assert_eq!(
            s.claim(&format!("k{}", MAX_KEYS + 4), 11),
            Ok(false),
            "newest is kept"
        );
        let reopened = DeliveryKeys::open(&s.path);
        assert!(reopened.keys.lock().unwrap().len() <= MAX_KEYS);
    }

    #[test]
    fn a_corrupt_file_is_an_empty_store() {
        let d = tempfile::tempdir().unwrap();
        let p = d.path().join("k.json");
        std::fs::write(&p, "{not json").unwrap();
        assert_eq!(DeliveryKeys::open(&p).claim("a", 1), Ok(true));
    }
}
