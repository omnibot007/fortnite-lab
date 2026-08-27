# fortnite-guard.ps1 - pre-game watchdog for the tuned Fortnite/latency state.
# Checks every entry in baseline.json (data, not logic) against the live machine.
#   default : check only, print PASS/FAIL + the exact fix command for each FAIL
#   -Fix    : additionally repair the safe failures (registry, power plan, bcdedit
#             leftovers, WARP process). Ini fixes only when Fortnite is closed.
#   -GameMode: kill known background offenders (Docker Desktop), then run checks.
# Exit code 0 = all green, 1 = at least one FAIL (CI-friendly).

param([switch]$Fix, [switch]$GameMode)

$ErrorActionPreference = 'Continue'
$base = Get-ChildItem -LiteralPath $PSScriptRoot -Filter baseline.json | Select-Object -First 1
if (-not $base) { Write-Host "baseline.json not found next to script" -ForegroundColor Red; exit 2 }
$B = Get-Content $base.FullName -Raw | ConvertFrom-Json

$script:PASS = 0; $script:FAIL = 0
function Ok($label)   { $script:PASS++; Write-Host ("  [PASS] " + $label) -ForegroundColor Green }
function Bad($label, $detail, $fix) {
  $script:FAIL++
  Write-Host ("  [FAIL] " + $label) -ForegroundColor Red
  if ($detail) { Write-Host ("         now: " + $detail) -ForegroundColor DarkYellow }
  if ($fix)    { Write-Host ("         fix: " + $fix) -ForegroundColor Cyan }
}

$fortniteRunning = [bool](Get-Process -Name 'FortniteClient-Win64-Shipping' -ErrorAction SilentlyContinue)

if ($GameMode) {
  Write-Host "`n=== GAME MODE: stopping background offenders ===" -ForegroundColor Cyan
  foreach ($p in @('Docker Desktop', 'com.docker.backend')) {
    $running = Get-Process -Name $p -ErrorAction SilentlyContinue
    if ($running) { $running | Stop-Process -Force; Write-Host ("  stopped " + $p) }
    else { Write-Host ("  not running: " + $p) }
  }
}

Write-Host "`n=== POWER PLAN ===" -ForegroundColor Cyan
$scheme = (powercfg /getactivescheme)
if ($scheme -match [regex]::Escape($B.power.activeSchemeGuid)) { Ok ("active: " + $B.power.activeSchemeName) }
else { Bad "power plan" $scheme ("powercfg /setactive " + $B.power.activeSchemeGuid) 
       if ($Fix) { powercfg /setactive $B.power.activeSchemeGuid; Write-Host "         -> fixed" -ForegroundColor Green } }

Write-Host "`n=== REGISTRY ===" -ForegroundColor Cyan
foreach ($r in $B.registry) {
  $cur = (Get-ItemProperty -LiteralPath $r.path -Name $r.name -ErrorAction SilentlyContinue).($r.name)
  if ($null -ne $cur -and $cur -eq $r.expected) { Ok ($r.name + " = " + $r.expected) }
  else {
    $fixCmd = ("reg add `"{0}`" /v {1} /t REG_{2} /d {3} /f" -f $r.path.Replace('HKLM:\','HKLM\').Replace('HKCU:\','HKCU\'), $r.name, $(if ($r.type -eq 'DWord') {'DWORD'} else {'SZ'}), $r.expected)
    Bad ($r.path + " :: " + $r.name) ("expected " + $r.expected + ", got " + $(if ($null -eq $cur) {'<missing>'} else {$cur})) $fixCmd
    if ($Fix) {
      New-Item -Path $r.path -Force | Out-Null
      # DWORD 4294967295 (0xFFFFFFFF) overflows Int32 - store as -1 which writes the same bits
      $v = if ($r.expected -gt 2147483647) { -1 } else { [int]$r.expected }
      Set-ItemProperty -LiteralPath $r.path -Name $r.name -Value $v -Type DWord
      Write-Host "         -> fixed" -ForegroundColor Green
    }
  }
}
foreach ($r in $B.registryContains) {
  $cur = (Get-ItemProperty -LiteralPath $r.path -Name $r.name -ErrorAction SilentlyContinue).($r.name)
  if ($cur -and $cur -like ("*" + $r.mustContain + "*")) { Ok ($r.name + " contains " + $r.mustContain) }
  else { Bad ($r.name + " must contain " + $r.mustContain) $cur "see missions\fortnite-tweak.md addendum 2 (DirectX global settings)" }
}

Write-Host "`n=== BOOT CONFIG (bcdedit) ===" -ForegroundColor Cyan
$bcd = bcdedit /enum '{current}' | Out-String
foreach ($v in $B.bcdeditAbsent) {
  if ($bcd -match $v) { Bad ("bcdedit flag present, should be absent: " + $v) $v ("bcdedit /deletevalue " + $v)
    if ($Fix) { bcdedit /deletevalue $v 2>$null; Write-Host "         -> fixed (reboot to apply)" -ForegroundColor Green } }
  else { Ok ("bcdedit " + $v + " absent") }
}

Write-Host "`n=== BACKGROUND OFFENDERS ===" -ForegroundColor Cyan
foreach ($p in $B.processesAbsent) {
  $running = Get-Process -Name $p -ErrorAction SilentlyContinue
  if ($running) { Bad ("process running: " + $p) ($running.Count.ToString() + " instance(s)") ("taskkill /IM `"" + $p + ".exe`" /F")
    if ($Fix) { $running | Stop-Process -Force; Write-Host "         -> killed" -ForegroundColor Green } }
  else { Ok ("not running: " + $p) }
}

Write-Host "`n=== NETWORK ADAPTERS ===" -ForegroundColor Cyan
foreach ($a in $B.adapters) {
  $ad = Get-NetAdapter -Name $a.name -ErrorAction SilentlyContinue
  if (-not $ad) { Bad ("adapter missing: " + $a.name); continue }
  if ($a.requireUp) {
    if ($ad.Status -eq 'Up') { Ok ($a.name + " Up @ " + $ad.LinkSpeed) } else { Bad ($a.name + " status") $ad.Status "plug in / check cable" }
  }
  foreach ($adv in $a.advanced) {
    $cur = (Get-NetAdapterAdvancedProperty -Name $a.name -DisplayName $adv.displayName -ErrorAction SilentlyContinue).DisplayValue
    if ($cur -eq $adv.expected) { Ok ($a.name + ": " + $adv.displayName + " = " + $adv.expected) }
    else { Bad ($a.name + ": " + $adv.displayName) ("expected " + $adv.expected + ", got " + $cur) ("Set-NetAdapterAdvancedProperty -Name " + $a.name + " -DisplayName '" + $adv.displayName + "' -DisplayValue '" + $adv.expected + "'") }
  }
  if ($a.powerMgmtOff) {
    $pm = (Get-NetAdapterPowerManagement -Name $a.name -ErrorAction SilentlyContinue).AllowComputerToTurnOffDevice
    if ($pm -eq 'Disabled') { Ok ($a.name + ": power management off") }
    else { Bad ($a.name + ": AllowComputerToTurnOffDevice") $pm "see missions addendum 9 (WMI MSPower_DeviceEnable)" }
  }
}

Write-Host "`n=== FORTNITE CONFIG ===" -ForegroundColor Cyan
$iniPath = [Environment]::ExpandEnvironmentVariables($B.fortniteIni.path)
if (Test-Path -LiteralPath $iniPath) {
  $ini = Get-Content -LiteralPath $iniPath
  foreach ($k in $B.fortniteIni.keys.PSObject.Properties) {
    $line = $ini | Where-Object { $_ -match ('^\s*' + [regex]::Escape($k.Name) + '=') } | Select-Object -First 1
    $cur = if ($line) { $line.Split('=',2)[1] } else { '<missing>' }
    if ($cur -eq $k.Value) { Ok ($k.Name + " = " + $k.Value) }
    else {
      $fixNote = "set in-game, or edit ini while game closed"
      Bad ($k.Name) ("expected " + $k.Value + ", got " + $cur) $fixNote
      if ($Fix -and -not $fortniteRunning) {
        $ini = $ini | ForEach-Object { if ($_ -match ('^\s*' + [regex]::Escape($k.Name) + '=')) { ($k.Name + '=' + $k.Value) } else { $_ } }
        Set-Content -LiteralPath $iniPath -Value $ini
        Write-Host "         -> fixed" -ForegroundColor Green
      } elseif ($Fix -and $fortniteRunning) {
        Write-Host "         -> SKIPPED: Fortnite is running (ini would be overwritten)" -ForegroundColor DarkYellow
      }
    }
  }
} else { Bad "GameUserSettings.ini not found" $iniPath "" }

Write-Host ("`n=== RESULT: " + $script:PASS + " pass, " + $script:FAIL + " fail ===") -ForegroundColor $(if ($script:FAIL -eq 0) {'Green'} else {'Red'})
if ($fortniteRunning) { Write-Host "(Fortnite is running: ini fixes were skipped; re-run after closing)" -ForegroundColor DarkYellow }
exit $(if ($script:FAIL -eq 0) {0} else {1})
