# CLI Runtime HDC tool selection

Task: TASK-AIN-021

`arkdeck runtime tool select` changes the Runtime-owned active HDC selection
from one registered `toolRef` to another. It is a current v1 target command and
accepts only typed references and concurrency identities:

```text
arkdeck runtime tool select \
  --tool tool:sha256:<digest> \
  --expected-active-generation <generation> \
  --action-request-id <id>
```

The command first creates a durable control action and immutable
`arkdeck.tool-selection-preview/1`. The preview binds the old and new tool
references, content and executable hashes, static signature facts, published
profile references, expected active generation, and the complete current HDC
impact. Its `sha256-jcs` digest excludes the retry request identity. Selection
requires the shared impact-approval HumanActionResource and an interactive
challenge; the request cannot provide approval, execution facts, a path, raw
arguments, shell text, or HDC commands.

Before entering the launch window, Runtime rereads the registered candidates,
active generation, HDC process facts, targets, Jobs, and AgentExecutions. Any
change invalidates the preview with zero dispatch. The same final interlock used
by HDC restart prevents new Jobs and target-affecting work while the accepted
lifecycle is in flight.

The bootstrap registry is the durable owner of the active selection. Its write
ahead record pins the old and new candidates before Runtime stops HDC. Runtime
then uses the existing descriptor-bound supervisor and process executor to run
the registered new executable with the fixed server lifecycle arguments. The
accepted action remains `outcomeUnknown` while the daemon exits for launchd
recomposition.

On startup the daemon resolves the pending candidate from the registry, verifies
and starts that exact retained executable and its captured sibling resources,
and only then publishes a new active-selection generation. Startup or publication
failure keeps or restores the old published tool. The pending or final outcome
remains durable until `control-action reconcile` records it and acknowledges the
registry outcome. A crash after the launch window cannot release the Job
interlock or silently choose a third tool.

The selected retained copy is the only HDC resolver used by the provider,
dispatcher, observation, trace, debug, and control paths after composition. A
configured legacy HDC path is adopted once into the same registry when no active
selection exists; it does not remain a parallel mutable preference.

This implementation does not register an SDK root, publish a new Provider or
profile, or claim real-device acceptance. Protected-main validation must exercise
the selection, approval, daemon recomposition, HDC readiness, and a subsequent
typed device operation through the Agent/CLI path.
