//! Where the running app really lives, and whether we may change it there.
//!
//! An update or a switch must replace the app *where the user keeps it* — Desktop, `~/Applications`, an external
//! drive, a renamed copy, `/Applications` — and under the same file name. Nothing in here guesses a location: the
//! target is derived from the path of the process that asked, symlinks resolved. A bundle that is not on disk as a
//! real app, or that macOS runs from a temporary App-Translocation copy, is refused with a message that says what
//! to do. The pure functions are unit-tested; the folder probe touches only a throwaway file in the target folder.

use std::path::{Path, PathBuf};

fn is_app(p: &Path) -> bool {
    p.extension().is_some_and(|e| e == "app")
}

/// `…/Foo.app` containing `p` (the path itself when it already is the bundle).
pub fn bundle_of(p: &Path) -> Option<PathBuf> {
    p.ancestors().find(|a| is_app(a)).map(Path::to_path_buf)
}

/// A path macOS made for a quarantined app that was opened from outside Applications; writing there changes a
/// throwaway copy, never the app the user sees.
pub fn is_translocated(p: &Path) -> bool {
    p.to_string_lossy().contains("/AppTranslocation/")
}

pub const TRANSLOCATED_MESSAGE: &str = "Muya is running from a temporary location that macOS creates for apps opened straight from a download. Drag the app to Applications (or any folder you keep apps in) in Finder, open it from there, then try again.";

/// The real bundle for `candidate` (an app path, or any path inside one — e.g. the running executable):
/// symlinks resolved, must be a `.app` with an `Info.plist`, must not be a translocated copy. The file name is the
/// one on disk (a user's rename is kept).
pub fn resolve_bundle(candidate: &Path) -> Result<PathBuf, String> {
    // Check the path as given first: a translocated path may not canonicalize the same way.
    if is_translocated(candidate) {
        return Err(TRANSLOCATED_MESSAGE.into());
    }
    let bundle = bundle_of(candidate)
        .ok_or_else(|| format!("{} is not inside an app bundle", candidate.display()))?;
    let real = std::fs::canonicalize(&bundle).map_err(|e| {
        format!(
            "could not find the running app at {} ({e})",
            bundle.display()
        )
    })?;
    if is_translocated(&real) {
        return Err(TRANSLOCATED_MESSAGE.into());
    }
    // The symlink may point at something inside another bundle's folder; take the outermost real `.app` again.
    let real = bundle_of(&real).unwrap_or(real);
    if !real.join("Contents/Info.plist").is_file() {
        return Err(format!(
            "{} is not a complete app (Contents/Info.plist is missing)",
            real.display()
        ));
    }
    Ok(real)
}

fn name_of(app: &Path) -> String {
    app.file_stem()
        .map(|s| s.to_string_lossy().into_owned())
        .unwrap_or_else(|| "the app".into())
}

fn folder_of(app: &Path) -> String {
    app.parent()
        .map(|p| p.display().to_string())
        .unwrap_or_else(|| "its folder".into())
}

/// Can we add and remove an entry in the folder that holds `app`? A throwaway file is the honest test: it follows
/// permissions, ACLs and read-only volumes the way the real install will. Run it BEFORE downloading anything.
pub fn check_folder_writable(app: &Path) -> Result<(), String> {
    let dir = app
        .parent()
        .ok_or_else(|| format!("{} has no folder", app.display()))?;
    let probe = dir.join(format!(".muya-write-check-{}", std::process::id()));
    match std::fs::File::create(&probe) {
        Ok(_) => {
            let _ = std::fs::remove_file(&probe);
            Ok(())
        }
        Err(e) => Err(explain_denied(app, &e.to_string(), Op::Folder)),
    }
}

/// What the failing step was doing; picks the wording.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Op {
    /// Probing / writing in the folder that holds the app.
    Folder,
    /// Moving the old app out of the way or putting a new one in.
    ChangeApp,
}

/// Turn a raw OS error into a message that names the cause and the fix, and says nothing was changed.
/// `raw` is the error text (`Permission denied` = EACCES, `Operation not permitted` = EPERM).
pub fn explain_denied(app: &Path, raw: &str, op: Op) -> String {
    let (name, folder) = (name_of(app), folder_of(app));
    let low = raw.to_lowercase();
    let eperm = low.contains("operation not permitted");
    let eacces = low.contains("permission denied");
    let rofs = low.contains("read-only file system");
    if rofs {
        return format!("{folder} is on a read-only disk, so {name} cannot be updated there. Copy the app to a folder on your Mac (for example Applications), open it from there, then try again. Nothing was changed.");
    }
    if eperm {
        // EPERM on a folder we can otherwise write to is macOS' "App Management" protection.
        return format!("macOS did not let Muya change {name} in {folder}. Open System Settings → Privacy & Security → App Management, turn on {name}, then try again. Nothing was changed.");
    }
    if eacces && op == Op::Folder {
        return format!("Your account cannot write to {folder}, so {name} cannot be updated there. Move the app to a folder you own (for example ~/Applications), open it from there, then try again — or ask an administrator to update it. Nothing was changed.");
    }
    if eacces {
        return format!("{name} in {folder} cannot be replaced: it belongs to another user or is locked. Move a fresh copy to a folder you own, open it from there, then try again. Nothing was changed.");
    }
    raw.to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::{symlink, PermissionsExt};

    fn fake_app(dir: &Path, name: &str) -> PathBuf {
        let app = dir.join(name);
        std::fs::create_dir_all(app.join("Contents/MacOS")).unwrap();
        std::fs::write(app.join("Contents/Info.plist"), "<plist/>").unwrap();
        std::fs::write(app.join("Contents/MacOS/x"), "").unwrap();
        app
    }
    fn canon(p: &Path) -> PathBuf {
        std::fs::canonicalize(p).unwrap()
    }

    #[test]
    fn desktop_app_with_a_custom_name_resolves_to_itself() {
        let d = tempfile::tempdir().unwrap();
        let desktop = d.path().join("Desktop");
        std::fs::create_dir(&desktop).unwrap();
        let app = fake_app(&desktop, "Muya Native Yeni.app");
        assert_eq!(resolve_bundle(&app).unwrap(), canon(&app));
        // The running executable resolves to the same bundle.
        assert_eq!(
            resolve_bundle(&app.join("Contents/MacOS/x")).unwrap(),
            canon(&app)
        );
    }

    #[test]
    fn applications_and_user_applications_folders_keep_their_place_and_name() {
        let d = tempfile::tempdir().unwrap();
        for (folder, name) in [
            ("Applications", "Muya Native.app"),
            ("home/Applications", "Muya.app"),
            ("Volumes/X/Apps", "Muya 2.app"),
        ] {
            let f = d.path().join(folder);
            std::fs::create_dir_all(&f).unwrap();
            let app = fake_app(&f, name);
            let got = resolve_bundle(&app).unwrap();
            assert_eq!(got, canon(&app));
            assert_eq!(got.file_name().unwrap(), name);
        }
    }

    #[test]
    fn a_symlinked_app_resolves_to_the_real_bundle() {
        let d = tempfile::tempdir().unwrap();
        let real_dir = d.path().join("Real");
        let link_dir = d.path().join("Links");
        std::fs::create_dir_all(&real_dir).unwrap();
        std::fs::create_dir_all(&link_dir).unwrap();
        let app = fake_app(&real_dir, "Muya Native.app");
        symlink(&app, link_dir.join("Shortcut.app")).unwrap();
        assert_eq!(
            resolve_bundle(&link_dir.join("Shortcut.app")).unwrap(),
            canon(&app)
        );
    }

    #[test]
    fn a_translocated_path_is_refused_with_the_move_it_message() {
        let e = resolve_bundle(Path::new(
            "/private/var/folders/ab/T/AppTranslocation/1234-ABCD/d/Muya.app",
        ))
        .unwrap_err();
        assert!(e.contains("Drag the app to Applications"), "{e}");
        assert!(is_translocated(Path::new(
            "/private/var/folders/x/AppTranslocation/y/d/Muya.app/Contents/MacOS/muya"
        )));
        assert!(!is_translocated(Path::new("/Users/u/Desktop/Muya.app")));
    }

    #[test]
    fn something_that_is_not_a_real_bundle_is_refused() {
        let d = tempfile::tempdir().unwrap();
        assert!(resolve_bundle(&d.path().join("Gone.app"))
            .unwrap_err()
            .contains("could not find"));
        let empty = d.path().join("Empty.app");
        std::fs::create_dir(&empty).unwrap();
        assert!(resolve_bundle(&empty).unwrap_err().contains("Info.plist"));
        assert!(resolve_bundle(d.path())
            .unwrap_err()
            .contains("not inside an app bundle"));
    }

    #[test]
    fn writable_folder_passes_and_leaves_no_probe_behind() {
        let d = tempfile::tempdir().unwrap();
        let app = fake_app(d.path(), "Muya.app");
        check_folder_writable(&app).unwrap();
        let leftovers: Vec<_> = std::fs::read_dir(d.path())
            .unwrap()
            .map(|e| e.unwrap().file_name())
            .collect();
        assert_eq!(leftovers, ["Muya.app"]);
    }

    #[test]
    fn read_only_folder_is_refused_before_anything_happens_with_a_clear_message() {
        if unsafe { libc_geteuid() } == 0 {
            return; // root ignores directory permissions
        }
        let d = tempfile::tempdir().unwrap();
        let app = fake_app(d.path(), "Muya Native.app");
        std::fs::set_permissions(d.path(), std::fs::Permissions::from_mode(0o555)).unwrap();
        let r = check_folder_writable(&app);
        std::fs::set_permissions(d.path(), std::fs::Permissions::from_mode(0o755)).unwrap();
        let e = r.unwrap_err();
        assert!(
            e.contains("cannot write to") && e.contains("Nothing was changed"),
            "{e}"
        );
        assert!(
            app.join("Contents/Info.plist").is_file(),
            "the app is untouched"
        );
    }

    extern "C" {
        #[link_name = "geteuid"]
        fn libc_geteuid() -> u32;
    }

    #[test]
    fn explanations_name_the_cause_and_the_setting_to_open() {
        let app = Path::new("/Users/u/Desktop/Muya Native Yeni.app");
        let eperm = explain_denied(
            app,
            "ditto failed: ditto: /x: Operation not permitted",
            Op::ChangeApp,
        );
        assert!(
            eperm.contains("App Management")
                && eperm.contains("Muya Native Yeni")
                && eperm.contains("/Users/u/Desktop"),
            "{eperm}"
        );
        let eacces = explain_denied(app, "Permission denied (os error 13)", Op::Folder);
        assert!(
            eacces.contains("cannot write to /Users/u/Desktop"),
            "{eacces}"
        );
        let owned = explain_denied(app, "ditto: Permission denied", Op::ChangeApp);
        assert!(owned.contains("belongs to another user"), "{owned}");
        let ro = explain_denied(app, "Read-only file system (os error 30)", Op::Folder);
        assert!(ro.contains("read-only disk"), "{ro}");
        assert_eq!(
            explain_denied(app, "something else", Op::ChangeApp),
            "something else"
        );
    }
}
