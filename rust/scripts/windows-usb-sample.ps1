#requires -Version 7.2
<#
Maintainer-run sample of the USB device properties Windows exposes for a DAYU200, for the
Windows trusted USB relations of TASK-XPA-004 (the counterpart of the macOS I/O Registry
census `arkdeck_platform::usb_registry`: idVendor, idProduct, locationID, serial, product
name, registry entry ID). The agent never runs this. The crib is
openspec/changes/chg-2026-074-shared-rust-runtime-core/evidence/runs/TASK-XPA-004/dayu200-usb-properties-crib-20260930.md.

It only reads the PnP tree (Get-PnpDevice / Get-PnpDeviceProperty, i.e. the SetupAPI/CfgMgr32
device properties). It opens no device, sends no USB request, starts no HDC, and installs,
enables, disables or changes no driver or device.

Each run records every PRESENT node whose instance ID starts with USB\ (devices, interfaces,
hubs, root hubs) with all its properties and their types, plus every node, present or not,
whose instance ID carries VID_2207 (Rockchip, the DAYU200's vendor). Phases, in this order,
same -OutputDirectory root:
  before     DAYU200 unplugged
  after      DAYU200 plugged in, booted to its normal (HDC) personality
  removed    optional: DAYU200 unplugged again
  replugged  optional: DAYU200 plugged into the SAME port again
Raw output stays outside any git work tree: instance IDs and properties carry the USB serial
and other devices' identities. The agent redacts before anything is committed.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$OutputDirectory,
    [Parameter(Mandatory)][ValidateSet('before', 'after', 'removed', 'replugged')][string]$Phase
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'USB sampling requires Windows.' }
$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
$probe = $OutputDirectory
while ($probe) {
    if (Test-Path -LiteralPath (Join-Path $probe '.git')) { throw "Choose an output directory outside any git work tree ($probe)." }
    $probe = [System.IO.Path]::GetDirectoryName($probe)
}
if ($Phase -eq 'before') {
    if (Test-Path -LiteralPath $OutputDirectory) { throw "Use a new output directory; $OutputDirectory exists." }
    [void](New-Item -ItemType Directory -Path $OutputDirectory)
} elseif (-not (Test-Path -LiteralPath (Join-Path $OutputDirectory 'usb-before.json'))) {
    throw 'Run the before phase first with this -OutputDirectory.'
}
$path = Join-Path $OutputDirectory "usb-$Phase.json"
if (Test-Path -LiteralPath $path) { throw "This phase was already sampled; $path exists. Start a new root." }

function Get-NodeRecord($Device) {
    $properties = [ordered]@{}
    $errors = 0
    try {
        foreach ($property in @(Get-PnpDeviceProperty -InstanceId $Device.InstanceId -ErrorAction Stop)) {
            if ($null -ne $property.Data) {
                $properties[$property.KeyName] = [ordered]@{ type = "$($property.Type)"; data = $property.Data }
            }
        }
    } catch { $errors++ }
    [ordered]@{
        instanceId = $Device.InstanceId
        present = if ($Device.PSObject.Properties['Present']) { [bool]$Device.Present } else { $null }
        class = $Device.Class
        friendlyName = $Device.FriendlyName
        status = "$($Device.Status)"
        problem = "$($Device.Problem)"
        propertyReadFailed = $errors -gt 0
        properties = $properties
    }
}

$present = @(Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -like 'USB\*' })
$rockchip = @(Get-PnpDevice | Where-Object { $_.InstanceId -like '*VID_2207*' })
$record = [ordered]@{
    schema = 'arkdeck-windows-usb-sample/v2'
    phase = $Phase
    capturedAtUtc = [DateTime]::UtcNow.ToString('o')
    os = (Get-CimInstance Win32_OperatingSystem | Select-Object Caption, Version, BuildNumber, OSArchitecture)
    powershell = $PSVersionTable.PSVersion.ToString()
    rockchipNodes = @(foreach ($device in $rockchip) { Get-NodeRecord $device })
    presentUsbNodes = @(foreach ($device in $present) { Get-NodeRecord $device })
}
$record | ConvertTo-Json -Depth 10 | Set-Content -Encoding utf8NoBOM -LiteralPath $path
Write-Output $path
