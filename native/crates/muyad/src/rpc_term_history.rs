//! P7 Rpc methods: `term_history.*` — the Sessions page's per-terminal command history. The
//! history folder is under the daemon user's own data dir (never another user's files); a missing
//! or garbled history file yields an empty list / `null`, not an error (muya-core's parser).

use muya_core::term_history;
use serde::Deserialize;
use serde_json::Value;

#[derive(Deserialize)]
struct KeyParams {
    key: String,
}

#[derive(Deserialize)]
struct ExportParams {
    dest: String,
    text: String,
}

fn p<T: serde::de::DeserializeOwned>(params: &str) -> Result<T, String> {
    serde_json::from_str(if params.trim().is_empty() {
        "{}"
    } else {
        params
    })
    .map_err(|e| format!("bad parameters: {e}"))
}

fn enc<T: serde::Serialize>(v: &T) -> Result<Value, String> {
    serde_json::to_value(v).map_err(|e| format!("encode: {e}"))
}

/// `None` = not ours.
pub fn call(method: &str, params: &str) -> Option<Result<Value, String>> {
    let r = match method {
        "term_history.entries" => enc(&crate::rpc_resources::block_on(
            term_history::term_history_entries(),
        )),
        "term_history.full" => p::<KeyParams>(params)
            .and_then(|a| crate::rpc_resources::block_on(term_history::term_history_full(a.key)))
            .and_then(|r| enc(&r)),
        "term_history.export" => p::<ExportParams>(params)
            .and_then(|a| {
                crate::rpc_resources::block_on(term_history::term_history_export(a.dest, a.text))
            })
            .map(|()| Value::Null),
        "term_history.delete" => p::<KeyParams>(params)
            .and_then(|a| term_history::term_history_delete(a.key))
            .map(|()| Value::Null),
        _ => return None,
    };
    Some(r)
}
