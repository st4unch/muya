//! Embeds info.plist into the daemon executable (__TEXT,__info_plist): ptyd is the responsible process for the shells
//! and Claude sessions it spawns, so macOS needs its usage strings to ask once ("Muya ... Documents") and remember.
fn main() {
    let plist = std::path::Path::new(&std::env::var("CARGO_MANIFEST_DIR").unwrap()).join("info.plist");
    println!("cargo:rerun-if-changed={}", plist.display());
    println!("cargo:rustc-link-arg-bins=-Wl,-sectcreate,__TEXT,__info_plist,{}", plist.display());
}
