# Arguments redaction cannot satisfy — 2026-09-09

A closing record for a residual named in
`docs/design/references/single-v1/svc-acceptance-2026-09-09-published-main.md`,
which said twenty-one argument keys have character-constrained validators and no
redaction rule, and that **no real occurrence had been demonstrated**. That
framing was too weak in one direction and too alarming in the other. This
settles both halves with evidence.

## The premise is real, on ordinary host data

The export builds its device-identifier set from `originalTarget.connectKey`,
`identitySnapshot` and `bindingHistory`, taking **every string value** it finds.
On the reference host's published Session, read from the on-disk manifest:

```json
"identitySnapshot": {
  "catalogDigest": "508783acdf9e9b13d2d4a969e7e26f6fd60094a39d1cc9e02d2198e02ea13684",
  "providerId": "workspace",
  "workspaceScope": "project-fd677365f7bdefabda66a3c1"
}
```

So the set really does contain the bare word `workspace` — nine bytes, an
ordinary English word that appears in paths, provider operation ids and template
references — and the substring matcher fires at four bytes
(`minimumSubstringIdentifierBytes = 4`). This is not a contrived collision; it is
the normal shape of a host-scope Session produced by the workspace provider.

That host's own export was not corrupted: it contains zero `[R]` substitutions,
because no field in that one manifest happened to contain `workspace` as a
substring. Four exact-match replacements are present and all land in unconstrained
free-text fields. So the mechanism is live and this Session simply did not meet
it.

## What happens when a constrained field does collide

Not silent corruption. The export refuses before it touches the destination, and
names the argument.

`runApprovedRemoteRead` requires `catalogId` to be exactly
`arkdeck-remote-operations` — a closed constant, for which no replacement can be
correct. With a provider identity of `remote`, shaped exactly like the host's
`providerId: "workspace"`:

- the export throws, and the failure names `catalogId`
- the destination is not created

Negative control: the identical fixture with a non-colliding identity
(`zzzzserial`) exports successfully. The refusal is caused by the collision, not
by the fixture.

## Why this is a closed residual rather than an open defect

The failure mode that mattered was the one #1799 fixed: redaction producing a
document the exporter's own validation then refused, surfacing as
`outcomeUnknown` / "requires destination inspection" with the cause buried. For
these remaining keys the refusal is now:

- **fail-closed** — it happens before publication, so no partial or corrupted
  export is ever written, and the source Session is untouched
- **diagnosable** — #1800 classifies a pre-publication refusal as
  `recordUnreadable` naming the cause, and returns the preview to `ready`, so the
  operator sees which argument could not be redacted and can retry the same tuple

What remains is a policy question, not a correctness one: whether such a Session
*should* be exportable. Making it so means deciding, per validator family, what a
redacted value may look like — and for a closed enumeration or constant the
honest answer is that no redaction is correct, so a refusal is the right
behaviour rather than a gap. A separate question worth asking is whether a
host-scope target should contribute a device-identifier set at all: `providerId`
and `catalogDigest` are not device identity, and the digest is published in every
`doctor` output.

Neither question is settled here, and no redaction rule is added. The test added
with this record pins the behaviour that matters — refuse, name the argument,
write nothing — so a future change to that policy cannot silently become
corruption instead.
