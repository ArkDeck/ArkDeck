# Job events cursor dependency review — user-authorized, 2026-09-12

The Rust metadata event reader preserves the existing Swift `jec1` cursor format:
AES-256-GCM, a fresh OS-random 96-bit nonce, a 32-byte private cursor key, and
associated data `arkdeck.job.events.cursor/1:streamPositionAsc`. These cursors
select presentation offsets only. They grant no admission, recovery or device
authority. A custom cryptographic implementation and undocumented native symbols
are not proposed.

`aes-gcm = 0.10.3` is fixed with only `aes` and `alloc` features. `Cargo.lock`
contains ten additional packages; the exact-version allowlist and all license,
source and advisory checks pass. Existing configured upstream source audits cover
four packages; six lack complete `safe-to-deploy` chains. The user explicitly authorized the six fixed releases and individual publication
days below on 2026-09-12. Their bounded trust entries are now applied. No exemption
or local source-audit assertion is added.

The current dependency policy says: “Do not ... widen a publisher window merely
to make the check green.” It also states that dependency and trust-policy changes
are explicit PR review items. The previous user authorization recorded in
`rust/supply-chain/README.md` covers nine named releases for PR #1768; none of the
six new release dates below is covered. Accepting publisher provenance for these
releases is a separate trust decision, not a successful source audit.

The authorized decision is one UTC publication day per **named crate**,
combined with the exact version and checksum below. No future release or renewal
is accepted. Existing trust windows remain unchanged. Maintainer review and merge
are still required. The authorization covers only the listed releases and days; any later trust
change requires a separate review.

| Release | Publisher / numeric ID | Authorized UTC [start, end) | Exact checksum |
| --- | --- | --- | --- |
| [aead 0.5.2](https://crates.io/api/v1/crates/aead/0.5.2) | tarcieri / 267 | 2023-04-02 → 2023-04-03 | `d122413f284cf2d62fb1b7db97e02edb8cda96d769b16e443a4f6195e35662b0` |
| [aes 0.8.4](https://crates.io/api/v1/crates/aes/0.8.4) | tarcieri / 267 | 2024-02-13 → 2024-02-14 | `b169f7a6d4742236a0a00c541b845991d0ac43e546831af1249753ab4c3aa3a0` |
| [aes-gcm 0.10.3](https://crates.io/api/v1/crates/aes-gcm/0.10.3) | tarcieri / 267 | 2023-09-21 → 2023-09-22 | `831010a0f742e1209b3bcea8fab6a8e149051ba6099432c8cb2cc117dec3ead1` |
| [ctr 0.9.2](https://crates.io/api/v1/crates/ctr/0.9.2) | newpavlov / 5059 | 2022-09-30 → 2022-10-01 | `0369ee1ad671834580515889b80f2ea915f23b8be8d0daa4bbaf2ac5c7590835` |
| [ghash 0.5.1](https://crates.io/api/v1/crates/ghash/0.5.1) | tarcieri / 267 | 2024-03-03 → 2024-03-04 | `f0d8a4362ccb29cb0b265253fb0a2728f592895ee6854fd9bc13f2ffda266ff1` |
| [polyval 0.6.2](https://crates.io/api/v1/crates/polyval/0.6.2) | tarcieri / 267 | 2024-03-03 → 2024-03-04 | `9d1fe60d06143b2430aa532c94cfe9e29783047f06c0d7fd359a9a51b729fa25` |

All six checksums match the crates.io version API and all six versions were
reported as not yanked on 2026-09-12. Registry facts and the full failed vet
suggestion report are retained alongside this note. Publisher trust can accept a
compromised or defective release and does not establish cryptographic correctness.
No source-audit or hardware-acceptance claim is made.

The prepared Rust code passes the existing nineteen closed Journal event kinds,
four paging/append/corruption tests and two CLI argv/native-page tests. The same-inode
Swift/Rust cursor interoperability and actual daemon/CLI checks passed in both
directions: Rust resumes Swift cursors, Swift resumes a Rust cursor, and Rust
resumes its cursor after daemon restart. Journal, SQLite and key bytes were
preserved. Logs: `/private/tmp/xpa014-job-events-process-r1.log` and
`/private/tmp/xpa014-event-cursor-swift-readback-r1.log`. The final unified gate
after integrating the current Job owner and latest main remains pending.
