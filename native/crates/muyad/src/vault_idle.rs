//! Auto-lock of the password store after idle time — the same rule as classic Muya (src/App.tsx, PRD
//! vault-touchid-autolock): 15 minutes without any interaction ANYWHERE in the app, checked once a minute, then the
//! derived key is dropped (zeroized) and the UI is told (`muya://vault-locked`). Classic watches mouse / key / wheel in the
//! window; here the app pings `vault.activity` for the same events and the daemon counts, so a closed app cannot leave
//! the store open: the clock keeps running and the agents' secret tools answer "locked" afterwards.

use crate::Muyad;
use muya_core::credstore::{self, CredStore};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Weak};
use std::time::{Duration, Instant};

/// Classic's `IDLE_LOCK_MS`.
pub const DEFAULT_IDLE: Duration = Duration::from_secs(15 * 60);

/// When the store was last used by a person (unlock or an interaction ping), as milliseconds since `start`.
pub struct IdleClock {
    start: Instant,
    last_ms: AtomicU64,
}

impl IdleClock {
    pub fn new() -> Arc<Self> {
        Arc::new(Self { start: Instant::now(), last_ms: AtomicU64::new(0) })
    }
    pub fn touch(&self) {
        self.last_ms.store(self.start.elapsed().as_millis() as u64, Ordering::Relaxed);
    }
    pub fn idle_for(&self) -> Duration {
        Duration::from_millis((self.start.elapsed().as_millis() as u64).saturating_sub(self.last_ms.load(Ordering::Relaxed)))
    }
}

/// `MUYA_VAULT_IDLE_SECS` (tests) or classic's 15 minutes.
pub fn configured_idle() -> Duration {
    std::env::var("MUYA_VAULT_IDLE_SECS").ok().and_then(|s| s.parse::<u64>().ok()).filter(|s| *s > 0).map(Duration::from_secs).unwrap_or(DEFAULT_IDLE)
}

/// One check: lock when unlocked and idle for at least `limit`. Returns true when it locked.
pub fn check(vault: &CredStore, clock: &IdleClock, limit: Duration, muyad: &Weak<Muyad>) -> bool {
    if !credstore::is_unlocked(vault) || clock.idle_for() < limit {
        return false;
    }
    if credstore::lock_store(vault).is_err() {
        return false;
    }
    if let Some(m) = muyad.upgrade() {
        let _ = m.emit_event("muya://vault-locked", &serde_json::Value::Null);
    }
    true
}

/// Checks every minute (a quarter of the limit when that is shorter, for tests).
pub fn spawn(vault: Arc<CredStore>, clock: Arc<IdleClock>, limit: Duration, muyad: Weak<Muyad>) {
    let tick = Duration::from_secs(60).min(limit / 4).max(Duration::from_millis(100));
    let _ = std::thread::Builder::new().name("vault-idle".into()).spawn(move || loop {
        std::thread::sleep(tick);
        check(&vault, &clock, limit, &muyad);
    });
}
