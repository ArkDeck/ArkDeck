# Windows ArkTrace contract vectors

`manifest.json` and `inspect.json` are path-free metadata recorded during the
2026-10-18 native Windows development qualification of the real, recipe-built
TraceStreamer and the host-trusted signed Rust CLI, source revision
`6f2a510bc6da306d786531a4949738609f8d82c7` (`source.dirty: false`). The manifest
includes all 37 frozen Cargo dependencies and 75 Rust license texts. This is a
development qualification vector, not a production release or hardware acceptance
record. No executable or user Trace is
included. `inspect.json` parses ArkTrace's checked-in `zlib.htrace` fixture.

The contract tests require the signed-package vocabulary, closed attribution and
parser recipe, and reject altered identities and envelopes. The explicit native
qualification test additionally consumes an external signed distribution and
qualified private root; default CI does not claim that live qualification.
