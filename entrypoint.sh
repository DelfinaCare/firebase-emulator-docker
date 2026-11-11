#!/bin/bash
# Starts the Firebase Emulator Suite. Runs as PID 1 and handles SIGTERM/SIGINT.
#
# All configuration is via environment variables; see README.md.
#
# Persistence: data is imported from $FIREBASE_DATA_DIR on startup and
# exported back to it on shutdown. The emulator works from a local copy,
# because $FIREBASE_DATA_DIR is often a Cloud Storage FUSE mount, which does
# not support the atomic directory renames the emulator export relies on.
#
# Seeding: if there is no saved data and $FIREBASE_SEED_DIR is set, the seed
# is imported at startup when present. Otherwise the emulator starts empty,
# waits for the seed to appear and imports its auth accounts over REST. Until
# that happens nothing is saved on shutdown, so an empty export cannot hide
# the seed from the next instance.
set -euo pipefail

: "${FIREBASE_PROJECT:=demo-project}"
: "${FIREBASE_CONFIG_FILE:=}"
: "${FIREBASE_EMULATORS:=}"
: "${FIREBASE_AUTH_PORT:=9099}"
: "${FIREBASE_PUBSUB_PORT:=8085}"
: "${FIREBASE_FIRESTORE_PORT:=8080}"
: "${FIREBASE_DATABASE_PORT:=9000}"
: "${FIREBASE_UI_PORT:=4000}"
: "${FIREBASE_UI_ENABLED:=true}"
: "${FIREBASE_HUB_PORT:=4400}"
: "${FIREBASE_LOGGING_PORT:=4500}"
: "${FIREBASE_DATA_DIR:=/data}"
: "${FIREBASE_PERSIST:=true}"
: "${FIREBASE_SEED_DIR:=}"
: "${FIREBASE_SEED_POLL_INTERVAL:=5}"
: "${FIREBASE_RUNTIME_DIR:=/tmp/firebase-emulator}"
: "${PUBSUB_CONFIG:=/etc/firebase/pubsub.yaml}"
: "${PUBSUB_PUSH_BASE_URL:=http://localhost:8080}"

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
METADATA_FILE=firebase-export-metadata.json
LOCAL_DATA_DIR="${FIREBASE_RUNTIME_DIR}/data"
# Exists once the emulator holds data that should be saved on shutdown.
SAVE_MARKER="${FIREBASE_RUNTIME_DIR}/save"
# Exists once post-start configuration (Pub/Sub) has completed; read by
# healthcheck.sh.
READY_MARKER="${FIREBASE_RUNTIME_DIR}/ready"
# Exists if post-start configuration failed.
FAILED_MARKER="${FIREBASE_RUNTIME_DIR}/failed"

log() {
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] firebase-emulator: $*"
}

die() {
    log "ERROR: $*" >&2
    exit 1
}

is_true() {
    case "${1,,}" in
    true | 1 | yes) return 0 ;;
    *) return 1 ;;
    esac
}

# Copies an emulator export (metadata file + *_export directories) from $1 to
# $2. The metadata file is copied last, so an interrupted copy leaves the
# previous metadata in place.
copy_export() {
    local src=$1 dst=$2 entry
    mkdir -p "${dst}"
    for entry in "${src}"/*_export; do
        [ -d "${entry}" ] || continue
        cp -R "${entry}" "${dst}/"
    done
    cp "${src}/${METADATA_FILE}" "${dst}/${METADATA_FILE}"
}

has_emulator() {
    [[ ",${FIREBASE_EMULATORS}," == *",$1,"* ]]
}

# Port of emulator $1 from the effective config, falling back to the
# firebase-tools default.
emulator_port() {
    local default
    case "$1" in
    auth) default=9099 ;;
    pubsub) default=8085 ;;
    firestore) default=8080 ;;
    database) default=9000 ;;
    storage) default=9199 ;;
    functions) default=5001 ;;
    hosting) default=5000 ;;
    eventarc) default=9299 ;;
    tasks) default=9499 ;;
    *) default= ;;
    esac
    jq -r --arg e "$1" --arg d "${default}" '.emulators[$e].port // $d' "${CONFIG_FILE}"
}

# --- Effective firebase.json -------------------------------------------------

rm -rf "${FIREBASE_RUNTIME_DIR}"
mkdir -p "${FIREBASE_RUNTIME_DIR}" "${LOCAL_DATA_DIR}"

if [ -n "${FIREBASE_CONFIG_FILE}" ]; then
    [ -f "${FIREBASE_CONFIG_FILE}" ] || die "FIREBASE_CONFIG_FILE=${FIREBASE_CONFIG_FILE} does not exist"
    CONFIG_FILE=${FIREBASE_CONFIG_FILE}
    if [ -z "${FIREBASE_EMULATORS}" ]; then
        FIREBASE_EMULATORS=$(jq -r '.emulators // {} | keys - ["ui", "hub", "logging", "singleProjectMode"] | join(",")' "${CONFIG_FILE}")
    fi
    [ -n "${FIREBASE_EMULATORS}" ] || die "No emulators configured in ${CONFIG_FILE}"
    log "Using firebase config ${CONFIG_FILE}"
else
    : "${FIREBASE_EMULATORS:=auth,pubsub}"
    FIREBASE_EMULATORS=${FIREBASE_EMULATORS// /}
    CONFIG_FILE="${FIREBASE_RUNTIME_DIR}/firebase.json"
    config=$(jq -n \
        --arg ui_enabled "${FIREBASE_UI_ENABLED,,}" \
        --argjson ui_port "${FIREBASE_UI_PORT}" \
        --argjson hub_port "${FIREBASE_HUB_PORT}" \
        --argjson logging_port "${FIREBASE_LOGGING_PORT}" \
        '{emulators: {
            singleProjectMode: true,
            ui: {enabled: ($ui_enabled == "true"), host: "0.0.0.0", port: $ui_port},
            hub: {host: "0.0.0.0", port: $hub_port},
            logging: {host: "0.0.0.0", port: $logging_port}
        }}')
    IFS=, read -r -a emulators <<<"${FIREBASE_EMULATORS}"
    for emulator in "${emulators[@]}"; do
        case "${emulator}" in
        auth) port=${FIREBASE_AUTH_PORT} ;;
        pubsub) port=${FIREBASE_PUBSUB_PORT} ;;
        firestore) port=${FIREBASE_FIRESTORE_PORT} ;;
        database) port=${FIREBASE_DATABASE_PORT} ;;
        *) die "Unsupported emulator '${emulator}' in FIREBASE_EMULATORS (supported: auth, pubsub, firestore, database; mount your own firebase.json via FIREBASE_CONFIG_FILE for others)" ;;
        esac
        config=$(jq --arg e "${emulator}" --argjson p "${port}" \
            '.emulators[$e] = {host: "0.0.0.0", port: $p}' <<<"${config}")
    done
    printf '%s\n' "${config}" >"${CONFIG_FILE}"
    log "Generated ${CONFIG_FILE}"
fi

FIREBASE_EMULATORS=${FIREBASE_EMULATORS// /}

# Ports of the started emulators, one "name port" per line; read by
# healthcheck.sh.
IFS=, read -r -a emulators <<<"${FIREBASE_EMULATORS}"
for emulator in "${emulators[@]}"; do
    port=$(emulator_port "${emulator}")
    [ -n "${port}" ] && printf '%s %s\n' "${emulator}" "${port}"
done >"${FIREBASE_RUNTIME_DIR}/ports"

# --- Import ------------------------------------------------------------------

WAIT_FOR_SEED=false
IMPORT_ARGS=()
EXPORT_ARGS=()
if is_true "${FIREBASE_PERSIST}"; then
    EXPORT_ARGS=(--export-on-exit="${LOCAL_DATA_DIR}")
    mkdir -p "${FIREBASE_DATA_DIR}"
fi

if is_true "${FIREBASE_PERSIST}" && [ -f "${FIREBASE_DATA_DIR}/${METADATA_FILE}" ]; then
    log "Importing emulator data from ${FIREBASE_DATA_DIR}"
    copy_export "${FIREBASE_DATA_DIR}" "${LOCAL_DATA_DIR}"
    IMPORT_ARGS=(--import="${LOCAL_DATA_DIR}")
    touch "${SAVE_MARKER}"
elif [ -n "${FIREBASE_SEED_DIR}" ] && [ -f "${FIREBASE_SEED_DIR}/${METADATA_FILE}" ]; then
    log "Importing seed data from ${FIREBASE_SEED_DIR}"
    copy_export "${FIREBASE_SEED_DIR}" "${LOCAL_DATA_DIR}"
    IMPORT_ARGS=(--import="${LOCAL_DATA_DIR}")
    touch "${SAVE_MARKER}"
elif [ -n "${FIREBASE_SEED_DIR}" ]; then
    log "No emulator data found, starting empty until ${FIREBASE_SEED_DIR} is seeded"
    WAIT_FOR_SEED=true
else
    log "No emulator data found, starting empty"
    touch "${SAVE_MARKER}"
fi

# --- Start -------------------------------------------------------------------

log "Starting emulators: ${FIREBASE_EMULATORS} (project ${FIREBASE_PROJECT})"
# The emulators write their *-debug.log files to the working directory.
cd "${FIREBASE_RUNTIME_DIR}"
firebase emulators:start \
    --only="${FIREBASE_EMULATORS}" \
    --config="${CONFIG_FILE}" \
    --project="${FIREBASE_PROJECT}" \
    --non-interactive \
    "${IMPORT_ARGS[@]}" \
    "${EXPORT_ARGS[@]}" &
FIREBASE_PID=$!

# shellcheck disable=SC2317,SC2329 # Invoked by trap.
shutdown() {
    log "Received shutdown signal, stopping emulators"
    kill -INT "${FIREBASE_PID}" 2>/dev/null || true
}
trap shutdown TERM INT

# Post-start configuration. A failure stops the container, rather than
# leaving it running with missing topics or subscriptions.
(
    if has_emulator pubsub && [ -f "${PUBSUB_CONFIG}" ]; then
        if PUBSUB_EMULATOR_HOST="localhost:$(emulator_port pubsub)" \
            PUBSUB_PROJECT_ID="${FIREBASE_PROJECT}" \
            PUBSUB_CONFIG="${PUBSUB_CONFIG}" \
            PUBSUB_PUSH_BASE_URL="${PUBSUB_PUSH_BASE_URL}" \
            "${SCRIPT_DIR}/scripts/configure_pubsub.sh"; then
            touch "${READY_MARKER}"
        else
            log "ERROR: Pub/Sub configuration from ${PUBSUB_CONFIG} failed, stopping" >&2
            touch "${FAILED_MARKER}"
            kill -TERM $$
        fi
    else
        if has_emulator pubsub; then
            log "No Pub/Sub config at ${PUBSUB_CONFIG}, skipping topic setup"
        fi
        touch "${READY_MARKER}"
    fi
) &

if [ "${WAIT_FOR_SEED}" = true ]; then
    (
        until [ -f "${FIREBASE_SEED_DIR}/${METADATA_FILE}" ]; do
            sleep "${FIREBASE_SEED_POLL_INTERVAL}"
        done
        accounts="${FIREBASE_SEED_DIR}/auth_export/accounts.json"
        if ! has_emulator auth || [ ! -f "${accounts}" ]; then
            log "Seed found in ${FIREBASE_SEED_DIR}, but it has no auth accounts to import (late import covers auth only)"
            touch "${SAVE_MARKER}"
            exit 0
        fi
        auth_port=$(emulator_port auth)
        until curl -s -o /dev/null "http://localhost:${auth_port}/"; do sleep 1; done
        log "Importing seeded auth accounts from ${FIREBASE_SEED_DIR}"
        # Same request the emulator makes to import accounts.json on startup.
        if curl -sSf -o /dev/null -X POST \
            -H "Authorization: Bearer owner" \
            -H "Content-Type: application/json" \
            --data-binary "@${accounts}" \
            "http://localhost:${auth_port}/identitytoolkit.googleapis.com/v1/projects/${FIREBASE_PROJECT}/accounts:batchCreate"; then
            touch "${SAVE_MARKER}"
            log "Imported seeded auth accounts"
        else
            log "ERROR: Failed to import seeded auth accounts" >&2
        fi
    ) &
fi

# `wait` returns early when a trapped signal arrives, so keep waiting until
# the emulator process has actually exited.
set +e
while :; do
    wait "${FIREBASE_PID}"
    EXIT_CODE=$?
    if ! kill -0 "${FIREBASE_PID}" 2>/dev/null; then
        # If the last wait was interrupted, this one returns the real status;
        # if it already returned it, this one fails with 127.
        wait "${FIREBASE_PID}" 2>/dev/null
        rc=$?
        [ "${rc}" -ne 127 ] && EXIT_CODE=${rc}
        break
    fi
done
set -e
log "Emulators exited with code ${EXIT_CODE}"

# --- Save --------------------------------------------------------------------

if ! is_true "${FIREBASE_PERSIST}"; then
    :
elif [ ! -f "${SAVE_MARKER}" ]; then
    log "Not saving emulator data, since the seed was never imported"
elif [ -f "${LOCAL_DATA_DIR}/${METADATA_FILE}" ]; then
    log "Saving emulator data to ${FIREBASE_DATA_DIR}"
    copy_export "${LOCAL_DATA_DIR}" "${FIREBASE_DATA_DIR}"
    log "Saved emulator data"
else
    log "No emulator data was exported"
fi

if [ -f "${FAILED_MARKER}" ] && [ "${EXIT_CODE}" -eq 0 ]; then
    EXIT_CODE=1
fi
exit "${EXIT_CODE}"
