# Evidence — CHG-2026-074

Each `TASK-XPA-*` implementation PR writes one vertical run record under `runs/<task-id>/`. Record
only non-secret commands, exit codes, the Catalog digest, file SHA-256 values, Job/Artifact IDs,
redacted target identity and AC conclusions. Never commit serial numbers, connect keys, keystore
passwords, private keys, SSH credentials, device UDIDs or raw device output. Spike results
(`SPK-1..11`) are recorded under `runs/<task-id>/` of the task they unlock (`spk-N-run.md`, r11).
`macos-remaining.md` carries the six-number dashboard of the macOS chain and is updated on every merge
(r11); `adr-0009-decision-package-20260914.md` is the decision package for design §L.1 item 13.
