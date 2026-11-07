#!/bin/bash
# Regression / smoke tests for the reflector image.
# Runs INSIDE the built image on --network none with NET_ADMIN+NET_RAW only.
# Dummy/veth interfaces stand in for the trunk; static mode is the exercisable
# path. dhcpcd cannot run in THIS unprivileged dev container (read-only
# /proc/sys promote_secondaries + blocked privsep sockets) unless a
# namespace-scoped --sysctl net.ipv4.conf.default.promote_secondaries=1 is
# passed - that is verified separately in test/dhcp. Here we only assert
# dhcp/linklocal FAIL CLEARLY without that prereq. This is an environment
# limitation, NOT a universal "dhcpcd is unrunnable".
#
#   docker run --rm --network none --cap-add NET_ADMIN --cap-add NET_RAW \
#       --entrypoint /bin/bash -v "$PWD/test:/t" <image> /t/smoke.sh
set -u
# shellcheck source=../lib.sh
. /usr/local/lib/avahi-reflector/lib.sh 2>/dev/null || true
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

# snapshot of managed-namespace links+addrs for "no mutation" checks
snap() { ip -o link show; ip -o -4 addr show; }

# wait_for <timeout-sec> <cmd...> : poll every 0.5s until cmd succeeds or the
# bounded deadline passes. Bounded condition wait, not a fixed sleep.
wait_for() {
    local dl=$((SECONDS + $1)); shift
    until "$@"; do
        [ $SECONDS -lt $dl ] || return 1
        sleep 0.5
    done
}

# ---- owned-fixture lifecycle ---------------------------------------------
# EP is a GLOBAL set by start_ep; the supervisor is a DIRECT background child
# of THIS test shell - no `timeout` wrapper and no command-substitution
# subshell. Otherwise the real supervisor is orphaned: `kill`/`wait` then act
# on a wrapper that returns before entrypoint finishes cleanup, and the next
# fixture sees stale /run ready/ack/state being cleared mid-run (a real flake).
EP=""
EP_FORCEKILLED=0

# start_ep <logfile> <env...> : launch entrypoint as an owned background child.
start_ep() {
    local log="$1"; shift
    EP=""; EP_FORCEKILLED=0
    # Clear the previous fixture's ready log BEFORE the child can be scheduled.
    # Background redirection alone races the parent's first readiness probe.
    : >"$log" || return 1
    env "$@" /entrypoint.sh >"$log" 2>&1 &
    EP=$!
}

# stop_ep : TERM our owned supervisor and wait bounded for it to fully exit
# (its cleanup removes ready/ack/state + rolls back owned mutations). Only a
# genuine hang forces SIGKILL - reported via EP_FORCEKILLED=1 / nonzero rc so
# tests must assert it as a failure, never silently pass.
stop_ep() {
    EP_FORCEKILLED=0
    [ -n "$EP" ] || return 0
    kill -TERM "$EP" 2>/dev/null || true
    local dl=$((SECONDS + 10))
    while kill -0 "$EP" 2>/dev/null; do
        [ $SECONDS -lt $dl ] || break
        sleep 0.5
    done
    if kill -0 "$EP" 2>/dev/null; then
        kill -9 "$EP" 2>/dev/null || true
        EP_FORCEKILLED=1
    fi
    wait "$EP" 2>/dev/null
    EP=""
    [ "$EP_FORCEKILLED" -eq 0 ]
}

# abort guard: if the script dies mid-fixture, kill ONLY our own live fixture.
# No `exit` in the trap so the original exit status is preserved.
trap '[ -n "$EP" ] && { kill -9 "$EP" 2>/dev/null; wait "$EP" 2>/dev/null; }; true' EXIT

# expect_reject <desc> <substring> <env...> - deliberate nonzero + message,
# and NOT rc>=124 (timeout/sig). Also verifies no VLAN links were created.
expect_reject() {
    local desc="$1" want="$2"; shift 2
    local before after out rc
    before="$(snap)"
    out="$(env "$@" timeout 25 /entrypoint.sh 2>&1)"; rc=$?
    after="$(snap)"
    if [ $rc -eq 0 ]; then bad "$desc (succeeded)"; return; fi
    if [ $rc -ge 124 ]; then bad "$desc (rc=$rc timeout/sig, not a clean reject)"; return; fi
    case "$out" in *"$want"*) : ;; *) bad "$desc (rc=$rc, msg missing '$want': $(echo "$out"|tail -1))"; return;; esac
    [ "$before" = "$after" ] || { bad "$desc (network mutated on reject)"; return; }
    ok "$desc"
}

# expect_ready <desc> <env...> - reach 'ready' + health green, then fully stop
# the OWNED supervisor before returning so no fixture leaks into the next.
expect_ready() {
    local desc="$1"; shift
    start_ep /tmp/ep.log "$@"
    wait_for 35 grep -q 'ready:' /tmp/ep.log
    if grep -q 'ready:' /tmp/ep.log \
        && bash /healthcheck.sh >/dev/null 2>&1; then
        ok "$desc"
    else
        bad "$desc"
        echo "    --- ep.log ($(wc -c </tmp/ep.log 2>/dev/null) bytes, EP=$EP alive=$(kill -0 "$EP" 2>/dev/null && echo y || echo n)) ---"
        tail -12 /tmp/ep.log
        echo "    --- proc tree of EP ---"
        cat /proc/$EP/syscall 2>/dev/null | awk '{print "    syscall:",$0}'
        pinos=$(ls -l /proc/$EP/fd 2>/dev/null | awk '/pipe:/{n=$NF; gsub(/[^0-9]/,"",n); print n}')
        echo "    EP pipe inodes: $pinos"
        # find EVERY process holding one of those pipe ends (writer or reader)
        for d in /proc/[0-9]*/fd; do
            p=${d#/proc/}; p=${p%/fd}
            for fd in "$d"/*; do
                tgt=$(readlink "$fd" 2>/dev/null) || continue
                case "$tgt" in *pipe:*)
                    ino=${tgt#*[}; ino=${ino%]*}
                    case " $pinos " in *" $ino "*)
                        echo "    holder pid=$p fd=${fd##*/} -> $tgt  cmd=$(tr '\0' ' ' </proc/$p/cmdline 2>/dev/null | cut -c1-70) st=$(awk '{print $3}' /proc/$p/stat 2>/dev/null)" ;;
                    esac ;;
                esac
            done
        done
        ps aux 2>/dev/null | tail -20
        echo "    --- health trace ---"; bash -x /healthcheck.sh 2>&1 | tail -12
        echo "    --- run state ---"; ls -la /run/avahi-reflector/ 2>&1 | tail -6
    fi
    stop_ep || bad "$desc: supervisor hung on TERM (had to SIGKILL)"
}

ip link add trunk0 type dummy
ip link set trunk0 multicast on up

echo "== input validation rejects BEFORE network mutation =="
expect_reject "garbage VLAN id"     "invalid VLAN id"   VLAN_LIST=10,garbage
expect_reject "injection ;rm"       "invalid VLAN id"   VLAN_LIST='10;rm'
expect_reject "duplicate VLAN id"   "duplicate VLAN"    VLAN_LIST=10,10
expect_reject "VLAN 0"              "invalid VLAN id"   VLAN_LIST=0
expect_reject "VLAN 4095"           "invalid VLAN id"   VLAN_LIST=4095
expect_reject "VLAN int overflow"   "invalid VLAN id"   VLAN_LIST=18446744073709551626
expect_reject "trailing comma"      "empty"             VLAN_LIST=10,
expect_reject "leading comma"       "empty"             VLAN_LIST=,10
expect_reject "doubled comma"       "empty"             VLAN_LIST=10,,20
expect_reject "tab in VLAN_LIST"    "unsafe"            VLAN_LIST=$'10\t,20'
expect_reject "newline VLAN_LIST"   "unsafe"            VLAN_LIST=$'10\n20'
expect_reject "interior ws VLAN"    "invalid VLAN id"   VLAN_LIST='1 0'
expect_reject "space-only token"    "invalid VLAN id"   VLAN_LIST='10, ,20'

expect_reject "bad IPv4 octet"      "bad addr"   VLAN_LIST=10 IP_MODE=static STATIC_MAP='10:999.1.1.1/24' BASE_IF=trunk0
expect_reject "bad prefix /33"      "bad addr"   VLAN_LIST=10 IP_MODE=static STATIC_MAP='10:1.2.3.4/33' BASE_IF=trunk0
expect_reject "CIDR two slashes"    "bad addr"   VLAN_LIST=10 IP_MODE=static STATIC_MAP='10:192.168.10.250/x/24' BASE_IF=trunk0
expect_reject "loopback addr"       "bad addr"   VLAN_LIST=10 IP_MODE=static STATIC_MAP='10:127.0.0.5/24' BASE_IF=trunk0
expect_reject "linklocal in static" "bad addr"   VLAN_LIST=10 IP_MODE=static STATIC_MAP='10:169.254.1.1/16' BASE_IF=trunk0
expect_reject "multicast addr"      "bad addr"   VLAN_LIST=10 IP_MODE=static STATIC_MAP='10:224.0.0.5/24' BASE_IF=trunk0
expect_reject "unknown map VID"     "not in VLAN_LIST" VLAN_LIST=10 IP_MODE=static STATIC_MAP='10:1.2.3.4/24,99:5.6.7.8/24' BASE_IF=trunk0
expect_reject "missing map VID"     "missing entry"    VLAN_LIST=10,20 IP_MODE=static STATIC_MAP='10:1.2.3.4/24' BASE_IF=trunk0
expect_reject "map in nonstatic"    "only valid"       VLAN_LIST=10 IP_MODE=dhcp STATIC_MAP='10:1.2.3.4/24' BASE_IF=trunk0
expect_reject "newline STATIC_MAP"  "unsafe"           VLAN_LIST=10 IP_MODE=static STATIC_MAP=$'10:1.2.3.4/24\n20:5.6.7.8/24' BASE_IF=trunk0

expect_reject "bad IP_MODE"         "IP_MODE"          VLAN_LIST=10 IP_MODE=bogus BASE_IF=trunk0
expect_reject "non-strict bool"     "true or false"    VLAN_LIST=10 DHCP_FALLBACK_LL=yes BASE_IF=trunk0
expect_reject "lo in extras"        "lo"               VLAN_LIST=10 EXTRA_INTERFACES=lo BASE_IF=trunk0 IP_MODE=static STATIC_MAP='10:1.2.3.4/24'
expect_reject "dup extra"           "duplicate"        VLAN_LIST=10 EXTRA_INTERFACES=x0,x0 BASE_IF=trunk0 IP_MODE=static STATIC_MAP='10:1.2.3.4/24'
expect_reject "extra=trunk"         "trunk"            VLAN_LIST=10 EXTRA_INTERFACES=trunk0 BASE_IF=trunk0 IP_MODE=static STATIC_MAP='10:1.2.3.4/24'
expect_reject "extra=managed vlan"  "duplicates managed" VLAN_LIST=10 EXTRA_INTERFACES=trunk0.10 BASE_IF=trunk0 IP_MODE=static STATIC_MAP='10:1.2.3.4/24'
expect_reject "extra nonexistent"   "does not exist"   VLAN_LIST=10 EXTRA_INTERFACES=ghost9 BASE_IF=trunk0 IP_MODE=static STATIC_MAP='10:1.2.3.4/24'
expect_reject "bad filter token"    "REFLECT_FILTERS"  VLAN_LIST=10 REFLECT_FILTERS='good,with space' BASE_IF=trunk0 IP_MODE=static STATIC_MAP='10:1.2.3.4/24'
expect_reject "lo as BASE_IF"       "BASE_IF"          VLAN_LIST=10 BASE_IF=lo IP_MODE=static STATIC_MAP='10:1.2.3.4/24'

echo "== timeout normalization (leading zeros) =="
expect_ready  "INTERFACE_WAIT_TIMEOUT=08" \
    VLAN_LIST=10 BASE_IF=trunk0 IP_MODE=static STATIC_MAP='10:1.2.3.4/24' \
    INTERFACE_WAIT_TIMEOUT=08 STARTUP_TIMEOUT=20
expect_ready  "STARTUP_TIMEOUT=09" \
    VLAN_LIST=10 BASE_IF=trunk0 IP_MODE=static STATIC_MAP='10:1.2.3.4/24' \
    STARTUP_TIMEOUT=09
expect_reject "timeout 0"           "positive integer" VLAN_LIST=10 BASE_IF=trunk0 STARTUP_TIMEOUT=0
expect_reject "timeout negative"    "positive integer" VLAN_LIST=10 BASE_IF=trunk0 STARTUP_TIMEOUT=-5
expect_reject "timeout overflow"    "positive integer" VLAN_LIST=10 BASE_IF=trunk0 STARTUP_TIMEOUT=99999999999999999

echo "== STATIC_MAP edge-vs-interior whitespace =="
expect_ready  "edge whitespace trimmed" \
    VLAN_LIST=10 BASE_IF=trunk0 IP_MODE=static STARTUP_TIMEOUT=15 \
    STATIC_MAP=' 10:192.168.10.250/24 '
expect_reject "interior whitespace NOT merged" "bad addr" \
    VLAN_LIST=10 BASE_IF=trunk0 IP_MODE=static STATIC_MAP='10:1 92.168.10.250/24'
expect_ready  "VLAN_LIST edge whitespace" \
    VLAN_LIST=' 10 ' BASE_IF=trunk0 IP_MODE=static STATIC_MAP='10:192.168.10.250/24' STARTUP_TIMEOUT=15

echo "== happy path: static mode =="
expect_ready "static 2 VLANs + ready + health" \
    VLAN_LIST=10,20 BASE_IF=trunk0 IP_MODE=static \
    STATIC_MAP='10:192.168.10.250/24,20:192.168.20.250/24' STARTUP_TIMEOUT=20

echo "== idempotent exact reuse + foreign conflict =="
# desired addr already present alone -> reuse (must NOT fail)
ip link add link trunk0 name trunk0.30 type vlan id 30 2>/dev/null
ip link set trunk0.30 multicast on up
ip -4 addr add 192.168.30.250/24 dev trunk0.30
expect_ready "exact existing addr reused" \
    VLAN_LIST=30 BASE_IF=trunk0 IP_MODE=static STATIC_MAP='30:192.168.30.250/24' STARTUP_TIMEOUT=20
# desired + a foreign addr (different subnet so it is not a secondary) -> refuse
ip -4 addr add 10.99.99.1/24 dev trunk0.30
expect_reject "desired+foreign addr refused" "conflicting" \
    VLAN_LIST=30 BASE_IF=trunk0 IP_MODE=static STATIC_MAP='30:192.168.30.250/24' STARTUP_TIMEOUT=8
# foreign only (desired absent) -> must refuse, not overwrite
ip -4 addr del 192.168.30.250/24 dev trunk0.30 2>/dev/null
ip -o -4 addr show dev trunk0.30 | grep -q '10.99.99.1' || { bad "setup lost foreign addr"; }
expect_reject "foreign-only addr refused" "conflicting" \
    VLAN_LIST=30 BASE_IF=trunk0 IP_MODE=static STATIC_MAP='30:192.168.30.250/24' STARTUP_TIMEOUT=8
ip link del trunk0.30 2>/dev/null

echo "== exact-address: /2 desired vs /24 actual =="
ip link add link trunk0 name trunk0.50 type vlan id 50 2>/dev/null
ip link set trunk0.50 multicast on up
ip -4 addr add 192.168.10.250/24 dev trunk0.50
expect_reject "desired /2 vs actual /24" "conflicting" \
    VLAN_LIST=50 BASE_IF=trunk0 IP_MODE=static STATIC_MAP='50:192.168.10.250/2' STARTUP_TIMEOUT=8
ip link del trunk0.50 2>/dev/null

echo "== PREFLIGHT: reject must not mutate (regression A/B/C) =="
# (A) invalid EXTRA + initially-DOWN trunk -> reject, trunk flag UNCHANGED.
ip link add audit0 type dummy 2>/dev/null
ip link set audit0 multicast on          # deliberately left DOWN
before="$(snap)"
env VLAN_LIST=10 BASE_IF=audit0 EXTRA_INTERFACES=ghost0 IP_MODE=static \
    STATIC_MAP='10:192.168.10.250/24' STARTUP_TIMEOUT=8 \
    timeout 20 /entrypoint.sh >/tmp/rA.log 2>&1; rc=$?
after="$(snap)"
if [ $rc -ne 0 ] && [ $rc -lt 124 ] && grep -q 'does not exist' /tmp/rA.log \
    && [ "$before" = "$after" ]; then
    ok "A: invalid EXTRA + down trunk -> reject, trunk stays down"
else
    bad "A (rc=$rc)"; grep -i 'audit0\|exist\|up' /tmp/rA.log | tail -3
fi
ip link del audit0 2>/dev/null

# (B) preexisting VLAN10 (empty) + VLAN20 (foreign) -> reject VLAN20 WITHOUT
#     having assigned VLAN10's address. Both VLANs preexist so none is ours.
ip link add audit0 type dummy 2>/dev/null
ip link set audit0 multicast on up
ip link add link audit0 name audit0.10 type vlan id 10 2>/dev/null
ip link add link audit0 name audit0.20 type vlan id 20 2>/dev/null
ip link set audit0.10 multicast on up
ip link set audit0.20 multicast on up
ip -4 addr add 192.168.20.251/24 dev audit0.20    # foreign on VLAN20
before="$(snap)"
env VLAN_LIST=10,20 BASE_IF=audit0 IP_MODE=static \
    STATIC_MAP='10:192.168.10.250/24,20:192.168.20.250/24' STARTUP_TIMEOUT=8 \
    timeout 20 /entrypoint.sh >/tmp/rB.log 2>&1; rc=$?
after="$(snap)"
if [ $rc -ne 0 ] && [ $rc -lt 124 ] && grep -q 'conflicting' /tmp/rB.log \
    && [ "$before" = "$after" ] \
    && ! ip -o -4 addr show dev audit0.10 | grep -q '192.168.10.250'; then
    ok "B: VLAN20 foreign -> reject, VLAN10 got NO partial address"
else
    bad "B (rc=$rc)"; tail -4 /tmp/rB.log; ip -o -4 addr show dev audit0.10
fi
ip link del audit0.10 2>/dev/null; ip link del audit0.20 2>/dev/null
ip link del audit0 2>/dev/null

# (C) SECOND configured VLAN is the wrong kind (dummy, not a VLAN child):
#     preflight must reject BEFORE creating/bringing-up the FIRST VLAN or trunk.
ip link add audit0 type dummy 2>/dev/null   # start DOWN to prove no trunk raise
ip link set audit0 multicast on
ip link add audit0.20 type dummy 2>/dev/null # same name, NOT a vlan child
before="$(snap)"
env VLAN_LIST=10,20 BASE_IF=audit0 IP_MODE=static \
    STATIC_MAP='10:192.168.10.250/24,20:192.168.20.250/24' STARTUP_TIMEOUT=8 \
    timeout 20 /entrypoint.sh >/tmp/rC.log 2>&1; rc=$?
after="$(snap)"
if [ $rc -ne 0 ] && [ $rc -lt 124 ] && grep -qi 'not VLAN id' /tmp/rC.log \
    && [ "$before" = "$after" ]; then
    ok "C: wrong-kind 2nd VLAN -> reject, no mutation of 1st/trunk"
else
    bad "C (rc=$rc)"; tail -4 /tmp/rC.log
fi
ip link del audit0.20 2>/dev/null; ip link del audit0 2>/dev/null

echo "== composed name length validated before ANY vlan creation =="
# 12-char trunk + '.999' = 16 chars > IFNAMSIZ. Must fail BEFORE creating any
# link (vlan 10 would have been created first if validation were per-vlan).
ip link add tname1234567 type dummy 2>/dev/null
ip link set tname1234567 multicast on up
before="$(snap)"
env VLAN_LIST=10,999 BASE_IF=tname1234567 IP_MODE=static \
    STATIC_MAP='10:1.2.3.4/24,999:5.6.7.8/24' STARTUP_TIMEOUT=8 \
    timeout 20 /entrypoint.sh >/tmp/r.log 2>&1; rc=$?
after="$(snap)"
if [ $rc -ne 0 ] && [ $rc -lt 124 ] && grep -q 'exceeds 15' /tmp/r.log \
    && [ "$before" = "$after" ]; then
    ok "long composed name fails before creating any vlan"
else
    bad "long name check (rc=$rc)"; tail -4 /tmp/r.log
fi
ip link del tname1234567 2>/dev/null

echo "== ambiguous trunk =="
ip link add enx1 type dummy; ip link add enx2 type dummy
ip link set enx1 up; ip link set enx2 up
expect_reject "two trunk candidates" "ambiguous trunk" \
    VLAN_LIST=10 IP_MODE=static STATIC_MAP='10:1.2.3.4/24' STARTUP_TIMEOUT=5
ip link del enx1 2>/dev/null; ip link del enx2 2>/dev/null

echo "== sysfs pseudo-entry (bonding_masters) is not a trunk candidate =="
# CCR2116 regression: RouterOS /sys/class/net contains regular-file pseudo
# entries (e.g. bonding_masters) that are NOT netdevices. They have no ifindex
# file and `ip link show dev` fails - the detector must ignore them so the one
# REAL trunk is still auto-selected (previously: 'ambiguous trunk candidates:
# bonding_masters veth-Avahi'). A fixture tree + a mocked `ip` exercise the
# exact detection function extracted from /entrypoint.sh in a subshell.
detect_fixture() (
    set -e
    . /usr/local/lib/avahi-reflector/lib.sh
    # extract ONLY the detect_candidates function body from the shipped
    # entrypoint so the test exercises the real code path, not a copy.
    eval "$(awk '/^detect_candidates\(\)/,/^\}/' /entrypoint.sh)"
    fake=/tmp/fake-net; rm -rf "$fake"; mkdir -p "$fake"
    # real trunk device: netdevice dir with ifindex + a live `ip` answer
    mkdir -p "$fake/trunk0"; echo 3 >"$fake/trunk0/ifindex"; : >"$fake/trunk0/.live"
    # pseudo-entry: a regular FILE, no ifindex - like RouterOS bonding_masters
    echo x >"$fake/bonding_masters"
    # stale sysfs entry: has ifindex file but no live device (`ip` fails)
    mkdir -p "$fake/ghost0"; echo 9 >"$fake/ghost0/ifindex"
    # a real VLAN child: ifindex + live + a vlan type-line (must be skipped)
    mkdir -p "$fake/trunk0.10"; echo 4 >"$fake/trunk0.10/ifindex"
    : >"$fake/trunk0.10/.live"; : >"$fake/trunk0.10/.vlan"
    ip() {
        # find the operand after 'dev'
        local d="" a prev=""
        for a in "$@"; do [ "$prev" = dev ] && d="$a"; prev="$a"; done
        [ -n "$d" ] || return 1
        [ -f "$fake/$d/.live" ] || return 1
        echo "3: $d: <BROADCAST,MULTICAST,UP> mtu 1500"
        [ -f "$fake/$d/.vlan" ] && echo "    vlan protocol 802.1Q id 10"
        return 0
    }
    detect_candidates "$fake"
)
out="$(detect_fixture)"
if [ "$out" = "trunk0" ]; then
    ok "sysfs pseudo-entries + stale entries ignored -> lone real trunk emitted"
else
    bad "detect_candidates fixture (got: $(echo "$out" | tr '\n' ' '))"
fi
rm -rf /tmp/fake-net

# multiple REAL netdevices in sysfs still fail closed (ambiguity protection)
detect_amb() (
    set -e
    . /usr/local/lib/avahi-reflector/lib.sh
    eval "$(awk '/^detect_candidates\(\)/,/^\}/' /entrypoint.sh)"
    fake=/tmp/fake-net2; rm -rf "$fake"; mkdir -p "$fake"
    for n in e0 e1; do
        mkdir -p "$fake/$n"; echo 5 >"$fake/$n/ifindex"; : >"$fake/$n/.live"
    done
    echo x >"$fake/bonding_masters"      # pseudo-entry still not counted
    ip() {
        local d="" a prev=""
        for a in "$@"; do [ "$prev" = dev ] && d="$a"; prev="$a"; done
        [ -n "$d" ] || return 1
        [ -f "$fake/$d/.live" ] || return 1
        echo "5: $d: <BROADCAST,MULTICAST,UP> mtu 1500"; return 0
    }
    detect_candidates "$fake"
)
out="$(detect_amb)"
if [ "$(printf '%s\n' "$out" | sort | tr '\n' ' ')" = "e0 e1 " ]; then
    ok "two real netdevices -> both emitted (ambiguity protection intact)"
else
    bad "two-device fixture (got: $(echo "$out" | tr '\n' ' '))"
fi
rm -rf /tmp/fake-net2

echo "== unique trunk auto-detect logs BASE_IF=... (auto-detected) =="
# only 'trunk0' exists besides lo -> auto-detect must pick it and say so
# explicitly, then reach ready. Exercises the sysfs ifindex+if_exists gate on
# a REAL interface end-to-end.
start_ep /tmp/ep-auto.log VLAN_LIST=10 IP_MODE=static \
    STATIC_MAP='10:192.168.10.250/24' STARTUP_TIMEOUT=25
wait_for 35 grep -q 'ready:' /tmp/ep-auto.log
if grep -q 'ready:' /tmp/ep-auto.log \
    && grep -q 'BASE_IF=trunk0 (auto-detected)' /tmp/ep-auto.log; then
    ok "lone real interface auto-detected, BASE_IF logged, ready"
else
    bad "auto-detect trunk0"; tail -5 /tmp/ep-auto.log
fi
stop_ep || bad "auto-detect supervisor hung on TERM (had to SIGKILL)"

echo "== veth trunk (@-suffix) accepted =="
ip link add wan0 type veth peer name wan0p 2>/dev/null
ip link set wan0 multicast on up 2>/dev/null
expect_ready "veth trunk works" \
    VLAN_LIST=60 BASE_IF=wan0 IP_MODE=static \
    STATIC_MAP='60:192.168.60.250/24' STARTUP_TIMEOUT=20
ip link del wan0 2>/dev/null

echo "== startup-ack: daemon failure AFTER mutation rolls back (D) =="
# The stub avahi-daemon runs long enough to PROVE our static address was really
# installed on the PREEXISTING vlan (it writes a sentinel only when it can see
# the address), then exits nonzero without ever emitting the init-complete
# line. The supervisor must therefore treat this as a FAILED startup: no
# 'ready', no ack marker, owned addr rolled back, managed vlan flag state
# restored. The previous version of this test pre-assigned a FOREIGN addr on
# the same managed link, so preflight rejected before the stub ever ran - a
# false positive. Foreign-preservation is asserted on an unrelated link here.
mkdir -p /tmp/stub
cat > /tmp/stub/avahi-daemon <<'STUB'
#!/bin/sh
# Test hook: confirm the supervisor's static addr is live on audit0.10 before
# deliberately failing. This runs instead of the real daemon - it never emits
# the init-complete line, so the run must never go ready.
if ip -o -4 addr show dev audit0.10 2>/dev/null | grep -q 'inet 192\.168\.10\.250/24'; then
    echo addr-was-installed > /tmp/stub-saw-addr
fi
echo "stub: proving post-mutation failure" >&2
sleep 1
exit 1
STUB
chmod +x /tmp/stub/avahi-daemon

# -- D1: preexisting vlan is DOWN at start; we raise it, add the addr, then the
#        stub fails -> addr AND the up flag we set must both be rolled back.
rm -f /tmp/stub-saw-addr
ip link add audit0 type dummy 2>/dev/null
ip link set audit0 multicast on up
ip link add link audit0 name audit0.10 type vlan id 10 2>/dev/null
ip link set audit0.10 multicast on          # deliberately left DOWN
# foreign addr on an UNRELATED link must survive the run untouched
ip link add ext0 type dummy 2>/dev/null
ip link set ext0 multicast on up
ip -4 addr add 10.77.77.1/24 dev ext0
out="$(env PATH=/tmp/stub:$PATH VLAN_LIST=10 BASE_IF=audit0 IP_MODE=static \
    STATIC_MAP='10:192.168.10.250/24' STARTUP_TIMEOUT=15 \
    timeout 25 /entrypoint.sh 2>&1)"; rc=$?
fail=0
[ $rc -ne 0 ] && [ $rc -lt 124 ] || { fail=1; echo "    rc=$rc (want clean fail <124)"; }
[ -f /tmp/stub-saw-addr ] || { fail=1; echo "    stub never saw owned addr (mutation not proven)"; }
echo "$out" | grep -q 'stub: proving post-mutation failure' \
    || { fail=1; echo "    exact stub did not run"; }
! echo "$out" | grep -q 'ready:' || { fail=1; echo "    went ready despite no ack"; }
[ ! -f /run/avahi-reflector/ready ] || { fail=1; echo "    ready file left behind"; }
[ ! -f /run/avahi-reflector/avahi.ack ] || { fail=1; echo "    ack marker left behind"; }
! bash /healthcheck.sh >/dev/null 2>&1 || { fail=1; echo "    healthcheck green"; }
! ip -o -4 addr show dev audit0.10 2>/dev/null | grep -q '192\.168\.10\.250' \
    || { fail=1; echo "    owned addr NOT rolled back"; }
ip -o -4 addr show dev ext0 | grep -q '10\.77\.77\.1' \
    || { fail=1; echo "    foreign addr on unrelated link was touched"; }
if_up audit0.10 2>/dev/null && { fail=1; echo "    up flag not restored"; }
if [ $fail -eq 0 ]; then
    ok "D1: post-mutation daemon failure -> addr+flags rolled back, no ready"
else
    bad "D1"; echo "$out" | tail -6; ip -o -4 addr show dev audit0.10
fi

# -- D2: delayed failure (stub lives 2s before dying). A naive 'ready on
#        liveness' would already have declared STARTUP_OK=1 and skipped
#        rollback. With the ack gate it is still a failed startup.
rm -f /tmp/stub-saw-addr
cat > /tmp/stub/avahi-daemon <<'STUB'
#!/bin/sh
if ip -o -4 addr show dev audit0.10 2>/dev/null | grep -q 'inet 192\.168\.10\.250/24'; then
    echo addr-was-installed > /tmp/stub-saw-addr
fi
sleep 2
exit 1
STUB
chmod +x /tmp/stub/avahi-daemon
# audit0.10 still exists from D1 but is now DOWN again (D1 restored the flag);
# keep it down so this run also exercises flag restore.
out="$(env PATH=/tmp/stub:$PATH VLAN_LIST=10 BASE_IF=audit0 IP_MODE=static \
    STATIC_MAP='10:192.168.10.250/24' STARTUP_TIMEOUT=15 \
    timeout 25 /entrypoint.sh 2>&1)"; rc=$?
fail=0
[ $rc -ne 0 ] && [ $rc -lt 124 ] || { fail=1; echo "    rc=$rc (want clean fail <124)"; }
[ -f /tmp/stub-saw-addr ] || { fail=1; echo "    delayed stub never saw owned addr"; }
! echo "$out" | grep -q 'ready:' || { fail=1; echo "    went ready on liveness alone"; }
[ ! -f /run/avahi-reflector/ready ] || { fail=1; echo "    ready file left behind"; }
! ip -o -4 addr show dev audit0.10 2>/dev/null | grep -q '192\.168\.10\.250' \
    || { fail=1; echo "    owned addr NOT rolled back after delayed failure"; }
if_up audit0.10 2>/dev/null && { fail=1; echo "    up flag not restored"; }
if [ $fail -eq 0 ]; then
    ok "D2: delayed (2s) daemon failure -> still rolls back (no ready-on-alive)"
else
    bad "D2"; echo "$out" | tail -6
fi

# -- D3: daemon stays ALIVE but NEVER acknowledges -> STARTUP_TIMEOUT must fire
#        and roll back. This is the explicit controlled-timeout case.
cat > /tmp/stub/avahi-daemon <<'STUB'
#!/bin/sh
# alive but never emits the init-complete line
exec sleep 60
STUB
chmod +x /tmp/stub/avahi-daemon
out="$(env PATH=/tmp/stub:$PATH VLAN_LIST=10 BASE_IF=audit0 IP_MODE=static \
    STATIC_MAP='10:192.168.10.250/24' STARTUP_TIMEOUT=6 \
    timeout 30 /entrypoint.sh 2>&1)"; rc=$?
fail=0
# entrypoint must die(1) via its own startup timeout - i.e. rc=1 from the
# supervisor, NOT 124 (that would mean outer `timeout` had to kill it).
[ $rc -eq 1 ] || { fail=1; echo "    rc=$rc (want 1 = supervisor timeout, not 124)"; }
echo "$out" | grep -q 'timed out' || { fail=1; echo "    no timeout message"; }
! echo "$out" | grep -q 'ready:' || { fail=1; echo "    went ready without ack"; }
[ ! -f /run/avahi-reflector/ready ] || { fail=1; echo "    ready file left behind"; }
! ip -o -4 addr show dev audit0.10 2>/dev/null | grep -q '192\.168\.10\.250' \
    || { fail=1; echo "    owned addr NOT rolled back on ack timeout"; }
if_up audit0.10 2>/dev/null && { fail=1; echo "    up flag not restored"; }
if [ $fail -eq 0 ]; then
    ok "D3: alive-but-never-acks daemon -> supervisor timeout + rollback"
else
    bad "D3"; echo "$out" | tail -6
fi
ip link del ext0 2>/dev/null
ip link del audit0.10 2>/dev/null; ip link del audit0 2>/dev/null
rm -f /tmp/stub-saw-addr /tmp/stub/avahi-daemon

# -- D4: real daemon on a created (not preexisting) vlan: the genuine
#        'Server startup complete' ack must arrive BEFORE 'ready' is logged,
#        and the ack marker must exist while ready. Proves the ack path works
#        end-to-end with the real binary (no stub).
ip link add audit0 type dummy 2>/dev/null
ip link set audit0 multicast on up
start_ep /tmp/epD4.log VLAN_LIST=10 BASE_IF=audit0 IP_MODE=static \
    STATIC_MAP='10:192.168.10.250/24' STARTUP_TIMEOUT=25
okflag=0; ackfirst=0
dl=$((SECONDS+35))
while [ $SECONDS -lt $dl ]; do
    grep -q 'Server startup complete' /tmp/epD4.log 2>/dev/null && ackfirst=1
    grep -q 'ready:' /tmp/epD4.log 2>/dev/null && { okflag=1; break; }
    # if it died early, stop waiting
    kill -0 "$EP" 2>/dev/null || break
    sleep 0.5
done
if [ $okflag -eq 1 ] && [ $ackfirst -eq 1 ] \
    && [ -f /run/avahi-reflector/avahi.ack ] \
    && [ -f /run/avahi-reflector/ready ] \
    && bash /healthcheck.sh >/dev/null 2>&1; then
    # ack must precede ready in the log order
    if [ "$(grep -n 'Server startup complete' /tmp/epD4.log | head -1 | cut -d: -f1)" -lt \
         "$(grep -n 'ready:' /tmp/epD4.log | head -1 | cut -d: -f1)" ]; then
        ok "D4: real daemon ack precedes ready; health green with real avahi"
    else
        bad "D4: ready logged before daemon ack"; grep -n 'complete\|ready' /tmp/epD4.log
    fi
else
    bad "D4 (okflag=$okflag ackfirst=$ackfirst)"; tail -6 /tmp/epD4.log
fi
stop_ep || bad "D4 supervisor hung on TERM (had to SIGKILL)"
ip link del audit0 2>/dev/null

echo "== successful exact reuse is unchanged after normal shutdown (E) =="
# Preexisting vlan with the EXACT desired addr; a clean run+TERM must leave it
# (we did not add it; successful intentional state is retained).
ip link add audit0 type dummy 2>/dev/null
ip link set audit0 multicast on up
ip link add link audit0 name audit0.10 type vlan id 10 2>/dev/null
ip link set audit0.10 multicast on up
ip -4 addr add 192.168.10.250/24 dev audit0.10
start_ep /tmp/ep.log VLAN_LIST=10 BASE_IF=audit0 IP_MODE=static \
    STATIC_MAP='10:192.168.10.250/24' STARTUP_TIMEOUT=20
wait_for 35 grep -q 'ready:' /tmp/ep.log
if grep -q 'ready:' /tmp/ep.log; then
    stop_ep || bad "E supervisor hung on TERM (had to SIGKILL)"
    if ip -o -4 addr show dev audit0.10 | grep -q '192.168.10.250' \
        && ip link show dev audit0.10 >/dev/null 2>&1 \
        && if_up audit0.10 2>/dev/null; then
        ok "E: exact reuse + clean shutdown leaves preexisting state intact"
    else
        bad "E: preexisting state changed on clean shutdown"
        ip -o -4 addr show dev audit0.10
    fi
else bad "E: no ready"; tail -3 /tmp/ep.log; stop_ep; fi
ip link del audit0.10 2>/dev/null; ip link del audit0 2>/dev/null

echo "== if_up flag-token parsing (fixture, mocked ip) =="
# run the fixture in a SUBSHELL so the mocked `ip` never leaks into this script
if_up_fixture() (
  . /usr/local/lib/avahi-reflector/lib.sh
  ip() {
    case "${!#}" in
      f1) echo '3: x: <UP,LOWER_UP> mtu 1' ;;
      f2) echo '3: x: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1' ;;
      f3) echo '3: x: <BROADCAST,LOWER_UP> mtu 1' ;;
      f4) echo '3: x: <NO-CARRIER,BROADCAST,MULTICAST,UP> mtu 1' ;;
      f5) echo '3: x: <BROADCAST,MULTICAST> mtu 1' ;;
    esac
  }
  if_up f1 && if_up f2 && ! if_up f3 && if_up f4 && ! if_up f5
)
if_up_fixture && ok "if_up token cases" || bad "if_up token cases"

echo "== bounded shutdown on unresponsive (SIGSTOPped) child =="
# SIGSTOP the real avahi: the app's OWN cleanup must still TERM->bounded 5s
# poll->KILL the stopped child and exit on its own, removing ready first. This
# is the app's runtime escalation, so it must complete in <=9s and exit WITHOUT
# our helper needing to force-kill it. A helper-side SIGKILL here means FAIL.
ip link add bt0 type dummy 2>/dev/null; ip link set bt0 multicast on up
start_ep /tmp/ep.log VLAN_LIST=10 BASE_IF=bt0 IP_MODE=static \
    STATIC_MAP='10:192.168.10.250/24'
wait_for 35 grep -q 'ready:' /tmp/ep.log
if grep -q 'ready:' /tmp/ep.log; then
    . /run/avahi-reflector/state.env
    kill -STOP "$AVAHI_PID" 2>/dev/null
    t0=$SECONDS; kill -TERM "$EP"
    dl=$((SECONDS+14)); exited=0
    while kill -0 "$EP" 2>/dev/null; do
        [ $SECONDS -lt $dl ] || break; sleep 0.5
    done
    kill -0 "$EP" 2>/dev/null || exited=1
    el=$((SECONDS-t0))
    if [ $exited -eq 1 ]; then
        wait "$EP" 2>/dev/null; EP=""
    else
        stop_ep  # hung beyond budget -> stop_ep force-kills + flags failure
    fi
    if [ $exited -eq 1 ] && [ $el -le 9 ] && [ ! -f /run/avahi-reflector/ready ]; then
        ok "bounded shutdown (${el}s, app exited on own cleanup)"
    else bad "shutdown (${el}s exited=$exited forcekilled=$EP_FORCEKILLED)"; fi
else bad "setup: no ready for shutdown test"; stop_ep; fi
ip link del bt0 2>/dev/null

echo "== reader loss mid-run is essential (not silently green) =="
# After ready, killing the owned log-reader must take the supervisor down:
# the reader is the ack source AND the avahi log path, so its loss must never
# leave a stale-green health state.
ip link add rd0 type dummy 2>/dev/null; ip link set rd0 multicast on up
start_ep /tmp/ep.log VLAN_LIST=10 BASE_IF=rd0 IP_MODE=static \
    STATIC_MAP='10:192.168.10.250/24'
wait_for 35 grep -q 'ready:' /tmp/ep.log
if grep -q 'ready:' /tmp/ep.log; then
    . /run/avahi-reflector/state.env
    kill "$READER_PID" 2>/dev/null
    # supervisor should notice within its ~1s poll + exit; bounded wait
    dl=$((SECONDS+10)); gone=0
    while kill -0 "$EP" 2>/dev/null; do
        [ $SECONDS -lt $dl ] || break; sleep 0.5
    done
    kill -0 "$EP" 2>/dev/null || gone=1
    if [ $gone -eq 1 ] && [ ! -f /run/avahi-reflector/ready ] \
        && ! bash /healthcheck.sh >/dev/null 2>&1 \
        && grep -q 'log forwarder exited' /tmp/ep.log; then
        ok "reader loss -> supervisor exits, ready removed, health red"
    else
        bad "reader loss (gone=$gone)"; tail -4 /tmp/ep.log
    fi
    wait "$EP" 2>/dev/null; EP=""
else bad "setup: no ready for reader-loss test"; stop_ep; fi
ip link del rd0 2>/dev/null

echo "== dhcpcd-unavailable clear failure (this env) =="
# EXPECTED ENVIRONMENT LIMITATION, not a functional pass and not universal:
# dhcpcd cannot run in THIS default unprivileged container (no
# promote_secondaries sysctl, blocked privsep). With the namespace-scoped
# --sysctl it CAN run (see test/dhcp). Here we only assert it FAILS CLEARLY
# without that prereq; real DHCP/LL/renew is verified separately.
out="$(env VLAN_LIST=10 BASE_IF=trunk0 IP_MODE=dhcp DHCP_FALLBACK_LL=false \
      STARTUP_TIMEOUT=25 timeout 30 /entrypoint.sh 2>&1)"
rc=$?
if [ $rc -ne 0 ] && [ $rc -lt 124 ] && echo "$out" | grep -qi 'dhcpcd'; then
    ok "dhcp mode fails clearly when dhcpcd cannot run (env limitation, not functional)"
else
    bad "dhcp mode behaviour (rc=$rc)"; echo "$out" | tail -5
fi

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
