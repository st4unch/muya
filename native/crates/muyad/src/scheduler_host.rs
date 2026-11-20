//! The schedule timers hosted inside muyad (`--scheduler`, PRD AC22 / D8): muyad is the single
//! owner. `muya_core::schedules` holds the logic; this runs its timer on a dedicated runtime and
//! forwards "something changed" to attached apps as a `schedules-changed` event.

use crate::Muyad;
use muya_core::schedules::{self, ScheduleState};
use serde_json::Value;
use std::sync::Arc;

/// Starts the timer loop on its own thread. The state may be passive (another process owns the
/// lock, e.g. the Tauri window): the loop then keeps retrying, so ownership fails over when the
/// owner goes away. Returns whether this process owns the timers right now.
pub fn spawn(state: ScheduleState, muyad: Arc<Muyad>) -> Result<bool, String> {
    let owns = state.is_active();
    let typer = muyad.clone();
    state.set_session_sender(move |t, text| {
        typer
            .type_line(t.id, text)
            .map_err(|_| format!("The session “{}” is no longer running, so “{}” was not sent.", t.name, text.chars().take(40).collect::<String>()))
    });
    state.set_sink(move || {
        let _ = muyad.emit_event("schedules-changed", &Value::Null);
    });
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::Builder::new()
        .name("scheduler".into())
        .spawn(move || {
            let rt = match tokio::runtime::Builder::new_multi_thread().worker_threads(2).enable_all().build() {
                Ok(rt) => rt,
                Err(e) => return drop(tx.send(Err(format!("tokio runtime: {e}")))),
            };
            let handle = rt.handle().clone();
            state.set_spawner(move |f| {
                handle.spawn(f);
            });
            let _ = tx.send(Ok(()));
            rt.block_on(schedules::run_timer(state));
        })
        .map_err(|e| e.to_string())?;
    rx.recv().map_err(|_| "scheduler thread died".to_string())??;
    Ok(owns)
}
