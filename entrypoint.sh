#!/usr/bin/env bash
# Avahi mDNS reflector for MikroTik CCR2116 / RouterOS container (linux/arm64).
#
# All configuration is validated BEFORE any network mutation. Network changes
# are limited to interfaces we own or that the user explicitly named.
# dhcpcd is the sole DHCP/IPv4LL address manager; static mode needs no client.
set -euo pipefail
umask 077

# shellcheck source=lib.sh
. /usr/local/lib/avahi-reflector/lib.sh

RUN=/run/avahi-reflector
DHCPCD_CONF=$RUN/dhcpcd.conf
AVAHI_CONF=/etc/avahi/avahi-daemon.conf
AVAHI_TMPL=/etc/avahi/avahi-daemon.conf.tmpl
STATE_FILE=$RUN/state.env
READY_FILE=$RUN/ready
# Avahi has no machine-readable readiness protocol in 0.9 (no systemd notify in
# this build, no D-Bus): the only genuine "server init complete" signal is the
# log line emitted by the AVAHI_SERVER_RUNNING callback. The daemon's stderr is
# therefore routed through an OWNED FIFO to a tracked reader that forwards every
# line to container stderr in real time and drops a root-owned ack marker only
# when that line appears.
AVAHI_FIFO=$RUN/avahi.log.fifo
ACK_FILE=$RUN/avahi.ack

# ------------------------------------------------------------------- env in
VLAN_LIST="${VLAN_LIST:-}"                          # required: "10,20,300"
BASE_IF="${BASE_IF:-}"                              # optional explicit trunk
IP_MODE="${IP_MODE:-dhcp}"                          # dhcp | static | linklocal
STATIC_MAP="${STATIC_MAP:-}"                        # "10:192.168.10.250/24,..."
EXTRA_INTERFACES="${EXTRA_INTERFACES:-}"            # optional, comma list
DHCP_FALLBACK_LL="${DHCP_FALLBACK_LL:-false}"       # dhcp only
INTERFACE_WAIT_TIMEOUT="${INTERFACE_WAIT_TIMEOUT:-30}"
STARTUP_TIMEOUT="${STARTUP_TIMEOUT:-60}"
REFLECT_FILTERS="${REFLECT_FILTERS:-}"
LOG_LEVEL="${LOG_LEVEL:-info}"

# owned children (started by THIS supervisor via $!) + their start-time tokens
AVAHI_PID=""  ; AVAHI_TOK=""
DHCPCD_PID="" ; DHCPCD_TOK=""
READER_PID="" ; READER_TOK=""   # owned avahi stderr forwarder/ack writer
declare -a CREATED_VLANS=()     # "name ifindex" pairs we created
declare -a OWNED_ADDRS=()       # "ifname ifindex cidr" addrs WE added to preexisting links
declare -a UP_RESTORE=()        # "ifname ifindex" links WE brought up (restore down on failed start)
declare -a MC_RESTORE=()        # "ifname ifindex" links WE set multicast on (restore off on failed start)
declare -A PREEXISTING_VLAN=()  # ifname -> ifindex of VLAN links that existed before us
STARTUP_OK=0                    # 1 once 'ready' reached - failed-start rollback policy gate
declare -a VIDS=()
declare -a EXTRAS=()
declare -A SIP=()
declare -a FILTERS=()

# --------------------------------------------------------------- validation
# norm_bool_r <out-var> <token> : lowercase + strip whitespace in pure bash,
# write true|false into <out-var> via a nameref. No $( ) at the call site (the
# validation path deliberately avoids command-substitution subshells).
norm_bool_r() {
    # __nb holds the candidate; named to never collide with a caller out-var or
    # a caller's own locals (a same-name `local` would shadow the nameref).
    local -n _o="$1"; local __nb="${2,,}"
    __nb="${__nb//[[:space:]]/}"
    case "$__nb" in true|false) _o="$__nb" ;; *) return 1 ;; esac
}
# Prints normalized bool; 1 on invalid. (print contract kept)
norm_bool() { local v; norm_bool_r v "$1" || return 1; printf '%s' "$v"; }

# A comma-separated field must not embed newline/CR (which would hide extra
# "lines" that per-token whitespace trimming could silently discard) or other
# control characters. Returns 0 when the raw value is safe to split on ','.
# Printable-character validity is enforced per-token by the dedicated
# validators (norm_vid / valid_cidr / valid_ifname / valid_filter).
safe_list() {
    local v="$1"
    case "$v" in *$'\n'*|*$'\r'*|*$'\t'*) return 1 ;; esac
    # A here-string avoids the extra printf pipeline child.
    LC_ALL=C grep -q '[^[:print:] ]' <<<"$v" && return 1
    return 0
}

validate_env() {
    local _vl _sm _ex _rf    # scratch trimmed values (trimv targets; no $( ))
    # ---- numeric/mode scalars first (cheap, no lists)
    case "$IP_MODE" in dhcp|static|linklocal) ;; *) die "IP_MODE must be dhcp|static|linklocal";; esac
    case "$LOG_LEVEL" in info|debug) ;; *) die "LOG_LEVEL must be info|debug";; esac

    norm_bool_r DHCP_FALLBACK_LL "$DHCP_FALLBACK_LL" \
        || die "DHCP_FALLBACK_LL must be true or false"

    # timeouts: strict digits, bounded, then NORMALIZE to decimal (08->8) so
    # later shell arithmetic never hits "value too great for base".
    posint "$INTERFACE_WAIT_TIMEOUT" || die "INTERFACE_WAIT_TIMEOUT must be a positive integer (1..86400)"
    posint "$STARTUP_TIMEOUT"        || die "STARTUP_TIMEOUT must be a positive integer (1..86400)"
    INTERFACE_WAIT_TIMEOUT=$((10#$INTERFACE_WAIT_TIMEOUT))
    STARTUP_TIMEOUT=$((10#$STARTUP_TIMEOUT))

    # ---- VLAN_LIST (required): edge whitespace ok, interior/newline not.
    trimv _vl "$VLAN_LIST"
    [ -n "$_vl" ] || die "VLAN_LIST is required (e.g. VLAN_LIST=10,20)"
    safe_list "$VLAN_LIST" || die "VLAN_LIST has unsafe characters"
    has_empty_token "$_vl" \
        && die "VLAN_LIST has empty/leading/trailing/doubled token"
    local IFS=',' v nv
    read -ra raw <<< "$VLAN_LIST"
    declare -A seen=()
    for v in "${raw[@]}"; do
        norm_vid_r nv "$v" || die "invalid VLAN id in VLAN_LIST: '$v'"
        [ -z "${seen[$nv]:-}" ] || die "duplicate VLAN id: $nv"
        seen[$nv]=1
        VIDS+=("$nv")
    done
    [ "${#VIDS[@]}" -gt 0 ] || die "VLAN_LIST produced no VLAN ids"

    # ---- STATIC_MAP: required and exact in static mode (edge-ws tolerated)
    [ -z "$STATIC_MAP" ] || safe_list "$STATIC_MAP" \
        || die "STATIC_MAP has unsafe characters"
    if [ "$IP_MODE" = static ]; then
        trimv _sm "$STATIC_MAP"
        [ -n "$_sm" ] || die "STATIC_MAP required when IP_MODE=static"
        has_empty_token "$_sm" \
            && die "STATIC_MAP has empty/leading/trailing/doubled token"
        local IFS=',' p vid cidr
        read -ra pairs <<< "$STATIC_MAP"
        for p in "${pairs[@]}"; do
            trimv p "$p"                            # edge whitespace OK
            case "$p" in
                *:*) : ;;
                *) die "STATIC_MAP entry '$p' must be VID:IPv4/prefix";;
            esac
            norm_vid_r vid "${p%%:*}"  || die "STATIC_MAP bad VID in '$p'"
            valid_cidr_r cidr "${p#*:}" || die "STATIC_MAP bad addr in '$p'"
            [ -z "${SIP[$vid]:-}" ] || die "STATIC_MAP duplicate VID $vid"
            SIP[$vid]="$cidr"
        done
        for v in "${VIDS[@]}"; do
            [ -n "${SIP[$v]:-}" ] || die "STATIC_MAP missing entry for VLAN $v"
        done
        for v in "${!SIP[@]}"; do
            [ -n "${seen[$v]:-}" ] || die "STATIC_MAP entry for VLAN $v not in VLAN_LIST"
        done
    else
        trimv _sm "$STATIC_MAP"
        [ -z "$_sm" ] \
            || die "STATIC_MAP is only valid with IP_MODE=static (got IP_MODE=$IP_MODE)"
    fi

    # ---- EXTRA_INTERFACES
    [ -z "$EXTRA_INTERFACES" ] || safe_list "$EXTRA_INTERFACES" \
        || die "EXTRA_INTERFACES has unsafe characters"
    trimv _ex "$EXTRA_INTERFACES"
    if [ -n "$_ex" ]; then
        has_empty_token "$_ex" \
            && die "EXTRA_INTERFACES has empty/leading/trailing/doubled token"
        local IFS=',' e
        read -ra ex <<< "$EXTRA_INTERFACES"
        declare -A eseen=()
        for e in "${ex[@]}"; do
            trimv e "$e"
            valid_ifname "$e" || die "EXTRA_INTERFACES bad name: '$e'"
            [ "$e" != lo ] || die "EXTRA_INTERFACES must not contain 'lo'"
            [ -z "${eseen[$e]:-}" ] || die "EXTRA_INTERFACES duplicate: $e"
            eseen[$e]=1
            EXTRAS+=("$e")
        done
    fi

    # ---- REFLECT_FILTERS
    [ -z "$REFLECT_FILTERS" ] || safe_list "$REFLECT_FILTERS" \
        || die "REFLECT_FILTERS has unsafe characters"
    trimv _rf "$REFLECT_FILTERS"
    if [ -n "$_rf" ]; then
        has_empty_token "$_rf" \
            && die "REFLECT_FILTERS has empty/leading/trailing/doubled token"
        local IFS=',' f
        read -ra rf <<< "$REFLECT_FILTERS"
        for f in "${rf[@]}"; do
            trimv f "$f"
            valid_filter "$f" || die "REFLECT_FILTERS bad token: '$f'"
            FILTERS+=("$f")
        done
        warn "REFLECT_FILTERS restricts which mDNS service names are reflected"
    else
        warn "REFLECT_FILTERS unset: ALL mDNS traffic on allowed interfaces is reflected"
    fi

    # ---- BASE_IF: strict (no whitespace at all), not loopback
    if [ -n "$BASE_IF" ]; then
        reject_unsafe "$BASE_IF" || die "BASE_IF has unsafe characters"
        valid_ifname "$BASE_IF" \
            || die "BASE_IF '$BASE_IF' is not a supported interface name (use [A-Za-z0-9._-], max 15 chars; '@' and ':' are ambiguous in ip output)"
        [ "$BASE_IF" != lo ] || die "BASE_IF must not be 'lo'"
    fi
}

# ------------------------------------------------------------------ preflight
# READ-ONLY global preflight. Runs AFTER env validation + BASE_IF resolution +
# trunk-kind check and BEFORE ANY network mutation (trunk raise, VLAN create,
# flag changes, static/DHCP addressing). Every rejection reachable from here
# must leave the namespace byte-for-byte untouched - this is the two-phase
# "validate everything, then mutate" boundary.
preflight() {
    local v vid e ifn
    # (1) every composed VLAN name must fit IFNAMSIZ up front, regardless of
    #     whether BASE_IF was explicit or auto-detected.
    for v in "${VIDS[@]}"; do
        valid_ifname "${BASE_IF}.${v}" \
            || die "composed interface name '${BASE_IF}.${v}' exceeds 15 chars"
    done
    # (2) trunk must be multicast-capable L2 (read-only check; raising is a
    #     later mutation done only after this whole preflight passes).
    ip link show dev "$BASE_IF" | grep -qE '<[^>]*MULTICAST' \
        || die "BASE_IF '$BASE_IF' has no MULTICAST flag - mDNS cannot flow"
    # (3) every EXTRA: no overlap with trunk/managed names, exists, UP, and
    #     already carries a usable IPv4 (extras are user-managed; we never
    #     address or raise them ourselves).
    for e in "${EXTRAS[@]+"${EXTRAS[@]}"}"; do
        [ "$e" != "$BASE_IF" ] \
            || die "EXTRA_INTERFACES '$e' duplicates trunk BASE_IF"
        for vid in "${VIDS[@]}"; do
            [ "$e" != "${BASE_IF}.${vid}" ] \
                || die "EXTRA_INTERFACES '$e' duplicates managed VLAN"
        done
        if_exists "$e" || die "EXTRA_INTERFACES '$e' does not exist"
        if_up "$e"     || die "EXTRA_INTERFACES '$e' is down (extras must be preconfigured UP)"
        if_has_v4 "$e" || die "EXTRA_INTERFACES '$e' has no IPv4 (extras must be preconfigured)"
    done
    # (4) for EVERY managed VLAN: if it already exists it must be a genuine
    #     VLAN child of THIS trunk with THIS id (never reuse a same-name
    #     foreign link). Record preexisting links so later steps only restore
    #     flags we changed and roll back only addresses we added.
    for v in "${VIDS[@]}"; do
        ifn="${BASE_IF}.${v}"
        if if_exists "$ifn"; then
            if_vlan_ok "$ifn" "$BASE_IF" "$v" \
                || die "interface $ifn exists but is not VLAN id $v on $BASE_IF (refusing to reuse)"
            PREEXISTING_VLAN[$ifn]="$(if_index "$ifn")"
            # (5) static mode: the full conflict check on EVERY existing VLAN
            #     happens here, before ANY address is assigned anywhere - a
            #     foreign IPv4 on a later VLAN must not leave a new address
            #     behind on an earlier one.
            if [ "$IP_MODE" = static ] && if_foreign_v4 "$ifn" "${SIP[$v]}"; then
                die "static: $ifn has a conflicting/foreign IPv4, refusing (preflight)"
            fi
        fi
    done
    log "preflight ok: no mutations needed to validate topology"
}

# ------------------------------------------------------------- trunk detect
# Candidate = non-loopback L2 interface that is NOT a VLAN child. Real names are
# enumerated from sysfs (/sys/class/net/*) rather than `ip -o link` display
# text, because display text strips nothing: a literal '@' inside a real kernel
# name (e.g. 'p@x') would be silently truncated to 'p' by display parsing and
# could alias a different device. sysfs entries are the authoritative names.
# Real device TYPE is then checked via `ip -d` type-line (never a name match):
# a RouterOS trunk is typically a plain eth/veth/dummy, NOT a vlan child.
#
# /sys/class/net also contains regular-file pseudo-entries that are NOT
# netdevices at all (RouterOS exposes e.g. 'bonding_masters'). A plain glob
# would happily print those as trunk candidates. A real netdevice always has a
# readable ifindex file AND answers `ip link show dev`; require BOTH before an
# entry can become a candidate.
detect_candidates() {
    local dev path
    # sysfs netdev dir; an explicit override is accepted only so the detector
    # can be exercised against a fixture tree in tests - production callers
    # always use the default.
    local sysfs="${1:-/sys/class/net}"
    for path in "$sysfs"/*; do
        [ -e "$path" ] || continue
        dev="${path##*/}"
        [ "$dev" != lo ] || continue
        # only names in our supported charset can ever be managed here; a real
        # name containing '@'/':'/' '/whitespace is skipped, NOT truncated.
        valid_ifname "$dev" || continue
        # sysfs pseudo-entries (e.g. bonding_masters) have no ifindex file -
        # they are not netdevices, skip them before any `ip` probe.
        [ -f "$path/ifindex" ] || continue
        # and the entry must resolve to a live interface right now.
        if_exists "$dev" || continue
        # skip VLAN children - identified by link KIND, not by name.
        if_kind_is_vlan "$dev" && continue
        printf '%s\n' "$dev"
    done
}

wait_for_base_if() {
    local deadline cand n
    deadline=$(( SECONDS + INTERFACE_WAIT_TIMEOUT ))
    if [ -n "$BASE_IF" ]; then
        while ! if_exists "$BASE_IF"; do
            [ $SECONDS -lt $deadline ] || die "BASE_IF '$BASE_IF' did not appear"
            log "waiting for BASE_IF=$BASE_IF ..."
            sleep 1
        done
        log "BASE_IF=$BASE_IF (explicit)"
        return
    fi
    while :; do
        mapfile -t cand < <(detect_candidates)
        n=${#cand[@]}
        if [ "$n" -eq 1 ]; then
            BASE_IF="${cand[0]}"
            log "BASE_IF=$BASE_IF (auto-detected)"
            return
        elif [ "$n" -gt 1 ]; then
            die "ambiguous trunk candidates: ${cand[*]}. Set BASE_IF explicitly."
        fi
        [ $SECONDS -lt $deadline ] || die "no trunk interface found; set BASE_IF"
        log "waiting for a trunk interface ..."
        sleep 1
    done
}

# Trunk sanity shared by explicit + auto-detected BASE_IF: not a loopback, not
# itself a VLAN child. Anchored to the `ip -d` TYPE line, so an interface
# legitimately NAMED 'vlan-trunk' (kind veth/dummy) is still accepted while a
# real vlan/vlan-protocol child (802.1Q or 802.1ad) is rejected.
check_trunk_kind() {
    if if_kind_is_vlan "$BASE_IF"; then
        die "BASE_IF '$BASE_IF' is a VLAN sub-interface, not a trunk"
    fi
    return 0
}

# ------------------------------------------------------------- VLAN creation
# Record that WE raised a link that we did not create (preexisting trunk/VLAN).
# Stored as "name ifindex" so rollback only ever touches the same link object.
track_up()   { UP_RESTORE+=("$1 $(if_index "$1")"); }
# Record that WE enabled multicast on a link we did not create.
track_mc()   { MC_RESTORE+=("$1 $(if_index "$1")"); }

ensure_vlan() {
    local vid="$1"
    local ifn="${BASE_IF}.${vid}"
    local preexisting=0
    if if_exists "$ifn"; then
        # narrow race-safe recheck; the global identity check already ran in
        # preflight, so a mismatch here means something changed underneath us.
        if_vlan_ok "$ifn" "$BASE_IF" "$vid" \
            || die "interface $ifn exists but is not VLAN id $vid on $BASE_IF (refusing to reuse)"
        [ -n "${PREEXISTING_VLAN[$ifn]:-}" ] || PREEXISTING_VLAN[$ifn]="$(if_index "$ifn")"
        preexisting=1
        log "VLAN $ifn already exists (validated)"
    else
        # protocol pinned explicitly so the link we make always matches what
        # if_vlan_ok() will later verify (kernel default is 802.1Q, but never
        # rely on a default for a type we then assert).
        ip link add link "$BASE_IF" name "$ifn" type vlan protocol 802.1Q id "$vid" \
            || die "failed to create VLAN $ifn"
        CREATED_VLANS+=("$ifn $(if_index "$ifn")")
        log "created VLAN $ifn (ifindex $(if_index "$ifn"))"
    fi
    # Flags: only track a restore for links we did NOT create. Links in
    # CREATED_VLANS are deleted outright on cleanup, so flag state is moot.
    if [ "$preexisting" -eq 1 ]; then
        ip link show dev "$ifn" | grep -qE '<[^>]*MULTICAST' || track_mc "$ifn"
        if_up "$ifn" || track_up "$ifn"
    fi
    ip link set "$ifn" multicast on || die "cannot set multicast on $ifn"
    ip link set "$ifn" up            || die "cannot bring $ifn up"
}

# ------------------------------------------------------------- addressing
# Generate dhcpcd.conf with only validated literals (no sed substitution).
gen_dhcpcd_conf() {
    {
        echo 'ipv4only'
        [ "$IP_MODE" = linklocal ] && echo 'nodhcp'
        [ "$IP_MODE" = dhcp ] && [ "$DHCP_FALLBACK_LL" = false ] && echo 'noipv4ll'
        echo 'nogateway'
        echo 'nohook resolv.conf,hostname,ntp.conf,yp.conf,wpa_supplicant,timezone,lookup-hostname,test'
        echo 'nooption classless_static_routes,ms_classless_static_routes,static_routes,domain_name_servers,domain_name,domain_search,ntp_servers'
        # keep dhcpcd in foreground retrying forever; IPv4LL fallback is driven
        # by the default 'reboot' timeout (starts ~5s after DISCOVER begins).
        echo 'timeout 0'
    } > "$DHCPCD_CONF"
}

start_addressing() {
    case "$IP_MODE" in
        static)
            local v ifn cidr
            for v in "${VIDS[@]}"; do
                ifn="${BASE_IF}.${v}"; cidr="${SIP[$v]}"
                # narrow recheck (race safety): the full all-VLAN conflict scan
                # already ran in preflight before any mutation.
                if if_foreign_v4 "$ifn" "$cidr"; then
                    die "static: $ifn has a conflicting/foreign IPv4, refusing"
                fi
                if if_has_addr "$ifn" "$cidr"; then
                    log "static: $ifn already has exactly $cidr (reusing)"
                else
                    ip -4 addr add "$cidr" dev "$ifn" || die "static: failed $cidr on $ifn"
                    # Only roll back addresses WE added to links we did NOT
                    # create. Addrs on CREATED_VLANS vanish with the link.
                    if [ -n "${PREEXISTING_VLAN[$ifn]:-}" ]; then
                        OWNED_ADDRS+=("$ifn ${PREEXISTING_VLAN[$ifn]} $cidr")
                    fi
                    log "static: $ifn -> $cidr"
                fi
                if_has_addr "$ifn" "$cidr" || die "static: verify failed on $ifn"
            done
            ;;
        dhcp|linklocal)
            gen_dhcpcd_conf
            local ifs=() v
            for v in "${VIDS[@]}"; do ifs+=("${BASE_IF}.${v}"); done
            log "dhcpcd: starting on ${ifs[*]} (mode=$IP_MODE, ll_fallback=$DHCP_FALLBACK_LL)"
            # run in foreground; output goes straight to container stderr so
            # lease/LL transitions stay visible in `docker logs`.
            dhcpcd -B -f "$DHCPCD_CONF" "${ifs[@]}" &
            DHCPCD_PID=$!
            DHCPCD_TOK="$(proc_start "$DHCPCD_PID")"
            # Give it a few seconds to either settle into privsep/lease work or
            # die on an unsupported environment. Do not mask a dead manager.
            local settle=0 alive=1
            while [ $settle -lt 6 ]; do
                sleep 1; settle=$((settle+1))
                kill -0 "$DHCPCD_PID" 2>/dev/null || { alive=0; break; }
            done
            if [ "$alive" -eq 0 ]; then
                wait "$DHCPCD_PID" 2>/dev/null || true   # reap + capture status
                cat <<-EOF >&2
				ERROR: dhcpcd exited during init (see its stderr above).
				  Observed causes in this container:
				    - /proc/sys is read-only and net.ipv4.conf.*.promote_secondaries
				      is not already 1. dhcpcd 10.x only needs to WRITE it when it
				      differs; it is already 1 inside a FRESH container network
				      namespace created with e.g.
				        docker run --sysctl net.ipv4.conf.default.promote_secondaries=1 ...
				      (namespace-scoped, no host change or extra privilege needed).
				    - its privilege-separation sockets are unavailable in this
				      environment (observed under QEMU user-mode emulation:
				      'Protocol not supported'); may also be blocked by seccomp.
				  dhcpcd is the sole DHCP/IPv4LL manager - DHCP/linklocal are
				  unavailable in this environment. Static mode still works.
				EOF
                die "dhcpcd failed to start"
            fi
            ;;
    esac
}

# --------------------------------------------------------------- avahi conf
# Render the config by replacing two placeholders, but build the substitution
# values only from already-validated structured data (interface names, filter
# tokens) - never raw env. This avoids any sed/delimiter injection.
render_avahi() {
    local allow="" v
    for v in "${VIDS[@]}"; do allow+="${BASE_IF}.${v},"; done
    for v in "${EXTRAS[@]+"${EXTRAS[@]}"}"; do allow+="${v},"; done
    allow="${allow%,}"
    local filters_line=""
    if [ "${#FILTERS[@]}" -gt 0 ]; then
        local IFS=','
        filters_line="reflect-filters=${FILTERS[*]}"
    fi
    local tmp
    tmp="$(mktemp /etc/avahi/.avahi-daemon.conf.XXXXXX)"
    # use awk (literal gsub on a placeholder string) instead of sed 's/x/y/'
    # so no delimiter in $allow/$filters_line can alter the result.
    awk -v a="$allow" -v f="$filters_line" '
        { gsub(/\{\{ALLOW_INTERFACES\}\}/, a); gsub(/\{\{REFLECT_FILTERS\}\}/, f); print }
    ' "$AVAHI_TMPL" > "$tmp"
    mv -f "$tmp" "$AVAHI_CONF"
    chmod 644 "$AVAHI_CONF"
    log "avahi allow-interfaces: $allow"
}

# ---------------------------------------------------------------- readiness
iface_ready() {
    local v ifn
    for v in "${VIDS[@]}"; do
        ifn="${BASE_IF}.${v}"
        if_exists "$ifn" && if_up "$ifn" || return 1
        if_vlan_ok "$ifn" "$BASE_IF" "$v" || return 1
        case "$IP_MODE" in
            static)    if_has_addr "$ifn" "${SIP[$v]}" || return 1 ;;
            linklocal) if_ll_v4 "$ifn" || return 1 ;;
            dhcp)
                if [ "$DHCP_FALLBACK_LL" = true ]; then
                    if_has_v4 "$ifn" || return 1
                else
                    if_global_v4 "$ifn" || return 1
                fi ;;
        esac
    done
    for v in "${EXTRAS[@]+"${EXTRAS[@]}"}"; do
        if_exists "$v" && if_up "$v" || return 1
        if_has_v4 "$v" || return 1
    done
    return 0
}

# alive = an owned child PID still running with the SAME start token and not a
# zombie (we poll is_running in the supervise loop instead of a bare blocking
# wait, so an exited child must NOT read as alive while it awaits reaping).
is_running() {
    proc_alive "$1" || return 1
    [ -n "$2" ] || return 0
    [ "$(proc_start "$1" 2>/dev/null)" = "$2" ]
}

child_alive() { is_running "$1" "$2"; }

procs_alive() {
    child_alive "$AVAHI_PID"  "$AVAHI_TOK"  || return 1
    child_alive "$READER_PID" "$READER_TOK" || return 1
    [ "$IP_MODE" = static ] && return 0
    child_alive "$DHCPCD_PID" "$DHCPCD_TOK"
}

# ------------------------------------------------------- avahi startup ack
# The reader is an OWNED child ($! + start token, supervised, killed on
# cleanup). It does two things: (1) forward every avahi log line to container
# stderr in real time, (2) write the root-owned ack marker when - and only
# when - the daemon's own AVAHI_SERVER_RUNNING callback line appears. The ack
# file is created via an atomic mktemp+mv so the supervisor never sees a torn
# write; a repeated line (e.g. after a host-name collision retry) just rewrites
# it, and a stale marker can never exist because the file is deleted before the
# FIFO is created on every run.
avahi_log_reader() {
    umask 077
    exec <"$AVAHI_FIFO"           # O_RDONLY open: blocks until avahi opens O_WRONLY
    local line tmp
    while IFS= read -r line; do
        printf '%s\n' "$line" >&2
        case "$line" in
            *"Server startup complete."*)
                tmp="$(mktemp "$RUN/.ack.XXXXXX")" || continue
                printf 'ack\n' >"$tmp"
                chmod 600 "$tmp"
                mv -f "$tmp" "$ACK_FILE" ;;
        esac
    done
    # EOF: last writer (the daemon) closed its end - it is gone.
}

# avahi_ready: genuine daemon init-complete observed AND iface state verified.
avahi_ready() { [ -f "$ACK_FILE" ]; }

start_avahi() {
    # FIFO then READER then DAEMON - never a daemon writing into a fifo no one
    # reads (writer-side open would block forever, masking the exit).
    rm -f "$ACK_FILE"; mkfifo -m 600 "$AVAHI_FIFO"
    avahi_log_reader &  READER_PID=$!
    READER_TOK="$(proc_start "$READER_PID")"
    local AVAHI_ARGS=""
    [ "$LOG_LEVEL" = debug ] && AVAHI_ARGS="--debug"
    avahi-daemon $AVAHI_ARGS 2>"$AVAHI_FIFO" &
    AVAHI_PID=$!
    AVAHI_TOK="$(proc_start "$AVAHI_PID")"
}

write_state() {
    mkdir -p "$RUN"
    local tmp; tmp="$(mktemp "$RUN/.state.XXXXXX")"
    {
        printf 'BASE_IF=%q\n' "$BASE_IF"
        printf 'IP_MODE=%q\n' "$IP_MODE"
        printf 'DHCP_FALLBACK_LL=%q\n' "$DHCP_FALLBACK_LL"
        declare -p VIDS EXTRAS 2>/dev/null
        printf 'AVAHI_PID=%q\n' "$AVAHI_PID"
        printf 'AVAHI_TOK=%q\n' "$AVAHI_TOK"
        printf 'READER_PID=%q\n' "$READER_PID"
        printf 'READER_TOK=%q\n' "$READER_TOK"
        printf 'DHCPCD_PID=%q\n' "$DHCPCD_PID"
        printf 'DHCPCD_TOK=%q\n' "$DHCPCD_TOK"
        declare -p SIP 2>/dev/null || echo "declare -A SIP=()"
    } > "$tmp"
    chmod 600 "$tmp"; mv -f "$tmp" "$STATE_FILE"
}

# ------------------------------------------------------------- supervision
# reap <pid> : collect an already-exited child (non-blocking for us).
reap() { wait "$1" 2>/dev/null || true; }

do_cleanup() {
    trap - TERM INT EXIT
    # mark unready FIRST so a concurrent healthcheck fails immediately.
    rm -f "$READY_FILE" "$STATE_FILE" "$ACK_FILE"
    # TERM our own children only, by PID+stored start token.
    local p tok
    for p in "$AVAHI_PID" "$DHCPCD_PID" "$READER_PID"; do
        tok=""
        [ "$p" = "$AVAHI_PID" ]  && tok="$AVAHI_TOK"
        [ "$p" = "$DHCPCD_PID" ] && tok="$DHCPCD_TOK"
        [ "$p" = "$READER_PID" ] && tok="$READER_TOK"
        [ -n "$p" ] && is_running "$p" "$tok" && kill "$p" 2>/dev/null || true
    done
    # bounded poll (never a bare blocking wait on a possibly-stopped child)
    local _i
    for _i in 1 2 3 4 5; do
        { [ -z "$AVAHI_PID" ]  || ! is_running "$AVAHI_PID"  "$AVAHI_TOK"; } && \
        { [ -z "$DHCPCD_PID" ] || ! is_running "$DHCPCD_PID" "$DHCPCD_TOK"; } && \
        { [ -z "$READER_PID" ] || ! is_running "$READER_PID" "$READER_TOK"; } && break
        sleep 1
    done
    # escalate only what is still running (same identity); then reap so no zombie
    for p in "$AVAHI_PID" "$DHCPCD_PID" "$READER_PID"; do
        tok=""
        [ "$p" = "$AVAHI_PID" ]  && tok="$AVAHI_TOK"
        [ "$p" = "$DHCPCD_PID" ] && tok="$DHCPCD_TOK"
        [ "$p" = "$READER_PID" ] && tok="$READER_TOK"
        [ -n "$p" ] && is_running "$p" "$tok" && kill -9 "$p" 2>/dev/null || true
        [ -n "$p" ] && reap "$p" || true
    done
    rm -f "$ACK_FILE" "$AVAHI_FIFO"
    # ---- network teardown (only after children are stopped) ----------------
    local ent name idx cidr
    if [ "$STARTUP_OK" -eq 0 ]; then
        # FAILED STARTUP: roll back every change WE made to links we did not
        # create, so a rejected/failed config leaves the namespace untouched.
        # (a) remove only the exact addresses WE added to preexisting links,
        #     matched by ifindex + exact CIDR - never foreign/preexisting ones.
        for ent in "${OWNED_ADDRS[@]+"${OWNED_ADDRS[@]}"}"; do
            name="${ent%% *}"; cidr="${ent##* }"
            idx="${ent#* }"; idx="${idx% *}"
            if [ "$(if_index "$name" 2>/dev/null)" = "$idx" ] \
               && if_has_addr "$name" "$cidr"; then
                ip -4 addr del "$cidr" dev "$name" 2>/dev/null || true
            fi
        done
        # (b) restore flags we changed on links we did not create.
        for ent in "${MC_RESTORE[@]+"${MC_RESTORE[@]}"}"; do
            name="${ent% *}"; idx="${ent##* }"
            [ "$(if_index "$name" 2>/dev/null)" = "$idx" ] \
                && ip link set "$name" multicast off 2>/dev/null || true
        done
    fi
    # delete only links we created AND that still have the same ifindex
    for ent in "${CREATED_VLANS[@]+"${CREATED_VLANS[@]}"}"; do
        name="${ent% *}"; idx="${ent##* }"
        [ "$(if_index "$name" 2>/dev/null)" = "$idx" ] && ip link del "$name" 2>/dev/null || true
    done
    # (c) failed start only: put back DOWN the links WE raised, in REVERSE
    #     record order - children first, trunk LAST (the trunk was pushed first
    #     but must go down only after the VLANs sitting on it are restored).
    if [ "$STARTUP_OK" -eq 0 ]; then
        local _j
        for (( _j=${#UP_RESTORE[@]}-1; _j>=0; _j-- )); do
            ent="${UP_RESTORE[$_j]}"
            name="${ent% *}"; idx="${ent##* }"
            [ "$(if_index "$name" 2>/dev/null)" = "$idx" ] \
                && ip link set "$name" down 2>/dev/null || true
        done
    fi
    # NOTE on the SUCCESSFUL path (STARTUP_OK=1): an intentional, fully-applied
    # static assignment on a preexisting link is left in place on clean
    # shutdown (the user asked for that address on their link). Only failed
    # startups roll mutations back. Links we created are always deleted.
}
on_signal() { log "shutting down ($1)"; do_cleanup; exit 0; }
on_exit()   { local rc=$?; do_cleanup; exit "$rc"; }
trap 'on_signal TERM' TERM
trap 'on_signal INT'  INT
trap 'on_exit' EXIT

# ------------------------------------------------------------------ main
mkdir -p "$RUN" /run/avahi-daemon
# drop ALL stale run state first: readiness, ack marker and any leftover fifo
rm -f "$READY_FILE" "$STATE_FILE" "$ACK_FILE" "$AVAHI_FIFO"
rm -f /run/avahi-daemon/pid /run/avahi-daemon/socket 2>/dev/null || true

validate_env
wait_for_base_if
check_trunk_kind
# ---- two-phase boundary: everything above is READ-ONLY --------------------
preflight
# ---- mutations begin (each guarded by a narrow local recheck) -------------
# trunk must be UP for VLAN children to carry traffic. The trunk is a link we
# did not create, so record that WE raised it (restored DOWN on failed start).
if ! if_up "$BASE_IF"; then
    UP_RESTORE+=("$BASE_IF $(if_index "$BASE_IF")")
    ip link set "$BASE_IF" up \
        || die "BASE_IF '$BASE_IF' is down and could not be brought up"
    log "brought trunk $BASE_IF up"
fi
for v in "${VIDS[@]}"; do ensure_vlan "$v"; done
start_addressing
render_avahi

start_avahi
write_state
log "avahi-daemon started (pid $AVAHI_PID)"

deadline=$(( SECONDS + STARTUP_TIMEOUT ))
while :; do
    procs_alive || die "an essential process died during startup"
    # Ready only when avahi reported its own init-complete (ack marker) AND the
    # interface state is what we configured. A live-but-initializing daemon is
    # NOT ready; a never-ack daemon hits the timeout and rolls back.
    if avahi_ready && iface_ready; then
        touch "$READY_FILE"; chmod 600 "$READY_FILE"
        STARTUP_OK=1
        log "ready: avahi initialized, all interfaces configured"
        break
    fi
    [ $SECONDS -lt $deadline ] || die "startup timed out (${STARTUP_TIMEOUT}s) - avahi init not acknowledged / interfaces not ready"
    sleep 1
done

# supervise: any owned essential child exiting (even code 0) -> fail.
while :; do
    # Poll owned children by PID+start-token (is_running excludes zombies, so
    # an exited child is never mistaken for alive while it awaits reaping).
    # Check avahi first so a daemon exit wins the message over a reader EOF.
    if ! child_alive "$AVAHI_PID"  "$AVAHI_TOK";  then die "avahi-daemon exited"; fi
    if ! child_alive "$READER_PID" "$READER_TOK"; then die "avahi log forwarder exited"; fi
    if [ "$IP_MODE" != static ] && ! child_alive "$DHCPCD_PID" "$DHCPCD_TOK"; then
        die "dhcpcd exited"
    fi
    sleep 1
done
