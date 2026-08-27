# ping-monitor.ps1 - background route monitor for the Fortnite path.
# Targets: default gateway (ICMP) and AWS us-west-2 TCP:443 handshake
# (Fortnite NA-West servers live in us-west-2; AWS blocks ICMP).
#   default       : monitor for -DurationSec (300) at -IntervalSec (5)
#   -Once         : single quick sample, print and exit
# Alerts (console + alerts.log) when a 60s rolling window shows
# avg > 60 ms or spread > 10 ms to us-west-2 - the conditions under
# which a relay/VPN would actually be worth building.
# CSV telemetry -> logs\route-<stamp>.csv

param([int]$DurationSec = 300, [int]$IntervalSec = 5, [switch]$Once)

$ErrorActionPreference = 'Continue'
$target = 'ec2.us-west-2.amazonaws.com'
$gw = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' | Sort-Object RouteMetric | Select-Object -First 1).NextHop

function Tcp-Rtt {
  param([string]$h, [int]$port = 443)
  $c = New-Object System.Net.Sockets.TcpClient
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  try { $c.Connect($h, $port); $sw.Stop(); return [int]$sw.ElapsedMilliseconds } catch { return $null } finally { $c.Close() }
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$logDir = Join-Path $PSScriptRoot 'logs'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$csv = Join-Path $logDir ("route-" + $stamp + ".csv")
'time,gateway_ms,uswest2_ms' | Out-File $csv -Encoding ascii

$alertFile = Join-Path $PSScriptRoot 'alerts.log'
$usWin = New-Object System.Collections.ArrayList

Write-Host ("monitoring gateway {0} + {1}:443 for {2}s every {3}s - Ctrl+C to stop" -f $gw, $target, $DurationSec, $IntervalSec)

$deadline = (Get-Date).AddSeconds($DurationSec)
while ((Get-Date) -lt $deadline -or $Once) {
  $g = $null
  $p = Test-Connection $gw -Count 1 -ErrorAction SilentlyContinue
  if ($p) { $g = $p.ResponseTime }
  $u = Tcp-Rtt $target
  $row = ("{0},{1},{2}" -f (Get-Date -Format 'HH:mm:ss'), $g, $u)
  $row | Out-File $csv -Append -Encoding ascii
  Write-Host ("  " + $row)
  if ($u -ne $null) {
    [void]$usWin.Add($u); if ($usWin.Count -gt 12) { $usWin.RemoveAt(0) }
    if ($usWin.Count -ge 12) {
      $avg = ($usWin | Measure-Object -Average).Average
      $spread = ($usWin | Measure-Object -Maximum).Maximum - ($usWin | Measure-Object -Minimum).Minimum
      if ($avg -gt 60 -or $spread -gt 10) {
        $msg = ("{0} ALERT uswest2 avg={1:n1}ms spread={2}ms (window 60s)" -f (Get-Date), $avg, $spread)
        Write-Host $msg -ForegroundColor Red
        $msg | Out-File $alertFile -Append -Encoding utf8
      }
    }
  }
  if ($Once) { break }
  Start-Sleep -Seconds $IntervalSec
}
Write-Host ("done -> " + $csv) -ForegroundColor Cyan
