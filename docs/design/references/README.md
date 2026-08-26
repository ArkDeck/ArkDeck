# ArkDeck UI reference images

Checked-in UI reference images are the review companion to
`docs/design/prototype.html`. Every user-visible interaction change updates the affected
prototype page and state plus its Simplified Chinese and English images in the same PR.

- Capture the prototype with `reference=1`, an explicit `page`, `lang`, and every state
  parameter needed to reproduce the reviewed surface.
- Use a browser viewport of exactly 1180×760 and capture the viewport without browser
  chrome. Store new images under the current design-version directory.
- Keep the prototype's demo-data disclosure visible. These images review layout, copy,
  and state only; they are not App screenshots, Runtime output, or hardware evidence.
- Record the exact URLs and image names in the version directory's README so the next
  interaction change can regenerate the same states instead of relying on browser memory.

Existing version directories remain historical references. Do not rewrite an older
baseline when a newer design version owns the changed surface.
