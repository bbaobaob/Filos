// Airlift Rust core — C FFI surface.
//
// All fallible calls return an int32 code (0 == OK). Heap strings must be
// released with al_string_free().
#ifndef AIRLIFT_H
#define AIRLIFT_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ---------------------------------------------------------------------------
// Logging
// ---------------------------------------------------------------------------

// Receives every formatted log line. `msg` is only valid for the duration of
// the call — copy it. May be called from arbitrary Rust threads.
typedef void (*ALLogCallback)(void *ctx, const char *msg);

// Install the global tracing subscriber. Returns 0 on success, 1 if already
// initialised. Call once at launch.
int32_t al_log_init(ALLogCallback cb, void *ctx);

// Free any char* returned by this library.
void al_string_free(char *p);

// ---------------------------------------------------------------------------
// Pairing — RPPairing host
// ---------------------------------------------------------------------------

// Fires once the host is bound. The Swift side publishes `service_id` over
// Bonjour (NetService). All pointers are only valid during the call.
typedef void (*ALPairReadyCb)(void *ctx,
                               const char *service_id,
                               uint16_t port,
                               const char *const *txt_keys,
                               const char *const *txt_vals,
                               size_t txt_count);

// Fires with the PIN the user must confirm in Settings → Developer Mode.
typedef void (*ALPairPinCb)(const char *pin, void *ctx);

// Heap-allocated result of one pairing run. Free with al_pairing_result_free().
typedef struct {
    char *error;
    char *device_name;
    char *device_model;
    char *device_udid;
    char *pairing_file_path;
    char *host_alt_irk_hex;
} ALPairResult;

// Run the RPPairing host. BLOCKS until paired or errored — run off main thread.
// `port` 0 lets the OS pick a free port.
// `host_alt_irk_hex` is the value a previous run returned, or NULL/"" first time.
// Returns 0 on success, non-zero on error (with out->error set).
int32_t al_pairing_run_host(const char *bind_addr,
                             uint16_t port,
                             const char *name,
                             const char *model,
                             const char *out_path,
                             const char *host_alt_irk_hex,
                             ALPairReadyCb ready_cb,
                             ALPairPinCb pin_cb,
                             void *ctx,
                             ALPairResult *out);

// Free the heap strings inside an ALPairResult.
void al_pairing_result_free(ALPairResult *r);

// ---------------------------------------------------------------------------
// Exploit
// ---------------------------------------------------------------------------

// Run the AirTraffic sandbox escape. BLOCKS — run off the main thread.
// `pairing_path` — path produced by al_pairing_run_host.
// `target`       — absolute iOS directory (e.g. "/var/mobile/Library/SpringBoard").
// `log_cb`       — receives log lines (called from arbitrary threads; may be NULL).
// `out_json`     — set to a JSON result string; free with al_string_free().
// `out_error`    — set on failure; free with al_string_free().
// Returns 0 if the canary write was confirmed, 1 otherwise.
int32_t al_exploit_run(const char *pairing_path,
                        const char *target,
                        ALLogCallback log_cb,
                        void *ctx,
                        char **out_json,
                        char **out_error);

// Write all files from `source_dir` into `target_dir` on the device.
// Returns 0 on success, 1 on error (with out_error set).
int32_t al_exploit_write_dir(const char *pairing_path,
                             const char *source_dir,
                             const char *target_dir,
                             ALLogCallback log_cb,
                             void *ctx,
                             char **out_error);

// Inject an entire directory `folder_path` into `target_parent_dir/dest_name` on the device.
// Preserves complete folder hierarchy and all internal assets in one AirTraffic operation.
// Returns 0 on success, 1 on error (with out_error set).
int32_t al_exploit_inject_folder(const char *pairing_path,
                                 const char *folder_path,
                                 const char *target_parent_dir,
                                 const char *dest_name,
                                 ALLogCallback log_cb,
                                 void *ctx,
                                 char **out_error);

// ---------------------------------------------------------------------------
// Remote browsing (AFC over the pairing tunnel)
// ---------------------------------------------------------------------------

// List a remote directory. BLOCKS — run off the main thread.
// `path`          — absolute device path, e.g. "/var/mobile/Library/Preferences".
// `log_cb`        — receives log lines (may be NULL).
// `out_json`      — on success receives
//                   [{"name":"com.apple.mobilesafari","is_dir":true,"size":0}, …].
//                   Free with al_string_free().
// `out_error`     — set on failure; free with al_string_free().
// Returns 0 on success, 1 on error, 2 if both out pointers are NULL.
//
// Only the exact path given is read. AirTraffic staging files (Books.plist,
// Books/Sync, Airlock, airlift-*) are refused, as are relative paths and any
// path containing "..".
int32_t al_dir_list(const char *pairing_path,
                    const char *path,
                    ALLogCallback log_cb,
                    void *ctx,
                    char **out_json,
                    char **out_error);

// Read one remote file. BLOCKS — run off the main thread.
// `out_b64` receives the base64-encoded contents; free with al_string_free().
// Files larger than 16 MiB are refused instead of being pulled over AFC.
int32_t al_file_read(const char *pairing_path,
                     const char *path,
                     char **out_b64,
                     char **out_error);

// Write base64 `b64_content` to the remote `path` (created/truncated).
// BLOCKS — run off the main thread. Payloads over 16 MiB are refused.
int32_t al_file_write(const char *pairing_path,
                      const char *path,
                      const char *b64_content,
                      char **out_error);

// Delete the remote `path` (recursively when it is a directory).
// BLOCKS — run off the main thread.
int32_t al_file_delete(const char *pairing_path,
                       const char *path,
                       char **out_error);

// ---------------------------------------------------------------------------
// Installed apps + app-container browsing (InstallationProxy + house_arrest)
// ---------------------------------------------------------------------------

// List every installed app. BLOCKS — run off the main thread.
// `log_cb`        — receives log lines (may be NULL).
// `out_json`      — on success receives
//                   [{"bundle_id":"com.apple.mobilesafari",
//                     "name":"Safari",
//                     "path":"/var/mobile/Containers/Data/Application/<UUID>",
//                     "group_containers":{"group.com.example":"…"}}, …].
//                   Free with al_string_free().
// `out_error`     — set on failure; free with al_string_free().
// Returns 0 on success, 1 on error, 2 if both out pointers are NULL.
int32_t al_list_apps(const char *pairing_path,
                     ALLogCallback log_cb,
                     void *ctx,
                     char **out_json,
                     char **out_error);

// List a directory inside one app's Data container, reached through
// com.apple.mobile.house_arrest (VendContainer). BLOCKS — run off the main thread.
//
// `path` is CONTAINER-RELATIVE, not a device path: "/" is the container root,
// so "/Documents" and "/Library/Preferences" are the natural inputs. Paths
// containing ".." are refused — house arrest AFC is rooted inside the container
// and the caller must not try to leave it.
// `out_json` receives [{"name":…,"is_dir":…,"size":…}, …] like al_dir_list.
//
// Apps installed without a developer profile can answer PermDenied; that error
// is surfaced verbatim rather than hidden.
int32_t al_house_list(const char *pairing_path,
                      const char *bundle_id,
                      const char *path,
                      ALLogCallback log_cb,
                      void *ctx,
                      char **out_json,
                      char **out_error);

// Read one file from inside an app's Data container (container-relative path).
// BLOCKS — run off the main thread. Files over 16 MiB are refused.
int32_t al_house_files(const char *pairing_path,
                       const char *bundle_id,
                       const char *path,
                       char **out_b64,
                       char **out_error);

// Write base64 `b64_content` to a container-relative `path` (created/truncated).
// BLOCKS — run off the main thread. Payloads over 16 MiB are refused.
int32_t al_house_write(const char *pairing_path,
                       const char *bundle_id,
                       const char *path,
                       const char *b64_content,
                       char **out_error);

// Delete a container-relative `path` (recursively when it is a directory).
// BLOCKS — run off the main thread. "/" is refused.
int32_t al_house_delete(const char *pairing_path,
                        const char *bundle_id,
                        const char *path,
                        char **out_error);

// ---------------------------------------------------------------------------
// Airlift pull/restore listing (AirManager's ATC move trick, no HouseArrest)
// ---------------------------------------------------------------------------

// List a directory anywhere under an app container *without* HouseArrest.
//
// The Apple Books sync engine is used as a "move any object anywhere"
// primitive: Books.plist declares the target, one FileComplete pulls it to
// Airlock/Read/<T> where ordinary AFC can see it, then a second ATC session
// pushes it back through a symlink pointing at the real parent directory.
//
// `path` must be a real device path under
//   /var/mobile/Containers/Data/Application/
//   /var/mobile/Containers/Shared/AppGroup/
//   /var/mobile/Applications
// ".." is refused. out_json receives exactly what al_dir_list emits:
// [{"name":…,"is_dir":…,"size":…}, …]
//
// BLOCKS for several seconds (two ATC syncs) — run it off the main thread, for
// the directory the user explicitly opened. Never call it at launch or from a
// scroll handler.
//
// On a failure after the pull has succeeded, out_error contains
// "kept at Airlock/Read/<T>"; call al_airlift_recover to finish it.
int32_t al_airlift_list_dir(const char *pairing_path,
                            const char *path,
                            ALLogCallback log_cb,
                            void *ctx,
                            char **out_json,
                            char **out_error);

// Finish every pull still parked in Airlock/Read (an interrupted
// al_airlift_list_dir), staging a fresh restore symlink per recovery record.
// Best-effort per path; out_json receives
// [{"target":…,"token":…,"status":"restored"|"failed"|"missing"…, …}].
int32_t al_airlift_recover(const char *pairing_path,
                           ALLogCallback log_cb,
                           void *ctx,
                           char **out_json,
                           char **out_error);

// ---------------------------------------------------------------------------
// Syslog Stream / Live Card Detection
// ---------------------------------------------------------------------------

typedef void (*ALSyslogLineCallback)(void *ctx, const char *line);

// Stream device syslog messages over RSD.
// Blocks until al_syslog_stream_stop() is called.
int32_t al_syslog_stream_start(const char *pairing_path,
                               ALSyslogLineCallback line_cb,
                               void *ctx,
                               char **out_error);

// Stop any running syslog stream.
void al_syslog_stream_stop(void);

// Extract all files from a .passthm archive into dest_dir. Returns 0 on success.
int32_t al_passthm_extract(const char *archive_path, const char *dest_dir);

// Extract all files and directories from a zip archive into dest_dir. Returns 0 on success.
int32_t al_zip_extract_all(const char *archive_path, const char *dest_dir);

// Look up the Data Application Container directory for a bundle ID (e.g. "com.apple.PosterBoard").
// Blocks until resolved or errored. Returns 0 on success, with out_container set.
int32_t al_find_app_container(const char *pairing_path,
                             const char *bundle_id,
                             ALLogCallback log_cb,
                             void *ctx,
                             char **out_container,
                             char **out_error);

// Restart device / respring via Diagnostics Relay over the pairing tunnel.
// Blocks until sent. Returns 0 on success.
int32_t al_device_respring(const char *pairing_path,
                          ALLogCallback log_cb,
                          void *ctx,
                          char **out_error);


#ifdef __cplusplus
}
#endif

#endif /* AIRLIFT_H */
