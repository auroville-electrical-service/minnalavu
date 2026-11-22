<#
.SYNOPSIS
Stop the alavi collector's Windows service after a planned quiesce: every
poller retires first, a copy at its next entry boundary with its session
closed, in its own time rather than in the seconds a stopping service leaves.

.DESCRIPTION
Without -Apply it shows what it would do, changing nothing. With -Apply, in
an administrator's PowerShell:

 1. if the running collector wrote <buffer>\control\ready (one too old to
    answer did not), writes quiesce beside it and waits up to
    -TimeoutSeconds for quiesced, which the collector writes once its pollers
    have retired: within about 30 s of the request, plus however long they
    take, which the collector bounds at 120 s, so the default wait covers it.
    It prints what quiesced says, including how many were still running;
 2. stops the service. Its stop action stops the application, whose own
    bounded wait then has little or nothing left to do;
 3. removes ready, quiesce and quiesced.

With no quiesced in time it says so and stops the service anyway: the stop
is then the ordinary bounded one, and a selector restore left owed is done at
the next start.

.EXAMPLE
powershell -ExecutionPolicy Bypass -File stop.ps1 -Root C:\alavi

.EXAMPLE
powershell -ExecutionPolicy Bypass -File stop.ps1 -Root C:\alavi -TimeoutSeconds 600 -Apply
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$Root,
  [ValidateRange(1, 3600)][int]$TimeoutSeconds = 180,
  [switch]$Apply
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ServiceName = 'alavi_alavi'
$StopWaitSeconds = 60

function Get-ControlDir([string]$Root) {
  $file = Join-Path $Root 'settings.json'
  if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "No settings file at $file." }
  $json = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
  $buffer = $json.PSObject.Properties['buffer']
  if ($null -eq $buffer -or $null -eq $buffer.Value.PSObject.Properties['dir']) {
    throw "$file has no buffer.dir: check it against settings.example.json."
  }
  Join-Path $buffer.Value.dir 'control'
}

function Assert-Admin {
  $identity = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
  if (-not $identity.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this from an administrator''s PowerShell.'
  }
}

function Wait-Quiesced([string]$Answer, [int]$Seconds) {
  $deadline = (Get-Date).AddSeconds($Seconds)
  while (-not (Test-Path -LiteralPath $Answer) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 2 }
  if (Test-Path -LiteralPath $Answer) { Get-Content -LiteralPath $Answer -Raw } else { $null }
}

$control = Get-ControlDir $Root
$ready = Join-Path $control 'ready'
$request = Join-Path $control 'quiesce'
$answer = Join-Path $control 'quiesced'
$status = (Get-Service -Name $ServiceName).Status
$answers = ($status -eq 'Running') -and (Test-Path -LiteralPath $ready)

Write-Output "Service:  $ServiceName, $status"
Write-Output "Quiesce:  $(if ($answers) { "asked in $control, waiting up to $TimeoutSeconds s" } else { 'not asked: no ready file from a running collector; an ordinary stop' })"
if (-not $Apply) {
  Write-Output 'Checked; nothing changed. Rerun with -Apply to stop.'
  return
}

Assert-Admin
if ($answers) {
  Remove-Item -LiteralPath $answer -ErrorAction SilentlyContinue
  Set-Content -LiteralPath $request -Value (Get-Date).ToUniversalTime().ToString('o')
  $quiesced = Wait-Quiesced $answer $TimeoutSeconds
  if ($quiesced) { Write-Output "Quiesced: $($quiesced.Trim())" }
  else { Write-Warning "No quiesced in $TimeoutSeconds s: stopping anyway, the ordinary bounded stop." }
}
if ((Get-Service -Name $ServiceName).Status -ne 'Stopped') { Stop-Service -Name $ServiceName }
(Get-Service -Name $ServiceName).WaitForStatus('Stopped', [TimeSpan]::FromSeconds($StopWaitSeconds))
Remove-Item -LiteralPath $ready, $request, $answer -ErrorAction SilentlyContinue
Write-Output 'Stopped.'
