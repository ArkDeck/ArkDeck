# TASK-XPA-007 — SPK-4 prerequisites crib, 2026-09-30

What the maintainer installs before SPK-4 (WinUI 3 vs WPF, design §H.4) and TASK-XPA-007 can start,
and what the Windows 11 x64 reference host already has. This is a preparation note, not the SPK-4
run record (`spk-4-run.md` comes later, r11 naming): nothing was installed, no license was accepted,
nothing was elevated, no registry or system setting was changed, and SPK-4 was not run. The host
inventory below is from read-only queries (`vswhere`, directory listings, `reg query`,
`Get-AppxPackage`, `winget list/show/search`).

Governing text: `docs/design/cross-platform/windows-phase-agent-prompt.md` WM5 ("list the Visual
Studio workloads and the Windows App SDK for the maintainer first") and §1.1 (only the maintainer
installs, elevates and accepts licenses); design §H.4 (criteria (a)–(e)), §H.5, §H.6, §L.2;
`tasks.md` SPK-4 row and TASK-XPA-007; `verification.md` Environment (.NET 10 LTS, Windows App SDK
2.x stable); proposal r12 decision 10 (MSIX packaged + self-contained Windows App SDK).

## 1. Summary

- **Already on the host:** Developer Mode on; Windows 11 SDK 10.0.26100 with `makeappx`, `signtool`,
  `makepri`, `inspect.exe`, `accevent.exe` (x64 and arm64 tool folders); VS 2022 Build Tools 17.14
  with C++ (VCTools, used by the Rust lane); inbox `wpr.exe` and Narrator; Windows App Runtime 2.5.1
  (x64/x86) framework packages, pulled in by other apps; App Installer (winget 1.29).
- **Missing and required for SPK-4:** the .NET 10 SDK (no `dotnet` at all), the WinUI project
  templates, the `winapp` CLI, a local development code-signing certificate, a clean install target
  (Windows Sandbox is not enabled) and an ARM64 Windows 11 host for criterion (d).
- **Recommended, not strictly required:** Visual Studio 2026 with the WinUI and .NET desktop
  workloads (debugger, XAML Hot Reload, profiler). The command-line path (`dotnet new winui`,
  `dotnet build/run/publish`) is officially supported without the IDE; §H.5 still requires the
  Windows SDK and native tools, which the host has.
- **Minimum to unblock a first build:** checklist steps 1–4 below (about 1 GB on C:, one UAC prompt).

## 2. Current host inventory (read-only, 2026-09-30)

| Item | Found | Relevance |
| --- | --- | --- |
| OS | Windows 11 Pro 10.0.26200 x64 | SPK-4 x64 reference host; Pro edition allows Windows Sandbox |
| Disk | C: 400 GB, 144 GB free; D: 554 GB, 494 GB free | C: kept lean by policy; toolchains, caches and builds go to D: |
| Visual Studio instances (`vswhere -all -prerelease -products *`) | VS Build Tools 2022 17.14.41 (`17.14.37710.0`, complete) — workloads `VCTools`, `MSBuildTools`; components include `VC.Tools.x86.x64`, `Windows11SDK.26100`, `VC.CMake.Project`, `Vcpkg`, `VC.ASAN`. VS Build Tools 2019 16.11.50 — **incomplete** (`isComplete: false`, `state: 5`), MSBuild only | No .NET desktop, WinUI or MSIX components in any instance; no ARM64 MSVC tools. VS 2022 stays for Rust; VS 2019 is not needed |
| Visual Studio 2026 (v18) | not installed | Microsoft's WinUI quickstart names VS 2026 |
| .NET | `command -v dotnet` empty; no `C:\Program Files\dotnet`; no NuGet cache in the profile. Only the legacy UWP ".NET Native" 2.2 framework packages | .NET 10 SDK missing |
| Windows SDK | `Windows Kits\10\Lib` and `Include`: `10.0.26100.0` only (winget: Windows SDK 10.0.26100.7705); `Lib\...\um` and `ucrt` have x86/x64/arm64 | Matches `net10.0-windows10.0.26100.0`; arm64 import libs present |
| MSIX / signing tools | `bin\10.0.26100.0\x64` and `\arm64`: `makeappx.exe`, `makepri.exe`, `signtool.exe`; `MakeCert.exe`; App Certification Kit present | Packaging and signing available without VS |
| UIA tools | `bin\10.0.26100.0\x64\inspect.exe`, `accevent.exe` present; WinAppDriver not installed; Accessibility Insights not installed; `winapp` CLI not installed | (c), (e) |
| Developer Mode | `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock` `AllowDevelopmentWithoutDevLicense = 0x1` | **On** — needed for `dotnet run` debug identity and loose-file deployment |
| Windows App Runtime (`Get-AppxPackage Microsoft.WindowsAppRuntime*`) | `Microsoft.WindowsAppRuntime.2` 2.2.0, 2.3.1, 2.4.0, 2.5.1 (x64; 2.5.1 also x86); 1.4–1.8 families | Installed by other apps. Irrelevant to the self-contained MSIX of decision 10, and it makes this host **not** a clean host for (d) |
| Performance / screen reader | `C:\Windows\System32\wpr.exe`, `narrator.exe` present; Windows Performance Toolkit (WPA) absent | (a), (b), (c) |
| Clean install target | `WindowsSandbox.exe` absent (feature not enabled) | (d) needs a clean host |
| ARM64 host | none known | (d) ARM64 install cannot run here |

## 3. Install list

Current versions as of 2026-09-30 (sources in §7). "UAC" = needs the maintainer's elevation;
"License" = the maintainer accepts it (winget `--accept-package-agreements` counts as acceptance).
Sizes are approximate: the VS Installer shows the exact total before it installs.

| # | Item | Official ID / version | UAC | License | Disk (approx.) | Location | Why ((a)–(e) of §H.4) |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | .NET 10 SDK | winget `Microsoft.DotNet.SDK.10`, 10.0.401 (runtime 10.0.12, 2026-09-08; LTS to 2028-11-14) | yes (machine MSI/burn) | MIT | ~1 GB | `C:\Program Files\dotnet` (fixed for the installer) | All: builds WinUI 3 and the WPF fallback (.NET 10 Fluent theme), `dotnet publish` of self-contained MSIX, ClientKit. `verification.md` pins .NET 10 LTS |
| 2 | NuGet package cache on D: | user env var `NUGET_PACKAGES=D:\nuget\packages` | no | — | 1–3 GB over time, on D: | D: | Keeps Windows App SDK/.NET runtime packs (hundreds of MB per version) off C: |
| 3 | WinUI C# project templates for `dotnet new` | NuGet `Microsoft.WindowsAppSDK.WinUI.CSharp.Templates` (latest listed 0.0.7-alpha) | no | NuGet package license | < 10 MB (NuGet cache) | D: via #2 | Scaffold used by Microsoft's CLI quickstart (`dotnet new winui`) |
| 4 | Windows App SDK | NuGet `Microsoft.WindowsAppSDK` **2.5.1** (stable, 2026-09-16), restored per project; `WindowsAppSDKSelfContained=true` | no (NuGet restore) | NuGet package license | ~0.5–1 GB per version in the cache | D: via #2 | (a), (b), (d): the thing under test; self-contained per decision 10. No runtime installer needed for the MSIX path |
| 5 | Windows App Development CLI (`winapp`) | winget `Microsoft.WinAppCli` 0.7.0 (MSIX) | expected no (per-user MSIX); confirm at install | MIT | < 100 MB | per-user package store on C: | (c), (e): `winapp ui inspect/search/screenshot/invoke` candidate UIA runner (§H.6); the template's `Microsoft.Windows.SDK.BuildTools.WinApp` also uses it for `dotnet run` identity |
| 6 | Development code-signing certificate, trusted on this host only | self-signed, subject = the MSIX `Publisher`; created with `New-SelfSignedCertificate`, private key stays in the maintainer's `CurrentUser\My`, public cert imported into `LocalMachine\TrustedPeople` | yes (import into LocalMachine) | — | negligible | cert stores | (d): an MSIX must be signed to install; also r12 ruling 8 (dev daemon identity). §1.1: certificate creation and trust are maintainer-only |
| 7 | Windows Sandbox (clean x64 host) | optional feature `Containers-DisposableClientVM` | yes, plus reboot | Windows license (already) | ~1 GB on C:, runtime is disposable | C: | (d): "installs on a clean host" — this host already carries Windows App Runtime 2.x, so installing here does not prove self-containment. A clean Windows 11 VM is an equivalent alternative |
| 8 | ARM64 Windows 11 host (hardware or VM) | — | maintainer | — | — | — | (d) ARM64 build **and** install. The x64 host can build ARM64 (managed code + arm64 SDK libs present) but cannot install/launch it |
| 9 | Visual Studio 2026 (recommended) | winget `Microsoft.VisualStudio.Community` 18.10.3 **or** `Microsoft.VisualStudio.BuildTools` 18.10.2; workloads below | yes | Proprietary (Community: individuals, open-source and small teams; maintainer decides) | Community with the two workloads ~10–20 GB; Build Tools ~5–10 GB; several GB always land in the shared/cache folders on C: | `--installPath D:\VS\2026\...` | Debugger, XAML Hot Reload, .NET profiler (helps diagnose (a)/(b) failures); "WinUI application development" workload is what Microsoft's VS quickstart asks for |
| 10 | Accessibility Insights for Windows (optional) | not in the winget source; MSI from accessibilityinsights.io | yes | MIT | ~100 MB | C: | (c), (e): FastPass/automated UIA checks as a second opinion to `inspect.exe` |
| 11 | WinAppDriver (optional, fallback only) | winget `Microsoft.WindowsApplicationDriver` 1.2.1.0 | yes (MSI) | Microsoft license | ~10 MB | C: | §H.6 names it as the existing candidate; 1.2.1 is old (no newer release in winget). Install only if `winapp ui` fails SPK-4's runner evaluation |
| 12 | Windows Performance Analyzer (optional) | Windows ADK "Windows Performance Toolkit" | yes | Microsoft license | ~0.5 GB | C: | Viewing `wpr.exe` traces for (a)/(b) cross-checks; the primary numbers come from in-app timestamps |

Visual Studio 2026 workload and component IDs (channel `VisualStudio.18.Release`):

| Product | IDs | Note |
| --- | --- | --- |
| Community (IDE) | `Microsoft.VisualStudio.Workload.ManagedDesktop`, `Microsoft.VisualStudio.Workload.Universal` ("WinUI application development"), `Microsoft.VisualStudio.ComponentGroup.WindowsAppSDK.Cs` ("Windows App SDK C# Templates") | Exactly the set in Microsoft's `winui-config.winget` (the file behind `winget configure -f https://aka.ms/winui-config`) |
| Build Tools (no IDE) | `Microsoft.VisualStudio.Workload.ManagedDesktopBuildTools`, `Microsoft.VisualStudio.Workload.UniversalBuildTools` (requires `Microsoft.VisualStudio.ComponentGroup.UWP.BuildTools` ".NET WinUI app development build tools", `Microsoft.NetCore.Component.SDK`, `Microsoft.NetCore.Component.Runtime.10.0`) | MSBuild-only alternative for CI-like builds |
| Optional in either | `Microsoft.VisualStudio.Component.Windows11SDK.26100` (already on host via VS 2022), `Microsoft.ComponentGroup.MSIX.Packaging` ("MSIX Packaging Tools", in the VS 2022 list; confirm the ID in the 2026 installer) | Do **not** add `Microsoft.VisualStudio.Component.VC.Tools.ARM64` or other VC tools to the 2026 instance unless needed: Rust's `cc`/linker discovery picks the newest VS instance with VC tools, which would silently move the Rust lane off the VS 2022 toolset W0 measured |

Not needed: the Windows App SDK runtime installer (`WindowsAppRuntimeInstall-x64.exe`) — only for
framework-dependent or unpackaged apps, not decision 10; the VS 2019 Build Tools (incomplete; the
maintainer may repair or remove it at leisure); another Windows SDK (10.0.26100 is present).

## 4. Maintainer checklist

Run in a **non-elevated** Windows Terminal unless a step says elevated; winget prompts UAC itself for
machine installers. `winget` is reached through the WindowsApps alias (see the W0 record).

1. NuGet and .NET CLI caches on D: (user scope, no UAC):

   ```powershell
   setx NUGET_PACKAGES D:\nuget\packages
   setx DOTNET_CLI_TELEMETRY_OPTOUT 1
   ```

2. .NET 10 SDK (UAC; license MIT):

   ```powershell
   winget install --id Microsoft.DotNet.SDK.10 --exact --source winget --accept-package-agreements --accept-source-agreements
   ```

3. Open a new terminal, then check and add the WinUI templates (no UAC):

   ```powershell
   dotnet --list-sdks
   dotnet new install Microsoft.WindowsAppSDK.WinUI.CSharp.Templates
   dotnet new list winui
   ```

4. `winapp` CLI (MSIX; license MIT):

   ```powershell
   winget install --id Microsoft.WinAppCli --exact --source winget --accept-package-agreements --accept-source-agreements
   winapp --version
   ```

5. Visual Studio 2026 on D: (recommended; UAC; proprietary license). IDE:

   ```powershell
   winget install --id Microsoft.VisualStudio.Community --exact --source winget --accept-package-agreements --accept-source-agreements --override "--installPath D:\VS\2026\Community --add Microsoft.VisualStudio.Workload.ManagedDesktop --add Microsoft.VisualStudio.Workload.Universal --add Microsoft.VisualStudio.ComponentGroup.WindowsAppSDK.Cs --includeRecommended --passive --wait"
   ```

   or, without the IDE:

   ```powershell
   winget install --id Microsoft.VisualStudio.BuildTools --exact --source winget --accept-package-agreements --accept-source-agreements --override "--installPath D:\VS\2026\BuildTools --add Microsoft.VisualStudio.Workload.ManagedDesktopBuildTools --add Microsoft.VisualStudio.Workload.UniversalBuildTools --includeRecommended --passive --wait"
   ```

   The shared-components and package-cache folders were fixed by the first VS install on this
   machine and cannot be moved by these commands; expect a few GB on C: regardless. Microsoft's
   `winget configure -f https://aka.ms/winui-config` does the same workloads plus Developer Mode
   (already on) but installs to the default path on C:.

6. Development code-signing certificate (maintainer only, §1.1). Non-elevated, create the key in the
   user store and export the public part; the subject must equal the MSIX `Publisher` SPK-4 will use
   (proposed `CN=ArkDeck Development`, see §6):

   ```powershell
   New-SelfSignedCertificate -Type CodeSigningCert -Subject "CN=ArkDeck Development" -KeyUsage DigitalSignature -CertStoreLocation Cert:\CurrentUser\My -NotAfter (Get-Date).AddYears(1) -TextExtension @("2.5.29.19={text}")
   ```

   Then, **elevated**, trust only the public certificate on this host (replace the thumbprint):

   ```powershell
   Export-Certificate -Cert Cert:\CurrentUser\My\<THUMBPRINT> -FilePath D:\certs\arkdeck-dev.cer
   Import-Certificate -FilePath D:\certs\arkdeck-dev.cer -CertStoreLocation Cert:\LocalMachine\TrustedPeople
   ```

   Tell the agent the thumbprint (not the key). The agent signs with
   `signtool sign /fd SHA256 /sha1 <THUMBPRINT> ...`; it never exports the private key.

7. Clean x64 install target, elevated, then reboot:

   ```powershell
   Enable-WindowsOptionalFeature -Online -FeatureName Containers-DisposableClientVM -All
   ```

   (Or provide a clean Windows 11 x64 VM snapshot instead.)

8. ARM64: say which Windows 11 ARM64 machine or VM SPK-4 may use for (d), and how the agent reaches
   it (or whether the maintainer runs the install step there by hand).

9. Optional: Accessibility Insights for Windows (MSI from <https://accessibilityinsights.io/downloads/>,
   UAC); WinAppDriver only if later requested
   (`winget install --id Microsoft.WindowsApplicationDriver --exact --source winget`); Windows
   Performance Toolkit from the Windows ADK.

10. Restart Claude Code from a fresh terminal so the session inherits `NUGET_PACKAGES` and the new
    `PATH` (W0 lesson), and tell the agent which steps were done.

## 5. What SPK-4 will measure, and how (not run)

Common frame: a fixture-only WinUI 3 shell (C#, .NET 10, Windows App SDK 2.5.1 self-contained,
MSIX packaged), release configuration, x64 and ARM64, on the reference host; no daemon or device
(§H.5: fixture pages only prove presentation). Each run records: source revision, `dotnet --info`,
SDK/template/`winapp` versions, `Microsoft.WindowsAppSDK` version, build mode (self-contained,
packaged, AOT or not), host, graphics session, and the raw numbers. The same harness then runs
against a WPF (.NET 10 Fluent) shell only if a criterion fails and cannot be fixed within the two
weeks (`tasks.md` SPK-4 row).

| Criterion (§H.4) | Fail if | Method |
| --- | --- | --- |
| (a) List virtualisation | p95 frame time > 33 ms while scrolling 10k-row History and Viewer lists | `ItemsView`/`ListView` bound to a 10,000-row fixture; scripted scroll (UIA `ScrollPattern` via the runner) for a fixed duration; per-frame timestamps from `CompositionTarget.Rendering` written to a file; ≥ 5 runs, p50/p95/max; `wpr.exe` trace kept as cross-check |
| (b) Cold start | launch to interactive > 2 s, release build, reference host | installed MSIX, first launch after reboot (and after sign-out as a second series); t0 = process creation, t1 = first navigation item exposed by UIA as enabled (plus an in-app "first frame + data bound" mark); ≥ 10 runs, median and p95 |
| (c) UIA/Narrator | navigation items or Job-state changes cannot be read | `winapp ui inspect`/`search` (and `inspect.exe`) show one invokable element with stable `AutomationProperties.AutomationId` and name per fixed navigation item; `accevent.exe` observes the `LiveRegionChanged` event when a fixture Job changes state (`AutomationProperties.LiveSetting`); the maintainer confirms by ear with Narrator once (graphics session, cannot be automated) |
| (d) ARM64 and clean-host install | ARM64 build fails, or the self-contained MSIX fails to install/launch on a clean host | `dotnet publish -r win-x64` and `-r win-arm64` with `WindowsAppSDKSelfContained=true`, signed with the dev cert; `Add-AppxPackage` in Windows Sandbox (x64, cert imported inside the sandbox) and on the ARM64 host; pass = installs, launches, UIA tree appears, uninstalls cleanly |
| (e) High contrast and text scaling | main-flow layout breaks | Contrast themes on, text size 225 %; UIA snapshot + screenshots of each surface's primary flow; fail on clipped/overlapping primary controls, lost focus path, or state conveyed by colour only (AC-UX-005-01) |

Also decided in SPK-4 (from §H.5/§H.6 and §L.2): whether `winapp ui` or WinAppDriver is the UI runner
(capabilities, error returns, waiting, process cleanup); which Windows App SDK 2.x / .NET 10 / NativeAOT
combination builds (L.2 row); and the committed toolchain pin and repro steps for `windows/**`.

## 6. Open questions for the maintainer

1. VS 2026 Community (IDE) or Build Tools, or neither for now (CLI only)? The spike can start on
   steps 1–4 alone.
2. MSIX `Publisher`/certificate subject for development: `CN=ArkDeck Development` is a proposal; the
   production subject comes from Azure Artifact Signing (decision 10) and is out of scope here.
3. Where is the ARM64 Windows 11 host for (d), and who runs the install there?
4. Clean x64 target: Windows Sandbox on this host, or a VM snapshot?
5. The only `dotnet new` WinUI template package is `0.0.7-alpha`. Accept it for the spike (the
   generated project is committed and reviewed anyway), or scaffold from the VS 2026 templates?
6. Windows App SDK pin: 2.5.1 (current stable, 2026-09-16) instead of the 2.4.0 snapshot in §H.4 —
   the design says to record the actual version SPK-4 used, so no design edit is needed now.
7. Location of the spike projects in the repo (under `windows/**`, which TASK-XPA-007 owns, or kept
   out of tree with only the run record committed).

## 7. Sources (accessed 2026-09-30)

- Windows App SDK downloads (stable 2.5.1 of 2026-09-16; 2.4.0 of 2026-08-13):
  <https://learn.microsoft.com/en-us/windows/apps/windows-app-sdk/downloads>
- WinUI 3 quickstart (VS 2026 + "WinUI application development" workload + Developer Mode; CLI path
  with .NET 10 SDK, `dotnet new install Microsoft.WindowsAppSDK.WinUI.CSharp.Templates`,
  `Microsoft.Windows.SDK.BuildTools.WinApp`): <https://learn.microsoft.com/en-us/windows/apps/get-started/start-here>
- WinGet configuration behind `https://aka.ms/winui-config` (workload IDs, channel
  `VisualStudio.18.Release`):
  <https://github.com/microsoft/winget-dsc/blob/main/samples/Configuration%20files/Learn%20tutorials/WinUI/winui-config.winget>
- VS Build Tools 2026 workload and component IDs:
  <https://learn.microsoft.com/en-us/visualstudio/install/workload-component-id-vs-build-tools>
- VS Community workload and component IDs (page served the 2022 list; used for
  `Microsoft.ComponentGroup.MSIX.Packaging` and ARM64 component names):
  <https://learn.microsoft.com/en-us/visualstudio/install/workload-component-id-vs-community>
- .NET 10 release metadata (10.0.12 / SDK 10.0.401, 2026-09-08, EOL 2028-11-14):
  <https://dotnetcli.blob.core.windows.net/dotnet/release-metadata/10.0/releases.json>
- NuGet versions: <https://www.nuget.org/packages/Microsoft.WindowsAppSDK/>,
  <https://www.nuget.org/packages/Microsoft.WindowsAppSDK.WinUI.CSharp.Templates/>
- `winapp ui` commands and CI note (graphics session required):
  <https://learn.microsoft.com/en-us/windows/apps/develop/ai-assisted/testing>
- Windows App SDK deployment architecture (self-contained vs framework-dependent):
  <https://learn.microsoft.com/en-us/windows/apps/windows-app-sdk/deployment-architecture>
- winget package metadata read with `winget show --id <ID> --exact --source winget` on the host:
  `Microsoft.DotNet.SDK.10` 10.0.401 (MIT), `Microsoft.VisualStudio.Community` 18.10.3,
  `Microsoft.VisualStudio.BuildTools` 18.10.2 (proprietary), `Microsoft.WinAppCli` 0.7.0 (MIT),
  `Microsoft.WindowsApplicationDriver` 1.2.1.0; Accessibility Insights is not in the winget source.
