# BM native-library metadata count — source analysis, 2026-10-06

This is an independent source analysis, not a Runtime record or acceptance result.
The original provisional report, check exit 2, frozen helper, stop markers and Raw
remain unchanged. No SDK, Runtime, HDC, device or private file was accessed for this
analysis.

The local provisional predicate `installedNativeFileCountOne` interprets BM's
`nativeLibraryFileNames` metadata as a required count of installed or loaded
libraries. That interpretation is incorrect for extracted native libraries. It is
an extra local helper criterion, not an accepted GJ-2 requirement. No Runtime
deployment or parsing defect is established by this zero value.

## Actual public facts

The [original provisional summary](gj2-provisional-smoke-results-19097bde14cb.json)
preserves the real result: `debug.hap@1` succeeded, three published products were
read whole, outcome is known and residue is zero. ARMv7, nonempty native path and
the baseline NAPI marker plus `add=42` were observed. The one-count observation is
false and check exit is 2. Process maps and formal acceptance remain unproved.

The [signed HAP report](gj2-signed-pair-results-19097bde14cb.json) identifies the
130,336-byte HAP by SHA-256
`ec5ce24958a16047c784a4af0f2197db86009abe1a3fbb193363a8bdd825e4bf`.
Its complete member inventory contains one native member,
`libs/armeabi-v7a/libarkdeck_gj.so`, 11,372 bytes, SHA-256
`907780120312af191be7cd268953c01d5daf5b5d488aa71e6403594d46ef0c59`.
This archive member count is distinct from BM's reported metadata count.

The public unsigned fixture's `module.json` declares
`compressNativeLibs=false` and `extractNativeLibs=true`. Its full module SHA-256,
`1b53eca56eb844e0c053d565e0f9258456c833a3b0e1e59bdb7c64f5585ae7af`,
equals the signed inventory's module hash. Thus these declarations are preserved
in the final signed HAP; they are not guesses from the current device. The public
unsigned native ZIP entry is stored, compression method 0.

## Primary BM source explanation

OpenHarmony's stage-model parser sets the internal native extraction flag to
`compressNativeLibs || extractNativeLibs`; see
[module_profile.cpp, ToInnerModuleInfo](https://github.com/openharmony/bundlemanager_bundle_framework/blob/master/services/bundlemgr/src/module_profile.cpp#L2854-L2858).
For this fixture, `false || true` becomes true. The installer takes its native
extraction branch. Only the opposite branch collects the archive's native names
and sets `nativeLibraryFileNames`; see
[base_bundle_installer.cpp, InnerProcessNativeLibs](https://github.com/openharmony/bundlemanager_bundle_framework/blob/master/services/bundlemgr/src/base_bundle_installer.cpp#L7723-L7767).
The same installer branch distinction is present in the
[OpenHarmony 6.0 release source](https://github.com/openharmony/bundlemanager_bundle_framework/blob/OpenHarmony-6.0-Release/services/bundlemgr/src/base_bundle_installer.cpp#L5317-L5354).

These are public upstream sources, not a source pin for the board's exact
7.0.0.37 build. The extraction explanation is a source-supported inference,
corroborated by the unchanged HAP declarations and actual public NAPI observation;
it does not claim the board binary was independently matched to those revisions.

ArkDeck's `debug_hap.rs::append_native_library_facts` (lines 1251–1277) sums the
lengths of `hapModuleInfos[].nativeLibraryFileNames`. The reported string `"0"`
therefore preserves an empty BM metadata list. It does not enumerate installed
filesystem bytes and does not read process maps. The provider correctly retains
that observed value rather than substituting the archive's one native member.

The fixture application imports `libarkdeck_gj.so` and calls its native `marker()`
and `add(19,23)` before emitting `NAPI_CHECK_OK`. Observing its exact baseline
marker and `add=42` supports an actual native call in that application. It does
not prove mapped-file SHA, BuildID, loader provenance or GJ-3 deployment/rollback.

## Correct GJ-2 completion criteria

`PRODUCT-LOOP.md` GJ-2 requires the HAP lease/send/install/package readback,
application state, HiLog/UI/Trace, stop and staging cleanup. The published
`scripts/gj_record/journeys.py::gj2` (lines 396–419) checks the original debug Job,
its exact deployment/cleanup timeline and whole products, plus a complete
app-scoped diagnostic capture with nonempty HiLog, UI Dump and Trace. Neither
requires BM's native name list to contain exactly one item.

The existing full local GJ-2 driver additionally verifies a separate retained
running preflight and exact durable Job/request/inventory/byte readback across
one typed Runtime restart. Those checks remain in force. Reusing the real signed
HAP and import receipt does not authorize replay of the completed provisional
execution or bypass a known/unknown outcome gate.

Keep BM's count as a factual diagnostic observation. Use the signed archive's
whole verified inventory for package membership, the actual application marker
for the bounded NAPI check, and the unchanged accepted recorder for formal GJ-2.
Do not convert the old check2 into PASS or replace missing app-scoped capture,
durable reads, source/Catalog identity or paired-baseline acceptance with a count.

## Local targeted checks

Read-only Python ZIP/JSON inspection: the public unsigned module hash exactly
equals the signed report's module hash; extraction flags are false/true; native
member has compression method 0 and size 11,372 bytes. Exit 0. Public source and
the sanitized reports were read. No tests, build, signing or live operation ran.
