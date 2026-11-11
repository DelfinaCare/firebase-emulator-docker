#!/bin/bash
# Exits 0 once every started emulator answers HTTP on its port and post-start
# configuration (Pub/Sub topics and subscriptions) has completed.
set -euo pipefail

: "${FIREBASE_RUNTIME_DIR:=/tmp/firebase-emulator}"

if [ ! -f "${FIREBASE_RUNTIME_DIR}/ready" ]; then
    echo "not ready: post-start configuration has not completed"
    exit 1
fi

while read -r emulator port; do
    if ! curl -s -o /dev/null --max-time 2 "http://127.0.0.1:${port}/"; then
        echo "not ready: ${emulator} is not answering on port ${port}"
        exit 1
    fi
done <"${FIREBASE_RUNTIME_DIR}/ports"

echo "ok"
