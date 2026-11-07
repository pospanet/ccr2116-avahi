#!/usr/bin/env bash
# End-to-end mDNS reflection test for the reflector image.
#
# Real packets on real (tagged) VLAN segments: a dedicated internal Docker
# network acts as the tagged "wire"; the reflector container gets its trunk on
# eth0 and manages VLAN sub-interfaces; each client container is a separate
# netns pinned to ONE VLAN sub-interface of its own eth0. Reflection is proven
# only by observing the EXACT emitted records (PTR/SRV/TXT/A) arrive via the
# reflector's own address on a DIFFERENT client segment - never by a bare
# config line or an unverified "some packet".
#
# Requires: docker, a built runtime image, and the e2e test image
# (test/e2e/Dockerfile = runtime image + python3, built locally, never pushed).
#
#   IMG=<runtime-image> TESTIMG=<e2e-image> bash test/e2e/run.sh
#
# Env overrides:
#   IMG       runtime image under test   (default ccr2116-avahi:local-amd64)
#   TESTIMG   e2e image (runtime + py3)  (default = $IMG if it has python3)
#   PLATFORM  docker --platform value    (default linux/amd64)
#   SUBNET    base of the 3 /24 subnets  (default 10.90; must be a.b form)
set -u
# On Windows Git-Bash/MSYS, container paths (/bin/bash, /t/...) would get
# path-translated into Windows paths. Disable it for THIS process only.
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'

IMG="${IMG:-ccr2116-avahi:local-amd64}"
TESTIMG="${TESTIMG:-$IMG}"
PLATFORM="${PLATFORM:-linux/amd64}"
SUBNET="${SUBNET:-10.90}"
# unique run id: every resource (containers, network) is tagged with this
# exact label so cleanup touches ONLY objects we created in this run.
RUN="e2e-$$-$RANDOM"
NET="e2ewire-$$-$RANDOM"
LABEL="e2e-avahi-lab=$RUN"     # exact-match label value on all our resources
PASS=0; FAIL=0

ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

# --- strict env/input validation (values are embedded into docker commands)
die() { echo "FATAL: $*" >&2; exit 2; }
# NEGATIVE charset = ALL chars must be in the safe set (a stray bad char -> die)
case "$IMG" in    ''|*[!A-Za-z0-9._/:@-]*) die "unsafe IMG";; esac
case "$TESTIMG" in ''|*[!A-Za-z0-9._/:@-]*) die "unsafe TESTIMG";; esac
# PLATFORM: explicit linux/<arch> form only (no stray/empty/metachars)
case "$PLATFORM" in
    linux/*)
        rest="${PLATFORM#linux/}"
        # arch token: alnum only, no extra '/', dots, spaces, or empty
        case "$rest" in
            ''|*/*|*.*|*' '*|*[!A-Za-z0-9]*) die "unsafe PLATFORM (want linux/<arch>)";;
        esac
        ;;
    *) die "unsafe PLATFORM (want linux/<arch>)";;
esac
# SUBNET must be exactly a.b (two numeric octets), bounded, no leading zeros.
# Validate BEFORE creating any docker resource. Require EXACTLY one dot.
_sdots="${SUBNET//[^.]/}"; [ "${#_sdots}" -eq 1 ] || die "SUBNET must be a.b"
a="${SUBNET%%.*}"; b="${SUBNET##*.}"
case "$a" in ''|*[!0-9]*) die "SUBNET must be a.b";; esac
case "$b" in ''|*[!0-9]*) die "SUBNET must be a.b";; esac
# no leading zeros (except bare "0") and bounded length
case "$a" in 0?*) die "SUBNET octet has leading zero";; esac
case "$b" in 0?*) die "SUBNET octet has leading zero";; esac
[ "${#a}" -le 3 ] && [ "${#b}" -le 3 ] || die "SUBNET octet too long"
a=$((10#$a)); b=$((10#$b))
[ "$a" -ge 1 ] && [ "$a" -le 223 ] && [ "$b" -le 255 ] \
    || die "SUBNET octet out of range (a:1-223, b:0-255)"
unset _sdots

# ------------------------------------------------------------- cleanup
# Remove ONLY resources carrying OUR exact run label. No broad prunes, never
# touch containers/networks we did not create in this run.
cleanup() {
    local id
    for id in $(docker ps -aq --filter "label=$LABEL" 2>/dev/null); do
        docker rm -f "$id" >/dev/null 2>&1
    done
    for id in $(docker network ls -q --filter "label=$LABEL" 2>/dev/null); do
        docker network rm "$id" >/dev/null 2>&1
    done
}
trap cleanup EXIT

echo "== e2e reflector lab: image=$IMG test=$TESTIMG platform=$PLATFORM net=$NET"
# create the wire; only mark it ours AFTER the create succeeded
docker network create --internal --label "$LABEL" "$NET" >/dev/null \
    || die "cannot create internal network $NET"

# ------------------------------------------------------------- reflector
start_reflector() {
    docker run -d --platform "$PLATFORM" --name "${RUN}-refl" \
        --network "$NET" --label "$LABEL" \
        --cap-add NET_ADMIN --cap-add NET_RAW \
        -e VLAN_LIST=10,20 -e BASE_IF=eth0 -e IP_MODE=static \
        -e STATIC_MAP="10:${SUBNET}.10.1/24,20:${SUBNET}.20.1/24" \
        -e STARTUP_TIMEOUT=30 \
        "$@" "$IMG" >/dev/null
    local dl=$((SECONDS+45))
    until docker logs "${RUN}-refl" 2>&1 | grep -q 'ready:'; do
        [ $SECONDS -lt $dl ] || return 1
        sleep 1
    done
}
stop_reflector() { docker rm -f "${RUN}-refl" >/dev/null 2>&1; }

# ------------------------------------------------------------- clients
# client <name> <vid> <ip> <cmd...> : detached client on segment <vid>.
client() {
    local name=$1 vid=$2 ip=$3; shift 3
    docker run -d --platform "$PLATFORM" --name "${RUN}-${name}" \
        --network "$NET" --label "$LABEL" \
        --cap-add NET_ADMIN --cap-add NET_RAW --entrypoint /bin/bash \
        "$TESTIMG" -c \
        "set -e
         ip link add link eth0 name eth0.$vid type vlan id $vid
         ip link set eth0.$vid up multicast on
         ip -4 addr add $ip/24 dev eth0.$vid
         $*" >/dev/null
}
# bounded wait for a client to exit; returns its numeric exit code.
wait_client() {
    local dl=$((SECONDS+20))
    while docker inspect -f '{{.State.Running}}' "${RUN}-$1" 2>/dev/null | grep -q true; do
        [ $SECONDS -lt $dl ] || { docker rm -f "${RUN}-$1" >/dev/null 2>&1; return 124; }
        sleep 0.5
    done
    docker inspect -f '{{.State.ExitCode}}' "${RUN}-$1" 2>/dev/null
}
# block until a listener container prints __READY__ (socket bound+joined)
wait_ready() {
    local dl=$((SECONDS+15))
    until docker logs "${RUN}-$1" 2>&1 | grep -q '__READY__'; do
        # if the container already died, fail fast
        docker inspect -f '{{.State.Running}}' "${RUN}-$1" 2>/dev/null | grep -q true || return 1
        [ $SECONDS -lt $dl ] || return 1
        sleep 0.3
    done
}
# block until a sender container prints __SENT__ (packet actually emitted)
wait_sent() {
    local dl=$((SECONDS+15))
    until docker logs "${RUN}-$1" 2>&1 | grep -q '__SENT__'; do
        docker inspect -f '{{.State.Running}}' "${RUN}-$1" 2>/dev/null | grep -q true || return 1
        [ $SECONDS -lt $dl ] || return 1
        sleep 0.3
    done
}
# full raw log of a client
logs()  { docker logs "${RUN}-$1" 2>&1; }
# captured-packet dump: lines after __HEARD__ marker
heard() { logs "$1" | awk '/^__HEARD__$/{f=1;next} f'; }
# did the client log contain a hard error (traceback / parse-error)?
client_error() { logs "$1" | grep -qE 'Traceback|<parse-error|setup failed|send failed'; }

# literal fixed-string contains (NOT regex): has "<haystack>" "<needle>"
has()   { case "$1" in *"$2"*) return 0;; *) return 1;; esac; }
empty() { [ -z "$(printf '%s' "$1" | tr -d '[:space:]')" ]; }

# listen command (in-container). Prints __READY__, captures, then __HEARD__+dump
LISTEN_TO=8
listener() { echo "python3 /t/mdns.py listen --if $1 --timeout $LISTEN_TO --out /tmp/h.txt"; }
ANN()   { echo "python3 /t/mdns.py announce --if $1 --src-ip $2 --type $3 --instance $4 --host $5 --port $6 --target-ip $7 --txt $8"; }
QUERY() { echo "python3 /t/mdns.py query --if $1 --src-ip $2 --name $3"; }

# ================================================================== [1]
echo "== [1] positive reflection: announce on seg10 -> observed on seg20 (exact records)"
start_reflector || { bad "reflector never became ready"; logs refl | tail; }
# expect the announce to be reflected and show up on the OTHER segment.
client c20 20 "${SUBNET}.20.2" "$(listener eth0.20)"
wait_ready c20 || bad "listener c20 never became ready"
client c10 10 "${SUBNET}.10.2" "$(ANN eth0.10 ${SUBNET}.10.2 _e2eok._tcp.local inst1 host1.local 80 ${SUBNET}.10.2 k=v)"
wait_sent c10 || bad "sender c10 never emitted packet"
rc=$(wait_client c20); [ "$rc" = "0" ] || bad "listener c20 exited rc=$rc"
rc=$(wait_client c10); [ "$rc" = "0" ] || bad "sender c10 exited rc=$rc"
client_error c20 && bad "c20 logged an error"
out="$(heard c20)"
# exact full record set: PTR target, SRV target+port, TXT payload, A record
if has "$out" "PTR _e2eok._tcp.local. -> inst1._e2eok._tcp.local." \
   && has "$out" "SRV inst1._e2eok._tcp.local. -> host1.local.:80" \
   && has "$out" "TXT inst1._e2eok._tcp.local. [k=v]" \
   && has "$out" "A host1.local. -> ${SUBNET}.10.2" \
   && has "$out" "${SUBNET}.20.1:"; then
    ok "announce reflected seg10->seg20 with exact PTR/SRV:80/TXT/A"
else
    bad "reflection"; printf '%s\n' "$out" | sed 's/^/    /'
fi
docker rm -f "${RUN}-c10" "${RUN}-c20" >/dev/null 2>&1

# ================================================================== [2]
echo "== [2] query seg20 -> seg10: reflected packet carries the exact question"
client c10 10 "${SUBNET}.10.5" "$(listener eth0.10)"
wait_ready c10 || bad "listener c10 never became ready"
client c20q 20 "${SUBNET}.20.5" "$(QUERY eth0.20 ${SUBNET}.20.5 _e2eq._tcp.local)"
wait_sent c20q || bad "sender c20q never emitted query"
rc=$(wait_client c10); [ "$rc" = "0" ] || bad "listener c10 exited rc=$rc"
rc=$(wait_client c20q); [ "$rc" = "0" ] || bad "sender c20q exited rc=$rc"
out="$(heard c10)"
# Assert the SAME captured packet line is BOTH (a) sourced from the reflector's
# own seg10 address AND (b) carries the exact question with exact type/class.
# mdns.py prints "<srcip>: <recs>" so one line must hold reflector IP + the
# literal question token - not two unrelated packets.
qline="$(printf '%s\n' "$out" | grep -F "Q _e2eq._tcp.local. type=PTR class=1")"
if has "$qline" "${SUBNET}.10.1:"; then
    ok "reflected query on seg10 carries exact Q _e2eq PTR/IN via reflector IP"
else
    bad "query reflection seg20->seg10"; printf '%s\n' "$out" | sed 's/^/    /'
fi
docker rm -f "${RUN}-c10" "${RUN}-c20q" >/dev/null 2>&1

# ================================================================== [3]
echo "== [3] isolation: unmanaged VLAN30 announce -> seg10 must NOT receive it"
client c10x 10 "${SUBNET}.10.9" "$(listener eth0.10)"
wait_ready c10x || bad "listener c10x never became ready"
client c30 30 "${SUBNET}.30.2" "$(ANN eth0.30 ${SUBNET}.30.2 _e2eok._tcp.local inst30 host30.local 80 ${SUBNET}.30.2 k=v)"
wait_sent c30 || bad "sender c30 never emitted packet"
rc=$(wait_client c10x); [ "$rc" = "0" ] || bad "listener c10x exited rc=$rc"
rc=$(wait_client c30); [ "$rc" = "0" ] || bad "sender c30 exited rc=$rc"
client_error c10x && bad "c10x logged an error"
out="$(heard c10x)"
if empty "$out"; then
    ok "unmanaged VLAN30 announce not reflected to seg10"
else
    bad "VLAN30 leaked"; printf '%s\n' "$out" | sed 's/^/    /'
fi
docker rm -f "${RUN}-c10x" "${RUN}-c30" >/dev/null 2>&1

# ================================================================== [4]
echo "== [4] same-segment sanity: announce on seg10 heard on seg10 (control)"
client c10s 10 "${SUBNET}.10.7" "$(listener eth0.10)"
wait_ready c10s || bad "listener c10s never became ready"
client c10a 10 "${SUBNET}.10.6" "$(ANN eth0.10 ${SUBNET}.10.6 _e2eok._tcp.local instS hostS.local 80 ${SUBNET}.10.6 k=v)"
wait_sent c10a || bad "sender c10a never emitted packet"
rc=$(wait_client c10s); [ "$rc" = "0" ] || bad "listener c10s exited rc=$rc"
rc=$(wait_client c10a); [ "$rc" = "0" ] || bad "sender c10a exited rc=$rc"
out="$(heard c10s)"
if has "$out" "PTR _e2eok._tcp.local. -> instS._e2eok._tcp.local."; then
    ok "same-segment announce reaches its own segment (control)"
else
    bad "same-segment announce not received"; printf '%s\n' "$out" | sed 's/^/    /'
fi
docker rm -f "${RUN}-c10s" "${RUN}-c10a" >/dev/null 2>&1

# ================================================================== [5]
echo "== [5] avahi stopped -> no reflection (proves reflector, not the wire)"
docker exec "${RUN}-refl" pkill -TERM avahi-daemon >/dev/null 2>&1 || true
sleep 2
client c20s 20 "${SUBNET}.20.8" "$(listener eth0.20)"
wait_ready c20s || bad "listener c20s never became ready"
client c10d 10 "${SUBNET}.10.4" "$(ANN eth0.10 ${SUBNET}.10.4 _e2eok._tcp.local instD hostD.local 80 ${SUBNET}.10.4 k=v)"
wait_sent c10d || bad "sender c10d never emitted packet"
rc=$(wait_client c20s); [ "$rc" = "0" ] || bad "listener c20s exited rc=$rc"
rc=$(wait_client c10d); [ "$rc" = "0" ] || bad "sender c10d exited rc=$rc"
out="$(heard c20s)"
if empty "$out"; then
    ok "no reflection after avahi stopped (reflector was the cause)"
else
    bad "reflection continued with avahi dead"; printf '%s\n' "$out" | sed 's/^/    /'
fi
docker rm -f "${RUN}-c20s" "${RUN}-c10d" >/dev/null 2>&1
stop_reflector

# ================================================================== [6]
echo "== [6] reflect-filters=_e2eok._tcp.local"
start_reflector -e REFLECT_FILTERS='_e2eok._tcp.local' || bad "filtered reflector not ready"
echo "   -- matching type _e2eok -> seg20 SHOULD see full records"
client c20f 20 "${SUBNET}.20.6" "$(listener eth0.20)"
wait_ready c20f || bad "listener c20f never became ready"
client c10f 10 "${SUBNET}.10.3" "$(ANN eth0.10 ${SUBNET}.10.3 _e2eok._tcp.local instF hostF.local 80 ${SUBNET}.10.3 k=v)"
wait_sent c10f || bad "sender c10f never emitted packet"
rc=$(wait_client c20f); [ "$rc" = "0" ] || bad "listener c20f exited rc=$rc"
rc=$(wait_client c10f); [ "$rc" = "0" ] || bad "sender c10f exited rc=$rc"
out="$(heard c20f)"
if has "$out" "PTR _e2eok._tcp.local. -> instF._e2eok._tcp.local." \
   && has "$out" "SRV instF._e2eok._tcp.local. -> hostF.local.:80" \
   && has "$out" "TXT instF._e2eok._tcp.local. [k=v]" \
   && has "$out" "A hostF.local. -> ${SUBNET}.10.3"; then
    ok "matching service reflected through filter (full records)"
else
    bad "matching service dropped by filter"; printf '%s\n' "$out" | sed 's/^/    /'
fi
docker rm -f "${RUN}-c20f" "${RUN}-c10f" >/dev/null 2>&1

echo "   -- NON-matching type _e2eno -> service records suppressed on seg20"
echo "      (avahi 0.9 still forwards bare A/AAAA address records - filters"
echo "       filter *services*, not address records; not a security boundary)"
client c20n 20 "${SUBNET}.20.7" "$(listener eth0.20)"
wait_ready c20n || bad "listener c20n never became ready"
client c10n 10 "${SUBNET}.10.3" "$(ANN eth0.10 ${SUBNET}.10.3 _e2eno._tcp.local instN hostN.local 80 ${SUBNET}.10.3 k=v)"
wait_sent c10n || bad "sender c10n never emitted packet"
rc=$(wait_client c20n); [ "$rc" = "0" ] || bad "listener c20n exited rc=$rc"
rc=$(wait_client c10n); [ "$rc" = "0" ] || bad "sender c10n exited rc=$rc"
out="$(heard c20n)"
if ! has "$out" "_e2eno._tcp.local." \
   && ! has "$out" "instN._e2eno"; then
    ok "non-matching service PTR/SRV/TXT suppressed on seg20"
    has "$out" "A hostN.local." \
        && echo "    (info: bare A record still forwarded - avahi addr-vs-service semantics)"
else
    bad "non-matching service leaked"; printf '%s\n' "$out" | sed 's/^/    /'
fi
docker rm -f "${RUN}-c20n" "${RUN}-c10n" >/dev/null 2>&1
stop_reflector

# ================================================================== [7]
echo "== [7] harness self-check: a failed listener must FAIL the lab"
# point the listener at a nonexistent interface -> __READY__ never appears,
# client dies -> wait_ready must return non-zero (not a false 'empty' pass).
client cbad 10 "${SUBNET}.10.60" "$(listener eth0.99)"
if wait_ready cbad; then
    bad "fault-injection: listener on bad IF reported ready (harness too weak)"
else
    rc=$(wait_client cbad)
    [ "$rc" != "0" ] || bad "fault-injection: bad listener exited 0"
    logs cbad | grep -q 'setup failed' || bad "fault-injection: no 'setup failed' logged"
    ok "listener on nonexistent IF -> wait_ready fails + nonzero exit (no false pass)"
fi
docker rm -f "${RUN}-cbad" >/dev/null 2>&1

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
