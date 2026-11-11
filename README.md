# firebase-emulator-docker

A Docker image that runs the [Firebase Local Emulator Suite](https://firebase.google.com/docs/emulator-suite)
(auth and Pub/Sub by default; Firestore and Realtime Database optional), configured entirely by
environment variables and mounted files. It is meant for:

- local development, as a service next to your app in Docker Compose or a VS Code devcontainer;
- preview environments on Cloud Run, as a sidecar container, so a service under test talks to the
  auth emulator instead of real Firebase Auth.

Image: `ghcr.io/OWNER/firebase-emulator-docker` (replace `OWNER` with the GitHub owner of the
repository the image is published from).

> The emulators are insecure by design: no real authentication, no access control on the admin
> APIs, all data readable and writable by anyone who can reach the ports. Never put production data
> in them or expose them to untrusted networks.

## Quick start

```sh
docker run --rm -p 4000:4000 -p 4500:4500 -p 9099:9099 -p 8085:8085 \
  ghcr.io/OWNER/firebase-emulator-docker
```

Then open the Emulator UI at http://localhost:4000. Publish the emulator ports on the same port
numbers on the host: the UI runs in your browser and connects to them directly.

From a clone of this repository, `docker compose up --build` does the same, with a named volume for
persistence and the example Pub/Sub config.

## Configuration

| Variable | Default | Description |
| --- | --- | --- |
| `FIREBASE_PROJECT` | `demo-project` | Project ID. See [Project ID](#project-id). |
| `FIREBASE_EMULATORS` | `auth,pubsub` | Comma-separated emulators to start. Supported in the generated config: `auth`, `pubsub`, `firestore`, `database`. With `FIREBASE_CONFIG_FILE`, defaults to every emulator in that file. |
| `FIREBASE_AUTH_PORT` | `9099` | Auth emulator port. |
| `FIREBASE_PUBSUB_PORT` | `8085` | Pub/Sub emulator port. |
| `FIREBASE_FIRESTORE_PORT` | `8080` | Firestore emulator port. **Collides with an app listening on 8080 in the same network namespace**, for example the ingress container of a Cloud Run service. Change it if you enable Firestore there. |
| `FIREBASE_DATABASE_PORT` | `9000` | Realtime Database emulator port. |
| `FIREBASE_UI_ENABLED` | `true` | Run the Emulator UI. |
| `FIREBASE_UI_PORT` | `4000` | Emulator UI port. |
| `FIREBASE_HUB_PORT` | `4400` | Emulator hub port. |
| `FIREBASE_LOGGING_PORT` | `4500` | Logging port, used by the UI's log viewer. |
| `FIREBASE_CONFIG_FILE` | unset | Path to your own `firebase.json`. Used as is: the `FIREBASE_*_PORT` and `FIREBASE_UI_ENABLED` variables are ignored, and ports are read from the file. Bind emulators to `0.0.0.0` in it if other containers need to reach them. |
| `FIREBASE_DATA_DIR` | `/data` | Where emulator data is imported from on startup and exported to on shutdown. |
| `FIREBASE_PERSIST` | `true` | Set to `false` to neither import from nor export to `FIREBASE_DATA_DIR`. |
| `FIREBASE_SEED_DIR` | unset | Emulator export used when `FIREBASE_DATA_DIR` holds no data. See [Seeding](#seeding). |
| `FIREBASE_SEED_POLL_INTERVAL` | `5` | Seconds between checks for a seed that is not there yet. |
| `PUBSUB_CONFIG` | `/etc/firebase/pubsub.yaml` | Topics and subscriptions to create. Skipped if the file does not exist. |
| `PUBSUB_PUSH_BASE_URL` | `http://localhost:8080` | Base URL that `pushPath` values are joined to. |
| `FIREBASE_RUNTIME_DIR` | `/tmp/firebase-emulator` | Scratch directory for the generated config, the working copy of the data and the emulator logs. Emptied on start. |

Unless `FIREBASE_CONFIG_FILE` is set, `firebase.json` is generated at startup with every emulator bound
to `0.0.0.0`, so other containers can reach them.

### Project ID

Use a project ID that starts with `demo-`. For such projects the emulators never contact real
Google services or need credentials, and any attempt by your app to use a service that is not
emulated fails instead of reaching a real project. Configure your app with the same project ID.

### Pub/Sub

Mount a YAML or JSON file at `PUBSUB_CONFIG`:

```yaml
topics:
  - name: orders
    subscriptions:
      - name: orders-worker          # no push fields: pull subscription
      - name: orders-push
        pushPath: /pubsub/orders     # joined to PUBSUB_PUSH_BASE_URL
      - name: orders-abs
        pushEndpoint: http://other:9000/hook   # absolute, wins over pushPath
        ackDeadlineSeconds: 30       # other fields are passed through to the subscription
```

`PUBSUB_PUSH_BASE_URL` lets the same file work in Compose (`http://app:8080`) and on Cloud Run
(`http://localhost:8080`). Topics and subscriptions that already exist are left alone. If the
emulator rejects a request, the error is logged and the container stops with exit code 1, rather
than running with missing subscriptions.

The Pub/Sub emulator does not persist anything; topics and subscriptions are recreated on every
start.

`scripts/configure_pubsub.sh` can also be run on its own against any Pub/Sub emulator; see the
comment at its top for its environment variables.

### Persistence

If `FIREBASE_DATA_DIR` contains `firebase-export-metadata.json`, the data is imported on startup. On
SIGTERM or SIGINT the emulators export their data and the export is copied back to
`FIREBASE_DATA_DIR`. The emulators work from a copy in `FIREBASE_RUNTIME_DIR`, because
`FIREBASE_DATA_DIR` is often a Cloud Storage FUSE mount, which lacks the atomic directory rename
the export relies on.

Data is only saved on a clean shutdown. If the container is killed (SIGKILL, out of memory), changes
since the last start are lost.

### Seeding

Set `FIREBASE_SEED_DIR` to the directory of an emulator export (as written by
`firebase emulators:export`) to start from it when `FIREBASE_DATA_DIR` holds no data yet. Saved
data always takes precedence over the seed.

- If the seed is present at startup, it is imported with `--import` (all emulators).
- If it is not present yet, for example because another job is still generating it, the emulators
  start empty and the directory is polled. When the seed appears, its auth accounts
  (`auth_export/accounts.json`) are imported through the auth emulator's REST API. **Late import
  covers auth accounts only**; restart the container to import other data.
- Until a late seed has been imported, nothing is saved on shutdown, so an empty export cannot
  hide the seed from the next start.

### Health check

The image's `HEALTHCHECK` passes once every started emulator answers HTTP on its port and the
Pub/Sub topics and subscriptions have been created. Use it with
`depends_on: condition: service_healthy` in Compose.

### Build arguments

`PRELOAD_EMULATORS` (default `pubsub ui`) lists the emulator binaries downloaded at build time. Add
`firestore`, `database` or `storage` if you use them; otherwise they are downloaded on first start,
which needs network access and is repeated for every new container. The auth emulator needs no
download.

```sh
docker build --build-arg PRELOAD_EMULATORS="pubsub ui firestore" -t firebase-emulator .
```

## Devcontainer

[`examples/devcontainer/.devcontainer`](examples/devcontainer/.devcontainer) has a
`devcontainer.json`, a `docker-compose.yml` with an `app` service (your development container) and a
`firebase` service, and an example `pubsub.yaml`. Copy the directory into your repository and
replace the `app` image. In it:

- the app reaches the emulators at `firebase:9099` and `firebase:8085`
  (`FIREBASE_AUTH_EMULATOR_HOST`, `PUBSUB_EMULATOR_HOST`);
- push subscriptions deliver to `http://app:8080`;
- emulator data persists in the `firebase-data` named volume;
- the UI (4000) and auth (9099) ports are forwarded to your machine.

## Cloud Run sidecar

[`examples/cloud-run/service.yaml`](examples/cloud-run/service.yaml) defines a service with your app
as the ingress container and the emulators as a sidecar:

- the app starts after the emulators' startup probe (HTTP on the auth port) passes
  (`run.googleapis.com/container-dependencies`);
- the app reaches the emulators on `localhost`, and push subscriptions deliver to
  `http://localhost:8080`;
- emulator data is kept in a Cloud Storage bucket mounted at `/data`, one directory per service;
- the Pub/Sub config comes from a Secret Manager secret mounted at `/etc/firebase`.

```sh
# One-off: an Artifact Registry remote repository that proxies ghcr.io.
gcloud artifacts repositories create ghcr \
  --project PROJECT_ID --location REGION \
  --repository-format docker --mode remote-repository \
  --remote-docker-repo https://ghcr.io

# One-off: the Pub/Sub config.
gcloud secrets create firebase-pubsub-config --data-file pubsub.yaml

# Per preview environment, after replacing the placeholders in service.yaml.
gcloud run services replace service.yaml --project PROJECT_ID --region REGION
```

The service account the service runs as needs read and write access to the bucket and access to
the secret. Instead of the secret you can build a small image `FROM` this one that copies your
`pubsub.yaml` to `/etc/firebase/pubsub.yaml`.

## Gotchas

1. **Cloud Run cannot pull images from ghcr.io.** Use an Artifact Registry remote repository with
   `https://ghcr.io` as upstream (above), or copy the image into Artifact Registry. A remote
   repository can only pull a private ghcr.io package if you give it credentials; making the
   package public avoids that.
2. **Sidecar ports are not publicly reachable.** Only the ingress container's port is exposed. Code
   running in the app container can use the emulators on `localhost`, but a browser client calling
   `connectAuthEmulator` cannot reach them. Either have the app reverse-proxy the auth emulator's
   paths (such as `/identitytoolkit.googleapis.com/`, `/securetoken.googleapis.com/` and
   `/emulator/`) to `localhost:9099` and point `connectAuthEmulator` at the app's own URL, or keep
   authentication server-side.
3. **Shutdown has a deadline.** Cloud Run sends SIGTERM and kills the instance about 10 seconds
   later; `docker stop` also waits 10 seconds by default. The export and the copy to
   `FIREBASE_DATA_DIR` must finish in that window, which limits how much data can be persisted.
   State is in memory per instance, so keep `maxScale` at 1: a second instance would have its own,
   diverging data, and the last one to shut down would overwrite the others' export.
4. **The emulators are insecure by design.** Never use them for production data.

## Development

```sh
shellcheck entrypoint.sh scripts/*.sh test/*.sh
docker build -t firebase-emulator:test .
test/smoke.sh firebase-emulator:test
```

`firebase-tools` is pinned in `package.json` and `package-lock.json`; Dependabot keeps it, the base
images and the GitHub Actions up to date. CI publishes multi-arch images (`linux/amd64`,
`linux/arm64`) to `ghcr.io/<repository>` from `main` (`latest`) and from `v*` tags.

## License

MIT; see [LICENSE](LICENSE).
