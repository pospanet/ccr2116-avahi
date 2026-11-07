# shellcheck shell=bash
# Shared helpers for the Avahi reflector entrypoint and healthcheck.
# Sourced by /entrypoint.sh and /healthcheck.sh - not executed directly.

# Timestamp via bash's builtin %(fmt)T form (-1 = now), avoiding a subshell
# and date process for every log line.
log()  { local _ts; printf -v _ts '%(%H:%M:%S)T' -1; printf '[%s] %s\n' "$_ts" "$*" >&2; }
warn() { log "WARN: $*"; }
die()  { log "ERROR: $*"; exit 1; }

# ------------------------------------------------------------ tiny predicates
posint() {
    case "$1" in ''|*[!0-9]*) return 1 ;; esac
    # bound length BEFORE arithmetic to avoid integer overflow
    [ "${#1}" -le 9 ] || return 1
    local n=$((10#$1))
    [ "$n" -gt 0 ] && [ "$n" -le 86400 ]
}

# trim leading/trailing whitespace only (never interior)
trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; printf '%s' "${s%"${s##*[![:space:]]}"}"; }

# trimv <varname> <string> : same trim as trim() but writes the result into a
# caller variable via a nameref instead of printing it. Pure bash - no command
# substitution, no fork, no pipe. Namerefs avoid extra subprocesses in input
# validation; this is an optimization, not a workaround for a Bash defect.
trimv() {
    local -n _t="$1"; _t="$2"
    _t="${_t#"${_t%%[![:space:]]*}"}"
    _t="${_t%"${_t##*[![:space:]]}"}"
}

# Reject a value that is empty or contains anything outside a strict
# interface/addr charset (alnum . - _ / : @ + ,). No whitespace, quotes,
# shell meta, glob, newline. Returns 0 when safe.
reject_unsafe() {
    case "$1" in
        ''|*[!A-Za-z0-9.,/_:@+-]*) return 1 ;;
        *) return 0 ;;
    esac
}

# A stricter set for config scalar fields (no '/' so it is safe as a literal
# line and can never break line-oriented config rendering).
reject_unsafe_cfg() {
    case "$1" in
        ''|*[!A-Za-z0-9.,_:@+-]*) return 1 ;;
        *) return 0 ;;
    esac
}

# reject leading / trailing / doubled separators in a comma list
has_empty_token() {
    case ",$1," in *,,*) return 0 ;; esac
    return 1
}

# ------------------------------------------------------------- network parse
# VLAN id: digits, length<=4, range 1..4094. Leading zeros normalized via 10#.
# norm_vid_r <out-var> <token> : writes the normalized id into <out-var> via a
# nameref (NO command substitution - the caller runs zero forks/pipes). This is
# the form hot validation paths use to avoid a subshell per token.
# Returns 1 on invalid (out-var left untouched).
norm_vid_r() {
    local -n _o="$1"
    # __nv holds the candidate; named to never collide with the caller out-var
    # or a caller's own local (a same-name `local` shadows the nameref target).
    local __nv
    trimv __nv "$2"
    case "$__nv" in ''|*[!0-9]*) return 1 ;; esac
    [ "${#__nv}" -le 4 ] || return 1
    __nv=$((10#$__nv))
    [ "$__nv" -ge 1 ] && [ "$__nv" -le 4094 ] || return 1
    _o="$__nv"
}
# Prints normalized id; 1 on invalid. (thin wrapper kept for the print contract)
norm_vid() { local v; norm_vid_r v "$1" || return 1; printf '%s' "$v"; }

# strict dotted-quad octet 0..255, no empty/space/leading-plus.
# Also rejects leading zeros so a written '010' is not silently read as 8
# (kernel canonical form has no leading zeros).
_octet() {
    case "$1" in ''|*[!0-9]*) return 1 ;; esac
    [ "${#1}" -le 3 ] || return 1
    case "$1" in 0?*) return 1 ;; esac       # no leading zeros (except bare "0")
    [ "$((10#$1))" -le 255 ]
}

# Return 0 when $1 is a usable unicast host IPv4 (rejects 0.0.0.0, 127/8
# loopback, 224/4 multicast, 240/4 reserved, and 169.254/16 link-local which is
# reserved for the LL mode, not a static routable address).
valid_ipv4() {
    local ip="$1" o1 o2 o3 o4
    [ "$ip" = "${ip#*[!0-9.]}" ] || return 1          # only digits+dots
    # exactly 3 dots -> exactly 4 octets (pure-bash count, no $( ) fork)
    [ "${ip//[^.]/}" = "..." ] || return 1
    IFS=. read -r o1 o2 o3 o4 <<<"$ip"
    _octet "$o1" && _octet "$o2" && _octet "$o3" && _octet "$o4" || return 1
    o1=$((10#$o1))
    [ "$o1" -ge 1 ]   || return 1                     # 0.x unspecified
    [ "$o1" -ne 127 ] || return 1                     # loopback
    [ "$o1" -lt 224 ] || return 1                     # 224+ multicast/reserved
    case "$ip" in 169.254.*) return 1 ;; esac         # link-local not for static
    return 0
}

# Validate "IPv4/prefix": EXACTLY one '/', valid host IPv4, prefix integer 0..32.
# /31 (point-to-point) and /32 (host) are permitted deliberately; a reflector
# usually wants a real LAN prefix, but they are not invalid per se.
# Prints canonical "a.b.c.d/p" (leading octet zeros normalized via 10#).
# valid_cidr_r <out-var> <cidr-token> : writes the canonical "a.b.c.d/p" into
# <out-var> via a nameref (no command substitution). Same reason as norm_vid_r:
# the caller avoids forking a $() subshell for the value.
valid_cidr_r() {
    local -n _o="$1"
    # __vc holds the raw token; named to never collide with the caller out-var
    # or a caller's own local (a same-name `local` shadows the nameref target).
    local __vc="$2" ip pfx
    # exactly one '/' -> two fields (pure-bash count, no $( ) fork)
    [ "${__vc//[^\/]/}" = "/" ] || return 1
    ip="${__vc%%/*}"; pfx="${__vc##*/}"
    valid_ipv4 "$ip" || return 1
    case "$pfx" in ''|*[!0-9]*) return 1 ;; esac
    [ "${#pfx}" -le 2 ] || return 1
    pfx=$((10#$pfx))
    [ "$pfx" -ge 1 ] && [ "$pfx" -le 32 ] || return 1
    # canonicalize each octet too (drop leading zeros -> kernel form); octet
    # names are __-prefixed so a same-name caller out-var can't shadow the write.
    local __a __b __c __d
    IFS=. read -r __a __b __c __d <<<"$ip"
    _o="$((10#$__a)).$((10#$__b)).$((10#$__c)).$((10#$__d))/$pfx"
    return 0
}
# Prints canonical "a.b.c.d/p"; 1 on invalid. (print contract kept)
valid_cidr() { local c; valid_cidr_r c "$1" || return 1; printf '%s' "$c"; }

# Interface name <=15 bytes, sane charset, not empty. Charset is deliberately
# narrower than the kernel maximum: letters, digits, '.', '-', '_' ONLY.
# Excluded on purpose:
#   '@' and ':' - `ip` uses them as display delimiters (peer '@ifNN' suffix and
#     the 'name:' separator), so a literal 'p@x' would be truncated to 'p' by
#     display parsing and could point at the wrong device.
#   '/' and whitespace - would break `ip link ... dev`/`show dev` argument or
#     sysfs path handling.
# The kernel permits such names, but we support/manage only this portable
# charset, which covers every sane trunk/VLAN/extra name incl. RouterOS veth.
valid_ifname() {
    local n="$1"
    [ -n "$n" ] && [ "${#n}" -le 15 ] || return 1
    case "$n" in *[!A-Za-z0-9._-]*) return 1 ;; esac
    return 0
}

# Avahi reflect-filter token: a DNS-SD service type/name - printable DNS-safe
# chars only (letters, digits, dot, dash, underscore). No whitespace/comma/meta.
valid_filter() {
    case "$1" in
        ''|*[!A-Za-z0-9._-]*) return 1 ;;
        *) return 0 ;;
    esac
}

# ------------------------------------------------------- live interface state
# These parse `ip` output into exact fields - never substring match.
if_exists() { ip link show dev "$1" >/dev/null 2>&1; }

# UP flag: extract the flag list inside the first <...> group, split on ','
# and look for the exact token UP (covers UP-first as well as LOWER_UP
# which must NOT match). Token parsing, not a fragile regex.
if_up() {
    ip -o link show dev "$1" 2>/dev/null \
        | awk '{if (match($0, /<[^>]*>/)) {s=substr($0,RSTART+1,RLENGTH-2);
                n=split(s,a,","); for(i=1;i<=n;i++) if(a[i]=="UP"){f=1}} }
               END{exit !f}'
}

# Exact IPv4 addr/prefix present on dev: compare canonical "a.b.c.d/p" field.
# Usage: if_has_addr <dev> <canonical-cidr>
if_has_addr() {
    ip -o -4 addr show dev "$1" 2>/dev/null \
        | awk -v want="$2" '{for(i=1;i<=NF;i++) if($i=="inet" && $(i+1)==want) f=1} END{exit !f}'
}
# Any IPv4 on dev DIFFERENT from the canonical $2 (a foreign/conflicting addr).
# Usage: if_foreign_v4 <dev> <expected-canonical-cidr>
if_foreign_v4() {
    ip -o -4 addr show dev "$1" 2>/dev/null \
        | awk -v want="$2" '{for(i=1;i<=NF;i++) if($i=="inet" && $(i+1)!=want) f=1} END{exit !f}'
}
# Any non-link-local global IPv4 on dev (scope global, not 169.254/16).
if_global_v4() {
    ip -o -4 addr show dev "$1" 2>/dev/null \
        | awk '{for(i=1;i<=NF;i++) if($i=="inet" && $(i+1)!~/^169\.254\./ && $(i+1)!~/^127\./) f=1} END{exit !f}'
}
# A link-local 169.254/16 IPv4 present.
if_ll_v4() {
    ip -o -4 addr show dev "$1" 2>/dev/null \
        | awk '{for(i=1;i<=NF;i++) if($i=="inet" && $(i+1)~/^169\.254\./) f=1} END{exit !f}'
}
# Any IPv4 at all.
if_has_v4() { ip -o -4 addr show dev "$1" 2>/dev/null | grep -q 'inet '; }

# ifindex of an interface (stable identity, name-independent).
if_index() { cat "/sys/class/net/$1/ifindex" 2>/dev/null; }

# ------------------------------------------------------------ process identity
# start-time token (jiffies since boot, field 22 of /proc/pid/stat) - a stable
# per-PID identity that lets us detect PID reuse when checking our own children.
# Field 2 (comm) may contain spaces/parens, so take the text after the last ')'.
proc_start() {
    local stat rest
    # read builtin instead of $(cat): the file is a single line; read leaves it
    # in `stat`. No command-substitution fork on this hot child-identity path.
    IFS= read -r stat <"/proc/$1/stat" 2>/dev/null || return 1
    # comm (field 2) may contain spaces/parens -> strip through the last ')'.
    rest="${stat##*) }"
    # remainder field 20 == overall field 22 (starttime, jiffies). read -ra
    # indexes from 0, so field 20 is element 19. No awk/fork.
    local -a f; read -ra f <<<"$rest"
    printf '%s' "${f[19]:-}"
}

# Live process check: PID exists AND is not a zombie. comm (field 2) may
# contain spaces/parens, so state is taken as the text after the last ')'.
proc_alive() {
    local stat
    [ -n "$1" ] && kill -0 "$1" 2>/dev/null || return 1
    stat="$(cat "/proc/$1/stat" 2>/dev/null)" || return 1
    [[ ${stat##*) } != Z* ]]
}

# Return 0 when $ifn's link TYPE is 'vlan'. This is anchored to the type-info
# line of `ip -d` ("    vlan protocol ..."), NOT a word match across the whole
# output, so an interface merely *named* 'vlan-trunk' (kind veth/dummy) is not
# misclassified, and neither is another kind that has an 'id' field (vxlan).
if_kind_is_vlan() {
    ip -d link show dev "$1" 2>/dev/null \
        | awk '/^[[:space:]]+vlan /{f=1} END{exit !f}'
}

# Return 0 when $ifn is a REAL 802.1Q VLAN child of $parent with id $vid.
# All four facts are checked from structured `ip -d` output, not a loose
# substring/id match:
#   - kind is exactly 'vlan' (type-info line anchor),
#   - protocol is exactly '802.1Q' (an 802.1ad/QinQ link is REJECTED),
#   - the vlan 'id' field equals the wanted VID,
#   - the parent ('name@parent' suffix) resolves to the same ifindex.
if_vlan_ok() {
    local ifn="$1" parent="$2" vid="$3"
    local det parname paridx wantidx
    det="$(ip -d link show dev "$ifn" 2>/dev/null)" || return 1
    # parse the type-info line: fields must be 'vlan protocol 802.1Q id <vid>'
    awk -v v="$vid" '
        /^[[:space:]]+vlan /{
            for(i=1;i+3<=NF;i++)
                if($i=="vlan" && $(i+1)=="protocol" && $(i+2)=="802.1Q") {
                    for(j=i+3;j<NF;j++)
                        if($j=="id" && $(j+1)==v) f=1
                }
        }
        END{exit !f}' <<<"$det" || return 1
    # parent: text after '@' up to ':' on the device line -> resolve to ifindex
    parname="$(ip -o link show dev "$ifn" 2>/dev/null | awk -F'[@:]' '{print $3}')"
    [ "$parname" = "$parent" ] || return 1
    paridx="$(if_index "$parname")"; wantidx="$(if_index "$parent")"
    [ -n "$paridx" ] && [ "$paridx" = "$wantidx" ]
}
