# Tasks

Every immutable Task packet selects one concrete execution platform (`macos`, `windows` or `linux`) and pins its matching platform profile plus baseline, approved change, integration profiles, conformance suite, base revision, Requirement/AC, runtime capabilities, paths, verification and stop conditions. A shared change is split into platform-pinned Tasks. Claim/run state and externally verified owner attestations use separate append-only sidecars.
