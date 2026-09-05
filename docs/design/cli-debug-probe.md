# Bounded Debug Runtime probe

`arkdeck debug probe --target <target-id>` exposes the Runtime-owned Debug
portrait already used by the App. The CLI verifies the current v1 control identity and
sends exactly one `debug.probe` request containing only the durable target ID.
It accepts no executable, argv, shell, raw HDC command, connect key, remote
path, capability, or caller-provided observation.

The Runtime resolves the current target binding and its registered HDC tool,
then runs only its closed read-only package and port-rule observations. The
response schema is `arkdeck.debug-probe/1` and contains:

- the exact target ID and current binding revision;
- unique package names in byte-stable order;
- typed forward/reverse rules with bounded local and remote ports in stable order;
- closed warning codes for observations that could not be completed.

The command creates no Job, capability, evidence, Artifact, template execution,
or device mutation. A successful result means only that the bounded live probe
completed. It is not a real-device acceptance record, and warnings remain
explicit rather than being converted into invented empty facts.

The current control contract rejects extra request fields and bounds the target
identity before invoking the probe owner. App and CLI use the same bounded
projection after verifying the connected Runtime contract identity.
