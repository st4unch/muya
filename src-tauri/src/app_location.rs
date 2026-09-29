//! Where does this app really live — and how do other tools keep reaching it no
//! matter where the user keeps it?
//!
//! Two problems, one cause. macOS runs a quarantined app (every zip we ship is one)
//! that sits outside a trusted location from a randomized, read-only copy under
//! `/private/var/folders/.../AppTranslocation/<UUID>/d/Muya.app`. That copy is
//! deleted when the app quits. So:
//!
//! 1. Any path Muya hands to another program pointing INTO its own bundle — the
//!    `muya-ssh-mcp` helper Claude Code and opencode spawn — is dead the moment
//!    Muya quits. Users saw `ENOENT .../AppTranslocation/.../muya-ssh-mcp` and no
//!    SSH tools. Fixed by [`stable_mcp_binary`]: the helper is copied to a fixed
//!    per-user location and THAT path is registered.
//! 2. macOS keeps translocating until the quarantine flag is gone from the ORIGINAL
//!    bundle. [`original_bundle`] finds it (Security framework's own translocation
//!    API), so the startup quarantine sweep can clear the flag there and the next
//!    launch runs in place — wherever the user keeps the app, /Applications or not.
//!
//! Nothing here assumes a particular folder: the app must work from wherever the
//! user put it.

use std::path::{Path, PathBuf};

/// Is this executable running from an App Translocation mount?
pub(crate) fn path_is_translocated(exe_path: &str) -> bool {
    exe_path.contains("/AppTranslocation/")
}

/// The `.app` bundle root for a given executable path, if it is inside one.
///
/// `<bundle>/Contents/MacOS/<exe>` — three levels up. Returns None for a bare
/// binary (`cargo run`, tests), which must never be touched.
pub(crate) fn bundle_root_from_exe(exe_path: &str) -> Option<String> {
    let p = Path::new(exe_path);
    let root = p.parent()?.parent()?.parent()?;
    root.extension()
        .filter(|e| *e == "app")
        .map(|_| root.to_string_lossy().into_owned())
}

/// The bundle the user actually has on disk, behind a translocated launch.
///
/// `translocated_bundle` is the `.app` inside the AppTranslocation mount. Returns
/// None when the path is not translocated or macOS can't say.
pub(crate) fn original_bundle(translocated_bundle: &Path) -> Option<PathBuf> {
    #[cfg(target_os = "macos")]
    {
        sys::original_path(translocated_bundle)
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = translocated_bundle;
        None
    }
}

/// Does `path` still carry `com.apple.quarantine`? The flag on the bundle
/// directory is what makes macOS translocate it.
pub(crate) fn has_quarantine(path: &Path) -> bool {
    #[cfg(target_os = "macos")]
    {
        use std::os::unix::ffi::OsStrExt;
        let Ok(c_path) = std::ffi::CString::new(path.as_os_str().as_bytes()) else {
            return false;
        };
        // Size query only (null buffer): >= 0 means the attribute exists.
        let n = unsafe {
            libc::getxattr(
                c_path.as_ptr(),
                c"com.apple.quarantine".as_ptr(),
                std::ptr::null_mut(),
                0,
                0,
                0,
            )
        };
        n >= 0
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = path;
        false
    }
}

/// Name of the MCP helper binary shipped next to the app binary.
pub(crate) const MCP_BIN_NAME: &str = "muya-ssh-mcp";

/// Fixed per-user home for the helper: `~/Library/Application Support/com.staunch.muya/bin`.
fn stable_bin_dir() -> Option<PathBuf> {
    dirs_next::data_dir().map(|d| d.join("com.staunch.muya").join("bin"))
}

/// The path to register for the MCP helper.
///
/// Inside a bundle, the helper is copied to [`stable_bin_dir`] and that copy is
/// returned: its path survives the app being translocated, moved or updated, and
/// every launch refreshes it so it always matches the running app. Outside a
/// bundle (`cargo run`, `tauri dev`) the freshly built binary next to the exe is
/// used as-is. A failed copy falls back to the helper beside the exe and says why.
pub(crate) fn stable_mcp_binary(exe: &Path) -> Result<PathBuf, String> {
    let dir = exe.parent().ok_or("cannot resolve executable directory")?;
    let beside = dir.join(MCP_BIN_NAME);
    let in_bundle = bundle_root_from_exe(&exe.to_string_lossy()).is_some();
    if !in_bundle || !beside.exists() {
        return Ok(beside);
    }
    let Some(bin_dir) = stable_bin_dir() else {
        return Ok(beside);
    };
    match install_copy(&beside, &bin_dir, MCP_BIN_NAME) {
        Ok(p) => Ok(p),
        Err(e) => {
            crate::debuglog::log(&format!(
                "[mcp] could not install stable helper copy ({e}); registering {}",
                beside.display()
            ));
            Ok(beside)
        }
    }
}

/// Copy `src` into `dir/name`, atomically and only when the content differs.
///
/// The bytes are written into a fresh file rather than `fs::copy`'d: on macOS
/// `fs::copy` clones extended attributes, and a copy made from a quarantined
/// (translocated) bundle would carry `com.apple.quarantine` along with it. The
/// code signature lives inside the Mach-O, so identical bytes keep it valid.
///
/// Replace-by-rename, so a helper process already running from the old file keeps
/// its inode and is not disturbed.
pub(crate) fn install_copy(src: &Path, dir: &Path, name: &str) -> Result<PathBuf, String> {
    use std::io::Write;
    use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};

    let bytes = std::fs::read(src).map_err(|e| format!("read {}: {e}", src.display()))?;
    let dst = dir.join(name);
    if std::fs::read(&dst).map(|b| b == bytes).unwrap_or(false) {
        return Ok(dst);
    }
    std::fs::create_dir_all(dir).map_err(|e| format!("create {}: {e}", dir.display()))?;
    // An executable other tools will run — keep its directory the user's alone.
    let _ = std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700));
    let tmp = dir.join(format!(".{name}.{}.tmp", std::process::id()));
    let write = || -> std::io::Result<()> {
        let mut f = std::fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o755)
            .open(&tmp)?;
        f.write_all(&bytes)?;
        f.sync_all()
    };
    if let Err(e) = write() {
        let _ = std::fs::remove_file(&tmp);
        return Err(format!("write {}: {e}", tmp.display()));
    }
    std::fs::rename(&tmp, &dst).map_err(|e| {
        let _ = std::fs::remove_file(&tmp);
        format!("rename into {}: {e}", dst.display())
    })?;
    Ok(dst)
}

#[cfg(target_os = "macos")]
mod sys {
    //! Security.framework's translocation SPI. It is not in the public headers, so
    //! it is looked up at runtime: a missing symbol degrades to "don't know"
    //! instead of a launch failure. Sparkle and other updaters rely on the same
    //! calls to find the real bundle behind a translocated launch.

    use core_foundation::base::TCFType;
    use core_foundation::url::{CFURLRef, CFURL};
    use std::ffi::{c_void, CStr};
    use std::path::{Path, PathBuf};

    type CFErrorRef = *mut c_void;

    pub(super) fn symbol(name: &CStr) -> Option<*mut c_void> {
        let lib = unsafe {
            libc::dlopen(
                c"/System/Library/Frameworks/Security.framework/Security".as_ptr(),
                libc::RTLD_LAZY,
            )
        };
        if lib.is_null() {
            return None;
        }
        let sym = unsafe { libc::dlsym(lib, name.as_ptr()) };
        (!sym.is_null()).then_some(sym)
    }

    fn release_error(err: CFErrorRef) {
        if !err.is_null() {
            unsafe { core_foundation::base::CFRelease(err as *const c_void) };
        }
    }

    fn url(path: &Path) -> Option<CFURL> {
        CFURL::from_path(path, true)
    }

    /// `SecTranslocateCreateOriginalPathForURL`: for a path inside a translocation
    /// mount, the path it was translocated from. For any other path macOS hands the
    /// input back, so callers must only ask about translocated paths.
    pub(super) fn original_path(translocated: &Path) -> Option<PathBuf> {
        type F = unsafe extern "C" fn(CFURLRef, *mut CFErrorRef) -> CFURLRef;
        let f: F =
            unsafe { std::mem::transmute(symbol(c"SecTranslocateCreateOriginalPathForURL")?) };
        let input = url(translocated)?;
        let mut err: CFErrorRef = std::ptr::null_mut();
        let out = unsafe { f(input.as_concrete_TypeRef(), &mut err) };
        release_error(err);
        if out.is_null() {
            return None;
        }
        let out = unsafe { CFURL::wrap_under_create_rule(out) };
        let path = out.to_path()?;
        (path != translocated).then_some(path)
    }

    /// `SecTranslocateCreateSecureDirectoryForURL`: translocate `path` exactly as
    /// LaunchServices would for a quarantined launch. Tests only — it lets the real
    /// round trip be exercised without launching an app.
    #[cfg(test)]
    pub(super) fn translocate(path: &Path) -> Option<PathBuf> {
        type F = unsafe extern "C" fn(CFURLRef, CFURLRef, *mut CFErrorRef) -> CFURLRef;
        let f: F =
            unsafe { std::mem::transmute(symbol(c"SecTranslocateCreateSecureDirectoryForURL")?) };
        let input = url(path)?;
        let mut err: CFErrorRef = std::ptr::null_mut();
        let out = unsafe { f(input.as_concrete_TypeRef(), std::ptr::null(), &mut err) };
        release_error(err);
        if out.is_null() {
            return None;
        }
        unsafe { CFURL::wrap_under_create_rule(out) }.to_path()
    }

    /// Tear down a mount made by [`translocate`].
    #[cfg(test)]
    pub(super) fn untranslocate(mount: &Path) {
        type F = unsafe extern "C" fn(CFURLRef, *mut CFErrorRef) -> u8;
        let Some(sym) = symbol(c"SecTranslocateDeleteSecureDirectory") else {
            return;
        };
        let f: F = unsafe { std::mem::transmute(sym) };
        if let Some(u) = url(mount) {
            let mut err: CFErrorRef = std::ptr::null_mut();
            unsafe { f(u.as_concrete_TypeRef(), &mut err) };
            release_error(err);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detects_translocation_and_bundle_root() {
        let t =
            "/private/var/folders/96/xk_1/T/AppTranslocation/9F0C/d/Muya.app/Contents/MacOS/muya";
        assert!(path_is_translocated(t));
        assert!(!path_is_translocated(
            "/Users/u/Downloads/Muya.app/Contents/MacOS/muya"
        ));
        assert_eq!(
            bundle_root_from_exe(t).as_deref(),
            Some("/private/var/folders/96/xk_1/T/AppTranslocation/9F0C/d/Muya.app")
        );
        assert_eq!(bundle_root_from_exe("/repo/target/debug/muya"), None);
    }

    fn fake_bundle(root: &Path) -> PathBuf {
        let macos = root.join("Muya.app/Contents/MacOS");
        std::fs::create_dir_all(&macos).unwrap();
        std::fs::write(macos.join("muya"), b"app").unwrap();
        std::fs::write(macos.join(MCP_BIN_NAME), b"helper-v1").unwrap();
        macos.join("muya")
    }

    #[test]
    fn a_bare_binary_registers_the_helper_beside_it() {
        let dir = tempfile::tempdir().unwrap();
        let exe = dir.path().join("muya");
        std::fs::write(&exe, b"x").unwrap();
        assert_eq!(
            stable_mcp_binary(&exe).unwrap(),
            dir.path().join(MCP_BIN_NAME)
        );
    }

    // The field bug: the registered path pointed INTO the (translocated) bundle and
    // died with it. Whatever the bundle's location, the registered copy must not
    // live inside it.
    #[test]
    fn install_copy_puts_the_helper_outside_the_bundle_and_refreshes_it() {
        let dir = tempfile::tempdir().unwrap();
        let exe = fake_bundle(dir.path());
        let src = exe.parent().unwrap().join(MCP_BIN_NAME);
        let bin = dir.path().join("support/bin");

        let dst = install_copy(&src, &bin, MCP_BIN_NAME).unwrap();
        assert_eq!(dst, bin.join(MCP_BIN_NAME));
        assert!(!dst.starts_with(dir.path().join("Muya.app")));
        assert_eq!(std::fs::read(&dst).unwrap(), b"helper-v1");
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(
            std::fs::metadata(&dst).unwrap().permissions().mode() & 0o777,
            0o755
        );

        // The bundle is deleted (translocation mount gone): the copy still works.
        std::fs::remove_dir_all(dir.path().join("Muya.app")).unwrap();
        assert_eq!(std::fs::read(&dst).unwrap(), b"helper-v1");

        // An updated app refreshes the copy on its next launch.
        let exe = fake_bundle(dir.path());
        std::fs::write(exe.parent().unwrap().join(MCP_BIN_NAME), b"helper-v2").unwrap();
        install_copy(
            &exe.parent().unwrap().join(MCP_BIN_NAME),
            &bin,
            MCP_BIN_NAME,
        )
        .unwrap();
        assert_eq!(std::fs::read(&dst).unwrap(), b"helper-v2");
    }

    // A copy made from a quarantined bundle must not inherit the quarantine flag.
    #[cfg(target_os = "macos")]
    #[test]
    fn install_copy_does_not_carry_quarantine_over() {
        let dir = tempfile::tempdir().unwrap();
        let src = dir.path().join("helper");
        std::fs::write(&src, b"h").unwrap();
        let ok = std::process::Command::new("/usr/bin/xattr")
            .args([
                "-w",
                "com.apple.quarantine",
                "0081;00000000;Test;",
                &src.to_string_lossy(),
            ])
            .status()
            .unwrap()
            .success();
        assert!(ok && has_quarantine(&src));
        let dst = install_copy(&src, &dir.path().join("bin"), "helper").unwrap();
        assert!(!has_quarantine(&dst));
    }

    // An OS update that drops the SPI would silently turn every translocated launch
    // back into the old bug (helper found, original bundle never cleaned). Fail loudly.
    #[cfg(target_os = "macos")]
    #[test]
    fn the_translocation_spi_exists_on_this_macos() {
        assert!(sys::symbol(c"SecTranslocateCreateOriginalPathForURL").is_some());
        assert!(sys::symbol(c"SecTranslocateIsTranslocatedURL").is_some());
    }

    // Real round trip through macOS's own translocation. Creating a translocation
    // is reserved to LaunchServices — an ordinary process gets EPERM — so this only
    // proves anything where the caller is allowed to (run it by hand with
    // `cargo test -- --ignored` from a context that can). It is ignored rather than
    // quietly passing, so a green run never pretends to have covered it.
    #[cfg(target_os = "macos")]
    #[test]
    #[ignore = "needs LaunchServices' privilege to create a translocation"]
    fn original_bundle_finds_the_real_location_behind_a_translocation() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().canonicalize().unwrap();
        fake_bundle(&root);
        let bundle = root.join("Muya.app");
        std::process::Command::new("/usr/bin/xattr")
            .args([
                "-w",
                "com.apple.quarantine",
                "0081;00000000;Test;",
                &bundle.to_string_lossy(),
            ])
            .status()
            .unwrap();

        let translocated = sys::translocate(&bundle)
            .expect("macOS refused to translocate — this context lacks the privilege");
        assert!(
            path_is_translocated(&translocated.to_string_lossy()),
            "{translocated:?}"
        );
        let found = original_bundle(&translocated);
        sys::untranslocate(&translocated);
        assert_eq!(found.map(|p| p.canonicalize().unwrap()), Some(bundle));
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn original_bundle_is_none_for_a_path_that_was_never_translocated() {
        let dir = tempfile::tempdir().unwrap();
        assert_eq!(original_bundle(dir.path()), None);
    }
}
