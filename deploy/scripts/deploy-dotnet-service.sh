#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat >&2 <<USAGE
Usage: deploy-dotnet-service.sh --node NODE --archive ARCHIVE --sha256 SHA256 --release-id RELEASE_ID --service-name SERVICE_NAME --app-dll APP_DLL --base-dir BASE_DIR --health-mode http|h2c|none --health-path PATH --service-env-file FILE --required-files-file FILE --source-repository REPO --source-ref REF --source-sha SHA
USAGE
  exit 2
}

NODE=""
ARCHIVE=""
EXPECTED_SHA=""
RELEASE_ID=""
SERVICE_NAME=""
APP_DLL=""
BASE_DIR=""
HEALTH_MODE="none"
HEALTH_PATH="/healthz"
SERVICE_ENV_FILE=""
REQUIRED_FILES_FILE=""
SOURCE_REPOSITORY=""
SOURCE_REF=""
SOURCE_SHA=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --node) NODE="$2"; shift 2 ;;
    --archive) ARCHIVE="$2"; shift 2 ;;
    --sha256) EXPECTED_SHA="$2"; shift 2 ;;
    --release-id) RELEASE_ID="$2"; shift 2 ;;
    --service-name) SERVICE_NAME="$2"; shift 2 ;;
    --app-dll) APP_DLL="$2"; shift 2 ;;
    --base-dir) BASE_DIR="$2"; shift 2 ;;
    --health-mode) HEALTH_MODE="$2"; shift 2 ;;
    --health-path) HEALTH_PATH="$2"; shift 2 ;;
    --service-env-file) SERVICE_ENV_FILE="$2"; shift 2 ;;
    --required-files-file) REQUIRED_FILES_FILE="$2"; shift 2 ;;
    --source-repository) SOURCE_REPOSITORY="$2"; shift 2 ;;
    --source-ref) SOURCE_REF="$2"; shift 2 ;;
    --source-sha) SOURCE_SHA="$2"; shift 2 ;;
    *) usage ;;
  esac
done

for value in NODE ARCHIVE EXPECTED_SHA RELEASE_ID SERVICE_NAME APP_DLL BASE_DIR SERVICE_ENV_FILE REQUIRED_FILES_FILE SOURCE_REPOSITORY SOURCE_REF SOURCE_SHA; do
  [[ -n "${!value}" ]] || usage
done

case "$NODE" in api-1|api-2|api-3) ;; *) echo "FAIL: invalid node: $NODE" >&2; exit 1 ;; esac
case "$HEALTH_MODE" in http|h2c|none) ;; *) echo "FAIL: invalid health mode: $HEALTH_MODE" >&2; exit 1 ;; esac

test -f "$ARCHIVE"
test -f "$SERVICE_ENV_FILE"
test -f "$REQUIRED_FILES_FILE"

SSH_OPTIONS=(-o BatchMode=yes -o StrictHostKeyChecking=yes)
REMOTE_ARCHIVE="/tmp/${SERVICE_NAME}-${RELEASE_ID}.tgz"
REMOTE_UNIT="/tmp/${SERVICE_NAME}.service"
UNIT_FILE="$(mktemp)"
cleanup() { rm -f "$UNIT_FILE"; }
trap cleanup EXIT

{
  echo "[Unit]"
  echo "Description=XanhNow ${SERVICE_NAME}"
  echo "After=network-online.target"
  echo "Wants=network-online.target"
  echo
  echo "[Service]"
  echo "Type=simple"
  echo "User=xanhnow"
  echo "Group=xanhnow"
  echo "WorkingDirectory=${BASE_DIR}/current"
  echo "ExecStart=/usr/bin/dotnet ${BASE_DIR}/current/${APP_DLL}"
  echo "Restart=always"
  echo "RestartSec=5"
  echo "KillSignal=SIGINT"
  echo "SyslogIdentifier=${SERVICE_NAME}"
  echo "Environment=DOTNET_ENVIRONMENT=Production"
  echo "Environment=ASPNETCORE_ENVIRONMENT=Production"
  grep -v '^[[:space:]]*$' "$SERVICE_ENV_FILE"
  echo
  echo "[Install]"
  echo "WantedBy=multi-user.target"
} > "$UNIT_FILE"

scp "${SSH_OPTIONS[@]}" "$ARCHIVE" "${NODE}:${REMOTE_ARCHIVE}"
scp "${SSH_OPTIONS[@]}" "$UNIT_FILE" "${NODE}:${REMOTE_UNIT}"
REMOTE_REQUIRED_B64="$(base64 -w0 "$REQUIRED_FILES_FILE")"

ssh "${SSH_OPTIONS[@]}" "$NODE" bash -s -- "$NODE" "$REMOTE_ARCHIVE" "$REMOTE_UNIT" "$EXPECTED_SHA" "$RELEASE_ID" "$SERVICE_NAME" "$APP_DLL" "$BASE_DIR" "$HEALTH_MODE" "$HEALTH_PATH" "$SOURCE_REPOSITORY" "$SOURCE_REF" "$SOURCE_SHA" "$REMOTE_REQUIRED_B64" <<'REMOTE'
set -Eeuo pipefail

NODE="$1"
REMOTE_ARCHIVE="$2"
REMOTE_UNIT="$3"
EXPECTED_SHA="$4"
RELEASE_ID="$5"
SERVICE_NAME="$6"
APP_DLL="$7"
BASE_DIR="$8"
HEALTH_MODE="$9"
HEALTH_PATH="${10}"
SOURCE_REPOSITORY="${11}"
SOURCE_REF="${12}"
SOURCE_SHA="${13}"
REMOTE_REQUIRED_B64="${14}"

fail() { echo "FAIL: $*" >&2; exit 1; }
HOST="$(hostname -s)"
[[ "$HOST" = "$NODE" ]] || fail "expected host $NODE; got $HOST"

test -f "$REMOTE_ARCHIVE" || fail "missing uploaded archive"
test -f "$REMOTE_UNIT" || fail "missing uploaded systemd unit"

REQUIRED_FILE_LIST="$(mktemp)"
cleanup() { rm -f "$REQUIRED_FILE_LIST" "$REMOTE_ARCHIVE" "$REMOTE_UNIT"; }
trap cleanup EXIT
printf '%s' "$REMOTE_REQUIRED_B64" | base64 -d > "$REQUIRED_FILE_LIST"
while IFS= read -r required_file; do
  [[ -z "$required_file" ]] && continue
  [[ -s "$required_file" ]] || fail "missing required runtime file: $required_file"
done < "$REQUIRED_FILE_LIST"

ACTUAL_SHA="$(sha256sum "$REMOTE_ARCHIVE" | awk '{print $1}')"
[[ "$ACTUAL_SHA" = "$EXPECTED_SHA" ]] || fail "artifact checksum mismatch"

RELEASE_DIR="${BASE_DIR}/releases/${RELEASE_ID}"
CURRENT_LINK="${BASE_DIR}/current"
PREVIOUS_TARGET=""
if [[ -L "$CURRENT_LINK" ]]; then PREVIOUS_TARGET="$(readlink -f "$CURRENT_LINK")"; fi
if [[ -e "$CURRENT_LINK" && ! -L "$CURRENT_LINK" ]]; then
  if [[ -d "$CURRENT_LINK" && -z "$(find "$CURRENT_LINK" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
    rmdir "$CURRENT_LINK"
  else
    fail "current path exists but is not a symlink or empty directory: $CURRENT_LINK"
  fi
fi

install -d -m 0755 "$BASE_DIR" "${BASE_DIR}/releases"
rm -rf "$RELEASE_DIR"
install -d -m 0750 "$RELEASE_DIR"
tar -xzf "$REMOTE_ARCHIVE" -C "$RELEASE_DIR"
test -f "${RELEASE_DIR}/${APP_DLL}" || fail "missing published DLL: $APP_DLL"

cat > "${RELEASE_DIR}/release.json" <<EOF
{
  "service_name": "${SERVICE_NAME}",
  "release_id": "${RELEASE_ID}",
  "source_repository": "${SOURCE_REPOSITORY}",
  "source_ref": "${SOURCE_REF}",
  "source_sha": "${SOURCE_SHA}",
  "artifact_sha256": "${EXPECTED_SHA}",
  "deployed_node": "${HOST}"
}
EOF
chmod 0640 "${RELEASE_DIR}/release.json"

ln -sfn "releases/${RELEASE_ID}" "${BASE_DIR}/current.next"
mv -Tf "${BASE_DIR}/current.next" "$CURRENT_LINK"

sudo mv "$REMOTE_UNIT" "/etc/systemd/system/${SERVICE_NAME}.service"
sudo chmod 0644 "/etc/systemd/system/${SERVICE_NAME}.service"
sudo systemctl daemon-reload
sudo systemctl enable "${SERVICE_NAME}.service" >/dev/null

READY=0
if sudo systemctl restart "${SERVICE_NAME}.service"; then
  case "$HEALTH_MODE" in
    http)
      for _ in $(seq 1 30); do
        if curl --noproxy '*' --fail --silent --show-error --connect-timeout 2 --max-time 5 "http://127.0.0.1${HEALTH_PATH}" >/dev/null; then READY=1; break; fi
        sleep 1
      done
      ;;
    h2c)
      for _ in $(seq 1 30); do
        if curl --noproxy '*' --http2-prior-knowledge --fail --silent --show-error --connect-timeout 2 --max-time 5 "http://127.0.0.1${HEALTH_PATH}" >/dev/null; then READY=1; break; fi
        sleep 1
      done
      ;;
    none)
      for _ in $(seq 1 20); do
        if sudo systemctl is-active --quiet "${SERVICE_NAME}.service"; then READY=1; break; fi
        sleep 1
      done
      ;;
  esac
fi

if [[ "$READY" -ne 1 ]]; then
  echo "FAIL: service did not pass readiness: ${SERVICE_NAME}" >&2
  sudo systemctl status "${SERVICE_NAME}.service" --no-pager || true
  if [[ -n "$PREVIOUS_TARGET" && -d "$PREVIOUS_TARGET" ]]; then
    ln -sfn "$PREVIOUS_TARGET" "${BASE_DIR}/current.rollback"
    mv -Tf "${BASE_DIR}/current.rollback" "$CURRENT_LINK"
    sudo systemctl restart "${SERVICE_NAME}.service" || true
  fi
  exit 1
fi

echo "DEPLOY_SERVICE=PASS | node=${HOST} | service=${SERVICE_NAME} | release=${RELEASE_ID} | source=${SOURCE_SHA}"
REMOTE
