# DHCP / IPv4LL integration lab

Real, reproducible tests that exercise the runtime's **dynamic addressing**
paths (dhcpcd) and IPv4LL fallback — the gap the smoke test cannot cover.

Everything runs **inside Docker containers**. No `--privileged`, no host
network, no `SYS_ADMIN`, no writes to host `/proc/sys`.

## Why it can run unprivileged

dhcpcd 10.5.2 `src/if-linux.c` `if_init_os()` checks
`check_proc_int(PROC_PROMOTE)` per interface: if
`/proc/sys/net/ipv4/conf/<if>/promote_secondaries` is already `1` it returns
`0` *without writing*; otherwise it tries to write `1` (which fails on the
read-only `/proc/sys` of a normal `docker run`).

So the lab gives each reflector container a **namespace-scoped** default that
makes every freshly created interface (incl. the `eth0.<vid>` VLAN children)
start with `promote_secondaries=1`:

```
--sysctl net.ipv4.conf.default.promote_secondaries=1
```

This applies **only inside that container's new network namespace** — never
to the host. Combined with `--cap-add NET_ADMIN --cap-add NET_RAW` it is
enough for a real dhcpcd to send/receive DHCP and ARP-probe IPv4LL
addresses.

> Prior "dhcpcd unconditionally writes promote_secondaries / DHCP is
> impossible unprivileged" claims were **incorrect**.

## Topology

```
 Docker --internal bridge (no host L3, no DHCP exposure)
   reflector C                      DHCP-server C   (lab image)
     eth0  <--- 802.1Q tag vid --->   eth0
     eth0.<vid> (VLAN child)          eth0.<vid>  (VLAN child, 10.<b3>.<vid>.1/24)
        ^ dhcpcd + avahi                  ^ dnsmasq (authoritative, pollution opts)
```

Both ends tag the same `vid`, so a single internal bridge acts as the
tagged wire for the managed VLAN sub-interfaces the runtime creates.

* reflector = the **runtime image under test** (built from repo root).
* server    = `test/dhcp/Dockerfile` → runtime image + `dnsmasq` (test-only).

The server's `dnsmasq` is configured `dhcp-authoritative` with a short
2-minute lease (dnsmasq's minimum, so T1 ≈ 60 s) and, for the pollution
test, deliberately offers `router` (`10.<b3>.<vid>.1`),
`domain-name-servers` (`10.<b3>.<vid>.53`), `domain-name` and a
`classless-static-route` (`10.<b3>.<vid+100>.0/24` via the router) — all of
which the generated `dhcpcd.conf` (`nogateway` / `nooption` / `nohook`)
must ignore.

## Run

Host needs only Docker + Python 3 (stdlib only). From repo root:

```bash
python test/dhcp/dhcp_lab.py                 # build images + run all
python test/dhcp/dhcp_lab.py --skip-build    # reuse already-built images
python test/dhcp/dhcp_lab.py --only T1,T5    # subset
```

Windows: `powershell -File test/dhcp/run.ps1`.

Every test wait is individually bounded (see `wait_for` calls); there is no
global timeout flag — a stuck test fails on its own deadline. `--only` only
accepts known test ids and fails fast before any image build or resource.

Per-test result files land in `test/dhcp/results/RESULTS-<runid>.txt` (this
dir plus `__pycache__` are git-ignored). All containers/networks are
labelled `dhcp-lab.run=<runid>` and removed in `finally` (a label-scoped
sweep catches stragglers); any leftover labelled object is reported and
fails the run. `--keep-resources` leaves them for debugging.

## Tests

| id  | what is proven (real evidence, not faked `ip addr add`) |
|-----|--------------------------------------------------------|
| T1  | `IP_MODE=linklocal` → dhcpcd ARP-probes and claims a usable `169.254.x.x/16` (3rd octet 1–254). Explicit `probing for an IPv4LL address` log + claim of that address. Two reflectors on the same VID claim **distinct** LL addresses. `ready`+`healthcheck` green, avahi ack. |
| T2  | `IP_MODE=dhcp` on VID10+VID20 → a real lease: server `DHCPACK(eth0.<vid>) <ip> <per-iface mac>` logged **and** `dnsmasq.leases` records the ip + expiry, client `dhcpcd --dumplease` = `BOUND`, IP in the server subnet. |
| T3  | Renewal: a **new** `DHCPACK`+`DHCPREQUEST` for the same IP+MAC **after** the initial-bound baseline (~T1 ≈60 s), `DHCPDISCOVER`/`DHCPOFFER` counts unchanged, and the server-side lease **expiry advances** — IP+MAC unchanged, health green. |
| T7  | Pollution rejected: the values the servers **actually advertise** (router `10.<b3>.<vid>.1`, DNS `10.<b3>.<vid>.53`, domain, classless `10.<b3>.<vid+100>.0/24`) must not appear — no `default` route, no offered classless dst in `ip route`, `resolv.conf` equals the pre-DHCP entry snapshot, hostname unchanged. |
| T4  | No server + `DHCP_FALLBACK_LL=true` → IPv4LL ready; then a real server appears → dhcpcd keeps retrying and switches to DHCP (LL withdrawn), ACK-verified, health green. |
| T5  | No server + fallback **off** → deliberate **nonzero** `startup timed out` exit (never `dhcpcd failed to start`); an observer container sharing the netns confirms the managed VLAN is removed after the main process dies. |
| T6  | Server stop → lease expires → address dropped + health red (client alive); server return → a **new** ACK beyond the pre-outage baseline + fresh lease expiry + new dnsmasq pid → health green. |
| T8  | Kill the **owned** dhcpcd (PID read from `state.env`, verified a live `dhcpcd`) → supervisor exits nonzero ("dhcpcd exited"); observer confirms the netns VLAN is removed. |

## Honest limits

* **Verified only on native amd64.** In the tested ARM64/QEMU environment,
  dhcpcd's privilege-separation socket setup fails with `Protocol not supported`.
  This is an observed limitation, not a confirmed upstream defect or a result
  for native ARM64. The engine-arch check warns about emulated runs.
* **RouterOS not exercised** — this is container-namespace behaviour on a
  Linux Docker bridge, not RouterOS veth/VLAN plumbing.
* T6 relies on the ~2 min lease: bounded but not instant.
* ARP-conflict *defence* (RFC3927 §2.5) is only partially covered (two
  reflectors pick distinct LL); **forced-conflict** recovery is NOT
  asserted — no colliding ARP prober is injected.
* Dead-container namespace inspection uses a dedicated **observer**
  container (`--network container:<reflector>`, base image, `sleep`
  entrypoint, run-labelled) that pins the target netns open so links/addrs
  remain checkable after the main process exits (a dead container cannot be
  `docker exec`'d).
