#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/auth-app-catalog.sh"

test "$(hostname -s)" = "hungangu"
dotnet --list-sdks | grep -Eq '^10\.'

export NUGET_PACKAGES="${NUGET_PACKAGES:-/home/gha-runner/.nuget/packages}"
mkdir -p "$NUGET_PACKAGES"

APPS="$(resolve_apps)"
NODES="$(resolve_nodes)"
SOURCE_REF="${SOURCE_REF:-main}"

dotnet_restore_with_retry() {
  local project_file="$1"

  for attempt in 1 2 3 4; do
    echo "DOTNET_RESTORE_ATTEMPT=${attempt} | project=${project_file}"

    if dotnet restore "$project_file" --disable-parallel; then
      return 0
    fi

    sleep $((attempt * 10))
  done

  echo "FAIL: dotnet restore failed after retries: ${project_file}" >&2
  return 1
}

for APP in $APPS; do
  REPO="$(source_repo_for_app "$APP")"
  SOURCE_DIR="${RUNNER_TEMP:-/tmp}/source-${APP}"
  clone_source "$REPO" "$SOURCE_REF" "$SOURCE_DIR"
  SOURCE_SHA="$(git -C "$SOURCE_DIR" rev-parse --verify HEAD)"

  for COMPONENT in $(components_for_app "$APP"); do
    PROJECT_FILE="$(project_for_component "$COMPONENT")"
    APP_DLL="$(dll_for_component "$COMPONENT")"
    SERVICE_NAME="$(service_for_component "$COMPONENT")"
    BASE_DIR="$(base_dir_for_component "$COMPONENT")"
    HEALTH_MODE="$(health_mode_for_component "$COMPONENT")"
    HEALTH_PATH="$(health_path_for_component "$COMPONENT")"
    PUBLISH_DIR="${RUNNER_TEMP:-/tmp}/publish-${COMPONENT}"
    RELEASE_ID="${COMPONENT}-${SOURCE_SHA:0:12}-${GITHUB_RUN_ID:-manual}-${GITHUB_RUN_ATTEMPT:-1}"
    ARCHIVE="${RUNNER_TEMP:-/tmp}/${RELEASE_ID}.tgz"
    ENV_FILE="${RUNNER_TEMP:-/tmp}/${COMPONENT}.env"
    REQUIRED_FILE="${RUNNER_TEMP:-/tmp}/${COMPONENT}.required"

    test -f "${SOURCE_DIR}/${PROJECT_FILE}"
    dotnet_restore_with_retry "${SOURCE_DIR}/${PROJECT_FILE}"
    dotnet build "${SOURCE_DIR}/${PROJECT_FILE}" --configuration Release --no-restore
    rm -rf "$PUBLISH_DIR"
    dotnet publish "${SOURCE_DIR}/${PROJECT_FILE}" --configuration Release --no-build --output "$PUBLISH_DIR"
    test -f "${PUBLISH_DIR}/${APP_DLL}"

    tar --sort=name --owner=0 --group=0 --numeric-owner -C "$PUBLISH_DIR" -czf "$ARCHIVE" .
    test -s "$ARCHIVE"
    SHA256="$(sha256sum "$ARCHIVE" | awk '{print $1}')"
    write_component_runtime_contract "$COMPONENT" "$ENV_FILE" "$REQUIRED_FILE"

    for NODE in $NODES; do
      "${SCRIPT_DIR}/deploy-dotnet-service.sh" \
        --node "$NODE" \
        --archive "$ARCHIVE" \
        --sha256 "$SHA256" \
        --release-id "$RELEASE_ID" \
        --service-name "$SERVICE_NAME" \
        --app-dll "$APP_DLL" \
        --base-dir "$BASE_DIR" \
        --health-mode "$HEALTH_MODE" \
        --health-path "$HEALTH_PATH" \
        --service-env-file "$ENV_FILE" \
        --required-files-file "$REQUIRED_FILE" \
        --source-repository "$REPO" \
        --source-ref "$SOURCE_REF" \
        --source-sha "$SOURCE_SHA"
    done
  done
done

echo "DEPLOY_AUTH_APP=PASS | apps=${APPS} | nodes=${NODES} | source_ref=${SOURCE_REF}"
