//! Fails the build when the pinned libghostty-vt from native/scripts/ghostty-env.sh is not
//! available through pkg-config: libghostty-vt-sys would otherwise silently clone and build
//! Ghostty from the network (Faz 0 S1 finding).
fn main() {
    embed_info_plist();
    println!("cargo:rerun-if-env-changed=PKG_CONFIG_PATH");
    let ok = std::process::Command::new("pkg-config")
        .args(["--exists", "libghostty-vt-static"])
        .status()
        .map(|s| s.success())
        .unwrap_or(false);
    if !ok {
        panic!("libghostty-vt not found via pkg-config: run `eval \"$(native/scripts/ghostty-env.sh)\"` first");
    }
}

/// Embeds info.plist into the executable (__TEXT,__info_plist). A launchd-started daemon has no bundle Info.plist of
/// its own, and it is the "responsible process" macOS holds accountable for the files its children (shells, Claude)
/// touch: without usage strings the Documents/Desktop/Downloads access of those children fails with "Operation not
/// permitted" and no readable prompt. See docs/prd-native-beta.progress.md.
fn embed_info_plist() {
    let plist = std::path::Path::new(&std::env::var("CARGO_MANIFEST_DIR").unwrap()).join("info.plist");
    println!("cargo:rerun-if-changed={}", plist.display());
    println!("cargo:rustc-link-arg-bins=-Wl,-sectcreate,__TEXT,__info_plist,{}", plist.display());
}
