# Verification — CHG-2026-080

> Change:CHG-2026-080-private-keyboard-input@r1

Status:planned. All local transport is synthetic; no device execution.

| AC | Method | Expected result |
| --- | --- | --- |
| KBI-AC-1 closed inputs | parser, Import and Catalog checks | exact payload format, ten key names, 512-byte text bound, clipboard consent, no caller command/code/path or extra fields |
| KBI-AC-2 admitted execution | isolated production owners with fake HDC | target/lease binding and full materialization precede admission; one keyboard dispatch; confirmed Session is readable |
| KBI-AC-3 privacy | inspect actual Job/WAL/Session/capability output from host run | sensitive Import retains original bytes; output contains neither plaintext nor reconstructable encoded input; arbitrary tool/error text is not copied |
| KBI-AC-4 failure and recovery | bad binding/expired input/partial reply/reconcile/restart | preflight refuses before dispatch; unknown retains target hold and original intent; repeat run/reconcile emits zero keyboard dispatch |
| KBI-AC-5 client surfaces | ClientKit tests, App build and prototype interaction tests | no unapproved text upload, exact receipt validation, lost reply never retries, draft cleared on send/navigation, separate native key/text controls and bilingual privacy disclosure |

Local targeted checks use the affected Swift classes, affected/direct-dependent
Rust crates with `CARGO_BUILD_JOBS=2`, App build-for-testing, generators and SDD.
The selected GitHub lanes are the unified gate. No full local gate is run.
Actual UiTest version/permissions, focus behavior and device clipboard semantics
remain part of future published-operation hardware validation.
