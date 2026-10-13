# Published Windows MSIX and packaged probe — 2026-10-13

## Result and source

After maintainer merge of #2634 and #2635, the clean protected-main source
`db53c65dee316f58bf95746595f4ba9fb68d8a7d` produced and signed a fresh MSIX
through the official RC producer. The actual registered package passed
`InstalledRcTests` and `InstalledCaptureTests`: **5/5, zero skips, 90 seconds**.
The App's exact process package identity was checked, and the English/Chinese
Diagnostics/Trace and screenshot/tree readbacks used the real account Runtime.

The final `ArkDeck.App_0.1.0.0_x64.msix` is 73,669,853 bytes, SHA-256
`b4d20dc4fff734fbf72156c3812f114353ff7b8496a2314bb8381880ebdb19b8`.
Its source is clean, signature valid, publisher equal to the existing development
certificate, and write virtualization disabled. Packaged daemon and CLI hashes
match the final manifest. The matching MSIX App/CLI/daemon were used for this run.

The original signed xcopy installation was restored afterward. Published health,
service status and full Job readback all succeeded; all **57 complete Job items**
matched the pre-run inventory. The test MSIX was removed.

## SPK-3 packaged-client row

The unchanged published SPK-3 probe from
`caec3e7f77a9bfd3c2f15e39e9716385987ae568`, executable SHA-256
`95ba5316f85f2f80e56164bc6a92cd33eaf2d4122106f99e4a6b512b08566eaf`,
was signed, packaged and registered as a separate probe. Against the original
published xcopy Runtime, client-side server authentication passed: native server
PID matched the installed Runtime, actual client package family matched the
registered family, and zero control frames were sent. The Runtime instance
record stayed byte-for-byte unchanged and the probe package was removed.

This closes that packaged-client observation only. It does not prove a full
mixed MSIX/xcopy control exchange. The earlier real-App mixed-installation
failure remains distinct; the
[peer image access repair](../TASK-XPA-002/windows-packaged-peer-locks-20261013-run.md)
is a separate candidate increment. Second-account, elevated-client and
remote-host observations remain absent.

## Trust lifecycle and limits

The current-user TrustedPeople attempt retained Windows' `0x800B0109` refusal
and removed its newly added entry. With the user's existing authorization and
fresh UAC confirmation, the exact same public certificate was temporarily added
to `LocalMachine/TrustedPeople` from **11:11:50 to 11:30:37 UTC**. The guarded
helper recorded addition and removal, no error, and an independent 30-minute
cleanup deadline. No certificate was generated and no private key was exported.

After cleanup, neither temporary TrustedPeople entry nor either test package
remained. The original CurrentUser Root trust was preserved. This is existing-host
development signing and installation; it does not supply production signing,
a clean host, an App Installer feed or a same-publisher higher-version update.
No device operation or hardware acceptance claim is added by this run.

## Local targeted checks

Raw logs remain under `D:/temp/arkdeck-windows-acceptance-20261013` outside Git.

- Released producer and private RC smoke: exit 0; `package-msix-released.log`,
  `rc-msix-released/rc-manifest.json` and `smoke.json`.
- Normal MSIX registration with final hash/signature checks: exit 0;
  `rc-msix-released/installed-registration.json`.
- Real installed App UIA: exit 0, 5/5; `uia-msix-released.log` and
  `uia-msix-released/installed-msix-released.trx`.
- Published packaged doctor/status and original restoration: exit 0;
  `raw-msix-released-smoke`, `raw-msix-released-stop`,
  `raw-msix-released-restore` and `msix-released-final.log`.
- Unregistration: exit 0; `rc-msix-released/installed-cleanup.json`.
- Packaged zero-frame probe: exit 0;
  `packaged-probe-validated/summary.json`, `cleanup.json` and
  `packaged-probe-final.log`.
- Complete workflow: `msix-final-run.json`; exact trust lifecycle:
  `msix-final-trust/msix-trust-lifecycle.json`. The failed narrower trust
  attempt is retained under `current-user-trust-probe`.

## CI

The released packaging repair #2634 passed Swift CI `38378925063` and SDD
Guard `38378924891`; its follow-up #2635 passed Swift CI `38381987342`, SDD
Guard `38381987285` and final body guard `38382482537`. Both were merged by the
maintainer before this fresh package build. The adjacent peer-authentication
repair reports its own CI; these released observations do not approve it.
