# PART 2/2 — one model-weight part, built FROM the env image.
# Build: podman build --build-arg PART=p1 -f sensenova-part.Dockerfile .
# Each part holds ~2 shards (~9 GB); push each as part-<name>, then
# ops/compose-image.py appends the new layers onto the env image.
ARG ENV_TAG="latest"
FROM docker.io/moneywaters/sensenova-code2video:${ENV_TAG}

ARG PART=p1

COPY sensenova/fetch-part.sh /opt/fetch-part.sh
RUN chmod +x /opt/fetch-part.sh

# One part per image, so this layer commits reliably on a GHA runner.
RUN PART="${PART}" /opt/fetch-part-parts.sh
