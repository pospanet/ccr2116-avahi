#!/bin/bash
# Focused runtime security/correctness tests for the reflector image.
# Runs INSIDE the built image on --network none with NET_ADMIN+NET_RAW only.
# Covers: strict 802.1Q-vs-802.1ad VLAN identity, interface-name charset
# handling, trunk-kind detection by link TYPE (not name), failed-startup
# flag/address rollback ordering, and the startup-ack gate.
#
#   docker run --rm --network none --cap-add NET_ADMIN --cap-add NET_RAW \
#       --entrypoint /bin/bash -v "$PWD/test:/t" <image> /t/runtime-security.sh
set -u
# shellcheck source=../lib.sh
. /usr/local/lib/avahi-reflector/lib.sh
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

# snapshot of links+addrs for "no mutation" checks. Only STABLE fields are
# compared: link names + their <flag,list> + inet addrs. qdisc/state/LOWER_UP
# change kernel-side after a link has once been up (noop->noqueue) and are NOT
# managed state, so a strict `ip -o link` diff would false-positive.
snap() {
    ip -o link show | awk '{n=$2; sub(/:.*/,"",n); if (match($0,/<[^>]*>/)) \
        print n, substr($0,RSTART,RLENGTH)}'
    ip -o -4 addr show
}

# wait_for <timeout-sec> <cmd...> : bounded condition wait, not a fixed sleep.
wait_for() {
    local dl=$((SECONDS + $1)); shift
    until "$@"; do
        [ $SECONDS -lt $dl ] || return 1
        sleep 0.5
    done
}

# ---- owned-fixture lifecycle ---------------------------------------------
# EP is a GLOBAL set by start_ep; the supervisor is a DIRECT background child
# of THIS test shell (no `timeout` wrapper, no command-substitution subshell),
# so kill/wait/poll act on the real process and never return early while it is
# still cleaning up shared /run state. That was the source of a cross-fixture
# race: `EP=$(run_ep ...)` ran the launcher in a subshell, orphaning the actual
# daemon supervisor which then cleared the NEXT fixture's ready/ack/state.
EP=""
EP_FORCEKILLED=0

# start_ep <logfile> <env...> : launch entrypoint as an owned background child.
start_ep() {
    local log="$1"; shift
    EP=""; EP_FORCEKILLED=0
    # Parent-side truncation prevents reading a previous fixture's ready line
    # before the asynchronous child opens and truncates this shared log path.
    : >"$log" || return 1
    env "$@" /entrypoint.sh >"$log" 2>&1 &
    EP=$!
}

# stop_ep : TERM our owned supervisor, wait bounded for it to fully exit (its
# own cleanup removes ready/ack/state + network mutations), and only SIGKILL
# if it is genuinely hung - which is reported as a failure, not masked. The
# app's own runtime escalation to a STOPPED child is expected and still exits
# 0 well inside this budget; we only flag when the app itself had to be killed.
# Returns 0 when the child exited on its own within the grace window.
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
# No `exit` inside the trap so the original exit status is preserved.
trap '[ -n "$EP" ] && { kill -9 "$EP" 2>/dev/null; wait "$EP" 2>/dev/null; }; true' EXIT

cleanup_links() { local l; for l in "$@"; do ip link del "$l" 2>/dev/null; done; }

echo "== if_vlan_ok: strict kind + protocol + vid + parent =="
ip link add s0 type dummy 2>/dev/null
ip link add s1 type dummy 2>/dev/null
ip link add link s0 name s0.10 type vlan id 10 2>/dev/null          # 802.1Q vid10 parent s0
ip link add link s0 name s0.20 type vlan protocol 802.1ad id 20 2>/dev/null  # QinQ
ip link add link s0 name s0.30 type vlan id 30 2>/dev/null
ip link add link s1 name s1.30 type vlan id 30 2>/dev/null          # same vid, other parent
ip link add sdum type dummy 2>/dev/null
ip link add svx type vxlan id 300 dstport 4789 nolearning 2>/dev/null

t() { if "$@"; then echo 0; else echo 1; fi; }
fails=0
[ "$(t if_vlan_ok s0.10 s0 10)" = 0 ] || { fails=1; echo "    1Q right vid/parent rejected"; }
[ "$(t if_vlan_ok s0.20 s0 20)" = 1 ] || { fails=1; echo "    802.1ad accepted as 802.1Q"; }
[ "$(t if_vlan_ok s0.30 s0 31)" = 1 ] || { fails=1; echo "    wrong vid accepted"; }
[ "$(t if_vlan_ok s0.30 s1 30)" = 1 ] || { fails=1; echo "    wrong parent accepted"; }
[ "$(t if_vlan_ok s1.30 s0 30)" = 1 ] || { fails=1; echo "    vid matches but parent wrong accepted"; }
[ "$(t if_vlan_ok s1.30 s1 30)" = 0 ] || { fails=1; echo "    right vid/parent s1.30 rejected"; }
[ "$(t if_vlan_ok sdum s0 10)" = 1 ]  || { fails=1; echo "    dummy accepted as vlan"; }
[ "$(t if_vlan_ok svx s0 300)" = 1 ]  || { fails=1; echo "    vxlan id matched as vlan id"; }
[ $fails -eq 0 ] && ok "if_vlan_ok discriminates 1Q/1ad/vid/parent/vxlan/dummy" \
                 || bad "if_vlan_ok matrix"

echo "== trunk-kind detection by TYPE, not name =="
# a real trunk legitimately NAMED 'vlan-trunk' must be accepted as a trunk,
# while an actual vlan child must be rejected. Also 'if_kind_is_vlan' unit.
ip link add vlan-trunk type dummy 2>/dev/null
ip link set vlan-trunk multicast on up
ip link add link vlan-trunk name vlan-trunk.10 type vlan id 10 2>/dev/null
fails=0
if_kind_is_vlan vlan-trunk     && { fails=1; echo "    dummy named vlan-trunk seen as vlan"; }
if_kind_is_vlan vlan-trunk.10  || { fails=1; echo "    real vlan child not seen as vlan"; }
[ $fails -eq 0 ] && ok "if_kind_is_vlan: named-vlan-trunk ok, real child detected" \
                 || bad "if_kind_is_vlan kind detection"

# whole entrypoint must accept a trunk literally named vlan-trunk
start_ep /tmp/vt.log VLAN_LIST=10 BASE_IF=vlan-trunk IP_MODE=static \
        STATIC_MAP='10:192.168.11.250/24' STARTUP_TIMEOUT=20
if wait_for 30 grep -q 'ready:' /tmp/vt.log; then
    ok "trunk named 'vlan-trunk' (dummy) accepted, reaches ready"
else
    bad "vlan-trunk trunk"; tail -4 /tmp/vt.log
fi
stop_ep || bad "vlan-trunk supervisor hung on TERM (had to SIGKILL)"
cleanup_links vlan-trunk.10 vlan-trunk

# a trunk that IS a vlan child must be rejected (explicit BASE_IF)
ip link add q0 type dummy 2>/dev/null; ip link set q0 multicast on up
ip link add link q0 name q0.40 type vlan id 40 2>/dev/null; ip link set q0.40 multicast on up
out="$(env VLAN_LIST=10 BASE_IF=q0.40 IP_MODE=static STATIC_MAP='10:1.2.3.4/24' \
        timeout 20 /entrypoint.sh 2>&1)"; rc=$?
if [ $rc -ne 0 ] && [ $rc -lt 124 ] && echo "$out" | grep -q 'VLAN sub-interface'; then
    ok "explicit vlan-child BASE_IF rejected as trunk"
else
    bad "vlan-child trunk reject (rc=$rc)"; echo "$out" | tail -3
fi
cleanup_links q0.40 q0

echo "== name charset: literal '@'/':' names =="
# explicit BASE_IF containing '@' must die early with a clear error, before any
# network mutation.
before="$(snap)"
out="$(env VLAN_LIST=10 BASE_IF='p@x' IP_MODE=static STATIC_MAP='10:1.2.3.4/24' \
        timeout 15 /entrypoint.sh 2>&1)"; rc=$?
after="$(snap)"
if [ $rc -ne 0 ] && [ $rc -lt 124 ] && echo "$out" | grep -qi 'not a supported interface name' \
    && [ "$before" = "$after" ]; then
    ok "explicit BASE_IF='p@x' rejected early, no mutation"
else
    bad "BASE_IF '@' reject (rc=$rc)"; echo "$out" | tail -3
fi

# EXTRA_INTERFACES with '@' must also die early
before="$(snap)"
out="$(env VLAN_LIST=10 BASE_IF=s0 IP_MODE=static STATIC_MAP='10:1.2.3.4/24' \
        EXTRA_INTERFACES='e@1' timeout 15 /entrypoint.sh 2>&1)"; rc=$?
after="$(snap)"
if [ $rc -ne 0 ] && [ $rc -lt 124 ] && echo "$out" | grep -qi 'EXTRA_INTERFACES bad name' \
    && [ "$before" = "$after" ]; then
    ok "EXTRA_INTERFACES 'e@1' rejected early, no mutation"
else
    bad "EXTRA '@' reject (rc=$rc)"; echo "$out" | tail -3
fi

# autodetect must NOT pick a truncated candidate: a lone REAL interface named
# 'p@x' must not be auto-selected as 'p' (kernel allowed it, we don't).
cleanup_links s0.10 s0.20 s0.30 s1.30 sdum svx s0 s1
ip link add 'p@x' type dummy 2>/dev/null
before="$(snap)"
out="$(env VLAN_LIST=10 IP_MODE=static STATIC_MAP='10:1.2.3.4/24' \
        INTERFACE_WAIT_TIMEOUT=4 timeout 15 /entrypoint.sh 2>&1)"; rc=$?
after="$(snap)"
# it must NOT auto-detect 'p' (truncated) - expect 'no trunk interface found'
if [ $rc -ne 0 ] && echo "$out" | grep -q 'no trunk interface found' \
    && [ "$before" = "$after" ]; then
    ok "autodetect skips unsupported 'p@x' (no truncated 'p' candidate)"
else
    bad "autodetect '@' skip (rc=$rc)"; echo "$out" | tail -4
fi
ip link del 'p@x' 2>/dev/null

# valid veth DISPLAY '@peer' suffix must still work as a trunk (peer side is a
# display artifact, not part of the name).
ip link add vw0 type veth peer name vw0p 2>/dev/null
ip link set vw0 multicast on up
start_ep /tmp/vw.log VLAN_LIST=60 BASE_IF=vw0 IP_MODE=static \
        STATIC_MAP='60:192.168.60.250/24' STARTUP_TIMEOUT=20
if wait_for 30 grep -q 'ready:' /tmp/vw.log; then
    ok "veth trunk (vw0@vw0p display) accepted, reaches ready"
else
    bad "veth trunk"; tail -4 /tmp/vw.log
fi
stop_ep || bad "veth supervisor hung on TERM (had to SIGKILL)"
cleanup_links vw0

echo "== preflight: wrong-protocol preexisting VLAN rejected before ANY mutation =="
# VLAN10 exists as good-but-EMPTY 802.1Q; VLAN20 exists as a FOREIGN 802.1ad
# (QinQ) link. The run must reject VLAN20 in read-only preflight WITHOUT having
# created/raised/addressed VLAN10 or raised the down trunk.
ip link add audit0 type dummy 2>/dev/null
ip link set audit0 multicast on                 # deliberately DOWN
ip link add link audit0 name audit0.10 type vlan id 10 2>/dev/null   # 1Q, empty, down
ip link add link audit0 name audit0.20 type vlan protocol 802.1ad id 20 2>/dev/null  # QinQ foreign
before="$(snap)"
out="$(env VLAN_LIST=10,20 BASE_IF=audit0 IP_MODE=static \
        STATIC_MAP='10:192.168.10.250/24,20:192.168.20.250/24' \
        STARTUP_TIMEOUT=8 timeout 20 /entrypoint.sh 2>&1)"; rc=$?
after="$(snap)"
if [ $rc -ne 0 ] && [ $rc -lt 124 ] && echo "$out" | grep -q 'not VLAN id' \
    && [ "$before" = "$after" ] \
    && ! ip -o -4 addr show dev audit0.10 2>/dev/null | grep -q '192\.168\.10\.250' \
    && ! if_up audit0 2>/dev/null; then
    ok "802.1ad preexisting VLAN rejected in preflight, zero mutations"
else
    bad "QinQ preflight reject (rc=$rc)"; echo "$out" | tail -5; ip -o -4 addr show dev audit0.10
fi
cleanup_links audit0.10 audit0.20 audit0

echo "== failed startup: trunk+child flags restored in safe order =="
# trunk DOWN, preexisting 1Q vlan child DOWN+no-multicast. Static addr gets
# installed, then a stub avahi fails after seeing the addr -> failed start must
# restore BOTH links to their initial flag state (children before trunk) and
# remove the owned addr.
mkdir -p /tmp/stub
cat > /tmp/stub/avahi-daemon <<'STUB'
#!/bin/sh
# Prove the static addr was installed on audit0.10, then fail without ack.
if ip -o -4 addr show dev audit0.10 2>/dev/null | grep -q 'inet 192\.168\.10\.250/24'; then
    echo saw-addr > /tmp/stub-saw-addr
fi
sleep 1
exit 1
STUB
chmod +x /tmp/stub/avahi-daemon
rm -f /tmp/stub-saw-addr
ip link add audit0 type dummy 2>/dev/null
ip link set audit0 multicast on                 # trunk: MULTICAST already on, but DOWN
ip link add link audit0 name audit0.10 type vlan id 10 2>/dev/null
ip link set audit0.10 multicast off down 2>/dev/null  # child: DOWN + MC off
before="$(snap)"
out="$(env PATH=/tmp/stub:"$PATH" VLAN_LIST=10 BASE_IF=audit0 IP_MODE=static \
        STATIC_MAP='10:192.168.10.250/24' STARTUP_TIMEOUT=12 \
        timeout 25 /entrypoint.sh 2>&1)"; rc=$?
after="$(snap)"
fails=0
[ $rc -ne 0 ] && [ $rc -lt 124 ] || { fails=1; echo "    rc=$rc"; }
[ -f /tmp/stub-saw-addr ] || { fails=1; echo "    stub never saw owned addr"; }
! echo "$out" | grep -q 'ready:' || { fails=1; echo "    went ready without ack"; }
! ip -o -4 addr show dev audit0.10 2>/dev/null | grep -q '192\.168\.10\.250' \
    || { fails=1; echo "    owned addr not rolled back"; }
if_up audit0.10 2>/dev/null && { fails=1; echo "    child up flag not restored"; }
if_up audit0    2>/dev/null && { fails=1; echo "    trunk up flag not restored"; }
ip link show dev audit0.10 2>/dev/null | grep -qE '<[^>]*MULTICAST' \
    && { fails=1; echo "    child multicast flag not restored"; }
[ "$before" = "$after" ] || { fails=1; echo "    netns differs after failed start"; }
[ $fails -eq 0 ] && ok "failed start: addr removed, trunk+child flags restored (initial state kept)" \
                 || bad "failed-start flag restore"
cleanup_links audit0.10 audit0
rm -f /tmp/stub-saw-addr /tmp/stub/avahi-daemon

echo "== health flips red when a ready 1Q vlan is swapped for same-name 802.1ad =="
# Real avahi on a created 802.1Q vlan reaches ready+health green; then the link
# is deleted and a same-named 802.1ad link carrying the SAME CIDR is created.
# Health must go red on the protocol/identity check (not merely 'link exists').
ip link add h0 type dummy 2>/dev/null; ip link set h0 multicast on up
start_ep /tmp/h.log VLAN_LIST=10 BASE_IF=h0 IP_MODE=static \
        STATIC_MAP='10:192.168.10.250/24' STARTUP_TIMEOUT=25
if wait_for 30 grep -q 'ready:' /tmp/h.log && bash /healthcheck.sh >/dev/null 2>&1; then
    # swap: delete our 1Q vlan, recreate as 802.1ad with the same name+addr
    ip link del h0.10 2>/dev/null
    ip link add link h0 name h0.10 type vlan protocol 802.1ad id 10 2>/dev/null
    ip link set h0.10 multicast on up
    ip -4 addr add 192.168.10.250/24 dev h0.10
    if bash /healthcheck.sh >/dev/null 2>&1; then
        bad "health stayed green on 802.1ad replacement"
    else
        ok "health red after 1Q->802.1ad same-name+addr swap"
    fi
else
    bad "setup: no ready/health green before swap"; tail -4 /tmp/h.log
fi
stop_ep || bad "h0 supervisor hung on TERM (had to SIGKILL)"
cleanup_links h0.10 h0

echo "== startup-ack regression: real daemon ack still gates ready on 1Q =="
ip link add a0 type dummy 2>/dev/null; ip link set a0 multicast on up
start_ep /tmp/a.log VLAN_LIST=10 BASE_IF=a0 IP_MODE=static \
        STATIC_MAP='10:192.168.10.250/24' STARTUP_TIMEOUT=25
if wait_for 30 grep -q 'ready:' /tmp/a.log \
    && grep -q 'Server startup complete' /tmp/a.log \
    && [ -f /run/avahi-reflector/avahi.ack ] \
    && bash /healthcheck.sh >/dev/null 2>&1; then
    ok "real daemon ack + ready + green on 802.1Q path (unchanged)"
else
    bad "1Q ack path"; tail -5 /tmp/a.log
fi
stop_ep || bad "a0 supervisor hung on TERM (had to SIGKILL)"
cleanup_links a0

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
