# ArkDeck UI reference images

Latest: [v1.6 follow-up design and native App references](v1.6-followup/README.md).
The [initial v1.6 audit references](v1.6/README.md) remain a historical snapshot.

Checked-in UI reference images are the review companion to
`docs/design/prototype.html`. Every user-visible interaction change updates the affected
prototype page and state plus its Simplified Chinese and English images in the same PR.

- Capture the prototype with `reference=1`, an explicit `page`, `lang`, and every state
  parameter needed to reproduce the reviewed surface.
- Prefer 1180×760 for the primary browser baseline. Supplemental captures must record
  their actual viewport and scroll position; never relabel or resize them to imply pixel
  parity. The follow-up uses 1280×720 around the fixed 1180×760 reference window.
  Capture without browser chrome and store images under the current version directory.
- Keep the prototype's demo-data disclosure visible. These images review layout, copy,
  and state only; they are not App screenshots, Runtime output, or hardware evidence.
- Record the exact URLs and image names in the version directory's README so the next
  interaction change can regenerate the same states instead of relying on browser memory.
- Keep native App test attachments separate from browser demos, preserving original
  bytes and recording test identifiers, hashes, and fixture/hardware classification.

Existing version directories remain historical references. Do not rewrite an older
baseline when a newer design version owns the changed surface.
