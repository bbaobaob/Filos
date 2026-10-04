//! Remote file browsing over the Airlift tunnel.
//!
//! The exploit path (`exploit.rs`) can only stage and verify a canary write, so
//! the file browser had nothing to enumerate. These helpers reuse the very same
//! `connect_tunnel` + `AfcClient` machinery to list a directory, read a file,
//! write a file and delete a file on the paired device.
//!
//! Safety model — every call is deliberately narrow:
//!   * Only the exact path handed in by the caller is touched. Nothing else on
//!     the device is enumerated, written or deleted.
//!   * `..` components, relative paths and empty paths are rejected. The `..`
//!     in [`path_candidates`] output is generated internally from the fixed
//!     `/var/mobile` mapping, never taken from the caller.
//!   * Files that the AirTraffic escape itself owns are refused outright — the
//!     staging set (`Books.plist`, `Books/Sync`, `Airlock/…`) and any
//!     `airlift-*-` artefact. Clobbering those breaks the escape (or bricks the
//!     Books app), so browsing refuses them for reads *and* writes.
//!   * Reads/writes are size-capped so a huge file cannot exhaust memory while
//!     being base64'd into a JSON string.
//!
//! Tunnel opens are serialised behind `TUNNEL_LOCK`: each call opens its own
//! loopback tunnel, and letting several of them race makes the remote side drop
//! connections unpredictably.

use std::ffi::{c_char, c_void};
use std::sync::{Mutex, MutexGuard};

use idevice::afc::opcode::AfcFopenMode;
use idevice::afc::AfcClient;

use crate::exploit::{connect_tunnel, AppDeviceTunnel, Logger, ALLogCallback};
use crate::ffi_util::{cstr, opt_str, run_with_large_stack};

/// Largest file `al_file_read` will pull over the wire (16 MiB).
const MAX_READ_BYTES: usize = 16 * 1024 * 1024;
/// Largest payload `al_file_write` will accept (16 MiB of raw bytes).
const MAX_WRITE_BYTES: usize = 16 * 1024 * 1024;

/// One remote tunnel open at a time.
static TUNNEL_LOCK: Mutex<()> = Mutex::new(());

fn lock_tunnel(name: &str) -> MutexGuard<'static, ()> {
    match TUNNEL_LOCK.lock() {
        Ok(guard) => guard,
        // A previous holder panicked; the tunnel it opened is long gone, so the
        // data is no longer meaningful — but blocking every later call forever
        // is worse than carrying on.
        Err(poisoned) => {
            tracing::warn!("{name}: tunnel lock was poisoned by an earlier panic, continuing");
            poisoned.into_inner()
        }
    }
}

/// Refuse anything that could disturb the AirTraffic escape.
fn is_protected(path: &str) -> bool {
    if path.contains("Books/Sync") {
        return true;
    }
    path.split('/').any(|component| {
        component == "Books.plist"
            || component == "Airlock"
            || component.starts_with("airlift-src-")
            || component.starts_with("airlift-link-")
            || component.starts_with("airlift-recovered-")
            || component.starts_with("airlift-canary-")
    })
}

/// Validate a caller-supplied path and return its canonical spelling.
///
/// Rejects empty/relative paths, `..` traversal and the protected staging set.
fn checked_path(path: &str) -> Result<String, String> {
    let trimmed = path.trim();
    if trimmed.is_empty() {
        return Err("path must not be empty".to_owned());
    }
    if !trimmed.starts_with('/') {
        return Err(format!("path must be absolute, got '{trimmed}'"));
    }
    if trimmed.split('/').any(|component| component == "..") {
        return Err(format!("path must not contain '..', got '{trimmed}'"));
    }
    if is_protected(trimmed) {
        return Err(format!("'{trimmed}' is reserved by Airlift and cannot be browsed"));
    }
    Ok(trimmed.to_owned())
}

/// Directory AFC is actually rooted at for this tunnel.
///
/// `connect_afc` negotiates `com.apple.afc`, whose root is `/var/mobile/Media`
/// — that is where the exploit stages `Books/`, `Airlock/` and the
/// `airlift-*` artefacts. Every path handed to [`AfcClient`] is therefore
/// relative to this directory, never an absolute device path.
const AFC_ROOT: &str = "/var/mobile/Media";

/// Spellings to try on the device for one logical path.
///
/// AFC roots differ between services, so the absolute path is tried first and
/// the obvious relatives are used as fallbacks. Duplicates are dropped and the
/// original order is preserved.
///
/// Ordering is deliberate and load-bearing for debugging: absolute spellings
/// first (what a differently-rooted service understands), then the mapping onto
/// [`AFC_ROOT`], then plain relatives. Every candidate is logged by the caller,
/// so the device log shows exactly which spelling AFC accepted.
fn path_candidates(path: &str) -> Vec<String> {
    let mut candidates: Vec<String> = Vec::new();
    let mut push = |value: String| {
        if !candidates.contains(&value) {
            candidates.push(value);
        }
    };

    // 1. Absolute spellings. Tried first so services that do understand a
    //    full device path keep working, and so a mismatch is visible in the log.
    push(path.to_owned());
    // Directories often need an explicit trailing slash.
    if !path.ends_with('/') {
        push(format!("{path}/"));
    }
    if let Some(rest) = path.strip_prefix("/private/var/") {
        push(format!("/var/{rest}"));
    }

    // 2. The same path expressed relative to AFC_ROOT. A bare
    //    `Afc(ObjectNotFound)` for every absolute spelling is the symptom of
    //    handing AFC a device path it cannot resolve, so translate:
    //      /var/mobile/Media/X -> X     (already below the root)
    //      /var/mobile/X        -> ../X  (exactly one level above the root)
    // The `..` is a fixed, bounded mapping derived from the prefixes below —
    // never from caller input, which `checked_path` already rejects.
    // `/private` is peeled first (without its trailing slash, so the result
    // keeps the leading `/` the prefix checks below expect) and the `/private/var`
    // spelling of step 1 maps identically.
    let normalized = path.strip_prefix("/private").unwrap_or(path);
    if let Some(mapped) = afc_relative_path(normalized) {
        push(mapped.clone());
        if !mapped.ends_with('/') {
            push(format!("{mapped}/"));
        }
    }

    // 3. Plain relative fallbacks, for an AFC whose root is the parent dir.
    if let Some(rest) = normalized.strip_prefix("/var/mobile/") {
        push(rest.to_owned());
        push(format!("/{rest}"));
    }
    candidates
}

/// Translate a device path into the spelling AFC (rooted at [`AFC_ROOT`])
/// expects, or `None` when it does not live under `/var/mobile`.
fn afc_relative_path(path: &str) -> Option<String> {
    let normalized = path.trim_end_matches('/');
    if let Some(rest) = normalized.strip_prefix("/var/mobile/Media/") {
        return Some(rest.to_owned());
    }
    // `AFC_ROOT` is `/var/mobile/Media`, so one `..` reaches `/var/mobile`.
    normalized
        .strip_prefix("/var/mobile/")
        .map(|rest| format!("../{rest}"))
}

fn join(base: &str, name: &str) -> String {
    if base.ends_with('/') {
        format!("{base}{name}")
    } else {
        format!("{base}/{name}")
    }
}

// ---------------------------------------------------------------------------
// base64 (kept local so rust-core needs no extra dependency)
// ---------------------------------------------------------------------------

const B64_ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

pub(crate) fn base64_encode(input: &[u8]) -> String {
    let mut out = String::with_capacity(input.len().div_ceil(3) * 4);
    for chunk in input.chunks(3) {
        let b0 = chunk[0] as u32;
        let b1 = *chunk.get(1).unwrap_or(&0) as u32;
        let b2 = *chunk.get(2).unwrap_or(&0) as u32;
        let triple = (b0 << 16) | (b1 << 8) | b2;

        out.push(B64_ALPHABET[((triple >> 18) & 0x3f) as usize] as char);
        out.push(B64_ALPHABET[((triple >> 12) & 0x3f) as usize] as char);
        if chunk.len() > 1 {
            out.push(B64_ALPHABET[((triple >> 6) & 0x3f) as usize] as char);
        } else {
            out.push('=');
        }
        if chunk.len() > 2 {
            out.push(B64_ALPHABET[(triple & 0x3f) as usize] as char);
        } else {
            out.push('=');
        }
    }
    out
}

pub(crate) fn base64_decode(input: &str) -> Result<Vec<u8>, String> {
    fn value(byte: u8) -> Option<u32> {
        match byte {
            b'A'..=b'Z' => Some((byte - b'A') as u32),
            b'a'..=b'z' => Some((byte - b'a') as u32 + 26),
            b'0'..=b'9' => Some((byte - b'0') as u32 + 52),
            b'+' => Some(62),
            b'/' => Some(63),
            _ => None,
        }
    }

    let mut out: Vec<u8> = Vec::with_capacity(input.len() / 4 * 3);
    let mut buffer: u32 = 0;
    let mut bits: u32 = 0;
    let mut padding = 0usize;

    for byte in input.bytes() {
        match byte {
            b'=' => {
                padding += 1;
                continue;
            }
            b'\n' | b'\r' | b' ' | b'\t' => continue,
            _ => {}
        }
        if padding > 0 {
            return Err("base64 payload has data after padding".to_owned());
        }
        let Some(v) = value(byte) else {
            return Err(format!("invalid base64 character '{}'", byte as char));
        };
        buffer = (buffer << 6) | v;
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push(((buffer >> bits) & 0xff) as u8);
        }
    }

    if out.len() > MAX_WRITE_BYTES {
        return Err(format!("payload is {} bytes, over the {MAX_WRITE_BYTES} byte limit", out.len()));
    }
    Ok(out)
}

// ---------------------------------------------------------------------------
// Async workers
// ---------------------------------------------------------------------------

async fn open_afc(pairing_path: &str, logger: &Logger) -> Result<AfcClient, String> {
    let pairing_bytes = std::fs::read(pairing_path)
        .map_err(|e| format!("Failed to read pairing file at {pairing_path}: {e}"))?;
    let mut tunnel = connect_tunnel(&pairing_bytes, logger).await?;
    tunnel.connect_afc(logger).await
}

/// Container-rooted AFC: `list_dir_json` and friends are reused verbatim, they
/// just talk to an `AfcClient` whose root is an app's Data container instead of
/// `/var/mobile/Media`. House arrest paths are container-relative (`/`,
/// `/Documents`, `/Library/Preferences`), so no candidate mapping is applied —
/// the caller's path is used as given.
type HouseAfc = AfcClient;

/// Open the AFC connection house_arrest vends for `bundle_id`.
///
/// The returned `AfcClient` is rooted *at* the app's Data container, so every
/// path handed to it afterwards is container-relative (`/`, `/Documents`, …).
async fn open_house_afc(pairing_path: &str, bundle_id: &str, logger: &Logger) -> Result<HouseAfc, String> {
    if bundle_id.trim().is_empty() {
        return Err("bundle_id must not be empty".to_owned());
    }
    let pairing_bytes = std::fs::read(pairing_path)
        .map_err(|e| format!("Failed to read pairing file at {pairing_path}: {e}"))?;
    let mut tunnel = connect_tunnel(&pairing_bytes, logger).await?;
    tunnel.house_arrest_container(bundle_id.trim(), logger).await
}

/// Validate a container-relative path handed to the house_arrest helpers.
///
/// House arrest AFC is rooted *inside* one app container, so `..` can never be
/// useful: it is either a no-op or an escape attempt. Refuse it, and require an
/// absolute (container-relative) path so `""` never silently means the root.
fn checked_container_path(path: &str) -> Result<String, String> {
    let trimmed = path.trim();
    if trimmed.is_empty() {
        return Err("container path must not be empty (use \"/\" for the container root)".to_owned());
    }
    if !trimmed.starts_with('/') {
        return Err(format!(
            "container path must be absolute inside the app container, got '{trimmed}'"
        ));
    }
    if trimmed.split('/').any(|component| component == "..") {
        return Err(format!("container path must not contain '..', got '{trimmed}'"));
    }
    Ok(trimmed.to_owned())
}

/// `/private/var/…` and `/var/…` name the same place on device; the Swift side
/// compares the `/var` spelling, so normalise the device's answer to match.
fn normalize_container_path(path: &str) -> String {
    match path.strip_prefix("/private/var/") {
        Some(rest) => format!("/var/{rest}"),
        None => path.to_owned(),
    }
}

async fn list_dir_json(afc: &mut AfcClient, path: &str) -> Result<String, String> {
    let names = afc
        .list_dir(path.to_owned())
        .await
        .map_err(|e| format!("ReadDir failed: {e:?}"))?;

    let mut entries: Vec<serde_json::Value> = Vec::with_capacity(names.len());
    for name in names {
        if name.is_empty() || name == "." || name == ".." {
            continue;
        }
        let child = join(path, &name);
        let (is_dir, size) = match afc.get_file_info(child.clone()).await {
            Ok(info) => (info.st_ifmt.contains("DIR"), info.size),
            // Some AFC services refuse GetFileInfo on entries they still list.
            // Fall back to a name heuristic so the row still shows up.
            Err(e) => {
                tracing::debug!("browse: GetFileInfo({child}) failed: {e:?}");
                (name.ends_with(".app"), 0usize)
            }
        };
        entries.push(serde_json::json!({
            "name": name,
            "is_dir": is_dir,
            "size": size,
        }));
    }

    Ok(serde_json::Value::Array(entries).to_string())
}

async fn read_file_bytes(afc: &mut AfcClient, path: &str) -> Result<Vec<u8>, String> {
    if let Ok(info) = afc.get_file_info(path.to_owned()).await {
        if info.size > MAX_READ_BYTES {
            return Err(format!(
                "{path} is {} bytes, over the {MAX_READ_BYTES} byte read limit",
                info.size
            ));
        }
    }
    let mut fd = afc
        .open(path.to_owned(), AfcFopenMode::RdOnly)
        .await
        .map_err(|e| format!("FileOpen failed: {e:?}"))?;
    let result = fd.read_entire().await;
    let _ = fd.close().await;
    let data = result.map_err(|e| format!("Read failed: {e:?}"))?;
    if data.len() > MAX_READ_BYTES {
        return Err(format!(
            "{path} read {} bytes, over the {MAX_READ_BYTES} byte limit",
            data.len()
        ));
    }
    Ok(data)
}

async fn write_file_bytes(afc: &mut AfcClient, path: &str, data: &[u8]) -> Result<(), String> {
    let mut fd = afc
        .open(path.to_owned(), AfcFopenMode::WrOnly)
        .await
        .map_err(|e| format!("FileOpen for write failed: {e:?}"))?;
    let write = fd.write_entire(data).await;
    let close = fd.close().await;
    write.map_err(|e| format!("Write failed: {e:?}"))?;
    close.map_err(|e| format!("Close failed: {e:?}"))?;
    Ok(())
}

async fn delete_path(afc: &mut AfcClient, path: &str) -> Result<(), String> {
    match afc.remove(path.to_owned()).await {
        Ok(()) => Ok(()),
        Err(first) => {
            // Directories need the recursive variant.
            afc.remove_all(path.to_owned())
                .await
                .map_err(|second| format!("Remove failed ({first:?}) and RemoveAll failed ({second:?})"))
        }
    }
}

// ---------------------------------------------------------------------------
// FFI entry points
// ---------------------------------------------------------------------------

/// # Safety
/// All pointer args must be null or valid for their documented use.
pub unsafe fn dir_list(
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

    let res = run_with_large_stack("al_dir_list", move || {
        let logger = Logger::new(log_cb, ctx_usize as *mut c_void);
        let path = checked_path(&requested)?;
        let _guard = lock_tunnel("al_dir_list");
        idevice_ffi::run_sync_local(async move {
            let mut afc = open_afc(&pairing_path, &logger).await?;
            let candidates = path_candidates(&path);
            logger.log(format!(
                "airlift: al_dir_list('{path}'), AFC root {AFC_ROOT}, {} candidate(s): {candidates:?}",
                candidates.len()
            ));
            let mut last_error = String::new();
            for candidate in &candidates {
                logger.log(format!("airlift: listing '{candidate}'"));
                match list_dir_json(&mut afc, candidate).await {
                    Ok(json) => {
                        logger.log(format!("airlift: listing '{candidate}' ok"));
                        return Ok(json);
                    }
                    Err(e) => {
                        logger.log(format!("airlift: listing '{candidate}' failed: {e}"));
                        last_error = e;
                    }
                }
            }
            Err(format!(
                "Failed to list '{path}' (AFC root {AFC_ROOT}, tried {candidates:?}): {last_error}"
            ))
        })
    });

    finish_string_result(res, "al_dir_list", out_json, out_error)
}

/// # Safety
/// All pointer args must be null or valid for their documented use.
pub unsafe fn file_read(
    pairing_path: *const c_char,
    path: *const c_char,
    out_b64: *mut *mut c_char,
    out_error: *mut *mut c_char,
) -> i32 {
    if out_b64.is_null() && out_error.is_null() {
        return 2;
    }

    let pairing_path = opt_str(pairing_path, "airlift_pairing.plist");
    let requested = opt_str(path, "");

    let res = run_with_large_stack("al_file_read", move || {
        let logger = Logger::new(None, std::ptr::null_mut());
        let path = checked_path(&requested)?;
        let _guard = lock_tunnel("al_file_read");
        idevice_ffi::run_sync_local(async move {
            let mut afc = open_afc(&pairing_path, &logger).await?;
            let mut last_error = String::new();
            for candidate in path_candidates(&path) {
                match read_file_bytes(&mut afc, &candidate).await {
                    Ok(data) => return Ok(base64_encode(&data)),
                    Err(e) => {
                        logger.log(format!("airlift: reading '{candidate}' failed: {e}"));
                        last_error = e;
                    }
                }
            }
            Err(format!("Failed to read '{path}': {last_error}"))
        })
    });

    finish_string_result(res, "al_file_read", out_b64, out_error)
}

/// # Safety
/// All pointer args must be null or valid for their documented use.
pub unsafe fn file_write(
    pairing_path: *const c_char,
    path: *const c_char,
    b64_content: *const c_char,
    out_error: *mut *mut c_char,
) -> i32 {
    let pairing_path = opt_str(pairing_path, "airlift_pairing.plist");
    let requested = opt_str(path, "");
    let encoded = opt_str(b64_content, "");

    let res = run_with_large_stack("al_file_write", move || {
        let logger = Logger::new(None, std::ptr::null_mut());
        let path = checked_path(&requested)?;
        // An empty payload is valid (creates/truncates an empty file).
        let data = base64_decode(&encoded)?;
        let _guard = lock_tunnel("al_file_write");
        idevice_ffi::run_sync_local(async move {
            let mut afc = open_afc(&pairing_path, &logger).await?;
            let mut last_error = String::new();
            for candidate in path_candidates(&path) {
                match write_file_bytes(&mut afc, &candidate, &data).await {
                    Ok(()) => {
                        logger.log(format!("airlift: wrote {} bytes to '{candidate}'", data.len()));
                        return Ok(());
                    }
                    Err(e) => {
                        logger.log(format!("airlift: writing '{candidate}' failed: {e}"));
                        last_error = e;
                    }
                }
            }
            Err(format!("Failed to write '{path}': {last_error}"))
        })
    });

    finish_void_result(res, "al_file_write", out_error)
}

/// # Safety
/// All pointer args must be null or valid for their documented use.
pub unsafe fn file_delete(
    pairing_path: *const c_char,
    path: *const c_char,
    out_error: *mut *mut c_char,
) -> i32 {
    let pairing_path = opt_str(pairing_path, "airlift_pairing.plist");
    let requested = opt_str(path, "");

    let res = run_with_large_stack("al_file_delete", move || {
        let logger = Logger::new(None, std::ptr::null_mut());
        let path = checked_path(&requested)?;
        let _guard = lock_tunnel("al_file_delete");
        idevice_ffi::run_sync_local(async move {
            let mut afc = open_afc(&pairing_path, &logger).await?;
            let mut last_error = String::new();
            for candidate in path_candidates(&path) {
                match delete_path(&mut afc, &candidate).await {
                    Ok(()) => {
                        logger.log(format!("airlift: deleted '{candidate}'"));
                        return Ok(());
                    }
                    Err(e) => {
                        logger.log(format!("airlift: deleting '{candidate}' failed: {e}"));
                        last_error = e;
                    }
                }
            }
            Err(format!("Failed to delete '{path}': {last_error}"))
        })
    });

    finish_void_result(res, "al_file_delete", out_error)
}

// ---------------------------------------------------------------------------
// Installed app listing (InstallationProxy over the same tunnel)
// ---------------------------------------------------------------------------

/// Turn an InstallationProxy lookup into
/// `[{"bundle_id":…,"name":…,"path":…,"group_containers":{…}}, …]`.
async fn list_apps_json(tunnel: &mut AppDeviceTunnel, logger: &Logger) -> Result<String, String> {
    let mut client = tunnel.connect_installation_proxy(logger).await?;
    let apps = client
        .get_apps(Some("Any"), None)
        .await
        .map_err(|e| format!("InstallationProxy get_apps failed: {e:?}"))?;

    // `get_apps` returns a HashMap, so sort by bundle id to keep the JSON (and
    // therefore the UI order) stable across calls.
    let mut bundle_ids: Vec<&String> = apps.keys().collect();
    bundle_ids.sort();

    let mut entries: Vec<serde_json::Value> = Vec::with_capacity(bundle_ids.len());
    for bundle_id in bundle_ids {
        let Some(value) = apps.get(bundle_id) else { continue };
        let Some(dict) = value.as_dictionary() else { continue };

        let path = dict
            .get("Container")
            .and_then(|v| v.as_string())
            .map(normalize_container_path)
            .unwrap_or_default();

        // InstallationProxy spells the display name a few different ways
        // depending on how the app was installed.
        let name = ["CFBundleDisplayName", "CFBundleName", "CFBundleExecutable"]
            .iter()
            .find_map(|key| dict.get(*key).and_then(|v| v.as_string()))
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| bundle_id.as_str());

        let mut group_containers = serde_json::Map::new();
        if let Some(plist::Value::Dictionary(groups)) = dict.get("GroupContainers") {
            for (group_id, group_path) in groups {
                if let Some(group_path) = group_path.as_string() {
                    group_containers
                        .insert(group_id.clone(), serde_json::Value::String(normalize_container_path(group_path)));
                }
            }
        }

        entries.push(serde_json::json!({
            "bundle_id": bundle_id,
            "name": name,
            "path": path,
            "group_containers": serde_json::Value::Object(group_containers),
        }));
    }

    logger.log(format!("airlift: InstallationProxy listed {} app(s)", entries.len()));
    Ok(serde_json::Value::Array(entries).to_string())
}

/// # Safety
/// All pointer args must be null or valid for their documented use.
pub unsafe fn list_apps(
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

    let res = run_with_large_stack("al_list_apps", move || {
        let logger = Logger::new(log_cb, ctx_usize as *mut c_void);
        let _guard = lock_tunnel("al_list_apps");
        idevice_ffi::run_sync_local(async move {
            let pairing_bytes = std::fs::read(&pairing_path)
                .map_err(|e| format!("Failed to read pairing file at {pairing_path}: {e}"))?;
            let mut tunnel = connect_tunnel(&pairing_bytes, &logger).await?;
            list_apps_json(&mut tunnel, &logger).await
        })
    });

    finish_string_result(res, "al_list_apps", out_json, out_error)
}

// ---------------------------------------------------------------------------
// House arrest: browse inside one app's Data container
// ---------------------------------------------------------------------------

/// # Safety
/// All pointer args must be null or valid for their documented use.
pub unsafe fn house_list(
    pairing_path: *const c_char,
    bundle_id: *const c_char,
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
    let bundle_id = opt_str(bundle_id, "");
    let requested = opt_str(path, "/");
    let ctx_usize = ctx as usize;

    let res = run_with_large_stack("al_house_list", move || {
        let logger = Logger::new(log_cb, ctx_usize as *mut c_void);
        let path = checked_container_path(&requested)?;
        let _guard = lock_tunnel("al_house_list");
        idevice_ffi::run_sync_local(async move {
            let mut afc = open_house_afc(&pairing_path, &bundle_id, &logger).await?;
            logger.log(format!(
                "airlift: house_arrest vended '{bundle_id}', listing container-relative '{path}'"
            ));
            list_dir_json(&mut afc, &path).await
        })
    });

    finish_string_result(res, "al_house_list", out_json, out_error)
}

/// # Safety
/// All pointer args must be null or valid for their documented use.
pub unsafe fn house_files(
    pairing_path: *const c_char,
    bundle_id: *const c_char,
    path: *const c_char,
    out_b64: *mut *mut c_char,
    out_error: *mut *mut c_char,
) -> i32 {
    let pairing_path = opt_str(pairing_path, "airlift_pairing.plist");
    let bundle_id = opt_str(bundle_id, "");
    let requested = opt_str(path, "");

    let res = run_with_large_stack("al_house_files", move || {
        let logger = Logger::new(None, std::ptr::null_mut());
        let path = checked_container_path(&requested)?;
        let _guard = lock_tunnel("al_house_files");
        idevice_ffi::run_sync_local(async move {
            let mut afc = open_house_afc(&pairing_path, &bundle_id, &logger).await?;
            let data = read_file_bytes(&mut afc, &path).await?;
            Ok(base64_encode(&data))
        })
    });

    finish_string_result(res, "al_house_files", out_b64, out_error)
}

/// # Safety
/// All pointer args must be null or valid for their documented use.
pub unsafe fn house_write(
    pairing_path: *const c_char,
    bundle_id: *const c_char,
    path: *const c_char,
    b64_content: *const c_char,
    out_error: *mut *mut c_char,
) -> i32 {
    let pairing_path = opt_str(pairing_path, "airlift_pairing.plist");
    let bundle_id = opt_str(bundle_id, "");
    let requested = opt_str(path, "");
    let encoded = opt_str(b64_content, "");

    let res = run_with_large_stack("al_house_write", move || {
        let logger = Logger::new(None, std::ptr::null_mut());
        let path = checked_container_path(&requested)?;
        // An empty payload is valid (creates/truncates an empty file).
        let data = base64_decode(&encoded)?;
        let _guard = lock_tunnel("al_house_write");
        idevice_ffi::run_sync_local(async move {
            let mut afc = open_house_afc(&pairing_path, &bundle_id, &logger).await?;
            write_file_bytes(&mut afc, &path, &data).await?;
            logger.log(format!(
                "airlift: wrote {} bytes to '{bundle_id}:{path}'",
                data.len()
            ));
            Ok(())
        })
    });

    finish_void_result(res, "al_house_write", out_error)
}

/// # Safety
/// All pointer args must be null or valid for their documented use.
pub unsafe fn house_delete(
    pairing_path: *const c_char,
    bundle_id: *const c_char,
    path: *const c_char,
    out_error: *mut *mut c_char,
) -> i32 {
    let pairing_path = opt_str(pairing_path, "airlift_pairing.plist");
    let bundle_id = opt_str(bundle_id, "");
    let requested = opt_str(path, "");

    let res = run_with_large_stack("al_house_delete", move || {
        let logger = Logger::new(None, std::ptr::null_mut());
        let path = checked_container_path(&requested)?;
        if path == "/" {
            return Err("refusing to delete the container root".to_owned());
        }
        let _guard = lock_tunnel("al_house_delete");
        idevice_ffi::run_sync_local(async move {
            let mut afc = open_house_afc(&pairing_path, &bundle_id, &logger).await?;
            delete_path(&mut afc, &path).await?;
            logger.log(format!("airlift: deleted '{bundle_id}:{path}'"));
            Ok(())
        })
    });

    finish_void_result(res, "al_house_delete", out_error)
}

// ---------------------------------------------------------------------------
// Result plumbing (mirrors exploit.rs: 0 on success, 1 on error)
// ---------------------------------------------------------------------------

fn finish_string_result(
    res: Result<Result<String, String>, String>,
    name: &str,
    out_value: *mut *mut c_char,
    out_error: *mut *mut c_char,
) -> i32 {
    match res {
        Ok(Ok(value)) => {
            if !out_value.is_null() {
                unsafe { *out_value = cstr(value) };
            }
            0
        }
        Ok(Err(e)) => {
            set_error(out_error, e);
            1
        }
        Err(panic_msg) => {
            set_error(out_error, format!("Worker thread '{name}' failed: {panic_msg}"));
            1
        }
    }
}

fn finish_void_result(res: Result<Result<(), String>, String>, name: &str, out_error: *mut *mut c_char) -> i32 {
    match res {
        Ok(Ok(())) => 0,
        Ok(Err(e)) => {
            set_error(out_error, e);
            1
        }
        Err(panic_msg) => {
            set_error(out_error, format!("Worker thread '{name}' failed: {panic_msg}"));
            1
        }
    }
}

fn set_error(out_error: *mut *mut c_char, message: String) {
    if !out_error.is_null() {
        unsafe { *out_error = cstr(message) };
    }
}

#[cfg(test)]
mod tests {
    use super::{
        afc_relative_path, base64_decode, base64_encode, checked_container_path, checked_path,
        normalize_container_path, path_candidates,
    };

    #[test]
    fn base64_round_trips() {
        for sample in [b"".as_slice(), b"f", b"fo", b"foo", b"foob", b"fooba", b"foobar"] {
            let encoded = base64_encode(sample);
            let decoded = base64_decode(&encoded).expect("decodes");
            assert_eq!(decoded, sample, "round trip failed for {sample:?}");
        }
        assert_eq!(base64_encode(b"foobar"), "Zm9vYmFy");
    }

    #[test]
    fn protected_paths_are_refused() {
        assert!(checked_path("/var/mobile/Media/Books/Sync/Books.plist").is_err());
        assert!(checked_path("/var/mobile/Media/Books/Sync").is_err());
        assert!(checked_path("/var/mobile/Media/Airlock/Book").is_err());
        assert!(checked_path("/var/mobile/airlift-src-123").is_err());
        assert!(checked_path("/var/mobile/../etc/passwd").is_err());
        assert!(checked_path("var/mobile").is_err());
        assert!(checked_path("").is_err());
        assert!(checked_path("/var/mobile/Library/Preferences").is_ok());
    }

    #[test]
    fn candidates_cover_absolute_and_relative_spellings() {
        let candidates = path_candidates("/var/mobile/Library/Preferences");
        assert!(candidates.contains(&"/var/mobile/Library/Preferences".to_owned()));
        assert!(candidates.contains(&"/var/mobile/Library/Preferences/".to_owned()));
        assert!(candidates.contains(&"Library/Preferences".to_owned()));

        let candidates = path_candidates("/private/var/tmp");
        assert!(candidates.contains(&"/var/tmp".to_owned()));
    }

    #[test]
    fn container_paths_must_stay_inside_the_container() {
        assert_eq!(checked_container_path("/").unwrap(), "/");
        assert_eq!(checked_container_path("/Documents").unwrap(), "/Documents");
        assert_eq!(
            checked_container_path("/Library/Preferences").unwrap(),
            "/Library/Preferences"
        );
        assert!(checked_container_path("").is_err());
        assert!(checked_container_path("Documents").is_err());
        assert!(checked_container_path("/../..").is_err());
        assert!(checked_container_path("/Documents/../Library").is_err());
    }

    #[test]
    fn device_container_paths_are_normalized() {
        assert_eq!(
            normalize_container_path("/private/var/mobile/Containers/Data/Application/ABC"),
            "/var/mobile/Containers/Data/Application/ABC"
        );
        assert_eq!(
            normalize_container_path("/var/mobile/Containers/Data/Application/ABC"),
            "/var/mobile/Containers/Data/Application/ABC"
        );
    }

    #[test]
    fn candidates_map_onto_the_afc_root() {
        // One level below the AFC root (/var/mobile/Media) -> plain relative.
        let candidates = path_candidates("/var/mobile/Media/DCIM");
        assert!(candidates.contains(&"DCIM".to_owned()));
        assert!(candidates.contains(&"DCIM/".to_owned()));

        // One level above the AFC root -> exactly one `..`.
        let candidates = path_candidates("/var/mobile/Library/SpringBoard");
        assert!(
            candidates.contains(&"../Library/SpringBoard".to_owned()),
            "missing AFC-root mapping in {candidates:?}"
        );
        assert!(candidates.contains(&"../Library/SpringBoard/".to_owned()));

        // /private spelling maps identically.
        let candidates = path_candidates("/private/var/mobile/Library/SpringBoard");
        assert!(
            candidates.contains(&"../Library/SpringBoard".to_owned()),
            "missing /private mapping in {candidates:?}"
        );

        // Absolute spellings stay first, mapping before plain relatives.
        let candidates = path_candidates("/var/mobile/Library/SpringBoard");
        let absolute = candidates
            .iter()
            .position(|c| c == "/var/mobile/Library/SpringBoard")
            .expect("absolute path is a candidate");
        let mapped = candidates
            .iter()
            .position(|c| c == "../Library/SpringBoard")
            .expect("mapped path is a candidate");
        let relative = candidates
            .iter()
            .position(|c| c == "Library/SpringBoard")
            .expect("relative path is a candidate");
        assert!(absolute < mapped, "absolute must be tried before the mapping");
        assert!(mapped < relative, "mapping must be tried before plain relatives");

        // Nothing outside /var/mobile is mapped — no unbounded traversal.
        assert!(afc_relative_path("/var/tmp").is_none());
        assert!(afc_relative_path("/private/etc").is_none());
    }
}
