# docker/open-wire.Dockerfile
#
# Wraps a pre-built open-wire binary into a minimal runtime image.
# Used by scripts/build-image.sh for local development.
# In CI, the image is built from the nats_rust repo and pushed to ghcr.io.
#
# Build context: repo root (bin/open-wire must exist)

FROM debian:bookworm-slim

RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates && \
    rm -rf /var/lib/apt/lists/*

COPY bin/open-wire /usr/local/bin/open-wire

EXPOSE 4222 4223

ENTRYPOINT ["open-wire"]
CMD ["--port", "4222"]
