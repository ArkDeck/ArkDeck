# CHG-2026-052 Design

## Context and constraints

- Audit base:`dd3b110daed9311f9c2c732c7c971c21482bed59`
- Core baseline:`CORE-2.1.0`
- Current producer:`openspec/verification/core-conformance.yaml`
  `acceptance_index.count = 111`
- Current consumer:`scripts/test_check_sdd.py`
  `ScopeCoverageTests.test_real_baseline_has_active_covered_scope_and_main_passes`
- Current failure:PR #816 head `ee33d996fd9adce4ef32d8527e49ae87da100143`
  produces a correct 114-count SDD summary, while the consumer expects literal 111.

## Requirement mapping

| Acceptance | Design component | Verification |
| --- | --- | --- |
| `GUARD-COUNT-CURRENCY-001` | strict manifest-count reader + real-baseline summary assertion | valid/invalid synthetic matrix + full real-repo suite + #816 downstream replay |

## Reader contract

The reader accepts exactly this path:

```text
YAML mapping
└── acceptance_index (mapping)
    └── count (integer > 0, bool rejected)
```

Missing mappings, null, bool, string, float, zero and negative values raise an
assertion failure before the subprocess result can be accepted. The real-baseline
test formats one exact expected line:

```text
check_sdd: 0 error(s), 0 warning(s), <declared-count> acceptance IDs
```

It still independently requires subprocess exit code 0. It does not accept a
count range, ignore count text or parse the subprocess output as its own expected
value.

## Authority and production reachability

Not applicable. This is an offline test reader. It has no authority/capability
surface, production composition root, provider/device dispatch point, durable job
or Artifact publication. Test fixtures cannot reach product effects.

The accepted manifest and actual subprocess output are separate producers.
`TASK-GCC-001` Allowed paths exclude both `core-conformance.yaml` and
`check_sdd.py`, so the implementation cannot change either producer in the same
PR as the comparison logic.

## Failure, compatibility, security

- malformed manifest → test failure, never default count;
- check_sdd exit nonzero → test failure regardless of summary;
- reported count differs from accepted manifest → test failure;
- current 111 and candidate 114 both work without conditional branches;
- no input/network/secret/device data is read; only tracked repository YAML and
  a local Python subprocess are used.

Rejected alternatives:

- literal `114`:moves the same double-write problem to the next baseline;
- `{111,114}` allowlist or regex count wildcard:permits stale/unknown count;
- editing CHG-2026-051 tasks after verification:retroactive scope expansion;
- changing guard/workflow:unnecessary and outside the observed defect.
