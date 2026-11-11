#!/bin/bash
# Creates Pub/Sub topics and subscriptions in the Pub/Sub emulator from a
# YAML or JSON file. Safe to run more than once: existing topics and
# subscriptions are left as they are.
#
# File format:
#   topics:
#     - name: orders
#       subscriptions:
#         - name: orders-worker                     # pull subscription
#         - name: orders-push
#           pushPath: /pubsub/orders                # joined to PUBSUB_PUSH_BASE_URL
#         - name: orders-abs
#           pushEndpoint: http://other:9000/hook    # absolute, wins over pushPath
#
# Any other subscription fields (e.g. ackDeadlineSeconds) are passed through
# to the Subscription resource unchanged.
#
# Environment:
#   PUBSUB_EMULATOR_HOST   host:port of the emulator (required)
#   PUBSUB_PROJECT_ID      project ID (default: $FIREBASE_PROJECT or demo-project)
#   PUBSUB_CONFIG          config file (default: /etc/firebase/pubsub.yaml)
#   PUBSUB_PUSH_BASE_URL   base URL for pushPath (default: http://localhost:8080)
#   PUBSUB_WAIT_TIMEOUT    seconds to wait for the emulator (default: 60)
set -euo pipefail

: "${PUBSUB_EMULATOR_HOST:?PUBSUB_EMULATOR_HOST must be set}"
: "${PUBSUB_PROJECT_ID:=${FIREBASE_PROJECT:-demo-project}}"
: "${PUBSUB_CONFIG:=/etc/firebase/pubsub.yaml}"
: "${PUBSUB_PUSH_BASE_URL:=http://localhost:8080}"
: "${PUBSUB_WAIT_TIMEOUT:=60}"

BASE_URL="http://${PUBSUB_EMULATOR_HOST}/v1/projects/${PUBSUB_PROJECT_ID}"

log() {
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] configure-pubsub: $*"
}

die() {
    log "ERROR: $*" >&2
    exit 1
}

RESPONSE_FILE=$(mktemp)
trap 'rm -f "${RESPONSE_FILE}"' EXIT

# PUTs JSON body $2 to $BASE_URL/$1. Succeeds on 200 (created) and 409
# (already exists); fails with the response body on anything else.
put() {
    local path=$1 body=$2 status
    status=$(curl -sS -o "${RESPONSE_FILE}" -w '%{http_code}' -X PUT \
        -H 'Content-Type: application/json' \
        --data-binary "${body}" \
        "${BASE_URL}/${path}") || die "PUT ${BASE_URL}/${path} failed: could not connect"
    case "${status}" in
    200) log "Created ${path}" ;;
    409) log "Already exists: ${path}" ;;
    *) die "PUT ${BASE_URL}/${path} returned HTTP ${status}: $(cat "${RESPONSE_FILE}")" ;;
    esac
}

[ -f "${PUBSUB_CONFIG}" ] || die "Config file ${PUBSUB_CONFIG} not found"
# yq reads both YAML and JSON.
CONFIG=$(yq -o=json '.' "${PUBSUB_CONFIG}") || die "Could not parse ${PUBSUB_CONFIG}"

# Validate the structure up front, so a typo fails before anything is created.
errors=$(jq -r '
    if (.topics | type) != "array" then "top-level \"topics\" must be a list"
    else .topics | to_entries[] | .key as $i | .value |
        if (.name | type) != "string" or .name == "" then "topics[\($i)]: \"name\" is required"
        elif has("subscriptions") and (.subscriptions | type) != "array" then "topic \(.name): \"subscriptions\" must be a list"
        else .name as $t | (.subscriptions // [])[] |
            select((.name | type) != "string" or .name == "") |
            "topic \($t): every subscription needs a \"name\""
        end
    end' <<<"${CONFIG}")
[ -z "${errors}" ] || die "Invalid ${PUBSUB_CONFIG}: ${errors}"

log "Waiting for the Pub/Sub emulator at ${PUBSUB_EMULATOR_HOST}"
deadline=$((SECONDS + PUBSUB_WAIT_TIMEOUT))
until curl -sf -o /dev/null "http://${PUBSUB_EMULATOR_HOST}/"; do
    [ "${SECONDS}" -lt "${deadline}" ] || die "Timed out after ${PUBSUB_WAIT_TIMEOUT}s waiting for the Pub/Sub emulator"
    sleep 1
done

# One compact JSON object per resource: {path, body}, topics before their
# subscriptions.
while IFS= read -r request; do
    put "$(jq -r '.path' <<<"${request}")" "$(jq -c '.body' <<<"${request}")"
done < <(jq -c \
    --arg project "projects/${PUBSUB_PROJECT_ID}" \
    --arg base "${PUBSUB_PUSH_BASE_URL%/}" '
    .topics[] |
    .name as $topic |
    {path: "topics/\($topic | @uri)", body: {}},
    ((.subscriptions // [])[] |
        (if .pushEndpoint then .pushEndpoint
         elif .pushPath then $base + (if (.pushPath | startswith("/")) then "" else "/" end) + .pushPath
         else null end) as $endpoint |
        {path: "subscriptions/\(.name | @uri)",
         body: (del(.name, .pushPath, .pushEndpoint)
                + {topic: "\($project)/topics/\($topic)"}
                + (if $endpoint then {pushConfig: {pushEndpoint: $endpoint}} else {} end))})
    ' <<<"${CONFIG}")

log "Pub/Sub configuration complete"
