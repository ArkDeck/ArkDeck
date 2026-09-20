# The DevEco toolchain pin on the Rust registry owner (TASK-XPA-015, M3)

The Rust DevEco registry owner now acquires and releases the pin a workspace
preset holds on a toolchain, as Swift's `BootstrapDevEcoToolchainRegistry`
does, and the isolated daemon composes it. A build or test preset, which #2056
refused for want of a toolchain owner, is now answered by the registry itself.

Stacked on the frames slice, whose schemas publish the registry's refusal
codes. Base: `main` `88248f67`, which is the frames slice #2073.

| Already on `main` | This change | Still remaining (M3) |
|---|---|---|
| The seven workspace methods on the Rust owner (#2056); the pin oracle (#2064); the refusal frames and widened schemas (the slice below this one) | `DevEcoRegistryStore::acquire/release`, their pure index transitions, and the isolated daemon's toolchain pin | the signing credential owner, so a signing preset resolves; the 13 `workspace.*` operations; GJ-5 |

## Behaviour, as Swift's registry

- **Acquire** finds the reference (a malformed one is `invalidInput`, an
  unknown one `resourceNotFound`), refuses a retired toolchain or another
  generation as `resourceConflict`, verifies the registered content, and adds
  the owner to the record's references, sorted by kind and then identity. A
  pin the record already holds changes nothing and is not refused, even at the
  reference bound; a new one past 1,024 is `quotaExceeded`.
- **Release** finds and verifies the same way, then removes the owner. A pin
  the record does not hold changes nothing.
- **Verification** is the registry's own measurement of the registered root,
  its manifests and child tools. Changed content refuses both calls with
  `recordUnreadable` before the index is touched, and a missing child with
  `fileIdentityChanged`, as the frames record.
- **The transaction** is the one retirement runs: the bootstrap lock, both
  indexes loaded and re-checked, the new index published only when it changed
  and only if nothing moved meanwhile, and the publication read back.
- **The isolated daemon** composes `host::toolchain_pinning` over its own
  `bootstrap` registry, as Swift's composition root builds
  `RuntimeWorkspaceToolchainPinning`. A refusal keeps the registry's code and
  message under the preset owner's phase. No credential owner is composed, so
  a signing preset is still refused as Swift refuses it without one.

## Tests

- `pins_and_releases_leave_swift_s_index_byte_for_byte` replays every acquire
  and release of #2064's oracle, 19 in all, on the index Swift recorded before
  each step: the same answer or refusal, and the index Swift recorded after,
  byte for byte. Content verification is the injected one, which holds until
  the recorded content change and then refuses.
- `an_owner_outside_swift_s_kinds_or_identifiers_is_refused`,
  `a_pin_in_an_empty_registry_finds_no_toolchain` and
  `a_retired_toolchain_is_not_pinned` cover the owner's own validation and the
  store transaction on a registry with nothing to pin.
- `tests/deveco_pins_native.rs` pins the installed DevEco Studio through the
  real verification: registered read-only into a fresh private registry,
  pinned, refused retirement while pinned, released, then retired. It is
  `#[ignore]`d, as the other native registry test is, and passes on the
  reference host in 5.3 s.
- `actual_host_pins_a_preset_toolchain_in_its_own_bootstrap_registry` (agentd)
  registers a build preset through the actual Control and Host with the pin
  composed: the registry's `resourceNotFound` reaches the caller under the
  preset owner's phase, nothing is written, a signing preset still wants the
  credential owner, and a symbol preset is served.

**Not covered:** a successful pin through the composed daemon, which needs a
registered DevEco toolchain; the native test covers the owner, and GJ-5 covers
the daemon. A build that runs hvigor cannot pass on this host at all: the
bundled `ninja` is x86_64 and the host has no Rosetta.

## Local targeted checks

With `CARGO_BUILD_JOBS=2`, on the changed crates:

| Check | Exit | Result |
|---|---|---|
| `cargo fmt --all --check` | 0 | |
| `cargo clippy -p arkdeck-hoststore -p arkdeck-agentd --all-targets -- -D warnings` | 0 | |
| `cargo test --no-fail-fast -p arkdeck-hoststore -p arkdeck-agentd` | 0 | 479 passed, 0 failed, 14 ignored |
| `cargo test -p arkdeck-hoststore --test deveco_pins_native -- --ignored` | 0 | 1 passed (5.3 s), against the installed DevEco Studio |
| `sh scripts/check-sdd.sh` | 0 | 0 errors, 0 warnings |

No new crate dependency edge, so `rust/scripts/check-readonly.py` is unchanged.

## CI

The PR's `guard` and `swift` aggregate are the unified gate. Their result is
added by the next slice.

The first run, stacked on #2073, was red only in `arkdeck-platform`'s
`loopback_server_lease::an_existing_loopback_listener_of_the_verified_executable_is_proved_without_a_connect`,
the load-sensitive flake family: this change touches neither that crate nor
that path, the whole test binary passes 7 of 7 here and the case 3 of 3. The
change was rebased on `88248f67` instead of asking for a rerun.
