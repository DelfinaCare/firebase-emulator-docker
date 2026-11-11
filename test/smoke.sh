#!/bin/bash
# Smoke test for a built image: startup, healthcheck, Pub/Sub config, auth
# REST API, and export on SIGTERM followed by import on the next start.
#
# Usage: test/smoke.sh IMAGE
set -euo pipefail

IMAGE=${1:?usage: $0 IMAGE}
TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
NAME=firebase-emulator-smoke-$$
VOLUME=${NAME}-data
PROJECT=demo-smoke
AUTH=http://localhost:9099/identitytoolkit.googleapis.com/v1/projects/${PROJECT}
PUBSUB=http://localhost:8085/v1/projects/${PROJECT}

log() {
    echo "[$(date -u +%H:%M:%S)] smoke: $*"
}

fail() {
    log "FAIL: $*" >&2
    docker logs "${NAME}" 2>&1 | tail -n 50 >&2 || true
    exit 1
}

cleanup() {
    docker rm -f "${NAME}" >/dev/null 2>&1 || true
    docker volume rm "${VOLUME}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

start() {
    docker rm -f "${NAME}" >/dev/null 2>&1 || true
    docker run -d --name "${NAME}" \
        -e FIREBASE_PROJECT="${PROJECT}" \
        -e PUBSUB_PUSH_BASE_URL=http://app:8080 \
        -v "${VOLUME}:/data" \
        -v "${TEST_DIR}/pubsub.yaml:/etc/firebase/pubsub.yaml:ro" \
        "${IMAGE}" >/dev/null
    log "Waiting for the container to become healthy"
    for _ in $(seq 1 120); do
        status=$(docker inspect -f '{{.State.Health.Status}}' "${NAME}")
        case "${status}" in
        healthy) log "Healthy" && return 0 ;;
        unhealthy) fail "container is unhealthy" ;;
        esac
        [ "$(docker inspect -f '{{.State.Running}}' "${NAME}")" = true ] || fail "container exited"
        sleep 1
    done
    fail "timed out waiting for the container to become healthy"
}

# Runs curl inside the container, so no ports need to be published.
dcurl() {
    docker exec "${NAME}" curl -sS --fail-with-body "$@"
}

start

log "Checking Pub/Sub subscriptions"
subscriptions=$(dcurl "${PUBSUB}/subscriptions" |
    jq -c '[.subscriptions[] | {name: (.name | split("/")[-1]), push: .pushConfig.pushEndpoint}] | sort_by(.name)')
expected='[{"name":"smoke-absolute","push":"http://other:9000/hook"},{"name":"smoke-pull","push":null},{"name":"smoke-push","push":"http://app:8080/pubsub/smoke"}]'
[ "${subscriptions}" = "${expected}" ] || fail "unexpected subscriptions: ${subscriptions}"

log "Creating an auth user"
dcurl -X POST -H 'Authorization: Bearer owner' -H 'Content-Type: application/json' \
    -d '{"email":"smoke@example.com","password":"smoke-password"}' \
    "${AUTH}/accounts" >/dev/null

log "Stopping the container (SIGTERM)"
docker stop -t 10 "${NAME}" >/dev/null
exit_code=$(docker inspect -f '{{.State.ExitCode}}' "${NAME}")
[ "${exit_code}" = 0 ] || fail "container exited with code ${exit_code}"
docker logs "${NAME}" 2>&1 | grep -q "Saved emulator data" || fail "data was not saved on shutdown"

log "Restarting with the same data volume"
start
emails=$(dcurl -X POST -H 'Authorization: Bearer owner' -H 'Content-Type: application/json' \
    -d '{}' "${AUTH}/accounts:query" | jq -c '[.userInfo[]?.email]')
[ "${emails}" = '["smoke@example.com"]' ] || fail "user was not restored, got ${emails}"

log "PASS"
