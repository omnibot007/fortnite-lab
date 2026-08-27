# upload-bloat.ps1 - upstream bufferbloat test (the half latency-bench.ps1 doesn't cover).
# Saturates UPLOAD with a 10MB POST while pinging an INTERNET host (gateway ping staying
# flat proves nothing about ISP-side queues) plus us-west-2 TCP handshakes = the exact
# signal that read 79-84ms during live matches vs 42-46ms idle.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File upload-bloat.ps1

$ErrorActionPreference = 'Continue'
$gw = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' | Sort-Object RouteMetric | Select-Object -First 1).NextHop

function Icmp-Stats([string]$h, [int]$n) {
  $p = Test-Connection $h -Count $n -ErrorAction SilentlyContinue
  $r = @($p | ForEach-Object ResponseTime)
  if ($r.Count -eq 0) { return @{ n = 0 } }
  $s = $r | Measure-Object -Minimum -Maximum -Average
  @{ n = $r.Count; min = $s.Minimum; max = $s.Maximum; avg = [math]::Round($s.Average,1); spread = $s.Maximum - $s.Minimum }
}

function Tcp-Stats([string]$h, [int]$n) {
  $t = @()
  foreach ($i in 1..$n) {
    $c = New-Object System.Net.Sockets.TcpClient
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try { $c.Connect($h, 443); $sw.Stop(); $t += [int]$sw.ElapsedMilliseconds } catch {}
    finally { $c.Close() }
    Start-Sleep -Milliseconds 150
  }
  if ($t.Count -eq 0) { return @{ n = 0 } }
  $s = $t | Measure-Object -Minimum -Maximum -Average
  $sorted = $t | Sort-Object
  $p95 = $sorted[[int][math]::Floor(0.95 * ($sorted.Count - 1))]
  @{ n = $t.Count; min = $s.Minimum; max = $s.Maximum; avg = [math]::Round($s.Average,1); p95 = $p95 }
}

Write-Host "=== idle baseline ===" -ForegroundColor Cyan
$idleGw = Icmp-Stats $gw 10
Write-Host ("  gateway {0}: avg {1} ms, spread {2} ms" -f $gw, $idleGw.avg, $idleGw.spread)
$idleEdge = Icmp-Stats '1.1.1.1' 15
Write-Host ("  1.1.1.1: avg {0} ms, spread {1} ms" -f $idleEdge.avg, $idleEdge.spread)

Write-Host "=== saturating upload (10MB POST) ===" -ForegroundColor Cyan
$job = Start-Job {
  try {
    $bytes = [byte[]]::new(10485760)
    Invoke-RestMethod -Uri 'https://speed.cloudflare.com/__up' -Method Post `
      -ContentType 'application/octet-stream' -Body $bytes -TimeoutSec 60 | Out-Null
  } catch {}
}
Start-Sleep -Seconds 2

$loadEdge = Icmp-Stats '1.1.1.1' 20
$loadGw   = Icmp-Stats $gw 15
$loadTcp  = Tcp-Stats 'ec2.us-west-2.amazonaws.com' 8

Wait-Job $job -Timeout 60 | Out-Null; Remove-Job $job -Force

$edgeDelta = $loadEdge.avg - $idleEdge.avg
$gwDelta   = $loadGw.avg - $idleGw.avg
$grade = if ($edgeDelta -lt 5) { 'A' } elseif ($edgeDelta -lt 15) { 'B' } elseif ($edgeDelta -lt 40) { 'C' } else { 'F' }

Write-Host ("  1.1.1.1 loaded: avg {0} ms (delta {1:+0;-0} ms), spread {2} ms -> upstream bloat grade {3}" -f $loadEdge.avg, $edgeDelta, $loadEdge.spread, $grade) -ForegroundColor $(if ($grade -eq 'A') {'Green'} elseif ($grade -in 'C','F') {'Red'} else {'Yellow'})
Write-Host ("  gateway loaded: avg {0} ms (delta {1:+0;-0} ms)" -f $loadGw.avg, $gwDelta)
if ($loadTcp.n -gt 0) {
  Write-Host ("  us-west-2 TCP under load: min {0} / avg {1} / p95 {2} / max {3} ms (n={4})  [idle today: 36/42.4/46/81]" -f $loadTcp.min, $loadTcp.avg, $loadTcp.p95, $loadTcp.max, $loadTcp.n)
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$repDir = Join-Path $PSScriptRoot 'reports'; New-Item -ItemType Directory -Path $repDir -Force | Out-Null
$rep = Join-Path $repDir ("upbloat-" + $stamp + ".md")
@"
# Upload bloat $stamp

- idle: gateway $($idleGw.avg)/$($idleGw.spread) ms, 1.1.1.1 $($idleEdge.avg)/$($idleEdge.spread) ms
- under 10MB upload load: 1.1.1.1 avg $($loadEdge.avg) (delta $edgeDelta), spread $($loadEdge.spread); gateway avg $($loadGw.avg) (delta $gwDelta)
- us-west-2 TCP under load: min $($loadTcp.min) / avg $($loadTcp.avg) / p95 $($loadTcp.p95) / max $($loadTcp.max) (n=$($loadTcp.n)); idle reference 36/42.4/46/81
- grade: $grade

Interpretation: edge delta <5ms = upstream path clean, in-match 79ms readings were NOT
network queueing (server-side/CPU-side). Edge delta >15ms with flat gateway = ISP-side
queue; only fix is router SQM/cake at 85-95% line rate.
"@ | Out-File $rep -Encoding utf8
Write-Host ("Report saved: " + $rep) -ForegroundColor Cyan