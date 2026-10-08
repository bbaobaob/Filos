# Airlift reach research

RESEARCH ONLY. Everything described here runs against a device we own and is
deliberately research-only. It IS wired to a UI — `Filos/Airlift/ResearchView.swift`,
reached from Settings → Airlift → "Research sweep" — because the sweep needs a
human choosing each row and reading the log. That screen says out loud that it is
a probe for an unfixed Apple bug. Nothing in the browse path calls any of it.

## The primitive

`com.apple.atc` (Apple Books sync) moves an *arbitrary* filesystem object when a
host announces a `FileComplete { AssetID, AssetPath }` pair inside an AirTraffic
session, and `AssetID` is resolved relative to
`/var/mobile/Media/Books/Sync` — so `../../../` reaches `/var/mobile`,
`../../` reaches `/var/mobile/Media`. Directories move as a unit.

Airlift turns that into "move any directory here, list it, move it back":
STEP A stages a symlink zip, STEP B moves the target to
`/var/mobile/Media/Airlock/Read/<T>` (where ordinary AFC can read it), STEP D
writes a recovery record, STEP C moves the symlink and the parked directory
back through it. Everything except the guard is target-agnostic
(`rust-core/src/airlift_dir.rs`).

## Why it is interesting

HouseArrest is dead on current iOS; this is the only "read a directory that is
not under my container" primitive found so far. Shipping Airlift restricts it to
our own app containers out of caution — not because the daemon enforces it. The
daemon's authority is *not* the AFC root: AFC only ever sees
`/var/mobile/Media`, so "the daemon can move what AFC cannot see" has never
been tested. That gap is the research question.

## Apple-attributable hypotheses

1. **No allow-list, only a path policy.** `FileComplete` resolves the AssetID
   inside the Books daemon's own sandbox context. If so, its reach is whatever
   `mobile` can stat, not whatever `afcd` exports.
2. **Reach is bounded by asset-type handling, not by location.** The daemon may
   only move objects it recognises as assets — which would explain the
   asymmetry below better than any location rule.
3. **Reach is bounded by the sync anchor.** `AssetID` resolution may be clamped
   to the sync's own dataclass root rather than walking to `/`.

These are falsifiable one row at a time; see the matrix.

## Experiment matrix

`rust-core/src/research.rs` holds the machine-readable version
(`probe_matrix()`, asserted row-by-row in its tests). Run each accepted row on
device and record whether `Airlock/Read/<T>` ever became listable.

Which entry point to use depends on where the path lives:

* `/var/mobile/…` — `al_research_list_dir_any_path` is the one to use. It is the
  only one that goes through the *research* driver (`research_parent_and_basename`
  and the research `AssetID` arithmetic); `al_research_list_dir` used to call the
  shipping driver, so for `/var/mobile/Library` it refused the target with the
  shipping parent rule and measured Airlift's own policy, not the daemon. With
  the default sync root the two spellings resolve to the same place, so nothing
  is lost by using the research entry point throughout.
* outside `/var/mobile` — `al_research_list_dir` refuses them *itself*, before
  STEP A, so it cannot answer the question at all. Use
  `al_research_list_dir_any_path` (see below).

| Path | Offline verdict | Device result |
| --- | --- | --- |
| `/var/mobile/Containers/Data/Application` | accepted | **verified: moves** |
| `/var/mobile/Containers/Shared/AppGroup/<uuid>` | accepted | **verified: fails** |
| `/var/mobile/Containers/Data/Application/<uuid>` | accepted | **verified: fails** |
| `/var/mobile/Library/Preferences` | accepted | untested |
| `/var/mobile/Library` | accepted | **verified on device (iOS 27.0): REFUSED** — see below |
| `/var/containers/…/com.apple.MobileGestalt.plist` | accepted | untested — needs `any_path` |
| `/var/containers/Data/System` | accepted | untested — needs `any_path` |
| `/Library/MobileDevice/ProvisioningProfiles` | accepted | untested — needs `any_path` |
| `/Library/Preferences` | refused (< 3 components) | n/a — see depth floor |
| `/var/root/Library` | accepted | untested — needs `any_path` |
| `/private/var/mobile/Library/Foo` | normalises to `/var/mobile/Library/Foo` | untested |
| `/var/mobile/../var/mobile/Library` | refused (`..`) | n/a |
| `/Airlock`, `/var/mobile/Airlock`, `/Books.plist` | refused (reserved) | n/a |
| `""`, `relative/path` | refused | n/a |

## Measured: `/var/mobile/Library` is refused by the daemon

First row ever to measure `com.apple.atc` rather than our own guard. iOS 27.0,
iPhone12,5, via `al_research_list_dir_any_path` with the default (Books) root.
Everything on the wire was accepted and every step ran to completion:

```
STEP A verified airlift-pull-<T>/p0/p1/p2/link -> ../../../var/mobile
STEP B AssetManifest keys present = [Book]
STEP B manifest entries=[…, ../../../../../var/mobile/Library IsDownload=true]
STEP B FileComplete AssetID=../../../../../var/mobile/Library Dataclass=Book
STEP B pull: ATC session finished
Airlock/Read/<T> not listable yet (1..20): Afc(ObjectNotFound)
STEP B: never became listable after 20 attempts
```

`DataProtected=false`, `SyncFailed notices=0`, and the restore leg completed
normally — so this is **not** a lock-screen failure and **not** a sync error. The
daemon acknowledged the request, marked the asset `IsDownload=true`, then simply
never materialised the move.

What this rules in and out:

* The `IsDownload=true` acknowledgement means the manifest was read and parsed.
  The refusal happens **after** asset acceptance, during the move itself.
* `Airlock/Read` stayed `[".", ".."]` across 20 s, so the destination was never
  created — consistent with the daemon deciding not to move, not with it moving
  somewhere we are not looking. (A move to a different name would have shown up
  in the `Airlock/Read` listing.)
* The restore leg's `FileComplete` for `airlift-link-<T>/Library` succeeded,
  which proves the STEP C half of the primitive still works on a *successful*
  pull's shape — the write side was never the problem.

So the primitive is **not** a general "move any path the daemon can stat". The
reach is narrower than `mobile`'s filesystem authority: `AppGroup` (a plain
directory under `/var/mobile/Containers/Shared`) moves, `/var/mobile/Library`
does not. Hypothesis 2 in the previous section — reach bounded by asset-type
handling rather than location — now fits the evidence better than the others;
hypothesis 3 is weakened, because the root-relative spelling was used here and
still refused. Next rows to run: `/var/mobile/Library/Preferences`,
`/var/mobile/Library/Caches`, and a plain app container child directory
(`/var/mobile/Containers/Data/Application/<uuid>/Documents`) — that last one is
the decisive one: if a container child moves while `/var/mobile/Library` does
not, reach is container-scoped, not `mobile`-scoped.

## Root-relative `AssetID` (`al_research_list_dir_any_path`)

Now device-verified on the row above. The MobileGestalt cache is the reason this
exists:

```
/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches/com.apple.MobileGestalt.plist
```

`/var/containers` is a different filesystem branch from `/var/mobile`, and until
now the public primitive could not even *ask* for it. Two separate reasons, and
it is worth keeping them apart:

1. **The guard** (`research_checked_path`) accepts any absolute path with ≥ 3
   components. That part was already done.
2. **The arithmetic** could not express it. `asset_id_for_device_path` emits
   `../../../<path relative to /var/mobile>`, so a path outside `/var/mobile`
   was refused by *our own* code before STEP A. Until now those rows measured
   Airlift's guard, not `com.apple.atc`.

`research_asset_id_for_device_path` emits `"../".repeat(5) +
<path with the leading / stripped>`. Five is the component count of
`/var/mobile/Media/Books/Sync`, so the chain climbs from the sync directory all
the way to `/` and the tail is the whole absolute path — no `/var/mobile`
assumption anywhere. For a path under `/var/mobile` this is
`../../../../../var/mobile/<rest>`, which resolves to the same object as
today's `../../../<rest>`; that equivalence is asserted by resolving both
spellings component-by-component from `Books/Sync` in
`research_asset_ids_agree_with_the_shipping_ones_inside_var_mobile`, with no
device and no daemon involved. `LinkTarget` needed no change:
`link_target_for_parent` was already generic, because the STEP A symlink is
re-based under the Media root before it is ever followed.

Examples:

| Path | `AssetID` on the wire |
| --- | --- |
| `/var/mobile/Containers/Shared/AppGroup` | `../../../../../var/mobile/Containers/Shared/AppGroup` |
| `/var/containers/Data/System` | `../../../../../var/containers/Data/System` |
| `/var/root/Library` | `../../../../../var/root/Library` |
| `/Library/MobileDevice/ProvisioningProfiles` | `../../../../../Library/MobileDevice/ProvisioningProfiles` |

`al_research_list_dir_any_path` is otherwise a line-for-line copy of
`al_research_list_dir`, and its driver
(`research_pull_list_and_restore`) is a copy of `pull_list_and_restore` that
differs in exactly two lines — the two id helpers. The shipping driver and
`list_dir` are untouched; `the_research_driver_is_a_copy_of_the_shipping_one`
fails the build if that ever stops being true. Safety properties are unchanged:
`research_checked_path` still refuses `..`, still refuses `Airlock` /
`Books.plist`, still requires ≥ 3 components, and the snapshot/restore pair
still brackets every step.

**Untested on device.** The arithmetic is proven correct offline; whether
`com.apple.atc` resolves a `..` chain that climbs past `/var/mobile` is not
known. Until a run says otherwise, the first attempt against any path outside
`/var/mobile` is an experiment, not a known outcome — treat "no error" and "an
empty listing" as possible results and read the STEP B diagnostics
(`AssetManifest` contents, `SyncFailed` payloads) rather than the return value.

One more consequence to know before the first run: the STEP D recovery record
is still validated by the *shipping* `checked_pull_path`, so
`al_airlift_recover` reports a record written for an out-of-`/var/mobile`
target as `rejected` instead of replaying it. The record is still written and
still names where the data is, so a run that ends `kept at Airlock/Read/<T>` on
such a path has to be finished by hand.

## Verified on device (iOS 27, iPhone12,5)

* The `…/Containers/Shared/AppGroup` **root** pulls and restores correctly.
* An app-data container **root** does not materialise at `Airlock/Read/<T>`.
* An AppGroup **sub-UUID** does not materialise.
* HouseArrest (`com.apple.mobile.house_arrest`) is dead for reading containers.

## Untested / known limits of the probe

* Everything in the matrix marked *untested*, including the whole
  root-relative `AssetID` family above.
* **Depth floor.** The guard requires three components, so `/Library` and
  `/Library/Preferences` cannot be probed directly; the nearest probeable
  `/Library` target is one level deeper.
* **`al_research_list_dir` still cannot reach outside `/var/mobile`.** It uses
  the shipping `/var/mobile`-relative `AssetID`, so those rows are refused
  before STEP A and measure our guard, not the daemon. That is why
  `al_research_list_dir_any_path` exists; the shipping driver is deliberately
  left alone.
* Both drivers are *expression*, not permission: reaching `/var/containers` on
  the wire says the daemon honoured the request, not that the target is
  readable or that a jailbreak is a step closer.
* A single ATC sync is one `Item ID` base; run rows sequentially, never
  concurrently — the tunnel mutex serialises them but the journal is shared.
* If a row fails mid-sequence, run `al_airlift_recover` before the next one.