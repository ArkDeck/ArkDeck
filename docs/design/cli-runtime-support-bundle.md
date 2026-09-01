# Runtime support bundle CLI

`arkdeck runtime support-bundle` exposes the existing bounded diagnostic export through one
local product facade shared with the Settings UI. The CLI does not receive a storage exporter,
Session root, diagnostic log path, raw device bytes, Runtime capability, or device transport.

The flow has two commands:

```text
arkdeck runtime support-bundle preview --destination /absolute/new-directory --output json
arkdeck runtime support-bundle export --destination /absolute/new-directory \
  --preview-digest <scope-sha256> --output json
```

`preview` writes nothing. Its digest binds the canonical destination parent identity and every
included entry digest. `export` rebuilds the request through the same facade and refuses a changed
destination or scope. The storage layer then performs its existing anchored staging, quota,
owner-only permission, TOCTOU, and atomic publication checks.

The bundle contains bounded product metadata, redacted tool placeholders, and any explicitly
configured redacted sources. Raw device data remains excluded and automatic upload remains false.
An unknown post-publication outcome is reported as `outcomeUnknown`; callers must inspect the
destination and must not retry the export blindly.
