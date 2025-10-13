#!/usr/bin/env bash
set -euo pipefail

VLAN_LIST="${VLAN_LIST:-}"                 # např. "10,20,300"
IP_MODE="${IP_MODE:-linklocal}"            # linklocal | dhcp | static
STATIC_MAP="${STATIC_MAP:-}"               # pro static: "10:192.168.10.250/24,20:192.168.20.250/24"
EXTRA_INTERFACES="${EXTRA_INTERFACES:-}"
DHCP_FALLBACK_LL="${DHCP_FALLBACK_LL:-true}"  # true= při neúspěchu DHCP nasadí LL IP

trim() { awk '{$1=$1};1'; }
to_iflist() {
  local v="$1"; local o=""
  IFS=',' read -ra V <<< "$v"
  for id in "${V[@]}"; do id="$(echo "$id" | trim)"; [ -z "$o" ] && o="eth0.$id" || o="$o,eth0.$id"; done
  echo "$o"
}
assign_ll() {
  local id="$1"
  local Q=$(( id / 254 ))
  local R=$(( id % 254 + 1 ))   # 1..254
  local IP="169.254.${Q}.${R}/24"
  echo "LL: assigning ${IP} to eth0.${id}"
  ip addr add "${IP}" dev "eth0.${id}" 2>/dev/null || true
}

[ -n "$VLAN_LIST" ] || { echo "ERROR: nastav VLAN_LIST (např. 10,20,300)"; exit 1; }

# 1) VLAN subifs (idempotentně)
IFS=',' read -ra VLANS <<< "$VLAN_LIST"
for id in "${VLANS[@]}"; do
  id="$(echo "$id" | trim)"
  if ip link show "eth0.${id}" >/dev/null 2>&1; then
    echo "VLAN eth0.${id} already exists, skipping create"
  else
    ip link add link eth0 name "eth0.${id}" type vlan id "${id}"
  fi
  ip link set "eth0.${id}" up
done

# 2) IP adresace dle režimu
case "$IP_MODE" in
  linklocal)
    for id in "${VLANS[@]}"; do id="$(echo "$id" | trim)"; assign_ll "$id"; done
    ;;
  dhcp)
    for id in "${VLANS[@]}"; do
      id="$(echo "$id" | trim)"
      echo "DHCP: requesting lease on eth0.${id}"
      if udhcpc -i "eth0.${id}" -s /usr/share/udhcpc/default.script -t 3 -T 2 -A 1 -q; then
        echo "DHCP: lease obtained on eth0.${id}"
      else
        echo "DHCP: no lease on eth0.${id}"
        [ "$DHCP_FALLBACK_LL" = "true" ] && assign_ll "$id"
      fi
    done
    ;;
  static)
    IFS=',' read -ra PAIRS <<< "$STATIC_MAP"
    for pair in "${PAIRS[@]}"; do
      kv="$(echo "$pair" | trim)"
      vid="${kv%%:*}"; addr="${kv#*:}"
      echo "STATIC: ${addr} on eth0.${vid}"
      ip addr add "$addr" dev "eth0.${vid}" 2>/dev/null || true
    done
    ;;
  *)
    echo "ERROR: neznámý IP_MODE: $IP_MODE"; exit 1
    ;;
esac

# 3) Avahi config
IFLIST="$(to_iflist "$VLAN_LIST")"
[ -n "$EXTRA_INTERFACES" ] && IFLIST="$IFLIST,${EXTRA_INTERFACES}"
sed "s/{{ALLOW_INTERFACES}}/${IFLIST}/" /etc/avahi/avahi-daemon.conf.tmpl > /etc/avahi/avahi-daemon.conf

# 4) D-Bus + Avahi
mkdir -p /run/dbus
dbus-daemon --system

exec avahi-daemon --debug
