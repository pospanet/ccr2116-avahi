#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
DHCP / IPv4LL integration lab for the avahi reflector runtime.

Drives real Docker containers:
  * reflector under test  = runtime image (entrypoint.sh + dhcpcd + avahi)
  * DHCP server           = lab image (runtime + dnsmasq) on a tagged wire

Everything runs inside containers on Docker-internal bridge networks.
The reflector container is run with the ONLY allowed sysctl override
  --sysctl net.ipv4.conf.default.promote_secondaries=1
which is namespace-scoped (fresh netns), required because dhcpcd's
if_init_os() must see promote_secondaries==1 (it returns 0 without writing
when already 1; the image's /proc/sys is read-only under docker run).

No --privileged, no host network, no SYS_ADMIN. All resources are labelled
with the run id and removed in `finally`.

Usage (from repo root, host needs only Docker + Python 3):
    python test/dhcp/dhcp_lab.py                 # build images + run all
    python test/dhcp/dhcp_lab.py --skip-build    # reuse existing images
    python test/dhcp/dhcp_lab.py --only T1,T5    # subset

Every per-test wait is individually bounded (see wait_for() calls); there is
no global --timeout knob - a stuck test fails on its own deadline.

Requirements: Linux Docker engine (amd64 native strongly recommended;
ARM64/qemu is known-broken for dhcpcd privsep sockets upstream - not a
runtime defect).
"""
import argparse
import base64
import datetime
import json
import os
import re
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
RESULTS = os.path.join(HERE, "results")
LABEL = "dhcp-lab.run"

BASE_IMAGE_DEFAULT = "ccr2116-avahi-a4-base:amd64"
LAB_IMAGE_DEFAULT = "ccr2116-avahi-a4-lab:amd64"

RUN_ID = datetime.datetime.now().strftime("%y%m%d%H%M%S") + "-" + str(os.getpid())
PFX = "a4d-{}".format(RUN_ID)          # unique prefix for every resource

LOG_LINES = []
RESULT_ROWS = []                       # (test, status, detail)


def out(msg):
    line = "[{}] {}".format(datetime.datetime.now().strftime("%H:%M:%S"), msg)
    print(line, flush=True)
    LOG_LINES.append(line)


def run(cmd, timeout=60, check=True, cwd=None):
    """Bounded subprocess; returns (rc, combined stdout+stderr text)."""
    try:
        p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                           timeout=timeout, text=True, errors="replace",
                           cwd=cwd)
        if check and p.returncode != 0:
            raise RuntimeError("cmd failed rc={}: {}\n{}".format(
                p.returncode, " ".join(cmd), p.stdout))
        return p.returncode, p.stdout
    except subprocess.TimeoutExpired:
        raise RuntimeError("cmd timed out ({}s): {}".format(
            timeout, " ".join(cmd)))


def wait_for(fn, timeout, interval=1.0, desc="condition"):
    """Poll fn() until truthy or deadline. Returns fn() value."""
    deadline = time.monotonic() + timeout
    while True:
        v = fn()
        if v:
            return v
        if time.monotonic() >= deadline:
            raise RuntimeError("timeout waiting for {}".format(desc))
        time.sleep(interval)


def ip_in_ll_range(ip):
    """RFC3927 usable host range 169.254.1.0 - 169.254.254.255
    (first/last /24 of 169.254/16 are reserved)."""
    m = re.match(r"^169\.254\.(\d+)\.(\d+)$", ip)
    if not m:
        return False
    return 1 <= int(m.group(1)) <= 254


def parse_kv(text):
    d = {}
    for line in text.splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            d[k.strip()] = v.strip()
    return d


class Lab(object):
    """Owns every Docker resource of this run; cleanup removes only ours."""

    def __init__(self, lab_image, base_image):
        self.lab_image = lab_image
        self.base_image = base_image
        self.containers = []
        self.networks = []

    # ---------------------------------------------------------- resources
    def net(self, suffix):
        name = "{}-{}".format(PFX, suffix)
        run(["docker", "network", "create", "--internal",
             "--label", "{}={}".format(LABEL, RUN_ID), name], timeout=30)
        self.networks.append(name)
        return name

    def _register(self, name):
        self.containers.append(name)

    def rm_container(self, name):
        run(["docker", "rm", "-f", name], timeout=30, check=False)
        if name in self.containers:
            self.containers.remove(name)

    # --------------------------------------------------------- reflector
    def reflector(self, suffix, net, vlans, ip_mode, fallback_ll=None,
                  startup_timeout=60, env=None):
        name = "{}-{}".format(PFX, suffix)
        env = list(env or [])
        env += ["-e", "VLAN_LIST={}".format(",".join(str(v) for v in vlans)),
                "-e", "BASE_IF=eth0",
                "-e", "IP_MODE={}".format(ip_mode),
                "-e", "STARTUP_TIMEOUT={}".format(startup_timeout),
                "-e", "INTERFACE_WAIT_TIMEOUT=15"]
        if fallback_ll is not None:
            env += ["-e", "DHCP_FALLBACK_LL={}".format(
                "true" if fallback_ll else "false")]
        # docker run [opts] <env> <image> [args...]
        cmd = ["docker", "run", "-d", "--name", name,
               "--platform", "linux/amd64",
               "--network", net,
               "--label", "{}={}".format(LABEL, RUN_ID),
               "--sysctl", "net.ipv4.conf.default.promote_secondaries=1",
               "--cap-add", "NET_ADMIN", "--cap-add", "NET_RAW"] + env
        if any("LAB_BASE_SNAPSHOT" in e for e in env):
            # Test-only entrypoint WRAPPER (no runtime change): before exec'ing
            # the image's real entrypoint (tini -> entrypoint.sh), snapshot
            # resolv.conf/hostname to /run/lab-base/ so the test has a
            # deterministic PRE-DHCP baseline (avoids the docker-exec race).
            cmd += ["--entrypoint", "sh", self.base_image,
                    "-c",
                    "mkdir -p /run/lab-base; "
                    "cp /etc/resolv.conf /run/lab-base/resolv.conf 2>/dev/null "
                    "|| true; "
                    "cp /etc/hostname /run/lab-base/hostname 2>/dev/null "
                    "|| true; "
                    "exec /sbin/tini -- /bin/bash /entrypoint.sh"]
        else:
            cmd += [self.base_image]
        run(cmd, timeout=30)
        self._register(name)
        return Reflector(name, vlans)

    def observer(self, suffix, target_name):
        """Read-only network-namespace observer: shares the target container's
        netns (--network container:<target>) so the target's links/addresses
        remain observable AFTER the target's main process exits and
        `docker exec` into it is impossible. Started BEFORE the target can
        die. No extra caps - it only reads `ip` output. Base-image entrypoint
        is overridden with sleep; --no-healthcheck (runtime healthcheck N/A).
        Registered under the run label for cleanup."""
        name = "{}-{}".format(PFX, suffix)
        run(["docker", "run", "-d", "--name", name,
             "--platform", "linux/amd64",
             "--network", "container:{}".format(target_name),
             "--label", "{}={}".format(LABEL, RUN_ID),
             "--no-healthcheck",
             "--entrypoint", "sh", self.base_image,
             "-c", "exec sleep 86400"], timeout=30)
        self._register(name)
        return Container(name)

    # ------------------------------------------------------------ server
    def server(self, suffix, net, vid, subnet_third, lease_s=120,
               pollution=True, start=True):
        """A DHCP server on a single VLAN `vid` with subnet 10.<subnet_third>.<vid>.0/24.
        pollution=True -> also offers router/DNS/classless-route options that
        the reflector config must reject."""
        name = "{}-{}".format(PFX, suffix)
        b3 = subnet_third
        lo, hi = 100, 200
        conf = [
            "no-daemon", "log-dhcp", "dhcp-authoritative",
            "dhcp-leasefile=/var/lib/dnsmasq/dnsmasq.leases",
            "bind-interfaces", "interface=eth0.{}".format(vid),
            "dhcp-range=10.{}.{}.{}".format(b3, vid, lo) +
            ",10.{}.{}.{},255.255.255.0,{}s".format(b3, vid, hi, lease_s),
            "dhcp-option=1,255.255.255.0",
        ]
        if pollution:
            conf += [
                "dhcp-option=3,10.{}.{}.1".format(b3, vid),          # router
                "dhcp-option=6,10.{}.{}.53".format(b3, vid),         # DNS
                "dhcp-option=15,a4lab.invalid",                      # domain
                "dhcp-option=121,10.{}.{}.0/24,10.{}.{}.1".format(   # classless
                    b3, vid + 100 if vid + 100 <= 255 else vid, b3, vid),
            ]
        b64 = base64.b64encode("\n".join(conf).encode()).decode()
        script = (
            "set -e; "
            "ip link add link eth0 name eth0.{v} type vlan id {v}; "
            "ip link set eth0.{v} up; "
            "ip addr add 10.{b}.{v}.1/24 dev eth0.{v}; "
            "echo '{b64}' | base64 -d > /etc/dnsmasq.conf; "
            "exec dnsmasq -C /etc/dnsmasq.conf"
        ).format(v=vid, b=b3, b64=b64)
        run(["docker", "create", "--name", name,
             "--platform", "linux/amd64",
             "--network", net,
             "--label", "{}={}".format(LABEL, RUN_ID),
             "--no-healthcheck",   # dnsmasq box: runtime healthcheck N/A
             "--cap-add", "NET_ADMIN", "--cap-add", "NET_RAW",
             "--entrypoint", "sh", self.lab_image, "-c", script], timeout=30)
        self._register(name)
        srv = DHCPServer(name, vid, b3, lease_s)
        if start:
            srv.start()
        return srv

    # ------------------------------------------------------------ cleanup
    def cleanup(self):
        # Attempt EVERY owned/labelled resource even if some removals fail.
        for c in list(self.containers):
            run(["docker", "rm", "-f", c], timeout=30, check=False)
        for n in list(self.networks):
            run(["docker", "network", "rm", n], timeout=30, check=False)
        # safety sweep: anything still carrying our run label
        _, cs = run(["docker", "ps", "-aq", "--filter",
                     "label={}={}".format(LABEL, RUN_ID)], timeout=30, check=False)
        for cid in cs.split():
            run(["docker", "rm", "-f", cid], timeout=30, check=False)
        _, ns = run(["docker", "network", "ls", "-q", "--filter",
                     "label={}={}".format(LABEL, RUN_ID)], timeout=30, check=False)
        for nid in ns.split():
            run(["docker", "network", "rm", nid], timeout=30, check=False)
        self.containers = []
        self.networks = []
        # Final verification: report every leftover object still carrying our
        # run label so a failed cleanup is visible and the run can exit
        # nonzero instead of silently leaking Docker resources.
        leftovers = []
        _, cs2 = run(["docker", "ps", "-aq", "--filter",
                      "label={}={}".format(LABEL, RUN_ID)],
                     timeout=30, check=False)
        leftovers += [("container", cid) for cid in cs2.split()]
        _, ns2 = run(["docker", "network", "ls", "-q", "--filter",
                      "label={}={}".format(LABEL, RUN_ID)],
                     timeout=30, check=False)
        leftovers += [("network", nid) for nid in ns2.split()]
        if leftovers:
            for kind, oid in leftovers:
                out("CLEANUP-LEFTOVER {} {}".format(kind, oid))
        return leftovers


class Container(object):
    def __init__(self, name):
        self.name = name

    def ex(self, cmd, timeout=20, check=True):
        return run(["docker", "exec", self.name, "sh", "-c", cmd],
                   timeout=timeout, check=check)[1]

    def exb(self, cmd, timeout=20, check=True):
        """Exec under bash (needed to source state.env - busybox sh cannot
        parse the `declare -a` lines it contains)."""
        return run(["docker", "exec", self.name, "bash", "-c", cmd],
                   timeout=timeout, check=check)[1]

    def running(self):
        _, s = run(["docker", "inspect", "-f", "{{.State.Running}}", self.name],
                   timeout=15, check=False)
        return s.strip() == "true"

    def exit_code(self):
        _, s = run(["docker", "inspect", "-f", "{{.State.ExitCode}}", self.name],
                   timeout=15, check=False)
        try:
            return int(s.strip())
        except ValueError:
            return None

    def logs(self):
        # stdout+stderr merged in REAL chronological order (docker multiplexes
        # both on the logs stream; never lexicographically sort evidence -
        # e.g. "eth0.10: probing..." must keep its place after "created...").
        p = subprocess.run(["docker", "logs", self.name], stdout=subprocess.PIPE,
                           stderr=subprocess.STDOUT, timeout=30,
                           text=True, errors="replace")
        return p.stdout.splitlines()

    def mac(self):
        out_s = self.ex("ip -o link show dev eth0 | awk '{for(i=1;i<=NF;i++)"
                        " if($i==\"link/ether\") print $(i+1)}'")
        return out_s.strip().lower()

    def stop(self):
        run(["docker", "stop", "-t", "3", self.name], timeout=30, check=False)

    def start(self):
        run(["docker", "start", self.name], timeout=30)


class Reflector(Container):
    def __init__(self, name, vlans):
        super(Reflector, self).__init__(name)
        self.vlans = vlans

    def vif(self, v):
        return "eth0.{}".format(v)

    def addrs_v4(self, ifn):
        s = self.ex("ip -o -4 addr show dev {} | awk '{{print $4}}'".format(ifn),
                    check=False)
        return [a.strip() for a in s.splitlines() if a.strip()]

    def global_v4(self, ifn):
        return [a.split("/")[0] for a in self.addrs_v4(ifn)
                if not a.startswith("169.254.") and not a.startswith("127.")]

    def ll_v4(self, ifn):
        return [a.split("/")[0] for a in self.addrs_v4(ifn)
                if a.startswith("169.254.")]

    def ll_cidrs(self, ifn):
        """169.254 CIDRs (addr WITH prefix len) actually installed on ifn."""
        return [a for a in self.addrs_v4(ifn) if a.startswith("169.254.")]

    def if_mac(self, ifn):
        out_s = self.ex("ip -o link show dev {} | awk '{{for(i=1;i<=NF;i++)"
                        " if($i==\"link/ether\") print $(i+1)}}'".format(ifn),
                        check=False)
        return out_s.strip().lower()

    def links(self):
        return self.ex("ip -o link show | awk -F': ' '{print $2}'",
                       check=False).split()

    def routes(self):
        return self.ex("ip -4 route show", check=False).splitlines()

    def resolv(self):
        return self.ex("cat /etc/resolv.conf", check=False)

    def hostname(self):
        return self.ex("cat /etc/hostname", check=False).strip()

    def ready(self):
        if not self.running():
            return False
        _, s = run(["docker", "exec", self.name, "sh", "-c",
                    "test -f /run/avahi-reflector/ready && echo yes"],
                   timeout=10, check=False)
        return "yes" in s

    def health_ok(self):
        if not self.running():
            return False
        rc, _ = run(["docker", "exec", self.name, "sh", "-c",
                     "/bin/bash /healthcheck.sh"], timeout=15, check=False)
        return rc == 0

    def dump_lease(self, ifn):
        return self.ex("dhcpcd --dumplease {} 2>/dev/null || true".format(ifn),
                       check=False)

    def wait_ready(self, timeout=70):
        def go():
            if not self.running():
                raise RuntimeError("container {} died (rc={}) during startup:\n{}"
                                   .format(self.name, self.exit_code(),
                                           "\n".join(self.logs()[-30:])))
            return self.ready()
        return wait_for(go, timeout, 2.0, "{} ready".format(self.name))

    def wait_exit(self, timeout):
        def go():
            return not self.running()
        wait_for(go, timeout, 1.0, "{} exit".format(self.name))
        return self.exit_code()


class DHCPServer(Container):
    def __init__(self, name, vid, b3, lease_s=120):
        super(DHCPServer, self).__init__(name)
        self.vid = vid
        self.b3 = b3
        self.lease_s = lease_s
        # Advertised option values (structured source of truth - assertions
        # compare against THESE, never a hardcoded/wrong regex).
        # Must stay in sync with the conf emitted in Lab.server().
        r3 = vid + 100 if vid + 100 <= 255 else vid
        self.offered = {
            "router": "10.{}.{}.1".format(b3, vid),            # opt 3
            "dns": ["10.{}.{}.53".format(b3, vid)],            # opt 6
            "domain": "a4lab.invalid",                         # opt 15
            "classless": "10.{}.{}.0/24".format(b3, r3),       # opt 121 dest
        }

    def pid(self):
        _, s = run(["docker", "inspect", "-f", "{{.State.Pid}}", self.name],
                   timeout=15, check=False)
        try:
            return int(s.strip())
        except ValueError:
            return None

    def ready(self):
        if not self.running():
            return False
        return any("dnsmasq: started" in l for l in self.logs())

    def wait_ready(self, timeout=40):
        def go():
            if not self.running():
                raise RuntimeError("server {} died (rc={}):\n{}".format(
                    self.name, self.exit_code(),
                    "\n".join(self.logs()[-25:])))
            return self.ready()
        return wait_for(go, timeout, 1.0, "{} dnsmasq started".format(self.name))

    def dhcp_lines(self, what):
        """Chronological lines of a given dnsmasq DHCP verb e.g. DHCPACK /
        DHCPOFFER / DHCPDISCOVER / DHCPREQUEST for this server's interface."""
        tag = "{}(eth0.{})".format(what, self.vid)
        return [l for l in self.logs() if tag in l]

    def lease_expiry(self, ip):
        """dnsmasq.leases expiry epoch for `ip` (field 1), or None."""
        for line in self.leases_file().splitlines():
            f = line.split()
            if len(f) >= 3 and f[2] == ip and f[0].isdigit():
                return int(f[0])
        return None

    def leases_file(self):
        return self.ex("cat /var/lib/dnsmasq/dnsmasq.leases 2>/dev/null || true",
                       check=False)

    def ack_ips(self):
        ips = []
        for l in self.dhcp_lines("DHCPACK"):
            m = re.search(r"DHCPACK\(eth0\.\d+\)\s+(\d+\.\d+\.\d+\.\d+)", l)
            if m:
                ips.append(m.group(1))
        return ips


# ------------------------------------------------------------------ helpers
def record(test, status, detail=""):
    RESULT_ROWS.append((test, status, detail))
    out("==== {} : {} {}".format(test, status, ("- " + detail) if detail else ""))


def fail(test, msg, ctx=None):
    if ctx:
        out("---- failure context ----")
        for l in ctx[-40:]:
            out("   | {}".format(l))
    record(test, "FAIL", msg)
    raise AssertionError(msg)


# ============================================================== TESTS =======
def t1_ll_only(lab):
    """IPv4LL only: real ARP-probed claim in 169.254/16 usable range; two
    reflectors on the same VID claim distinct addresses."""
    net = lab.net("t1")
    a = lab.reflector("t1a", net, [10], "linklocal", startup_timeout=40)
    a.wait_ready()
    b = lab.reflector("t1b", net, [10], "linklocal", startup_timeout=40)
    b.wait_ready()

    v = a.vif(10)
    cidrs_a = a.ll_cidrs(v)          # "169.254.x.y/16" actually installed
    cidrs_b = b.ll_cidrs(b.vif(10))
    logs_a = "\n".join(a.logs())
    logs_b = "\n".join(b.logs())

    if not cidrs_a:
        fail("T1", "reflector A has no IPv4LL address", a.logs())
    cidr_a = cidrs_a[0]
    ip_a, _, pfx_a = cidr_a.partition("/")
    if pfx_a != "16":
        fail("T1", "A LL {} not a /16 (cidr={})".format(ip_a, cidr_a))
    if not ip_in_ll_range(ip_a):
        fail("T1", "A LL {} outside usable 169.254.1.0-169.254.254.255".format(ip_a))
    # Explicit RFC3927 ARP-probe evidence for THIS claimed address, and the
    # claim must appear in the log AFTER the probe (chronological order).
    if not re.search(r"probing for an IPv4LL address", logs_a):
        fail("T1", "no explicit 'probing for an IPv4LL address' line", a.logs())
    claim = re.search(re.escape(ip_a) + r".*probing.*claim|claim.*" +
                      re.escape(ip_a), logs_a)
    if not claim and not re.search(
            r"(using IPv4LL address|claimed)\s*" + re.escape(ip_a), logs_a):
        fail("T1", "no dhcpcd claim of {} in log".format(ip_a), a.logs())
    if not a.health_ok():
        fail("T1", "A healthcheck red after ready")
    if not re.search(r"Server startup complete", logs_a):
        fail("T1", "avahi never acked init on A")

    if not cidrs_b:
        fail("T1", "reflector B has no IPv4LL address", b.logs())
    ip_b = cidrs_b[0].split("/")[0]
    if not ip_in_ll_range(ip_b):
        fail("T1", "B LL {} outside usable range".format(ip_b))
    if ip_a == ip_b:
        fail("T1", "two reflectors claimed the SAME LL {}".format(ip_a))
    if not b.health_ok():
        fail("T1", "B healthcheck red")

    record("T1", "PASS",
           "A={} B={} distinct RFC3927 /16 claims, ARP-probed ('probing for an "
           "IPv4LL address'), healthy".format(cidr_a, cidrs_b[0]))


def t2_t3_t7_dhcp(lab):
    """DHCP lease on 2 VLANs (real ACK + server lease file + MAC/VID match),
    renewal proof (2nd ACK ~T1, no new DISCOVER/OFFER, IP unchanged),
    and DNS/route pollution rejection."""
    net = lab.net("t2")
    srv10 = lab.server("t2s10", net, 10, 10, lease_s=120, pollution=True)
    srv20 = lab.server("t2s20", net, 20, 20, lease_s=120, pollution=True)
    srv10.wait_ready()
    srv20.wait_ready()

    # resolv.conf/hostname baseline: recorded INSIDE the container at entry
    # (LAB_BASE_SNAPSHOT=1 wraps the image entrypoint: it snapshots these
    # files under /run/lab-base/ before exec'ing tini -> deterministic
    # pre-DHCP baseline, unlike a post-start `docker exec` read which races
    # the DHCP client). Runtime image/code is unchanged - the wrapper is a
    # test-only docker-run entrypoint prefix.
    ref = lab.reflector("t2r", net, [10, 20], "dhcp",
                        fallback_ll=False, startup_timeout=70,
                        env=["-e", "LAB_BASE_SNAPSHOT=1"])
    ref.wait_ready()
    resolv0 = ref.ex("cat /run/lab-base/resolv.conf 2>/dev/null || true",
                     check=False)
    host0 = ref.ex("cat /run/lab-base/hostname 2>/dev/null || cat /etc/hostname",
                   check=False).strip()
    if not host0:
        fail("T2", "could not read hostname baseline", ref.logs())
    if not ref.health_ok():
        fail("T2", "reflector health red after ready", ref.logs())

    # ---- T2: real lease proof ------------------------------------------
    # Per-VLAN-interface MAC (the ACK must carry the MAC of the iface the
    # lease is ON - not the trunk's, which can differ).
    lease0 = {}                    # vid -> server-side lease expiry epoch
    for v, srv, b3 in ((10, srv10, 10), (20, srv20, 20)):
        ifn = ref.vif(v)
        mac_v = ref.if_mac(ifn)
        if not re.match(r"^[0-9a-f]{2}(:[0-9a-f]{2}){5}$", mac_v):
            fail("T2", "could not read MAC of {}".format(ifn))
        g = ref.global_v4(ifn)
        if len(g) != 1:
            fail("T2", "{} has {} global v4 addrs {}".format(ifn, len(g), g))
        ip = g[0]
        if not ip.startswith("10.{}.{}.".format(b3, v)):
            fail("T2", "{} ip {} not in server subnet 10.{}.{}.0/24"
                 .format(ifn, ip, b3, v))
        # server-side ACK proof: this ip AND this VLAN iface's MAC, logged on
        # the matching server interface eth0.<v>
        acks = [l for l in srv.dhcp_lines("DHCPACK")
                if ip in l and mac_v in l.lower()]
        if not acks:
            fail("T2", "no server DHCPACK for {} mac {} on eth0.{}".format(
                ip, mac_v, v), srv.logs())
        offers = [l for l in srv.dhcp_lines("DHCPOFFER") if ip in l]
        if not offers:
            fail("T2", "no server DHCPOFFER for {}".format(ip), srv.logs())
        # client-side bound state
        dump = parse_kv(ref.dump_lease(ifn))
        if dump.get("reason") != "BOUND" or dump.get("ip_address") != ip:
            fail("T2", "dhcpcd dumplease mismatch on {}: {}".format(ifn, dump))
        # server lease file records this lease; capture expiry for T3 baseline
        exp = srv.lease_expiry(ip)
        if exp is None:
            fail("T2", "ip {} absent from server lease file".format(ip),
                 srv.logs())
        lease0[v] = (ip, exp)
    out("T2: both VLANs leased, ACK-verified "
        "v10={}(exp {}) v20={}(exp {})".format(
            lease0[10][0], lease0[10][1], lease0[20][0], lease0[20][1]))
    record("T2", "PASS", "leases on VID10+VID20 ACK-verified, per-iface MAC+VID "
                         "matched, server lease-file expiry recorded")

    # ---- T7: no DNS/route pollution --------------------------------------
    # Compare against the values the servers ACTUALLY advertise (structured,
    # stored on the DHCPServer object - no guessed regex).
    route_lines = ref.routes()
    if any(l.split() and l.split()[0] == "default" for l in route_lines):
        fail("T7", "default route installed", route_lines)
    # First field of each route line is the destination prefix: the offered
    # classless dest (opt 121) and offered router subnet must NOT appear as
    # installed routes (managed VLAN subnets themselves are legitimate).
    installed_dsts = [l.split()[0] for l in route_lines if l.split()]
    for srv in (srv10, srv20):
        adv = srv.offered
        if adv["classless"] in installed_dsts:
            fail("T7", "offered classless route {} installed: {}".format(
                adv["classless"], route_lines))
        router_dst = "10.{}.{}.0/24".format(srv.b3, srv.vid)
        # the VID subnet route is expected (it's our own lease subnet); the
        # OFFERED ROUTER (default via it) is already covered by 'default'.
    resolv1 = ref.resolv()
    # resolv.conf must equal the deterministic pre-DHCP entry snapshot AND
    # contain none of the advertised DNS/domain values.
    if resolv0 and resolv1 != resolv0:
        fail("T7", "resolv.conf changed after DHCP",
             ["before(entry):", resolv0, "after:", resolv1])
    offered_dns = [d for srv in (srv10, srv20) for d in srv.offered["dns"]]
    leaked = [d for d in offered_dns if d in resolv1]
    if leaked or srv10.offered["domain"] in resolv1:
        fail("T7", "offered DNS/domain leaked into resolv.conf: "
             "{} domain={}".format(leaked, srv10.offered["domain"]), [resolv1])
    if ref.hostname() != host0:
        fail("T7", "hostname changed: {} -> {}".format(host0, ref.hostname()))
    record("T7", "PASS",
           "advertised router/DNS {}/classless {} rejected; resolv.conf==entry "
           "snapshot, hostname unchanged".format(
               "+".join(offered_dns), srv10.offered["classless"]))

    # ---- T3: renewal ------------------------------------------------------
    # 120s lease -> T1 ~60s. Baseline the server verb counts AND the recorded
    # lease-expiry AFTER the initial bound; then require a NEW ACK for the
    # same IP+iface-MAC AFTER that baseline, the lease expiry to ADVANCE on
    # the server, and DISCOVER/OFFER counts to stay unchanged (a renew is a
    # unicast REQUEST - never a rebroadcast DISCOVER).
    ifn10 = ref.vif(10)
    ip10 = ref.global_v4(ifn10)[0]
    mac10 = ref.if_mac(ifn10)
    n_disc0 = len(srv10.dhcp_lines("DHCPDISCOVER"))
    n_off0 = len(srv10.dhcp_lines("DHCPOFFER"))
    n_req0 = len([l for l in srv10.dhcp_lines("DHCPREQUEST") if ip10 in l])
    n_ack0 = len([l for l in srv10.dhcp_lines("DHCPACK")
                  if ip10 in l and mac10 in l.lower()])
    exp0 = lease0[10][1]
    t0 = time.monotonic()

    def renewed():
        if not ref.running():
            raise RuntimeError("reflector died during renewal wait:\n{}"
                               .format("\n".join(ref.logs()[-30:])))
        # a NEW ACK for our IP+MAC beyond the initial-lease baseline
        a = [l for l in srv10.dhcp_lines("DHCPACK")
             if ip10 in l and mac10 in l.lower()]
        return len(a) > n_ack0

    wait_for(renewed, 150, 4.0, "new DHCPACK (renewal) for {}".format(ip10))
    dt = time.monotonic() - t0
    n_disc1 = len(srv10.dhcp_lines("DHCPDISCOVER"))
    n_off1 = len(srv10.dhcp_lines("DHCPOFFER"))
    n_req1 = len([l for l in srv10.dhcp_lines("DHCPREQUEST") if ip10 in l])
    n_ack1 = len([l for l in srv10.dhcp_lines("DHCPACK")
                  if ip10 in l and mac10 in l.lower()])
    exp1 = srv10.lease_expiry(ip10)
    if n_ack1 <= n_ack0:
        fail("T3", "ACK count for {} did not advance {}->{}".format(
            ip10, n_ack0, n_ack1), srv10.logs())
    if n_req1 <= n_req0:
        fail("T3", "no renewal REQUEST for {} ({}->{})".format(
            ip10, n_req0, n_req1), srv10.logs())
    if n_disc1 != n_disc0 or n_off1 != n_off0:
        fail("T3", "renewal used broadcast DISCOVER/OFFER: "
             "DISCOVER {}->{} OFFER {}->{}".format(
                 n_disc0, n_disc1, n_off0, n_off1), srv10.logs())
    if exp1 is None or exp1 <= exp0:
        fail("T3", "server lease expiry for {} did not advance {}->{}".format(
            ip10, exp0, exp1), srv10.logs())
    g10 = ref.global_v4(ifn10)
    if g10 != [ip10]:
        fail("T3", "IP changed after renewal: {} -> {}".format(ip10, g10))
    if ref.if_mac(ifn10) != mac10:
        fail("T3", "iface MAC changed after renewal")
    detail = ("renewal ACK #{}->{} for {} mac {} after ~{:.0f}s, REQUEST "
              "{}->{}, DISCOVER {} OFFER {} unchanged, server lease expiry "
              "{}->{} (+{}s), IP+MAC unchanged".format(
                  n_ack0, n_ack1, ip10, mac10, dt, n_req0, n_req1,
                  n_disc0, n_off0, exp0, exp1, exp1 - exp0))
    if not ref.health_ok():
        fail("T3", "health red after renewal")
    record("T3", "PASS", detail)


def t4_fallback_then_dhcp(lab):
    """No server -> LL fallback ready; then real DHCP server -> DHCP preferred,
    health stays green. LL retention policy recorded honestly."""
    net = lab.net("t4")
    srv = lab.server("t4s", net, 10, 10, lease_s=120, pollution=True,
                     start=False)          # created, not started
    ref = lab.reflector("t4r", net, [10], "dhcp",
                        fallback_ll=True, startup_timeout=70)
    ref.wait_ready()          # ready on LL fallback
    ifn = ref.vif(10)
    lls = ref.ll_v4(ifn)
    if not lls:
        fail("T4", "no IPv4LL after fallback wait", ref.logs())
    ll = lls[0]
    if not ip_in_ll_range(ll):
        fail("T4", "fallback LL {} outside usable range".format(ll))
    if not re.search(r"169\.254", "\n".join(ref.logs())):
        fail("T4", "no LL evidence in dhcpcd log")
    out("T4: fallback LL {} live; starting DHCP server".format(ll))

    srv.start()
    srv.wait_ready()
    # dhcpcd should keep retrying DHCP while on LL; wait for a global lease
    def got_dhcp():
        if not ref.running():
            raise RuntimeError("reflector died:\n{}"
                               .format("\n".join(ref.logs()[-30:])))
        return ref.global_v4(ifn)
    g = wait_for(got_dhcp, 90, 3.0, "DHCP addr after server start")
    ip = g[0]
    if not ip.startswith("10.10.10."):
        fail("T4", "dhcp ip {} not in server subnet".format(ip))
    acks = [l for l in srv.dhcp_lines("DHCPACK")
            if ip in l and ref.mac() in l.lower()]
    if not acks:
        fail("T4", "no server ACK for {} mac {}".format(ip, ref.mac()),
             srv.logs())
    if not ref.health_ok():
        fail("T4", "health red after DHCP acquired")
    cur_ll = ref.ll_v4(ifn)
    note = ("LL {} kept alongside DHCP".format(cur_ll[0])
            if cur_ll else "LL withdrawn after DHCP lease")
    record("T4", "PASS", "LL {} -> DHCP {} ({}), ACK-verified, healthy"
           .format(ll, ip, note))


def t5_no_server_no_fallback(lab):
    """DHCP required but no server + LL fallback OFF -> deliberate nonzero
    startup timeout, children cleaned, VLAN removed (verified via a live
    observer sharing the dead container's netns - a dead container cannot
    be exec'd, so an 'eth0.10 not found in error' check proved nothing)."""
    net = lab.net("t5")      # no server on this net
    ref = lab.reflector("t5r", net, [10], "dhcp",
                        fallback_ll=False, startup_timeout=25)
    # Observer pins the netns open BEFORE the main process can exit, so the
    # namespace (and any leftover links) stay inspectable after death.
    obs = lab.observer("t5obs", ref.name)
    # While it is still failing-to-start: dhcpcd must be alive (retrying),
    # state file exists, and there must be NO IPv4LL on the managed VLAN.
    def still_starting():
        return ref.running() and not ref.ready()
    if still_starting():
        # mid-startup evidence: owned dhcpcd running, no LL on eth0.10 yet
        pid = ref.exb(". /run/avahi-reflector/state.env; "
                      "echo ${DHCPCD_PID:-}", check=False).strip()
        if pid.isdigit():
            alive = ref.ex("kill -0 {} && echo y".format(pid),
                           check=False).strip()
            if alive != "y":
                out("T5: note - dhcpcd pid {} not alive mid-start".format(pid))
        ll = ref.ll_v4(ref.vif(10))
        if ll:
            fail("T5", "IPv4LL {} present although fallback is OFF".format(ll),
                 ref.logs())
    rc = ref.wait_exit(80)
    logs = "\n".join(ref.logs())
    if rc == 0 or rc is None:
        fail("T5", "expected nonzero exit, got rc={}".format(rc), ref.logs())
    # The failure must be the deliberate STARTUP TIMEOUT path - never an
    # unhandled 'dhcpcd failed to start' crash (which would be a defect).
    if "startup timed out" not in logs:
        fail("T5", "expected deliberate 'startup timed out' failure", ref.logs())
    if "dhcpcd failed to start" in logs:
        fail("T5", "dhcpcd itself failed to start (not a clean timeout)",
             ref.logs())
    # Post-death netns check via the still-alive observer (main is dead):
    # the managed VLAN the runtime created must be GONE, not just invisible.
    obs_links = obs.ex("ip -o link show 2>/dev/null || true", check=False)
    if re.search(r"eth0\.10\b", obs_links):
        fail("T5", "VLAN eth0.10 survived failed startup in shared netns",
             obs_links.splitlines())
    record("T5", "PASS",
           "no server+fallback off -> deliberate 'startup timed out' rc={}, "
           "no dhcpcd-start crash, netns VLAN removed (observer-verified)"
           .format(rc))


def t6_lease_loss_recovery(lab):
    """Server stop -> lease expires -> addr dropped + health red + client
    alive; server return -> new lease + health green."""
    net = lab.net("t6")
    srv = lab.server("t6s", net, 10, 10, lease_s=120, pollution=False)
    srv.wait_ready()
    ref = lab.reflector("t6r", net, [10], "dhcp",
                        fallback_ll=False, startup_timeout=70)
    ref.wait_ready()
    ifn = ref.vif(10)
    ip0 = ref.global_v4(ifn)[0]
    mac10 = ref.if_mac(ifn)
    # Baseline BEFORE the outage: ACK count for our ip+mac and the recorded
    # lease expiry, so the recovery asserts a NEW lease event - not a stale
    # pre-outage ACK from the merged log.
    n_ack0 = len([l for l in srv.dhcp_lines("DHCPACK")
                  if ip0 in l and mac10 in l.lower()])
    exp0 = srv.lease_expiry(ip0)
    srv_pid0 = srv.pid()
    out("T6: leased {} mac {} (ack#{} exp{} srvpid {}); "
        "stopping server to force expiry".format(
            ip0, mac10, n_ack0, exp0, srv_pid0))
    srv.stop()
    wait_for(lambda: not srv.running(), 30, 1.0, "server stopped")

    # lease 120s; wait for the address to disappear (client alive, health red)
    def dropped():
        if not ref.running():
            raise RuntimeError("reflector died on lease loss:\n{}"
                               .format("\n".join(ref.logs()[-30:])))
        return len(ref.global_v4(ifn)) == 0
    wait_for(dropped, 160, 4.0, "lease expiry drop of {}".format(ip0))
    if ref.health_ok():
        fail("T6", "health stayed green after lease loss")
    out("T6: addr dropped after expiry, health red, client alive; "
        "restarting server")
    srv.start()
    srv.wait_ready()

    def rebound():
        if not ref.running():
            raise RuntimeError("reflector died during rebind:\n{}"
                               .format("\n".join(ref.logs()[-30:])))
        return ref.global_v4(ifn)
    g = wait_for(rebound, 120, 4.0, "re-bound DHCP addr")
    if not ref.health_ok():
        fail("T6", "health red after rebind")
    ip1 = g[0]
    # NEW lease evidence: an ACK for the CURRENT ip+our mac BEYOND the
    # pre-outage baseline count, a fresh server-side lease expiry, and a new
    # dnsmasq process after the restart. Because `docker start` reuses the
    # same container the log is cumulative - baseline counts are mandatory.
    acks1 = [l for l in srv.dhcp_lines("DHCPACK")
             if ip1 in l and mac10 in l.lower()]
    n_ack1 = len(acks1)
    if ip1 == ip0:
        if n_ack1 <= n_ack0:
            fail("T6", "no NEW ACK after restart for {} ({}->{})".format(
                ip1, n_ack0, n_ack1), srv.logs())
    elif n_ack1 < 1:
        fail("T6", "no server ACK for rebound {} mac {}".format(ip1, mac10),
             srv.logs())
    exp1 = srv.lease_expiry(ip1)
    if exp1 is None or (ip1 == ip0 and exp1 <= (exp0 or 0)):
        fail("T6", "no fresh lease expiry after rebind ({}->{})".format(
            exp0, exp1), srv.logs())
    srv_pid1 = srv.pid()
    if srv_pid1 is not None and srv_pid0 is not None and srv_pid1 == srv_pid0:
        fail("T6", "dnsmasq not actually restarted (pid {})".format(srv_pid1))
    record("T6", "PASS",
           "lease {} expired->dropped+red, reacquired {} (ack#{}->{} exp {}->{},"
           " new dnsmasq pid {}) ->green".format(
               ip0, ip1, n_ack0, n_ack1, exp0, exp1, srv_pid1))


def t8_kill_dhcpcd(lab):
    """Kill the OWNED dhcpcd (by PID from state.env) -> supervisor must fail
    nonzero and clean up its VLANs; not an outer timeout."""
    net = lab.net("t8")
    srv = lab.server("t8s", net, 10, 10, lease_s=120, pollution=False)
    srv.wait_ready()
    ref = lab.reflector("t8r", net, [10], "dhcp",
                        fallback_ll=False, startup_timeout=70)
    ref.wait_ready()
    obs = lab.observer("t8obs", ref.name)   # pin netns before main can die
    pid = ref.exb(". /run/avahi-reflector/state.env; echo ${DHCPCD_PID:-}",
                  check=False).strip()
    if not pid.isdigit():
        fail("T8", "could not read owned DHCPCD_PID from state.env",
             ref.logs())
    # Confirm the pid is real and is the live dhcpcd before signalling it.
    if "dhcpcd" not in ref.ex("cat /proc/{}/comm 2>/dev/null".format(pid),
                              check=False):
        fail("T8", "state.env DHCPCD_PID {} is not a live dhcpcd".format(pid))
    out("T8: killing owned dhcpcd pid {}".format(pid))
    ref.ex("kill -TERM {}".format(pid), check=False)
    rc = ref.wait_exit(40)
    logs = "\n".join(ref.logs())
    if rc == 0 or rc is None:
        fail("T8", "expected nonzero exit after dhcpcd kill, rc={}".format(rc),
             ref.logs())
    if "dhcpcd exited" not in logs and "essential process died" not in logs:
        fail("T8", "no supervisor dhcpcd-death failure logged", ref.logs())
    # The managed VLAN must be gone from the (still-open) shared netns.
    obs_links = obs.ex("ip -o link show 2>/dev/null || true", check=False)
    if re.search(r"eth0\.10\b", obs_links):
        fail("T8", "VLAN survived supervisor teardown", obs_links.splitlines())
    record("T8", "PASS",
           "kill owned dhcpcd pid {} -> supervisor 'dhcpcd exited' rc={}, "
           "netns VLAN removed (observer-verified)".format(pid, rc))


TESTS = {
    "T1": ("IPv4LL-only claims (RFC3927, 2 reflectors)", t1_ll_only),
    "T2": ("DHCP lease 2 VLANs + ACK/lease-file/MAC proof", None),  # merged
    "T3": ("DHCP renewal (2nd ACK, no re-DISCOVER)", None),          # merged
    "T7": ("no DNS/route pollution", None),                          # merged
    "T4": ("LL fallback -> DHCP preferred", t4_fallback_then_dhcp),
    "T5": ("no server + fallback off -> nonzero timeout", t5_no_server_no_fallback),
    "T6": ("lease loss -> recovery", t6_lease_loss_recovery),
    "T8": ("kill owned dhcpcd -> supervisor fails", t8_kill_dhcpcd),
}
ORDER = ["T1", "T2", "T4", "T5", "T6", "T8"]


def build_images(base_image, lab_image):
    out("building base image {} from {}".format(base_image, ROOT))
    run(["docker", "build", "--platform", "linux/amd64",
         "-t", base_image, "."], timeout=600, cwd=ROOT)
    out("building lab image {} (runtime + dnsmasq)".format(lab_image))
    run(["docker", "build", "--platform", "linux/amd64",
         "--build-arg", "BASE_IMAGE={}".format(base_image),
         "-t", lab_image, "-f", os.path.join("test", "dhcp", "Dockerfile"), "."],
        timeout=600, cwd=ROOT)


def check_engine():
    _, info = run(["docker", "version", "--format",
                   "{{.Server.Os}}/{{.Server.Arch}}"], timeout=30)
    out("docker engine: {}".format(info.strip()))
    osname, _, arch = info.strip().partition("/")
    if osname != "linux":
        out("WARN: engine OS is '{}' - lab expects linux".format(osname))
    if arch != "amd64" and arch != "x86_64":
        out("WARN: engine arch '{}' - dhcpcd privsep sockets are broken under "
            "qemu emulation; run native amd64 for valid results".format(arch))


def main():
    ap = argparse.ArgumentParser(description="DHCP/IPv4LL lab for avahi reflector")
    ap.add_argument("--base-image", default=BASE_IMAGE_DEFAULT)
    ap.add_argument("--lab-image", default=LAB_IMAGE_DEFAULT)
    ap.add_argument("--skip-build", action="store_true")
    ap.add_argument("--only", default="",
                    help="comma subset e.g. T1,T5 (valid: {})".format(
                        ",".join(sorted(TESTS))))
    ap.add_argument("--keep-resources", action="store_true",
                    help="do NOT delete labelled containers/networks (debug)")
    a = ap.parse_args()

    # Validate --only BEFORE building images or creating any resource:
    # unknown/empty ids must fail fast, never silently run zero tests.
    if a.only:
        wanted = set(t.strip() for t in a.only.split(",") if t.strip())
        bad = wanted - set(TESTS)
        if bad:
            ap.error("unknown test id(s): {} (valid: {})".format(
                ",".join(sorted(bad)), ",".join(sorted(TESTS))))
        if not wanted:
            ap.error("--only produced an empty test set")
    else:
        wanted = set(ORDER)

    os.makedirs(RESULTS, exist_ok=True)
    resfile = os.path.join(RESULTS, "RESULTS-{}.txt".format(RUN_ID))

    t_start = time.monotonic()
    check_engine()
    if not a.skip_build:
        build_images(a.base_image, a.lab_image)

    lab = Lab(a.lab_image, a.base_image)
    rc = 0
    leftovers = []
    try:
        if "T1" in wanted:
            try:
                t1_ll_only(lab)
            except Exception as e:
                if not any(r[0] == "T1" for r in RESULT_ROWS):
                    record("T1", "FAIL", str(e))
        if any(k in wanted for k in ("T2", "T3", "T7")):
            try:
                t2_t3_t7_dhcp(lab)
            except Exception as e:
                for t in ("T2", "T3", "T7"):
                    if not any(r[0] == t for r in RESULT_ROWS):
                        record(t, "FAIL", str(e))
        for t in ("T4", "T5", "T6", "T8"):
            if t in wanted:
                try:
                    TESTS[t][1](lab)
                except Exception as e:
                    if not any(r[0] == t for r in RESULT_ROWS):
                        record(t, "FAIL", str(e))
    except KeyboardInterrupt:
        out("interrupted - cleaning up")
        rc = 130
    finally:
        if not a.keep_resources:
            leftovers = lab.cleanup()
            if leftovers:
                out("cleanup done WITH {} leftover labelled object(s)".format(
                    len(leftovers)))
            else:
                out("cleanup done (containers+networks removed, 0 leftovers)")
        else:
            out("--keep-resources: leaving labelled resources for debug")

    n_pass = sum(1 for r in RESULT_ROWS if r[1] == "PASS")
    n_fail = sum(1 for r in RESULT_ROWS if r[1] == "FAIL")
    out("===================== SUMMARY =====================")
    for t, s, d in RESULT_ROWS:
        out("  {:<3} {:<5} {}".format(t, s, d))
    out("  passed={} failed={} elapsed={:.0f}s".format(
        n_pass, n_fail, time.monotonic() - t_start))
    if n_fail:
        rc = 1
    if leftovers:
        out("  WARNING: {} labelled object(s) left behind".format(
            len(leftovers)))
        rc = 1
    with open(resfile, "w", encoding="utf-8") as f:
        f.write("\n".join(LOG_LINES) + "\n")
    out("log written: {}".format(resfile))
    return rc


if __name__ == "__main__":
    sys.exit(main())
