FROM alpine:3.24.4

# Packages: avahi (reflector), dhcpcd (DHCP/IPv4LL address manager - sole
# client, no fallback), iproute2 (ip), bash (entrypoint), tini (PID 1).
RUN set -eux; \
    apk add --no-cache avahi dhcpcd iproute2 bash tini; \
    # Drop packaged default services: this is a pure reflector and must not
    # advertise ssh/sftp daemons that do not exist here.
    rm -f /etc/avahi/services/*.service; \
    # Prepare runtime dirs owned by the image.
    mkdir -p /run/avahi-daemon /run/avahi-reflector /run/dhcpcd /var/lib/dhcpcd

COPY avahi-daemon.conf.tmpl /etc/avahi/avahi-daemon.conf.tmpl
COPY entrypoint.sh /entrypoint.sh
COPY healthcheck.sh /healthcheck.sh
COPY lib.sh /usr/local/lib/avahi-reflector/lib.sh
RUN sed -i 's/\r$//' /entrypoint.sh /healthcheck.sh \
        /usr/local/lib/avahi-reflector/lib.sh \
        /etc/avahi/avahi-daemon.conf.tmpl && \
    chmod +x /entrypoint.sh /healthcheck.sh

# Metadata only - this does NOT open any firewall; it just documents the port.
EXPOSE 5353/udp

# tini reaps zombies and forwards signals; entrypoint is the lightweight
# supervisor that keeps avahi + the DHCP client alive together.
ENTRYPOINT ["/sbin/tini","--","/bin/bash","/entrypoint.sh"]

# Readiness-aware healthcheck (interface up + expected address + avahi alive).
HEALTHCHECK --interval=30s --timeout=8s --start-period=75s --retries=3 \
    CMD ["/bin/bash","/healthcheck.sh"]
