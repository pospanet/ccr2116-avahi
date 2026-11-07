#!/usr/bin/env bash
# Readiness healthcheck. Green only when:
#   - supervisor reported ready (READY_FILE, freshly written each start),
#   - avahi's own init-complete ack marker exists (the daemon's
#     AVAHI_SERVER_RUNNING callback line was seen by our tracked reader),
#   - the OWNED avahi-daemon PID is alive,
#   - the OWNED log-reader PID is alive (it is the ack source + log path),
#   - the OWNED dhcpcd PID is alive for dhcp/linklocal modes,
#   - every VLAN interface exists, is UP, is still a real VLAN child of the
#     configured trunk, and carries the expected IPv4,
#   - every EXTRA interface is up with an IPv4.
# It does NOT prove end-to-end mDNS reflection (needs a second host).
set -euo pipefail
. /usr/local/lib/avahi-reflector/lib.sh

STATE_FILE=/run/avahi-reflector/state.env
READY_FILE=/run/avahi-reflector/ready
ACK_FILE=/run/avahi-reflector/avahi.ack

[ -f "$READY_FILE" ] || exit 1
[ -f "$STATE_FILE" ] || exit 1
[ -f "$ACK_FILE" ]   || exit 1   # real daemon ack, not mere process liveness
# state.env is written atomically (600) by the supervisor with %q-escaped
# scalar values and declare -p arrays - safe to source.
# shellcheck disable=SC1090
. "$STATE_FILE"

# owned avahi-daemon main process (live, non-zombie, + start-time identity)
proc_alive "${AVAHI_PID:-}" || exit 1
if [ -n "${AVAHI_TOK:-}" ]; then
    [ "$(proc_start "$AVAHI_PID" 2>/dev/null)" = "$AVAHI_TOK" ] || exit 1
fi

# owned log-reader (ack writer): if it died, the ack source and the avahi log
# path are gone, so we must not stay green on the strength of a helper.
proc_alive "${READER_PID:-}" || exit 1
if [ -n "${READER_TOK:-}" ]; then
    [ "$(proc_start "$READER_PID" 2>/dev/null)" = "$READER_TOK" ] || exit 1
fi

# owned dhcpcd main process when the mode needs one
if [ "${IP_MODE:-static}" != static ]; then
    proc_alive "${DHCPCD_PID:-}" || exit 1
    if [ -n "${DHCPCD_TOK:-}" ]; then
        [ "$(proc_start "$DHCPCD_PID" 2>/dev/null)" = "$DHCPCD_TOK" ] || exit 1
    fi
fi

for v in "${VIDS[@]+"${VIDS[@]}"}"; do
    ifn="${BASE_IF}.${v}"
    if_exists "$ifn" && if_up "$ifn" || exit 1
    # still a genuine VLAN child (guards against a same-name replacement)
    if_vlan_ok "$ifn" "$BASE_IF" "$v" || exit 1
    case "$IP_MODE" in
        static)
            # exact desired address AND nothing else on the link
            if_has_addr "$ifn" "${SIP[$v]:-}" || exit 1
            if_foreign_v4 "$ifn" "${SIP[$v]:-}" && exit 1
            ;;
        linklocal) if_ll_v4 "$ifn" || exit 1 ;;
        dhcp)
            if [ "${DHCP_FALLBACK_LL:-false}" = true ]; then
                if_has_v4 "$ifn" || exit 1
            else
                if_global_v4 "$ifn" || exit 1
            fi ;;
    esac
done

for v in "${EXTRAS[@]+"${EXTRAS[@]}"}"; do
    if_exists "$v" && if_up "$v" || exit 1
    if_has_v4 "$v" || exit 1
done

exit 0
