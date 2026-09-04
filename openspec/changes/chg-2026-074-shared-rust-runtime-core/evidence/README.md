# Evidence — CHG-2026-074

Each `TASK-XPA-*` implementation PR writes one vertical run record under `runs/<task-id>/`. Record
only non-secret commands, exit codes, the Catalog digest, file SHA-256 values, Job/Artifact IDs,
redacted target identity and AC conclusions. Never commit serial numbers, connect keys, keystore
passwords, private keys, SSH credentials, device UDIDs or raw device output. Spike results
(`SPK-1..5`) are recorded under `runs/<task-id>/` of the task they unlock.
