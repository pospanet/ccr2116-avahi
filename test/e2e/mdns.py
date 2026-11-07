#!/usr/bin/env python3
"""Minimal stdlib-only mDNS/DNS-SD sender+listener for the e2e reflector lab.

No third-party deps. Encodes/decodes just enough DNS to build and verify
PTR/SRV/TXT/A announcements and PTR queries on 224.0.0.251:5353.

Output contract (parsed by run.sh):
  __READY__          printed by listen after bind+join (readiness handshake)
  __SENT__           printed by announce/query after a successful send
  __HEARD__          printed by listen right before the file dump of captures
  <ip>: <recs>       one line per received packet; <recs> may be '<no-records>'
  <parse-error>      inside <recs> marks a malformed packet (counts as a
                     captured packet, but run.sh must not treat it as a record)
Exit code is non-zero on socket/bind/parse-setup failure so the driver can
trust that an empty capture really means "nothing arrived".

Usage:
  mdns.py listen  --if <if> --timeout <sec> [--out <file>]
  mdns.py announce --if <if> --src-ip <ip> --type <_x._tcp.local>
        --instance <n> --host <h.local> --port <n> --target-ip <ip> [--txt k=v,...]
  mdns.py query   --if <if> --src-ip <ip> --name <_x._tcp.local>
"""
import argparse
import socket
import struct
import sys
import time

MCAST = "224.0.0.251"
PORT = 5353
IP_MULTICAST_ALL = 49          # linux
IP_ADD_MEMBERSHIP = 35
IP_MULTICAST_IF = 32
IP_MULTICAST_LOOP = 34
IP_MULTICAST_TTL = 33
SO_BINDTODEVICE = 25

TYPE_A, TYPE_PTR, TYPE_TXT, TYPE_SRV, TYPE_AAAA = 1, 12, 16, 33, 28
TYPENAME = {1: "A", 12: "PTR", 16: "TXT", 28: "AAAA", 33: "SRV"}

MAX_NAME_STEPS = 128           # hard bound vs compression-pointer loops
MAX_LABELS = 128


class ParseError(Exception):
    pass


def enc_name(name):
    out = b""
    for label in name.rstrip(".").split("."):
        out += bytes([len(label)]) + label.encode()
    return out + b"\x00"


def dec_name(pkt, off):
    """Bounded DNS name decoder. Compression pointers are visited at most once
    each and total steps are capped, so a malformed packet can never loop."""
    labels = []
    jumped = False
    steps = 0
    end_off = off
    seen_ptrs = set()
    for _ in range(MAX_NAME_STEPS):
        if off >= len(pkt):
            raise ParseError("name runs past packet end")
        ln = pkt[off]
        if ln == 0:
            if not jumped:
                end_off = off + 1
            return ".".join(labels) + ".", end_off
        if ln & 0xC0 == 0xC0:
            if off + 1 >= len(pkt):
                raise ParseError("truncated compression pointer")
            ptr = ((ln & 0x3F) << 8) | pkt[off + 1]
            if ptr >= len(pkt):
                raise ParseError("compression pointer out of bounds")
            if ptr in seen_ptrs:
                raise ParseError("compression pointer loop")
            seen_ptrs.add(ptr)
            if not jumped:
                end_off = off + 2
            off = ptr
            jumped = True
            continue
        if ln & 0xC0:
            raise ParseError("bad label type")
        off += 1
        if off + ln > len(pkt):
            raise ParseError("label runs past packet end")
        labels.append(pkt[off:off + ln].decode("utf-8", "replace"))
        if len(labels) > MAX_LABELS:
            raise ParseError("too many labels")
        off += ln
        if not jumped:
            end_off = off
    raise ParseError("name decode exceeded step limit")


def rr(name, rtype, rdata, ttl=120):
    return enc_name(name) + struct.pack(">HHIH", rtype, 1, ttl, len(rdata)) + rdata


def build_announce(stype, instance, host, port, target_ip, txt):
    fqdn = instance + "." + stype
    txt_data = b"".join(bytes([len(t)]) + t.encode() for t in txt)
    answers = [
        rr(stype, TYPE_PTR, enc_name(fqdn)),
        rr(fqdn, TYPE_TXT, txt_data),
        rr(fqdn, TYPE_SRV, struct.pack(">HHH", 0, 0, port) + enc_name(host)),
        rr(host, TYPE_A, socket.inet_aton(target_ip)),
    ]
    hdr = struct.pack(">HHHHHH", 0, 0x8400, 0, len(answers), 0, 0)
    return hdr + b"".join(answers)


def build_query(name):
    return struct.pack(">HHHHHH", 0, 0, 1, 0, 0, 0) + enc_name(name) \
        + struct.pack(">HH", TYPE_PTR, 1)


def _txt_strings(rd):
    out, i = [], 0
    while i < len(rd):
        ln = rd[i]
        i += 1
        if i + ln > len(rd):
            break
        out.append(rd[i:i + ln].decode("utf-8", "replace"))
        i += ln
    return ",".join(out)


def parse(pkt):
    """Return list of printable record strings; raises nothing - a malformed
    packet yields ['<parse-error>'] so it is visible but never a real record."""
    try:
        if len(pkt) < 12:
            raise ParseError("packet shorter than DNS header")
        _id, flags, qd, an, ns, ar = struct.unpack_from(">HHHHHH", pkt, 0)
        off = 12
        recs = []
        for _ in range(qd):
            qname, off = dec_name(pkt, off)
            if off + 4 > len(pkt):
                raise ParseError("question runs past packet end")
            qt, qc = struct.unpack_from(">HH", pkt, off)
            off += 4
            recs.append("Q %s type=%s class=%d"
                        % (qname, TYPENAME.get(qt, str(qt)), qc & 0x7FFF))
        for _ in range(an + ns + ar):
            name, off = dec_name(pkt, off)
            if off + 10 > len(pkt):
                raise ParseError("record header runs past packet end")
            rt, _c, ttl, rdlen = struct.unpack_from(">HHIH", pkt, off)
            off += 10
            if off + rdlen > len(pkt):
                raise ParseError("rdata runs past packet end")
            rd = pkt[off:off + rdlen]
            if rt == TYPE_PTR:
                tgt, _ = dec_name(pkt, off)
                recs.append("PTR %s -> %s" % (name, tgt))
            elif rt == TYPE_SRV:
                if rdlen < 6:
                    raise ParseError("short SRV rdata")
                tgt, _ = dec_name(pkt, off + 6)
                port = struct.unpack_from(">H", rd, 4)[0]
                recs.append("SRV %s -> %s:%d" % (name, tgt, port))
            elif rt == TYPE_A:
                if rdlen != 4:
                    raise ParseError("bad A rdlen")
                recs.append("A %s -> %s" % (name, socket.inet_ntoa(rd)))
            elif rt == TYPE_TXT:
                recs.append("TXT %s [%s]" % (name, _txt_strings(rd)))
            elif rt == TYPE_AAAA:
                recs.append("AAAA %s" % name)
            else:
                recs.append("TYPE%d %s" % (rt, name))
            off += rdlen
        return recs or ["<no-records>"]
    except Exception as e:
        return ["<parse-error:%s>" % type(e).__name__]


def listen(ifname, timeout, out):
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            s.setsockopt(socket.IPPROTO_IP, IP_MULTICAST_ALL, 0)
        except OSError:
            pass
        s.bind(("", PORT))
        # Join on the SPECIFIC interface only (ip_mreqn: group,addr,ifindex) so
        # the kernel only delivers packets that arrived on THIS interface.
        mreq = socket.inet_aton(MCAST) + socket.inet_aton("0.0.0.0") \
            + struct.pack("=I", socket.if_nametoindex(ifname))
        s.setsockopt(socket.IPPROTO_IP, IP_ADD_MEMBERSHIP, mreq)
        s.settimeout(0.5)
    except OSError as e:
        print("listen setup failed on %s: %s" % (ifname, e), file=sys.stderr)
        return 2
    # readiness handshake: socket is bound+joined before we announce it
    print("__READY__", flush=True)
    lines = []
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            data, peer = s.recvfrom(65535)
        except socket.timeout:
            continue
        lines.append("%s: %s" % (peer[0], "; ".join(parse(data))))
    s.close()
    text = "\n".join(lines)
    if out:
        with open(out, "w") as f:
            f.write(text)
    print("__HEARD__", flush=True)
    if text:
        print(text, flush=True)
    return 0


def send(ifname, src_ip, packet):
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
        s.setsockopt(socket.SOL_SOCKET, SO_BINDTODEVICE, ifname.encode())
        s.setsockopt(socket.IPPROTO_IP, IP_MULTICAST_IF,
                     socket.inet_aton(src_ip))
        s.setsockopt(socket.IPPROTO_IP, IP_MULTICAST_LOOP, 1)
        # RFC 6762: mDNS packets are sent with IP TTL 255.
        s.setsockopt(socket.IPPROTO_IP, IP_MULTICAST_TTL, 255)
        # real mDNS responders source from 5353; REUSEADDR coexists with
        # avahi's 0.0.0.0:5353 bind (disallow-other-stacks=no)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.bind((src_ip, PORT))
        s.sendto(packet, (MCAST, PORT))
        s.close()
    except OSError as e:
        print("send failed on %s: %s" % (ifname, e), file=sys.stderr)
        return 2
    print("__SENT__", flush=True)
    return 0


def main():
    p = argparse.ArgumentParser()
    p.add_argument("mode", choices=["listen", "announce", "query"])
    p.add_argument("--if", dest="ifname", required=True)
    p.add_argument("--timeout", type=float, default=6)
    p.add_argument("--out")
    p.add_argument("--src-ip")
    p.add_argument("--type")
    p.add_argument("--instance", default="inst")
    p.add_argument("--host", default="h.local")
    p.add_argument("--port", type=int, default=80)
    p.add_argument("--target-ip")
    p.add_argument("--txt", default="")
    p.add_argument("--name")
    a = p.parse_args()
    if a.mode == "listen":
        return listen(a.ifname, a.timeout, a.out)
    if a.mode == "announce":
        pkt = build_announce(a.type, a.instance, a.host, a.port,
                             a.target_ip, a.txt.split(",") if a.txt else [])
        return send(a.ifname, a.src_ip, pkt)
    return send(a.ifname, a.src_ip, build_query(a.name))


if __name__ == "__main__":
    sys.exit(main())
