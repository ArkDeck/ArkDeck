# Linux CI runner pool

The lightweight `plan`, `guard`, `swift` aggregate and Agent PR jobs share
`vars.ARKDECK_LINUX_LIGHT_RUNNER`. An unset variable selects `ubuntu-latest`.
The Rust workspace, contract, macOS and Windows build lanes retain their
existing runners. Required check names, permissions and failure checks remain
unchanged. This is CI infrastructure, not a Device Runtime execution surface.

## Deployment profile

Prepare two isolated Linux x64 VM slots on the operator-selected host/provider.
Start each job in a fresh guest and destroy its disk and registration after the
job ends. Replenish the two slots from a clean image. GitHub's `ephemeral` runner
flag limits registration to one job; it does **not** make the VM or filesystem
disposable by itself. A host must support this lifecycle before activation.

- Use a repository-scoped registration for `ArkDeck/ArkDeck`, with labels
  `self-hosted`, `Linux`, `X64`, `arkdeck-linux-light`.
- Give every guest a unique name beginning `arkdeck-linux-light-`; keep host
  addresses, account names and credentials out of runner names and repository
  records.
- Keep provisioning and GitHub runner administration credentials outside job
  guests. Do not mount host homes, Docker/libvirt sockets, SSH keys, source
  workspaces or persistent work directories into guests.
- Deny guest access to the host management network and cloud metadata. Do not
  attach USB/device transports. Forward runner service logs to the operator's
  local storage and redact secrets before sharing.
- The clean image needs Git, Python 3.12+, Node.js 24 with npm, GitHub CLI and
  the Linux dependencies of the current supported Actions runner. It must reach
  GitHub, the npm registry and the Python package index for the existing checks.
  The runner's internal Node runtime does not replace the Node binary used by
  `node`/`npm` workflow steps.
- Register using GitHub's just-in-time configuration or `--ephemeral`. The
  provisioner retains no job-modified image. Refresh images and runner versions
  before GitHub's version support deadline.

Use the [official self-hosted runner API](https://docs.github.com/en/rest/actions/self-hosted-runners)
and [ephemeral lifecycle guidance](https://docs.github.com/en/actions/reference/runners/self-hosted-runners#ephemeral-runners-for-autoscaling).
Creating a VM/container controller does not by itself verify isolation or
deployment. The actual host, network boundary and guest replacement must be
tested before production routing is enabled.

## Activation and rollback

Run from an operator environment with existing GitHub repository administration
authentication. No administration token belongs in the workflow, repository, CLI argument or
run record; the operator's administration credential stays outside job guests.

```sh
python3 scripts/ci/linux_runner_pool.py status
python3 scripts/ci/linux_runner_pool.py smoke --ref main
python3 scripts/ci/linux_runner_pool.py activate
python3 scripts/ci/linux_runner_pool.py deactivate
```

`activate` requires complete API pages, the latest smoke to be a successful two-guest concurrent run
on the current protected-main commit, and at least two fresh online, idle,
ephemeral Linux x64 registrations replacing the consumed ones. Any matching
persistent/unmanaged runner or missing ephemeral fact rejects the switch. The command then writes only the
repository routing variable and verifies it. An unrelated existing route is
preserved. A failed read-back restores the previous value when the API still
shows this command's own write; a concurrent operator's value is preserved.

`deactivate` explicitly selects `ubuntu-latest`, even when the pool is offline.
The workload is not automatically transferred between pools while queued or
running. A routing change affects subsequently evaluated jobs; it does not
duplicate, replay or cancel a job. If an already queued job needs a rerun, first
confirm the old run's terminal state and keep the exact commit.

After the reviewed smoke workflow is available on protected `main`, `smoke`
checks capacity and dispatches two parallel guest jobs while the production
route remains hosted. Before activating, check both jobs' exact commit and
results, and verify that consumed guest IDs
disappear and two fresh guest IDs become online. API availability alone proves
neither successful checks nor VM cleanup. Fixtures in
`scripts/ci/test_linux_runner_pool.py` prove only activation logic.

## Current rollout

Workflow routing and activation checks can be reviewed before machines exist;
the unset variable keeps hosted CI working during that review. Provisioning and
the real concurrent/lifecycle checks require the operator to select a host or
cloud project. Do not pick a host merely because it appears in SSH configuration,
or register a developer workstation as a public-repository runner.
