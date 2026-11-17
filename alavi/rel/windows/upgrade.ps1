<#
.SYNOPSIS
Upgrade the alavi collector's Windows service to a built release, carrying
the buffer, the log, the settings and the polling config over.

.DESCRIPTION
Without -Apply it checks everything it can and prints the plan, changing
nothing. With -Apply, in an administrator's PowerShell:

 1. stops the service alavi_alavi and removes it, refusing if any process
    still runs from the install;
 2. renames the install root aside, to <Root>-<yyyyMMdd-HHmmss>;
 3. creates a fresh root with the README's ACL (Administrators and SYSTEM),
    lays the release down in it, and settings.json (the old one, or
    -Settings) with its ACL;
 4. moves the buffer and log directories back from the old install (a rename
    on the same volume: the buffer is never copied, so there is one copy and
    a selector restore owed in it survives), copies the polling config, and
    copies -Profiles into profiles_dir;
 5. places -ServedConfig as <buffer>\config\served.json, when given;
 6. installs the service from the new root, starts it, checks erlsrv's
    OnFail, WorkDir and InternalServiceName, and waits for status.json to be
    written by the new start, then prints its version, config digests and
    clock check.

settings.json's paths (polling_config, profiles_dir, buffer.dir, log.dir)
must be the same in the old file and in -Settings: this script carries an
install over, it does not move one. profiles_dir must be under Root. A
buffer or log directory outside Root is left where it is.

The release's bin, erts and lib come from -Release; nothing of the old
release is kept but what is listed above. The old install stays, renamed,
holding whatever else was in it (an erl_crash.dump, the old profiles).

Build the release first, in the clone, in cmd: set MIX_ENV=prod, then
mix.bat deps.get --only prod and mix.bat release; it lands in
_build\prod\rel\alavi. (mix.ps1 is refused over SSH; mix.bat is not.)

To go back after a failure: stop and remove the service if it was installed
(erlsrv under the new root), move the buffer and log directories back into
the old install, rename the new root aside and the old one back, then from
it bin\alavi.bat install and erlsrv start alavi_alavi.

.EXAMPLE
powershell -ExecutionPolicy Bypass -File upgrade.ps1 -Root C:\alavi -Release C:\src\minnalavu\alavi\_build\prod\rel\alavi -Profiles C:\src\minnalavu\contract\profiles

.EXAMPLE
powershell -ExecutionPolicy Bypass -File upgrade.ps1 -Root C:\alavi -Release ... -Profiles ... -Settings C:\Users\me\settings.json -Apply
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$Root,
  [Parameter(Mandatory)][string]$Release,
  [Parameter(Mandatory)][string]$Profiles,
  [string]$Settings,
  [string]$ServedConfig,
  [switch]$Apply
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ServiceName = 'alavi_alavi'
$StopWaitSeconds = 60
$StartWaitSeconds = 180

function Get-FullPath([string]$Path) {
  [IO.Path]::GetFullPath($Path).TrimEnd('\')
}

function Test-Under([string]$Path, [string]$Dir) {
  $Path.StartsWith("$Dir\", [StringComparison]::OrdinalIgnoreCase)
}

# A path under the old root, as it is once the root has been renamed aside.
function Move-Base([string]$Path, [string]$From, [string]$To) {
  if (Test-Under $Path $From) { $To + $Path.Substring($From.Length) } else { $Path }
}

function Get-Field($Object, [string]$Name, [string]$File) {
  $field = $Object.PSObject.Properties[$Name]
  if ($null -eq $field) { throw "$File has no '$Name': check it against settings.example.json." }
  $field.Value
}

function Read-SettingsPaths([string]$File) {
  if (-not (Test-Path -LiteralPath $File -PathType Leaf)) { throw "No settings file at $File." }
  $json = Get-Content -LiteralPath $File -Raw | ConvertFrom-Json
  [ordered]@{
    polling_config = Get-FullPath (Get-Field $json 'polling_config' $File)
    profiles_dir   = Get-FullPath (Get-Field $json 'profiles_dir' $File)
    buffer_dir     = Get-FullPath (Get-Field (Get-Field $json 'buffer' $File) 'dir' $File)
    log_dir        = Get-FullPath (Get-Field (Get-Field $json 'log' $File) 'dir' $File)
  }
}

function Assert-SamePaths($Old, $New, [string]$NewFile) {
  $moved = @($Old.Keys | Where-Object { $Old[$_] -ne $New[$_] })
  if ($moved.Count -gt 0) {
    throw "$NewFile changes $($moved -join ', ') from the installed settings.json. " +
    'This script carries an install over; move a path by hand, then upgrade.'
  }
}

function Find-Erlsrv([string]$Dir) {
  $found = @(Get-ChildItem -Path "$Dir\erts-*\bin\erlsrv.exe" -ErrorAction SilentlyContinue)
  if ($found.Count -ne 1) { throw "Expected one erts-*\bin\erlsrv.exe under $Dir, found $($found.Count)." }
  $found[0].FullName
}

# Windows PowerShell turns a native command's stderr line into a terminating
# error under 'Stop', so the exit code decides here instead.
function Invoke-Native([string]$Exe, [string[]]$Arguments) {
  $ErrorActionPreference = 'Continue'
  $output = & $Exe @Arguments 2>&1 | Out-String
  if ($LASTEXITCODE -ne 0) { throw "$Exe $($Arguments -join ' ') exited $LASTEXITCODE`n$output" }
  $output
}

function Assert-Admin {
  $identity = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
  if (-not $identity.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this from an administrator''s PowerShell.'
  }
}

function Assert-Leaf([string]$Path, [string]$What) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "No $What at $Path." }
}

function Assert-Container([string]$Path, [string]$What) {
  if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw "No $What at $Path." }
}

function New-Plan {
  $old = Get-FullPath $Root
  $aside = "$old-$(Get-Date -Format yyyyMMdd-HHmmss)"
  $settingsFile = if ($Settings) { Get-FullPath $Settings } else { "$old\settings.json" }
  $paths = Read-SettingsPaths "$old\settings.json"
  Assert-SamePaths $paths (Read-SettingsPaths $settingsFile) $settingsFile
  [pscustomobject]@{
    Root     = $old
    Aside    = $aside
    Release  = Get-FullPath $Release
    Profiles = Get-FullPath $Profiles
    Settings = $settingsFile
    Served   = if ($ServedConfig) { Get-FullPath $ServedConfig } else { $null }
    Paths    = $paths
    Carried  = @($paths.buffer_dir, $paths.log_dir | Where-Object { Test-Under $_ $old })
  }
}

function Assert-Plan($Plan) {
  Assert-Admin
  Assert-Container $Plan.Root 'install root'
  if (Test-Path -LiteralPath $Plan.Aside) { throw "$($Plan.Aside) exists already; wait a second and rerun." }
  if ($Plan.Release -eq $Plan.Root) { throw "-Release is the install root; give the built release, _build\prod\rel\alavi." }
  Assert-Leaf "$($Plan.Release)\bin\alavi.bat" 'built release (bin\alavi.bat)'
  $null = Find-Erlsrv $Plan.Release
  $null = Find-Erlsrv $Plan.Root
  if (@(Get-ChildItem -LiteralPath $Plan.Profiles -Filter *.json).Count -eq 0) { throw "No *.json profiles in $($Plan.Profiles)." }
  if (-not (Test-Under $Plan.Paths.profiles_dir $Plan.Root)) { throw "profiles_dir $($Plan.Paths.profiles_dir) is not under $($Plan.Root)." }
  if ($Plan.Served) { Assert-Leaf $Plan.Served 'served config' }
  if (Test-Under $Plan.Paths.polling_config $Plan.Root) { Assert-Leaf $Plan.Paths.polling_config 'polling config' }
  $null = Get-Service -Name $ServiceName
}

function Show-Plan($Plan) {
  Write-Output "Install root:   $($Plan.Root) (renamed aside to $($Plan.Aside))"
  Write-Output "Release:        $($Plan.Release)"
  Write-Output "Profiles:       $($Plan.Profiles) -> $($Plan.Paths.profiles_dir)"
  Write-Output "settings.json:  $($Plan.Settings)"
  Write-Output "Moved back:     $(if ($Plan.Carried) { $Plan.Carried -join ', ' } else { 'nothing (buffer and log are outside the root)' })"
  Write-Output "Polling config: $($Plan.Paths.polling_config)$(if (Test-Under $Plan.Paths.polling_config $Plan.Root) { ' (copied)' } else { ' (left where it is)' })"
  Write-Output "Served config:  $(if ($Plan.Served) { "$($Plan.Served) -> $($Plan.Paths.buffer_dir)\config\served.json" } else { 'not placed' })"
}

function Stop-Collector($Plan) {
  $erlsrv = Find-Erlsrv $Plan.Root
  if ((Get-Service -Name $ServiceName).Status -ne 'Stopped') { $null = Invoke-Native $erlsrv @('stop', $ServiceName) }
  (Get-Service -Name $ServiceName).WaitForStatus('Stopped', [TimeSpan]::FromSeconds($StopWaitSeconds))
  $running = @(Get-Process | Where-Object { $_.Path -and (Test-Under $_.Path $Plan.Root) })
  if ($running.Count -gt 0) {
    throw "Still running from $($Plan.Root): $(($running | ForEach-Object { "$($_.Name) ($($_.Id))" }) -join ', '). Stop them, then rerun."
  }
  $null = Invoke-Native $erlsrv @('remove', $ServiceName)
}

function New-Root($Plan) {
  $null = New-Item -ItemType Directory -Path $Plan.Root
  $null = Invoke-Native 'icacls.exe' @($Plan.Root, '/inheritance:r', '/grant', '*S-1-5-32-544:(OI)(CI)F', '/grant', '*S-1-5-18:(OI)(CI)F')
  Copy-Item -Path "$(Move-Base $Plan.Release $Plan.Root $Plan.Aside)\*" -Destination $Plan.Root -Recurse
  $settings = "$($Plan.Root)\settings.json"
  Copy-Item -LiteralPath (Move-Base $Plan.Settings $Plan.Root $Plan.Aside) -Destination $settings
  $null = Invoke-Native 'icacls.exe' @($settings, '/inheritance:r', '/grant', '*S-1-5-32-544:F', '/grant', '*S-1-5-18:F')
}

function Copy-State($Plan) {
  foreach ($dir in $Plan.Carried) { Move-Item -LiteralPath (Move-Base $dir $Plan.Root $Plan.Aside) -Destination $dir }
  $polling = $Plan.Paths.polling_config
  if (Test-Under $polling $Plan.Root) { Copy-Item -LiteralPath (Move-Base $polling $Plan.Root $Plan.Aside) -Destination $polling }
  $null = New-Item -ItemType Directory -Path $Plan.Paths.profiles_dir -Force
  Copy-Item -Path "$(Move-Base $Plan.Profiles $Plan.Root $Plan.Aside)\*.json" -Destination $Plan.Paths.profiles_dir
  if (-not $Plan.Served) { return }
  $config = "$($Plan.Paths.buffer_dir)\config"
  $null = New-Item -ItemType Directory -Path $config -Force
  Copy-Item -LiteralPath (Move-Base $Plan.Served $Plan.Root $Plan.Aside) -Destination "$config\served.json"
}

function Start-Collector($Plan) {
  Push-Location $Plan.Root
  try { $null = Invoke-Native 'cmd.exe' @('/c', 'bin\alavi.bat', 'install') } finally { Pop-Location }
  $erlsrv = Find-Erlsrv $Plan.Root
  $null = Invoke-Native $erlsrv @('start', $ServiceName)
  $list = Invoke-Native $erlsrv @('list', $ServiceName)
  $expected = @('OnFail:\s*restart', "WorkDir:\s*$([regex]::Escape($Plan.Root))\s", "InternalServiceName:\s*$ServiceName")
  $missing = @($expected | Where-Object { $list -notmatch $_ })
  if ($missing.Count -gt 0) { throw "erlsrv list lacks $($missing -join ', '):`n$list" }
  Write-Output $list
}

function Read-Status([string]$File) {
  if (-not (Test-Path -LiteralPath $File -PathType Leaf)) { return $null }
  try { Get-Content -LiteralPath $File -Raw | ConvertFrom-Json } catch { $null }
}

# status.json once the new node has written it with its clock check: the one
# carried over in the log directory is the old node's, older than $Since.
function Wait-Status([string]$File, [datetime]$Since) {
  $deadline = (Get-Date).AddSeconds($StartWaitSeconds)
  while ((Get-Date) -lt $deadline) {
    $status = Read-Status $File
    $fresh = $status -and ([datetime]$status.started_at).ToUniversalTime() -ge $Since
    if ($fresh -and $status.clock_check) { return $status }
    Start-Sleep -Seconds 5
  }
  throw "No status.json from the new start with a clock check in $StartWaitSeconds s ($File). " +
  "Service: $((Get-Service -Name $ServiceName).Status). See alavi.log, or run bin\alavi.bat start in the console."
}

function Show-Status($Status) {
  $check = $Status.clock_check
  Write-Output "version:        $($Status.version), started $($Status.started_at)"
  if ($Status.config) {
    Write-Output "config digest:  $($Status.config.digest); refused: $(if ($Status.config.refused_digest) { "$($Status.config.refused_digest) ($($Status.config.reason))" } else { 'none' })"
  }
  Write-Output "clock check:    $($check.outcome) at $($check.at) ($($check.trigger), $($check.server)), offset $($check.offset_ms) ms"
}

function Invoke-Upgrade($Plan) {
  $step = 'stopping the service'
  try {
    Stop-Collector $Plan
    $step = "renaming $($Plan.Root) to $($Plan.Aside)"
    Rename-Item -LiteralPath $Plan.Root -NewName (Split-Path -Leaf $Plan.Aside)
    $step = 'laying down the new root'
    New-Root $Plan
    $step = 'moving the buffer and log back, copying config and profiles'
    Copy-State $Plan
    $step = 'installing and starting the service'
    $since = (Get-Date).ToUniversalTime().AddSeconds(-1)
    Start-Collector $Plan
    $step = 'waiting for status.json'
    Show-Status (Wait-Status "$($Plan.Paths.log_dir)\status.json" $since)
  } catch {
    throw "Failed while $step. The old install is at $($Plan.Aside) unless that step had not run; " +
    "see 'To go back' in Get-Help .\upgrade.ps1 -Full.`n$_"
  }
}

$plan = New-Plan
Assert-Plan $plan
Show-Plan $plan
if (-not $Apply) {
  Write-Output 'Checked; nothing changed. Rerun with -Apply to upgrade.'
  return
}
Invoke-Upgrade $plan
Write-Output "Upgraded. The old install is at $($plan.Aside)."
