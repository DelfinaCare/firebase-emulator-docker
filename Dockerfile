# syntax=docker/dockerfile:1
FROM mikefarah/yq:4.54.3@sha256:7834187596ad56fd5a81436114e0b0b9dd54c91bb43946d1f7145b2be5f9c3d2 AS yq

# Node 24: the newest release line firebase-tools 15 declares support for
# (via superstatic's engines field). trixie: firebase-tools 15 requires Java 21
# or newer, which is trixie's default JRE (bookworm's is 17).
# Both base images are pinned by tag and digest; dependabot updates the two
# together (.github/dependabot.yml holds node back from new major versions).
FROM node:24.22.2-trixie-slim@sha256:0820eaa85e07d0490446dd01d14707e17e6108a36988cf374899cd057eb3812d

# Emulator binaries to download at build time, so startup does not need
# network access. Any of: pubsub ui firestore database storage. Emulators not
# listed here are downloaded on first start instead.
ARG PRELOAD_EMULATORS="pubsub ui"

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get -y install --no-install-recommends \
    bash ca-certificates curl default-jre-headless jq \
    && rm -rf /var/lib/apt/lists/*
COPY --link --from=yq /usr/bin/yq /usr/bin/yq

WORKDIR /opt/firebase-emulator
ENV PATH=/opt/firebase-emulator/node_modules/.bin:${PATH} \
    FIREBASE_EMULATORS_PATH=/opt/firebase-emulator/emulators

# firebase-tools is pinned in package.json/package-lock.json, so dependabot
# can update it.
COPY --link package.json package-lock.json ./
RUN npm ci --omit=dev --no-fund --no-audit \
    && npm cache clean --force

RUN for emulator in ${PRELOAD_EMULATORS}; do \
    firebase setup:emulators:"${emulator}" || exit 1; \
    done

COPY --link entrypoint.sh ./
COPY --link scripts/ ./scripts/

ENV FIREBASE_DATA_DIR=/data
VOLUME ["/data"]

# auth, pubsub, firestore, database, ui, hub, logging
EXPOSE 9099 8085 8080 9000 4000 4400 4500

HEALTHCHECK --interval=5s --timeout=5s --start-period=60s --retries=3 \
    CMD ["/opt/firebase-emulator/scripts/healthcheck.sh"]

# entrypoint.sh runs as PID 1 and handles SIGTERM itself.
ENTRYPOINT ["/opt/firebase-emulator/entrypoint.sh"]
