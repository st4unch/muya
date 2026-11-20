//! `classic-vault <init|add|list|reveal> ...` over classic Muya's original credstore (HOME decides the file).
#[allow(dead_code, unused_imports)]
mod old_credstore;

/// Just enough of tauri for the old file to compile unchanged apart from the `#[tauri::command]` lines.
mod tauri {
    pub struct State<'a, T> { inner: &'a T }
    impl<'a, T> State<'a, T> { pub fn new(inner: &'a T) -> Self { Self { inner } } }
    impl<T> std::ops::Deref for State<'_, T> {
        type Target = T;
        fn deref(&self) -> &T { self.inner }
    }
    pub struct AppHandle;
    pub trait Emitter { fn emit(&self, _: &str, _: ()) -> Result<(), String> { Ok(()) } }
    impl Emitter for AppHandle {}
}

use old_credstore::*;
use tauri::State;

#[tokio::main]
async fn main() {
    let a: Vec<String> = std::env::args().collect();
    let store = CredStore::default();
    let master = std::env::var("MUYA_TEST_MASTER").expect("MUYA_TEST_MASTER");
    let run = async {
        match a.get(1).map(String::as_str) {
            Some("init") => credstore_init(master, State::new(&store)).await.map(|_| String::new()),
            Some("add") => {
                credstore_unlock(master, State::new(&store)).await?;
                let c = CredInput { id: None, label: a[2].clone(), username: "tester".into(), secret_kind: "password".into(), secret: a[3].clone().into(), description: "made by classic".into(), group: String::new(), key_passphrase: None };
                credstore_cred_upsert(c, State::new(&store)).map(|_| String::new())
            }
            Some("list") => {
                credstore_unlock(master, State::new(&store)).await?;
                Ok(credstore_cred_list(State::new(&store))?.into_iter().map(|m| m.label).collect::<Vec<_>>().join(","))
            }
            Some("reveal") => {
                credstore_unlock(master, State::new(&store)).await?;
                let id = credstore_cred_list(State::new(&store))?.into_iter().find(|m| m.label == a[2]).ok_or("no such label")?.id;
                credstore_reveal_cred(id, State::new(&store))
            }
            _ => Err("usage: classic-vault init|add <label> <secret>|list|reveal <label>".into()),
        }
    };
    match run.await {
        Ok(out) => println!("{out}"),
        Err(e) => { eprintln!("classic-vault: {e}"); std::process::exit(1); }
    }
}
