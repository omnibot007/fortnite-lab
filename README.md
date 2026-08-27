# fortnite-lab

Toolkit built 2026-08-21 on top of the tuning work in `C:\Users\LENOVO\missions\fortnite-tweak.md`.
These tools do not make the network faster (physics won) - they keep the tuned state
from regressing and turn every session into data.

## Tools

### fortnite-guard.ps1  (run before playing)
```powershell
powershell -File fortnite-guard.ps1            # check only, print PASS/FAIL + fix commands
powershell -File fortnite-guard.ps1 -Fix       # additionally repair safe failures
powershell -File fortnite-guard.ps1 -GameMode  # stop Docker etc, then check
```
Checks power plan, all tuned registry values, bcdedit leftovers, WARP, Ethernet adapter
state (1 Gbps, interrupt moderation, power management) and the Fortnite ini keys against
`baseline.json`. The baseline is data - when you deliberately change a tuned value,
update `baseline.json` (and the mission file) or the guard will flag it forever.
Ini fixes are skipped while Fortnite is running (the game rewrites the ini on exit).

### fortnite-report.ps1  (run after playing)
Parses the newest `FortniteGame.log`: hitch count, per-minute timeline, PSO compile
activity, draw-call histogram at hitch frames, and a verdict against the recorded
pre-fix baseline (348 total / 88-stitch startup storm). Reports land in `reports\`.
Use `-LogPath` to analyze an old backup log.

### ping-monitor.ps1  (leave running while you play)
```powershell
powershell -File ping-monitor.ps1 -Once          # quick sample
powershell -File ping-monitor.ps1 -DurationSec 3600   # monitor an hour
```
Samples gateway ICMP + us-west-2 TCP handshake every 5 s, logs CSV to `logs\`, and
writes `alerts.log` only when a 60 s window averages >60 ms or spreads >10 ms - the
conditions under which a relay/VPN would be worth anything. Silence = healthy route.

### latency-bench.ps1  (one-shot full suite)
Gateway, 1.1.1.1, us-west-2 TCP (min/avg/p95), DNS timing for Epic domains, and a
home bufferbloat test (gateway ping idle vs under a 25 MB load). Grades A-F.
Grade below A = router-side SQM would help; nothing on the PC fixes that.

## Baseline context
- Pre-fix hitch baseline (8/20-21): 348 hitches, 88 in the 7-minute startup storm,
  PSO compile lines co-located with the storm. After shader-cache-unlimited +
  worker threads + reboot, expect the storm to shrink; that is what the report
  verdict tracks.
- Healthy numbers on this machine: gateway 0.9 ms avg / 2 ms spread,
  us-west-2 TCP 36 min / 46 avg ms. In-game NAW ping should read ~40-55 ms.
