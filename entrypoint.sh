#!/usr/bin/env bash
set -euo pipefail

VLAN_LIST="${VLAN_LIST:-}"                 # např. "10,20,300"
IP_MODE="${IP_MODE:-linklocal}"            # linklocal | dhcp | static
STATIC_MAP="${STATIC_MAP:-}"               # pro static: "10:192.168.10.250/24,20:192.168.20.250/24"
EXTRA_INTERFACES="${EXTRA_INTERFACES:-}"
DHCP_FALLBACK_LL="${DHCP_FALLBACK_LL:-true}"  # true = při neúspěchu DHCP nasadí LL IP

trim() { awk '{$1=$1};1'; }

# Najdi trunk IF (první non-loopback), odřízni případné "@ifXX"
detect_base_if() {
    local raw
    raw="$(ip -o link show | awk -F': ' '$2 != "lo" {print $2; exit}')"
    echo "${raw%%@*}"
}

# Vytvoř seznam IF pro Avahi allow-interfaces (vethX.<vlan>[,vethX.<vlan>...])
to_iflist() {
    local base_if="$1"
    local v="$2"
    local o=""
    IFS=',' read -ra V <<< "$v"
    for id in "${V[@]}"; do
        id="$(echo "$id" | trim)"
        [ -z "$o" ] && o="${base_if}.${id}" || o="${o},${base_if}.${id}"
    done
    echo "$o"
}

assign_ll() {
    local base_if="$1"
    local id="$2"
    local Q=$(( id / 254 ))
    local R=$(( id % 254 + 1 ))   # 1..254
    local IP="169.254.${Q}.${R}/24"
    echo "LL: assigning ${IP} to ${base_if}.${id}"
    ip addr add "${IP}" dev "${base_if}.${id}" 2>/dev/null || true
}

[ -n "$VLAN_LIST" ] || { echo "ERROR: nastav VLAN_LIST (např. 10,20,300)"; exit 1; }

# 0) Detekce trunk rozhraní a wait-loop
BASE_IF="$(detect_base_if)"
echo "Detected base interface: ${BASE_IF}"

MAX_WAIT=10
count=0
while [ $count -lt $MAX_WAIT ] && ! ip link show dev "$BASE_IF" >/dev/null 2>&1; do
    count=$((count + 1))
    echo "Waiting for interface ${BASE_IF} to appear... (${count}/${MAX_WAIT})"
    sleep 1
done
ip link show dev "$BASE_IF" >/dev/null 2>&1 || { echo "ERROR: interface ${BASE_IF} not found"; exit 1; }

# 1) VLAN sub-interfaces (idempotentně)
IFS=',' read -ra VLANS <<< "$VLAN_LIST"
for id in "${VLANS[@]}"; do
    id="$(echo "$id" | trim)"
    if ip link show "${BASE_IF}.${id}" >/dev/null 2>&1; then
        echo "VLAN ${BASE_IF}.${id} already exists, skipping create"
    else
        ip link add link "${BASE_IF}" name "${BASE_IF}.${id}" type vlan id "${id}"
    fi
    ip link set "${BASE_IF}.${id}" up
done

# Pomocná: vyber DHCP klienta (udhcpc prefer, jinak dhclient)
dhcp_client() {
    if command -v udhcpc >/dev/null 2>&1; then
        # busybox udhcpc
        udhcpc -i "$1" -s /usr/share/udhcpc/default.script -t 3 -T 2 -A 1 -q
    elif command -v dhclient >/dev/null 2>&1; then
        dhclient -4 -v "$1"
    else
        echo "WARN: žádný DHCP klient (udhcpc ani dhclient) není k dispozici"
        return 1
    fi
}

# 2) IP adresace dle režimu
case "$IP_MODE" in
    linklocal)
        for id in "${VLANS[@]}"; do
            id="$(echo "$id" | trim)"
            assign_ll "$BASE_IF" "$id"
        done
        ;;
    dhcp)
        for id in "${VLANS[@]}"; do
            id="$(echo "$id" | trim)"
            echo "DHCP: requesting lease on ${BASE_IF}.${id}"
            if dhcp_client "${BASE_IF}.${id}"; then
                echo "DHCP: lease obtained on ${BASE_IF}.${id}"
            else
                echo "DHCP: no lease on ${BASE_IF}.${id}"
                [ "$DHCP_FALLBACK_LL" = "true" ] && assign_ll "$BASE_IF" "$id"
            fi
        done
        ;;
    static)
        IFS=',' read -ra PAIRS <<< "$STATIC_MAP"
        for pair in "${PAIRS[@]}"; do
            kv="$(echo "$pair" | trim)"
            vid="${kv%%:*}"
            addr="${kv#*:}"
            echo "STATIC: ${addr} on ${BASE_IF}.${vid}"
            ip addr add "$addr" dev "${BASE_IF}.${vid}" 2>/dev/null || true
        done
        ;;
    *)
        echo "ERROR: neznámý IP_MODE: $IP_MODE"; exit 1
        ;;
esac

# 3) Avahi config (allow-interfaces = <BASE_IF>.<vid>,… + EXTRA_INTERFACES)
IFLIST="$(to_iflist "$BASE_IF" "$VLAN_LIST")"
[ -n "$EXTRA_INTERFACES" ] && IFLIST="${IFLIST},${EXTRA_INTERFACES}"
sed "s/{{ALLOW_INTERFACES}}/${IFLIST}/" /etc/avahi/avahi-daemon.conf.tmpl > /etc/avahi/avahi-daemon.conf
echo "Avahi allow-interfaces: ${IFLIST}"

# 4) D-Bus + Avahi
mkdir -p /run/dbus
# některé base image potřebují machine-id, ať je po ruce:
if [ ! -s /var/lib/dbus/machine-id ] && command -v dbus-uuidgen >/dev/null 2>&1; then
    mkdir -p /var/lib/dbus
    dbus-uuidgen > /var/lib/dbus/machine-id
fi
dbus-daemon --system

exec avahi-daemon --debug
