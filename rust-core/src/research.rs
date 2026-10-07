//! Offline research helpers for measuring the AirTraffic move primitive's reach.
//!
//! No device required; unit-tested. The point of this module is to make the
//! *reach question* answerable in two steps: first, offline, "would we even ask
//! the daemon for this path, and with which ids?" ([`probe_path`],
//! [`probe_manifest_ids`]); second, on a device we own, "what does
//! `com.apple.atc` actually do when we ask?" — see
//! `airlift_dir::research_list_dir` / `al_research_list_dir` and RESEARCH.md.
//!
//! Everything here is a thin, honest wrapper over the real guards and the real
//! id arithmetic in [`crate::airlift_dir`]. It deliberately does **not** keep a
//! second copy of either, so an offline verdict can never drift from what the
//! device path would actually do.
//!
//! RESEARCH ONLY, on a device we own. Nothing in this module is reachable from
//! the UI.

use crate::airlift_dir::{
    asset_id_for_device_path, default_sync_root, link_target_for_parent, parent_and_basename,
    research_asset_id_for_device_path, research_checked_path, research_parent_and_basename,
};

// The dataclass sweep helpers are used by the tests in this module only, so they
// are imported there rather than re-exported: a caller on the device asks for a
// dataclass through the FFI argument, never by calling `atc_dataclass_wire`.
#[cfg(test)]
use crate::airlift_dir::{atc_dataclass_strings, atc_dataclass_wire, resolve_dataclass};

/// The verdict [`research_checked_path`] returns for one input path.
///
/// Exactly one of [`normalized`](PathProbe::normalized) and
/// [`rejected`](PathProbe::rejected) is `Some`: either the probe would accept
/// the path and send it, or it carries the guard's verbatim rejection reason.
/// The reason is the guard's own `Err` text, never a paraphrase, so an offline
/// verdict and a device run can be diffed line for line.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PathProbe {
    /// The input exactly as supplied, before normalisation.
    pub input: String,
    /// The canonical absolute path the probe would send, if it was accepted.
    pub normalized: Option<String>,
    /// Why the guard refused it, verbatim, if it was refused.
    pub rejected: Option<String>,
}

impl PathProbe {
    /// Whether the probe would attempt this path at all.
    pub fn accepted(&self) -> bool {
        self.normalized.is_some()
    }
}

/// Offline verdict for one candidate path — i.e. [`research_checked_path`].
pub fn probe_path(input: &str) -> PathProbe {
    match research_checked_path(input) {
        Ok(normalized) => PathProbe {
            input: input.to_owned(),
            normalized: Some(normalized),
            rejected: None,
        },
        Err(reason) => PathProbe {
            input: input.to_owned(),
            normalized: None,
            rejected: Some(reason),
        },
    }
}

/// The two ids a pull of `normalized` would put on the wire.
///
/// `(AssetID, LinkTarget)`, computed with the very helpers
/// `pull_list_and_restore` uses: `AssetID` is the STEP B manifest's
/// `Persistent ID` (relative to `/var/mobile/Media/Books/Sync`, so
/// `../../../<path relative to /var/mobile>`) and `LinkTarget` is the STEP A
/// symlink's target (three levels up from the Media root, tail repeating
/// `var/mobile`).
///
/// Both come back **empty** when the driver's own arithmetic cannot express the
/// path — which is any root outside `/var/mobile`, because `AssetID` is relative
/// to `/var/mobile` and the restore symlink is re-based to end up directly under
/// the Media root. Returning empty rather than a plausible-looking guess is the
/// point: it makes "the guard would accept this but the primitive cannot spell
/// it" a first-class, assertable row of the matrix instead of a runtime
/// surprise.
pub fn probe_manifest_ids(normalized: &str) -> (String, String) {
    let Ok((parent, _basename)) = parent_and_basename(normalized) else {
        return (String::new(), String::new());
    };
    let Ok(asset_id) = asset_id_for_device_path(normalized) else {
        return (String::new(), String::new());
    };
    (asset_id, link_target_for_parent(&parent))
}

/// The two ids `al_research_list_dir_any_path` would put on the wire.
///
/// The sibling of [`probe_manifest_ids`] with one change: the `AssetID` comes
/// from [`research_asset_id_for_device_path`], whose `..` chain climbs from
/// `Books/Sync` all the way to `/` instead of stopping at `/var/mobile`. That is
/// what lets a path outside `/var/mobile` — the MobileGestalt cache under
/// `/var/containers/Shared/SystemGroup/…`, `/Library/…`, `/var/root/…` — be
/// named on the wire at all; `probe_manifest_ids` returns empty for exactly
/// those paths.
///
/// `LinkTarget` is unchanged, and unchanged for the same reason as before: the
/// STEP A symlink is relocated to the Media root by STEP C and then resolves
/// three levels up, so [`link_target_for_parent`] already reaches any absolute
/// parent. For a path under `/var/mobile` the new `AssetID` resolves to the same
/// object as the old one (asserted in
/// `airlift_dir::tests::research_asset_ids_agree_with_the_shipping_ones_inside_var_mobile`),
/// so the verified rows mean the same thing through either driver.
///
/// Both ids come back empty only when the path has no usable parent at all.
pub fn probe_manifest_ids_any(normalized: &str) -> (String, String) {
    let Ok((parent, _basename)) = research_parent_and_basename(normalized) else {
        return (String::new(), String::new());
    };
    let Ok(asset_id) = research_asset_id_for_device_path(normalized, default_sync_root().depth)
    else {
        return (String::new(), String::new());
    };
    (asset_id, link_target_for_parent(&parent))
}

/// The experiment matrix: the paths worth asking about, with their offline
/// verdicts precomputed.
///
/// Ordered from "known to move" to "not a path the primitive can even ask for",
/// which is the order the on-device runs should follow. Every row is asserted
/// in this module's tests, so a change to the guard cannot quietly widen or
/// narrow the experiment without the tests moving with it.
pub fn probe_matrix() -> Vec<(&'static str, PathProbe)> {
    [
        // -- known-good baselines (verified on device, iOS 27) ----------------
        "/var/mobile/Containers/Data/Application",
        "/var/mobile/Containers/Shared/AppGroup/<uuid>",
        "/var/mobile/Containers/Data/Application/<uuid>",
        // -- candidates inside /var/mobile ----------------------------------
        "/var/mobile/Library/Preferences",
        "/var/mobile/Library",
        // -- candidates outside /var/mobile ---------------------------------
        // The prize: the MobileGestalt cache, and the reason the root-relative
        // `AssetID` exists. `probe_manifest_ids` is empty for it; only
        // `probe_manifest_ids_any` can spell it.
        "/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches/com.apple.MobileGestalt.plist",
        "/var/containers/Data/System",
        "/Library/MobileDevice/ProvisioningProfiles",
        "/Library/Preferences",
        "/var/root/Library",
        // -- normalisation ---------------------------------------------------
        "/private/var/mobile/Library/Foo",
        // -- refused: traversal ----------------------------------------------
        "/var/mobile/../var/mobile/Library",
        // -- refused: names this file reserves for itself --------------------
        "/Airlock",
        "/var/mobile/Airlock",
        "/Books.plist",
        // -- refused: not an absolute path -----------------------------------
        "",
        "relative/path",
    ]
    .into_iter()
    .map(|input| (input, probe_path(input)))
    .collect()
}

#[cfg(test)]
mod tests {
    use super::{
        atc_dataclass_strings, atc_dataclass_wire, probe_manifest_ids, probe_manifest_ids_any,
        probe_matrix, probe_path, resolve_dataclass, PathProbe,
    };

    /// The MobileGestalt cache: the highest-value target the primitive cannot
    /// currently express, and the reason the root-relative `AssetID` exists.
    const MOBILEGESTALT: &str = "/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches/com.apple.MobileGestalt.plist";

    const APP_ROOT: &str = "/var/mobile/Containers/Data/Application";
    const APP_UUID: &str = "/var/mobile/Containers/Data/Application/<uuid>";
    const APPGROUP_UUID: &str = "/var/mobile/Containers/Shared/AppGroup/<uuid>";

    /// The matrix, spelled out. Every entry is classified by
    /// [`the_matrix_is_the_documented_experiment_list`] below, and this list is
    /// the assertion that none of them is ever quietly dropped.
    const EXPECTED_MATRIX: &[&str] = &[
        "/var/mobile/Containers/Data/Application",
        "/var/mobile/Containers/Shared/AppGroup/<uuid>",
        "/var/mobile/Containers/Data/Application/<uuid>",
        "/var/mobile/Library/Preferences",
        "/var/mobile/Library",
        "/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches/com.apple.MobileGestalt.plist",
        "/var/containers/Data/System",
        "/Library/MobileDevice/ProvisioningProfiles",
        "/Library/Preferences",
        "/var/root/Library",
        "/private/var/mobile/Library/Foo",
        "/var/mobile/../var/mobile/Library",
        "/Airlock",
        "/var/mobile/Airlock",
        "/Books.plist",
        "",
        "relative/path",
    ];

    fn accepted(input: &str, normalized: &str) -> PathProbe {
        let probe = probe_path(input);
        assert_eq!(
            probe.normalized.as_deref(),
            Some(normalized),
            "{input}: expected the probe to accept it as {normalized}, got {probe:?}"
        );
        assert!(probe.rejected.is_none(), "{input}: {probe:?}");
        probe
    }

    fn refused(input: &str, reason_contains: &str) -> PathProbe {
        let probe = probe_path(input);
        assert!(
            probe.normalized.is_none(),
            "{input}: expected a refusal, got {probe:?}"
        );
        let reason = probe
            .rejected
            .as_deref()
            .unwrap_or_else(|| panic!("{input}: a refusal must carry a reason"));
        assert!(
            reason.contains(reason_contains),
            "{input}: reason '{reason}' does not mention '{reason_contains}'"
        );
        probe
    }

    /// The guard accepts the paths the primitive is already known to move, so
    /// the probe is a superset of the shipping behaviour and never a regression
    /// of it.
    #[test]
    fn the_probe_accepts_every_verified_container_target() {
        for input in [APP_ROOT, APPGROUP_UUID, APP_UUID] {
            assert!(
                probe_path(input).accepted(),
                "{input} is a verified-movable target and must stay accepted"
            );
        }
    }

    /// Every row of [`probe_matrix`], with its expected verdict. This is the
    /// experiment list itself: if a row's verdict changes, the experiment has
    /// changed and this test is where that has to show up.
    #[test]
    fn the_matrix_is_the_documented_experiment_list() {
        let matrix = probe_matrix();
        let inputs: Vec<&str> = matrix.iter().map(|(input, _)| *input).collect();
        assert_eq!(
            inputs, EXPECTED_MATRIX,
            "the matrix must stay exactly the documented experiment list"
        );

        // -- accepted: verified-movable baselines ---------------------------
        for expected in [APP_ROOT, APPGROUP_UUID, APP_UUID] {
            assert!(
                probe_path(expected).accepted(),
                "{expected} is a verified-movable target and must stay accepted"
            );
        }
        assert_eq!(probe_path(APP_ROOT).normalized.as_deref(), Some(APP_ROOT));
        assert_eq!(
            probe_path(APPGROUP_UUID).normalized.as_deref(),
            Some(APPGROUP_UUID)
        );
        assert_eq!(probe_path(APP_UUID).normalized.as_deref(), Some(APP_UUID));

        // -- accepted: candidates inside /var/mobile -----------------------
        accepted(
            "/var/mobile/Library/Preferences",
            "/var/mobile/Library/Preferences",
        );
        accepted("/var/mobile/Library", "/var/mobile/Library");

        // -- accepted: candidates outside /var/mobile ---------------------
        // Three components is the floor the guard enforces, so `/Library`,
        // `/Library/Preferences` (two) are below it and the nearest probeable
        // /Library target is one level deeper.
        accepted(MOBILEGESTALT, MOBILEGESTALT);
        accepted("/var/containers/Data/System", "/var/containers/Data/System");
        accepted(
            "/Library/MobileDevice/ProvisioningProfiles",
            "/Library/MobileDevice/ProvisioningProfiles",
        );
        accepted("/var/root/Library", "/var/root/Library");
        refused("/Library/Preferences", "at least three components");

        // -- normalisation: /private/var/… is /var/… ------------------------
        accepted(
            "/private/var/mobile/Library/Foo",
            "/var/mobile/Library/Foo",
        );

        // -- refused: traversal ---------------------------------------------
        refused(
            "/var/mobile/../var/mobile/Library",
            "must not contain '..'",
        );

        // -- refused: reserved component names ------------------------------
        refused("/Airlock", "'Airlock' is reserved by Airlift");
        refused("/var/mobile/Airlock", "'Airlock' is reserved by Airlift");
        refused("/Books.plist", "'Books.plist' is reserved by Airlift");

        // -- refused: not absolute / empty ----------------------------------
        refused("", "path must not be empty");
        refused("relative/path", "must be an absolute device path");
    }

    /// `/private/var/…` is the same directory on device, and the slashes get
    /// cleaned up on the way.
    #[test]
    fn probe_path_normalises_private_var_and_slashes() {
        assert_eq!(
            probe_path("/private/var/mobile/Library/Preferences").normalized,
            Some("/var/mobile/Library/Preferences".to_owned())
        );
        assert_eq!(
            probe_path("/var/mobile/Library/Preferences/").normalized,
            Some("/var/mobile/Library/Preferences".to_owned())
        );
        assert_eq!(
            probe_path("/var//mobile///Library/Preferences").normalized,
            Some("/var/mobile/Library/Preferences".to_owned())
        );
        // `private` is only dropped in front of `var`, never on its own.
        assert_eq!(
            probe_path("/private/var/tmp/scratch").normalized,
            Some("/var/tmp/scratch".to_owned())
        );
        assert_eq!(
            probe_path("/private/tmp/scratch").normalized,
            Some("/private/tmp/scratch".to_owned()),
            "a bare /private prefix is not /var, so it must not be stripped"
        );
        // Surrounding whitespace is trimmed like the shipping guard trims it.
        assert_eq!(
            probe_path("  /var/mobile/Library/Preferences  ").normalized,
            Some("/var/mobile/Library/Preferences".to_owned())
        );
        assert!(probe_path("   ").rejected.is_some());
    }

    /// The matrix must never name the Airlift staging zone or the sync
    /// manifest, whatever the spellings.
    #[test]
    fn no_matrix_row_targets_our_own_staging() {
        for (input, probe) in probe_matrix() {
            if let Some(normalized) = &probe.normalized {
                assert!(
                    !normalized.split('/').any(|c| c == "Airlock" || c == "Books.plist"),
                    "{input} normalised into the reserved zone: {normalized}"
                );
            }
        }
    }

    /// The ids a pull would put on the wire, for the paths the primitive can
    /// actually spell. `AssetID` is `../../../`-rooted because `Books/Sync` sits
    /// three levels below `/var/mobile`; `LinkTarget` is the restore symlink's
    /// target, which is always re-based under the Media root and therefore
    /// repeats `var/mobile`.
    #[test]
    fn manifest_ids_are_the_books_relative_arithmetic() {
        let (asset_id, link_target) = probe_manifest_ids("/var/mobile/Library/Preferences");
        assert_eq!(asset_id, "../../../Library/Preferences");
        assert_eq!(link_target, "../../../var/mobile/Library");

        let (asset_id, link_target) = probe_manifest_ids(APP_UUID);
        assert_eq!(
            asset_id,
            "../../../Containers/Data/Application/<uuid>"
        );
        assert_eq!(
            link_target,
            "../../../var/mobile/Containers/Data/Application"
        );
    }

    /// …and empty for every path outside `/var/mobile`, because `AssetID` is
    /// relative to `/var/mobile` and the restore symlink is re-based under the
    /// Media root. The guard accepts those paths; the primitive cannot express
    /// them, and the matrix has to say so out loud.
    ///
    /// This documents the boundary of `al_research_list_dir` — the shipping
    /// `/var/mobile` arithmetic. It stays as it is: the rows it covers are now
    /// reachable through [`probe_manifest_ids_any`] /
    /// `al_research_list_dir_any_path` instead, and which driver measured what
    /// is part of the record.
    #[test]
    fn manifest_ids_are_empty_outside_var_mobile() {
        for normalized in [
            MOBILEGESTALT,
            "/var/containers/Data/System",
            "/Library/MobileDevice/ProvisioningProfiles",
            "/Library/Preferences",
            "/var/root/Library",
            "/var/tmp/scratch",
        ] {
            assert_eq!(
                probe_manifest_ids(normalized),
                (String::new(), String::new()),
                "{normalized} is outside /var/mobile, so the driver has no ids for it"
            );
        }
    }

    /// The root-relative arithmetic: every research target gets a
    /// `../../../../..`-rooted `AssetID`, which is the whole point of the probe.
    /// `../../../../..` is `/` from `Books/Sync`, so the tail is the absolute
    /// path spelled out in full.
    #[test]
    fn manifest_ids_any_reach_the_research_targets() {
        for (normalized, expected_asset_id) in [
            (
                MOBILEGESTALT,
                "../../../../../var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches/com.apple.MobileGestalt.plist",
            ),
            (
                "/var/containers/Data/System",
                "../../../../../var/containers/Data/System",
            ),
            (
                "/var/root/Library",
                "../../../../../var/root/Library",
            ),
            (
                "/Library/MobileDevice/ProvisioningProfiles",
                "../../../../../Library/MobileDevice/ProvisioningProfiles",
            ),
        ] {
            let (asset_id, link_target) = probe_manifest_ids_any(normalized);
            assert_eq!(asset_id, expected_asset_id, "{normalized}");
            assert!(
                asset_id.starts_with("../../../../.."),
                "{asset_id} must climb to /, not to /var/mobile"
            );
            // The restore symlink is unchanged by all of this: it is re-based to
            // the Media root by STEP C, so it still repeats `var/mobile` only
            // because these parents happen to live there. `/var/containers/…`
            // does not, and its link target has to say so.
            
            assert_eq!(
                link_target,
                format!(
                    "../../../{}",
                    normalized
                        .trim_end_matches('/')
                        .rsplit_once('/')
                        .unwrap()
                        .0
                        .trim_start_matches('/')
                ),
                "{normalized}"
            );
        }

        // Every accepted matrix row is expressible through the research driver,
        // including the ones the shipping arithmetic already handled. For those
        // the two spellings differ but resolve to the same object.
        for (input, probe) in probe_matrix() {
            let Some(normalized) = &probe.normalized else {
                // A refused row never reaches the arithmetic: the guard is what
                // refuses it, so there is nothing for the id helper to spell.
                assert!(
                    probe_path(input).rejected.is_some(),
                    "{input} is neither accepted nor refused, which is not a verdict"
                );
                continue;
            };
            assert!(
                !probe_manifest_ids_any(normalized).0.is_empty(),
                "{normalized} is accepted and must be expressible"
            );
        }
    }

    /// No research row may reach into the scaffolding a pull depends on. The
    /// guard already refuses those names; this asserts the matrix cannot smuggle
    /// one in through a new spelling.
    #[test]
    fn no_research_target_lands_in_our_own_staging() {
        for (input, probe) in probe_matrix() {
            let Some(normalized) = &probe.normalized else {
                continue;
            };
            assert!(
                !normalized
                    .split('/')
                    .any(|c| c == "Airlock" || c == "Books.plist"),
                "{input} normalises into the reserved zone: {normalized}"
            );
            let (asset_id, link_target) = probe_manifest_ids_any(normalized);
            // The `AssetID` tail is the caller's own path, so it can only name
            // the reserved zone if the caller already did — which is refused
            // above. Check it anyway: this id goes on the wire.
            assert!(
                !asset_id.contains("/Airlock") && !asset_id.ends_with("/Airlock"),
                "{input}: AssetID {asset_id} names the staging zone"
            );
            assert!(!link_target.contains("Airlock"));
        }
    }

    // -- The dataclass sweep ------------------------------------------------
    //
    // The wire values are not re-spelled here: they come out of
    // `atc_dataclass_strings`, which reads the very `plist` values
    // `atc_asset_sync` inserts. So these assert what goes on the wire, not what
    // this file believes goes on the wire.

    /// The default dataclass is `Book`, and at the default every one of the five
    /// wire sites spells exactly the value the hard-coded literal used to — the
    /// shipping bytes are unchanged by making the dataclass a parameter.
    #[test]
    fn the_default_dataclass_is_book_on_every_wire_site() {
        assert_eq!(resolve_dataclass(""), "Book");
        assert_eq!(resolve_dataclass("Book"), "Book");

        for requested in ["", "Book"] {
            let strings = atc_dataclass_strings(requested);
            assert_eq!(
                strings.len(),
                5,
                "every dataclass-carrying field has to be accounted for: {strings:?}"
            );
            for (field, value) in &strings {
                assert_eq!(value, "Book", "{requested:?} at {field}");
            }

            // …and the plist values themselves, not only their spellings:
            // `SyncedDataclasses`/`SyncedAssetTypes`/`Dataclasses` are one-element
            // arrays, `SyncTypes` is `{Book: 1}`, `FileComplete/Dataclass` a
            // bare string.
            let wire = atc_dataclass_wire(requested);
            for (field, value) in [
                ("SyncedDataclasses", &wire.synced_dataclasses),
                ("SyncedAssetTypes", &wire.synced_asset_types),
                ("Dataclasses", &wire.dataclasses),
            ] {
                assert_eq!(
                    value,
                    &plist::Value::Array(vec![plist::Value::String("Book".to_owned())]),
                    "{field} is no longer a one-element array of the dataclass"
                );
            }
            assert_eq!(
                wire.sync_types.get("Book"),
                Some(&plist::Value::Integer(1.into())),
                "SyncTypes is no longer {{<dataclass>: 1}}"
            );
            assert_eq!(
                wire.sync_types.len(),
                1,
                "SyncTypes must carry only the requested dataclass: {:?}",
                wire.sync_types
            );
            assert_eq!(
                wire.file_complete,
                plist::Value::String("Book".to_owned())
            );
        }
    }

    /// A non-`Book` dataclass reaches all five sites and leaves no `Book`
    /// behind — the property the whole sweep rests on. If any site still spelled
    /// the literal, one of these two assertions fails.
    #[test]
    fn a_non_book_dataclass_reaches_all_five_sites() {
        let strings = atc_dataclass_strings("Music");
        let fields: Vec<&str> = strings.iter().map(|(field, _)| field.as_str()).collect();
        assert_eq!(
            fields,
            [
                "HostInfo/SyncedDataclasses",
                "HostInfo/SyncedAssetTypes",
                "RequestingSync/Dataclasses",
                "FinishedSyncingMetadata/SyncTypes",
                "FileComplete/Dataclass",
            ],
            "the five sites are the whole primitive; a sixth or a reordering \
             means the sweep would be measuring something else"
        );
        for (field, value) in &strings {
            assert_eq!(value, "Music", "{field} still sends the old dataclass");
            assert!(!value.contains("Book"), "{field} leaked a Book: {value}");
        }

        let wire = atc_dataclass_wire("Music");
        assert_eq!(wire.sync_types.keys().collect::<Vec<_>>(), vec!["Music"]);
        assert!(wire.sync_types.get("Book").is_none());
    }

    /// No allow-list: an unrecognised dataclass goes out verbatim. Inventing a
    /// spelling check here would answer a different question than "what does the
    /// device do with a dataclass nobody has sent".
    #[test]
    fn unknown_dataclasses_are_passed_through_verbatim() {
        for dataclass in ["App", "Podcast", "Movie", "Music", "Book"] {
            assert_eq!(resolve_dataclass(dataclass), dataclass);
            for (field, value) in atc_dataclass_strings(dataclass) {
                assert_eq!(value, dataclass, "{dataclass} at {field}");
            }
        }

        // And a name no Apple product has ever used is not normalised away
        // either — the daemon, not this file, gets to decide.
        assert_eq!(resolve_dataclass("Nonsense"), "Nonsense");
        for (_, value) in atc_dataclass_strings("Nonsense") {
            assert_eq!(value, "Nonsense");
        }
    }
}
