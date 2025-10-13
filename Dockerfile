FROM alpine:3.20
RUN set -eux; \
    echo "https://dl-cdn.alpinelinux.org/alpine/v3.20/main" > /etc/apk/repositories; \
    echo "https://dl-cdn.alpinelinux.org/alpine/v3.20/community" >> /etc/apk/repositories; \
    apk update; \
    apk add --no-cache avahi dbus iproute2 bash coreutils tini
COPY avahi-daemon.conf.tmpl /etc/avahi/avahi-daemon.conf.tmpl
COPY entrypoint.sh /entrypoint.sh
RUN sed -i 's/\r$//' /entrypoint.sh && chmod +x /entrypoint.sh
EXPOSE 5353/udp 5353/tcp
ENTRYPOINT ["/sbin/tini","--","/bin/bash","/entrypoint.sh"]
