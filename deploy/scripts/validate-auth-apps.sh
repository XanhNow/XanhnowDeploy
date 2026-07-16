#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/auth-app-catalog.sh"

test "$(hostname -s)" = "hungangu"
dotnet --list-sdks | grep -Eq '^10\.'

APPS="$(resolve_apps)"
SOURCE_REF="${SOURCE_REF:-main}"

dotnet_restore_with_retry() {
  local project_file="$1"

  for attempt in 1 2 3 4; do
    echo "DOTNET_RESTORE_ATTEMPT=${attempt} | project=${project_file}"

    if dotnet restore "$project_file" --disable-parallel; then
      return 0
    fi

    dotnet nuget locals http-cache --clear || true
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
    PUBLISH_DIR="${RUNNER_TEMP:-/tmp}/publish-${COMPONENT}"

    test -f "${SOURCE_DIR}/${PROJECT_FILE}"
    dotnet_restore_with_retry "${SOURCE_DIR}/${PROJECT_FILE}"
    dotnet build "${SOURCE_DIR}/${PROJECT_FILE}" --configuration Release --no-restore
    rm -rf "$PUBLISH_DIR"
    dotnet publish "${SOURCE_DIR}/${PROJECT_FILE}" --configuration Release --no-build --output "$PUBLISH_DIR"
    test -f "${PUBLISH_DIR}/${APP_DLL}"

    echo "VALIDATE_COMPONENT=PASS | app=${APP} | component=${COMPONENT} | source=${SOURCE_SHA}"
  done
done

echo "VALIDATE_AUTH_APPS=PASS | apps=${APPS} | source_ref=${SOURCE_REF}"
