FROM alpine:3.20

# Repo + balíčky: avahi, dbus, iproute2, bash, coreutils, tini
# (udhcpc je součástí busyboxu v Alpine, takže DHCP klient je k dispozici)
RUN set -eux; \
    echo "https://dl-cdn.alpinelinux.org/alpine/v3.20/main" > /etc/apk/repositories; \
    echo "https://dl-cdn.alpinelinux.org/alpine/v3.20/community" >> /etc/apk/repositories; \
    apk update; \
    apk add --no-cache avahi dbus iproute2 bash coreutils tini; \
    # příprava adresářů pro dbus/avahi (runtime se ještě ověří v entrypointu)
    mkdir -p /run/dbus /var/lib/dbus

# Šablona Avahi s placeholderem {{ALLOW_INTERFACES}}
COPY avahi-daemon.conf.tmpl /etc/avahi/avahi-daemon.conf.tmpl

# Entry point – dynamická detekce trunk IF, VLAN sub-IF, IP režimy, DBus + Avahi
COPY entrypoint.sh /entrypoint.sh
RUN sed -i 's/\r$//' /entrypoint.sh && chmod +x /entrypoint.sh

EXPOSE 5353/udp 5353/tcp

# Tini zajistí správný reaping procesů a signály
ENTRYPOINT ["/sbin/tini","--","/bin/bash","/entrypoint.sh"]

# (volitelné) jednoduchý healthcheck – avahi-daemon musí běžet
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD pidof avahi-daemon >/dev/null || exit 1
