# DHCP lab image: runtime image + dnsmasq (test-only DHCP server).
# Built FROM the freshly-built runtime image so tests exercise exactly the
# bits under review. dnsmasq is added ONLY to this derivative test image -
# never to the runtime image.
ARG BASE_IMAGE=ccr2116-avahi-a4-base:amd64
FROM ${BASE_IMAGE}
RUN set -eux; \
    apk add --no-cache dnsmasq; \
    mkdir -p /var/lib/dnsmasq
# No ENTRYPOINT override: tests pass explicit --entrypoint / command.
