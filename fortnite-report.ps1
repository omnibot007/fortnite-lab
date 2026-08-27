# fortnite-report.ps1 - post-game report card from FortniteGame.log.
# Extracts hitch counts, per-minute storm timeline, PSO compile activity,
# draw-call histogram and session duration; compares against the recorded
# pre-fix baseline (baseline.json -> hitchBaseline).
#   default : analyze the newest FortniteGame.log
#   -LogPath: analyze a specific log (e.g. a backup)
# Writes a markdown report to reports\ and prints a summary.

param([string]$LogPath)

$ErrorActionPreference = 'Continue'
$logDir = Join-Path $env:LOCALAPPDATA 'FortniteGame\Saved\Logs'
if (-not $LogPath) {
  $LogPath = Get-ChildItem -LiteralPath $logDir -Filter 'FortniteGame.log' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1 | ForEach-Object FullName
}
if (-not $LogPath -or -not (Test-Path -LiteralPath $LogPath)) { Write-Host "no FortniteGame.log found" -ForegroundColor Red; exit 2 }

$B = Get-Content (Join-Path $PSScriptRoot 'baseline.json') -Raw | ConvertFrom-Json
# Fortnite keeps its log locked while running - open with shared read/write.
$fs = [System.IO.File]::Open($LogPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
$sr = New-Object System.IO.StreamReader($fs)
$lines = New-Object System.Collections.Generic.List[string]
while (-not $sr.EndOfStream) { $lines.Add($sr.ReadLine()) }
$sr.Close(); $fs.Close()

$hitches = @{}          # minute -> count (HITCHHUNTER)
$gamethread = 0          # LogCore hitch errors
$pso = @{}               # minute -> count
$drawCalls = @{}         # drawcall count -> occurrences
$first = $null; $last = $null
foreach ($l in $lines) {
  if ($l -match '^\[(\d{4}\.\d{2}\.\d{2}-\d{2}\.\d{2})') {
    $min = $Matches[1]
    if (-not $first) { $first = $min }
    $last = $min
    if ($l -match 'HITCHHUNTER') {
      $hitches[$min] = 1 + $hitches[$min]
      if ($l -match 'Draw Calls this Frame: (\d+)') { $drawCalls[$Matches[1]] = 1 + $drawCalls[$Matches[1]] }
    }
    if ($l -match 'LogCore: Error: Hitch detected') { $gamethread++ }
    if ($l -match 'PSO' -and $l -match 'LogDeviceProfileManager|LogConfig') { $pso[$min] = 1 + $pso[$min] }
  }
}

$totalHitch = ($hitches.Values | Measure-Object -Sum).Sum
if (-not $totalHitch) { $totalHitch = 0 }
$worstMin = $hitches.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1
$stormHitches = 0
if ($worstMin) {
  $stormHitches = ($hitches.GetEnumerator() | Where-Object { $_.Key -ge $worstMin.Key } | Sort-Object Key | Select-Object -First 7 | Measure-Object -Property Value -Sum).Sum
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$repDir = Join-Path $PSScriptRoot 'reports'
New-Item -ItemType Directory -Path $repDir -Force | Out-Null
$rep = Join-Path $repDir ("report-" + $stamp + ".md")

$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine("# Fortnite session report")
[void]$sb.AppendLine("")
[void]$sb.AppendLine(("- Log: " + $LogPath))
[void]$sb.AppendLine(("- Session span (UTC): " + $first + " to " + $last))
[void]$sb.AppendLine(("- HITCHHUNTER hitches: **" + $totalHitch + "**"))
[void]$sb.AppendLine(("- Gamethread hitch errors: " + $gamethread))
if ($worstMin) {
  [void]$sb.AppendLine(("- Worst minute (UTC): " + $worstMin.Key + " with " + $worstMin.Value + " hitches"))
  [void]$sb.AppendLine(("- Storm total (worst minute + next 6): " + $stormHitches))
}
[void]$sb.AppendLine("")
[void]$sb.AppendLine("## Hitch timeline (UTC, hitches per minute)")
[void]$sb.AppendLine("")
[void]$sb.AppendLine("| minute | hitches |")
[void]$sb.AppendLine("|---|---|")
foreach ($m in ($hitches.GetEnumerator() | Sort-Object Key)) { [void]$sb.AppendLine("| " + $m.Key + " | " + $m.Value + " |") }
[void]$sb.AppendLine("")
[void]$sb.AppendLine("## PSO/compile activity per minute (top 10)")
[void]$sb.AppendLine("")
[void]$sb.AppendLine("| minute | lines |")
[void]$sb.AppendLine("|---|---|")
foreach ($m in ($pso.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 10)) { [void]$sb.AppendLine("| " + $m.Key + " | " + $m.Value + " |") }
[void]$sb.AppendLine("")
[void]$sb.AppendLine("## Draw calls at hitch frames (top 6)")
[void]$sb.AppendLine("")
foreach ($d in ($drawCalls.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 6)) { [void]$sb.AppendLine(("- " + $d.Key + " draw calls: " + $d.Value + " hitch frames")) }
[void]$sb.AppendLine("")
[void]$sb.AppendLine("## vs baseline")
$hb = $B.hitchBaseline
[void]$sb.AppendLine(("- Baseline (pre-fix, 8/20-21): total " + $hb.totalHitches + ", startup storm " + $hb.startupStormHitches + " in first " + $hb.startupStormWindowMin + " min"))
[void]$sb.AppendLine(("- This log: total " + $totalHitch + ", worst-window " + $stormHitches))
if ($totalHitch -lt $hb.totalHitch) { [void]$sb.AppendLine("- VERDICT: fewer total hitches than baseline - improvement holding.") }
elseif ($totalHitch -eq $hb.totalHitch) { [void]$sb.AppendLine("- VERDICT: identical to baseline.") }
else { [void]$sb.AppendLine("- VERDICT: MORE hitches than baseline - investigate (guard -Fix, thermals, background apps).") }

$out = $sb.ToString()
$out | Out-File -FilePath $rep -Encoding utf8
Write-Host $out
Write-Host ("Report saved: " + $rep) -ForegroundColor Cyan
