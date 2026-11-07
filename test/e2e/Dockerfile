# End-to-end test image: the runtime image PLUS a stdlib-only Python used by
# the lab mDNS client. This image is for LOCAL TESTING ONLY - it is never
# shipped to the router and never used as the production runtime.
#
# Build (amd64 example; swap --platform / ARG for arm64):
#   docker build -t ccr2116-avahi:local-amd64 .
#   docker build --build-arg RUNTIME_IMAGE=ccr2116-avahi:local-amd64 \
#       -f test/e2e/Dockerfile -t ccr2116-avahi-e2e:amd64 .
ARG RUNTIME_IMAGE=ccr2116-avahi:local-amd64
FROM ${RUNTIME_IMAGE}
# python3 is test-only. apk downloads are allowed at image-build time; the e2e
# lab runs fully on --internal networks (no internet needed at run time).
RUN set -eux; \
    apk add --no-cache python3; \
    # tini/entrypoint/healthcheck all come from the base runtime image.
    mkdir -p /t
COPY test/e2e/mdns.py /t/mdns.py
# Keep the runtime image's ENTRYPOINT/HEALTHCHECK. Tests invoke
# /entrypoint.sh (reflector) or /t/*.sh (clients) explicitly via
# `docker run --entrypoint`, so this image doubles as both.
