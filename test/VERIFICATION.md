# Verification status — 2026-11-07

## Final independent results

| Suite | Native amd64 | ARM64/QEMU |
|---|---|---|
| `smoke.sh` | **60/60**, five consecutive fresh containers | **60/60** |
| `runtime-security.sh` | **12/12**, five consecutive fresh containers | **12/12** |
| `e2e/run.sh` | **8/8** real tagged-packet tests | **8/8** real tagged-packet tests |
| `dhcp/dhcp_lab.py` | **8/8**, 304 seconds, zero leftover objects | not accepted under emulation |
| `fixture-log.sh` | **3/3**, including the buggy-shape control | **3/3** |

The five consecutive smoke/security rounds used no tracing, retries, longer
timeouts, or weakened readiness checks. Test source was mounted read-only.

Runtime image IDs:

- `ccr2116-avahi-review:fixture-final-amd64`:
  `sha256:2bfa7c9b44434532a46b933acbc049a46af9d18f14247eb45ffa748d18a0f752`
- `ccr2116-avahi-review:fixture-final-arm64`:
  `sha256:902b01c54f09289680626a79ddee145449010c3a7e9ad52aa743cc4379b303ea`

Both use Alpine **3.24.4** and its packaged Bash **5.3.9-r1**, not a
source-built replacement. Test-only derivative images add Python or dnsmasq;
those additions are not in the runtime image.

Trivy **0.76.2** scanned both runtime images on 2026-11-07 and reported
**zero HIGH/CRITICAL findings**, including unfixed vulnerabilities. Actionlint
**1.7.12**, Bash syntax, ShellCheck **0.10.0** (warning/error level), and Python
AST checks passed locally. Subsequent runtime edits only clarified comments.

The native DHCP lab uses only a fresh-container network-namespace prerequisite,
`--sysctl net.ipv4.conf.default.promote_secondaries=1`, plus NET_ADMIN/NET_RAW.
Renewal evidence: ACK and REQUEST counts advanced from 1 to 2, DISCOVER/OFFER
counts stayed at 1, and lease expiry advanced by 65 seconds for the same IP/MAC.
Lease expiry/recovery, rejected DNS/routes, IPv4LL-to-DHCP transition, and VLAN
cleanup observed through a retained namespace also passed.

## Resolved false startup failure

Earlier smoke runs intermittently reported **59/60**, with an empty log and
a live supervisor. Subsequent post-failure inspection showed a healthy
supervisor with Avahi, its reader, genuine startup acknowledgment and readiness.

The defect was in the test launcher: repeated fixtures shared `/tmp/ep.log`,
and `env ... /entrypoint.sh >"$log" 2>&1 &` truncated it only when the async
child ran. The parent's first readiness probe could see the **previous**
fixture's `ready:` line, return immediately, then see the newly truncated log.
This was not evidence of a 35-second timeout or an upstream Bash/musl hang.

Both fixture launchers now truncate the log **synchronously in the parent**
before starting the child. `fixture-log.sh` checks that parent-side contract
using the actual helper bodies and a synthesized original-bug control.
The test checks this contract deterministically rather than relying on a
particular scheduling order.

Bash 5.3.20 comparison builds and the experimental sysfs existence probe did
not fix the false failure and were not adopted. The sysfs experiment was
reverted. Official GNU patches 010/012 address separate bugs; their existence
does not establish a Bash defect in this project's startup path.

## Remaining limits

- Actual RouterOS/CCR2116 and native ARM64 dynamic addressing remain untested.
- ARM64/QEMU dhcpcd socket initialization failed in this environment.
- Forced IPv4LL conflict-defense recovery has not been tested.
- GitHub Actions is configured and locally linted, not run remotely.
- Package vulnerability scans do not establish runtime correctness or promise
  that an image will remain vulnerability-free.

No image was published or deployed. No router or host-global settings were
changed. See the README for safe reproduction and target-validation caveats.
