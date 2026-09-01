# CLI bootstrap bundle and HDC registration

`runtime bundle register/list/inspect/remove` provides a pre-daemon resource for
the signed macOS `daemon-bundle` kind. Registration copies an app bundle into the
current user's `Library/Application Support/ArkDeck/Bootstrap/v1` directory; it
does not execute it, install it, restart a service or affect HDC. The home is
resolved from the current uid, not `HOME` or an App Sandbox container.

```text
arkdeck runtime bundle register --kind daemon-bundle --file /absolute/ArkDeckAgent.app --output json
arkdeck runtime bundle inspect --bundle bundle:sha256:<digest> --output json
arkdeck runtime bundle list --page-size 100 --output json
arkdeck runtime bundle remove --bundle bundle:sha256:<digest> --expected-generation 1 --output json
```

The descriptor-relative copy rejects symbolic/hard links, special files,
unsafe owners/permissions, more than 4096 entries, depth greater than 24 and
content above 1 GiB. Info.plist is bounded to 64 KiB before signature validation.
Source identity and contents are rechecked after copying and trust validation.
The copied tree is rehashed and validated against the existing ArkDeck helper
signature requirement, team, hardened runtime, entitlements and provisioning
profile. Quarantine is preserved and included in content identity. The reported
trust policy is `arkdeck.daemon-helper/1`; `executionAssessment: notPerformed`
does not claim a Gatekeeper assessment or permission to execute the helper.

The reference digest is SHA-256 over JCS `arkdeck.bundle-content/1`, including
every directory and file path, file executable bit, byte count, content hash and
quarantine hash. Registration returns `arkdeck.runtime-bundle/1` under the usual
CLI envelope. A repeated registration of the same available content returns the
same reference, generation and timestamp. Different bytes or quarantine produce
a different reference. An absent version is explicitly null.

A private cross-process lock serializes publication, reference acquisition,
removal and snapshot retention. Immutable content is durable before its index
record. A crash after content publication leaves an orphan that can only be
adopted after complete revalidation. A crash after record publication can lose a
receipt, but retry finds the same record. Missing/corrupt indexes beside retained
state fail closed. Existing content is never overwritten.

Removal accepts the exact available generation (`1`) and persists a tombstone
(`2`); repeating the same generation-1 request returns that tombstone. Installed,
rollback, pending control-action, Job and recovery owners pin content before
consumption and block removal until explicitly released by the owning product
code. A crash does not release a pin. Removed content remains readable to owners
and is retained; this surface never unlinks historical bytes or silently selects
another bundle. The registry is limited to 128 records and 2 GiB of retained
bundle content, counting orphans, with at most one additional bounded staging
copy in flight. Excess interrupted staging fails closed for inspection. There
is no implicit garbage collection or resurrection of a removed reference.

Lists use the existing private, immutable snapshot pager under the same lock.
Continuation retains the original projection after later registrations/removals;
changing page size or using an expired/foreign cursor is rejected. Inventory and
inspection revalidate registered content; unreadable content is never omitted.

This resource does not complete the service lifecycle contract. The App still
needs its sandbox bridge to this shared owner; it must not create a separate
container registry. Service install/update must adopt typed references and
revalidate them, and any possible HDC interruption must use the shared impact
preview/control-action/HAR path. Existing service compatibility commands are
unchanged by this implementation. No real-device acceptance is claimed here.

## Native HDC candidates

The same store owner also exposes four local tool commands, without requiring
a running daemon or accepting a socket, executable arguments, or SDK root:

```text
arkdeck runtime tool register --kind hdc --file /absolute/toolchains/hdc --output json
arkdeck runtime tool inspect --tool tool:sha256:<digest> --output json
arkdeck runtime tool list --page-size 100 --output json
arkdeck runtime tool remove --tool tool:sha256:<digest> --expected-generation 1 --output json
```

Registration reads native Mach-O load commands without launching the candidate.
The copied entry is named `hdc`. When it loads `@rpath/libusb_shared.dylib`, the
required same-directory library is captured alongside it; missing, symbolic,
hard-linked or oversized dependencies are rejected. File identity, bytes and
quarantine are checked across copy and static signature inspection. The whole
copy is bounded to 256 MiB, with a 32 MiB library bound. No arbitrary dyld search
path is traversed. Unsupported relocation layouts may remain inspectable
candidates but cannot resolve for a Runtime consumer.

`arkdeck.runtime-tool/1` returns the content-addressed `toolRef`, generation,
executable hash, dependency identities and signatures, known profile version
or null, and durable references. Its SHA-256/JCS content digest includes the
`hdc-sibling-libusb/1` layout and all tree entries; replacing libusb changes the
tool reference even when the HDC executable is unchanged. Static signatures
distinguish unsigned, ad-hoc and verified code; `platformTrust: unverified` and
`executionAssessment: notPerformed` do not grant OS execution permission. A
version is reported only when executable bytes match an existing published
OpenHarmony profile. Registration never declares new Provider/hardware support.

The tool family shares the bundle lock and snapshot semantics. It retains at
most 128 records and 2 GiB including orphan/staging content. Exact-generation
removal retires the resource without deleting bytes and is blocked by any
installation, rollback, Job, AgentExecution, recovery, control-action, active
selection, lease or workspace-preset reference. Only product code can acquire
these pins. Resolving an available published HDC requires an exact durable
consumer pin, complete content/trust validation and a supported relocation
layout; it returns the exact copied executable/dependency manifest. The Runtime
consumer must retain/revalidate its directory and every file through the existing
Process identity layer. This manifest is not an execution authorization.

Tool selection, SDK/toolchain `--root` registration, typed service adoption and
the App bridge are not implemented by these four commands. They still require
the §7.8 control-action/HAR integration; registration never changes preferences
or stops/restarts HDC. The optional installed-DevEco integration test statically
checks the copied HDC/libusb pair and its drift handling, with no HDC invocation
or device dispatch. Machines without that SDK explicitly skip that host test.
