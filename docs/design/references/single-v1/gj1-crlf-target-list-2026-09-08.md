# GJ-1 registered CRLF target-list repair — 2026-09-08

Task: `TASK-AIN-021`. Original observation: published `0b35d535`.
The implementation is rebased onto protected main
`52319755834236dc974f03408be6cfc44ac812c5`, including the reviewed GJ-2
method-schema coverage and strict Rust schema consumer support.

The published Runtime's `device candidates` read exited 70 with
`target output line 1: target line is not the registered 5-column family; saw 1 columns`
and preview `"[Empty]\r\n"`. The original capture remains at
`/private/tmp/arkdeck-svc-a-20260908/published-0b35-readback/after/device-candidates.json`.
Its error message exactly matches an independent Swift reproduction using the
unmodified published parser and physical CRLF bytes. Literal backslash escapes
produce a different, double-escaped preview.

The existing [device-observation registry](../../../../openspec/integrations/openharmony/device-observation-probes.yaml)
registers LF and CRLF for hdc `3.2.0f`, executable SHA-256
`05b2bf7ad30201c082da336db28f8856952a2b2f49ac3404b96fdb4bf1a68f83`.
Its reviewed empty form is the nine-byte `[Empty]` marker ending in `0D 0A`;
the existing synthetic fixture has SHA-256
`c769b18b5babef2903583320036d1e507ee1e80e1386b29d098721999cd20bcf`.
The production semantic parser instead split on the Swift Character `LF`, which
does not match the single Character formed by CRLF. This also rejected ordinary
registered five-column CRLF rows. The registry tests exercised a separate
reference classifier, so their CRLF coverage did not protect this production path.

The dedicated target-list parser now recognizes exactly LF and CRLF boundaries, retaining
physical line numbers and the original terminator bytes in bounded, escaped and
redacted failure previews. Bare/residual CR, other newline forms, literal escape
sequences and malformed rows remain refusals. The five-column grammar, version
allowlist, invalid-encoding and truncation refusals remain intact; version probes
keep their original Character-LF splitting and diagnostic-prefix filtering, with
regression coverage for diagnostic noise containing other newline forms.
No registry, schema, Catalog or authority changes
are needed.

Existing consumers complete the path without new production branches:
`ProviderBootstrapObservation` reads the verified zero count, the target
coordinator publishes `health: current` with no observations, and Agent execution
publishes its owned `connectDevice` HAR. Regression coverage uses the existing
registered fixtures through the production provider, Bootstrap adapter, daemon
and CLI. It checks discovery, both resume surfaces, an intervening literal-escape
refusal and the same pending HAR afterward. Only explicit enumeration probes may
run; no target, Job, capability or operation dispatch may be created while no
candidate exists.

The required unified gate passed after rebase:

```sh
ARKDECK_TEST_WORKERS=2 python3 scripts/ci/plan.py \
  --repo-root . --base-revision origin/main --head-revision HEAD \
  --merge-base --include-worktree --run-local
```

It completed 2,492 Swift tests, 83 design-system tests and App
`build-for-testing`, together with the selected common checks. An earlier
eight-worker run failed two existing main tests; both passed in a focused rerun
before the complete two-worker gate passed. No test assertions were changed.

After every recorder stopped, the independent
`ControlMethodSchemaContractTests/testFramesRecordedByThisRunValidate` check
passed. Standard `jsonschema.Draft202012Validator` validation also passed all
1,365 completed handler frames with zero failures. Local validation logs are
`handoff-gj1-final-unified-gate.log`, `handoff-gj1-final-frame-validator.log` and
`handoff-gj1-standard-schema-validation.json` under the parent run's evidence
directory.

This development repair does not claim hardware acceptance or alter the original
unknown Job records. Published Runtime acceptance must be repeated after review
and merge.
