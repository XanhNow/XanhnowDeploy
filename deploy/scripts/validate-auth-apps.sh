#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/auth-app-catalog.sh"

test "$(hostname -s)" = "hungangu"
dotnet --list-sdks | grep -Eq '^10\.'

APPS="$(resolve_apps)"
SOURCE_REF="${SOURCE_REF:-main}"

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
    dotnet restore "${SOURCE_DIR}/${PROJECT_FILE}"
    dotnet build "${SOURCE_DIR}/${PROJECT_FILE}" --configuration Release --no-restore
    rm -rf "$PUBLISH_DIR"
    dotnet publish "${SOURCE_DIR}/${PROJECT_FILE}" --configuration Release --no-build --output "$PUBLISH_DIR"
    test -f "${PUBLISH_DIR}/${APP_DLL}"

    echo "VALIDATE_COMPONENT=PASS | app=${APP} | component=${COMPONENT} | source=${SOURCE_SHA}"
  done
done

echo "VALIDATE_AUTH_APPS=PASS | apps=${APPS} | source_ref=${SOURCE_REF}"
