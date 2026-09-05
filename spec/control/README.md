# Control-plane method contracts

`methods/<method>.json` is the typed, language-neutral contract of one local
control-plane method of the single current protocol: `$defs.request` (the
parameters a caller may send), `$defs.result` (the Runtime's reply),
`$defs.errorCode` and `$defs.errorDetails` (the structured evidence a refusal
attaches), plus `x-arkdeck-protocolVersion` and `x-arkdeck-contractIdentity`,
which name the exact registry the schema was derived under. The method set,
the version and the identity themselves are stated once, in
`Packages/ArkDeckKit/Contracts/control-protocol.json`, and projected into
`openspec/contracts/runtime-control-plane.schema.json`, whose method table
points at these files.

The files are derived, not written: a debug build of the daemon records every
dispatched request and response when `ARKDECK_CONTROL_FRAME_LOG=<directory>` is
set (a release build never reads the variable), and
`Packages/ArkDeckKit/Scripts/generate-control-contract.py --derive-method-schemas <directory>`
rewrites the schemas and the committed corpus under
`Packages/ArkDeckKit/Tests/ArkDeckContractTests/Fixtures/ControlFrames/`.
Results and error details are closed to the fields the daemon emitted; request
parameters are closed to the fields a contract test exercised. A field that no
contract test records is therefore not published, and
`ControlMethodSchemaContractTests` fails when a schema, a corpus frame or a
freshly recorded run disagrees with the other two, or when a schema carries a
contract identity other than the build's. The Swift daemon stays the oracle
until a second implementation passes the same corpus (design
`docs/design/cross-platform/rust-core-cross-platform-architecture.md` §F.1).
