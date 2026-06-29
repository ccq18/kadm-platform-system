#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_NAME="$(basename "${ROOT_DIR}")"
REPO_PARENT="$(dirname "${ROOT_DIR}")"

DIST_DIR="${KADM_SYSTEM_DIST_DIR:-${ROOT_DIR}/dist}"
PACKAGE_NAME="${KADM_SYSTEM_PACKAGE_NAME:-kadm-platform-system.tgz}"

mkdir -p "${DIST_DIR}"
rm -f "${DIST_DIR}/${PACKAGE_NAME}"

tar \
  --exclude "${REPO_NAME}/.git" \
  --exclude "${REPO_NAME}/console/node_modules" \
  --exclude "${REPO_NAME}/dist" \
  --exclude "${REPO_NAME}/output" \
  -czf "${DIST_DIR}/${PACKAGE_NAME}" \
  -C "${REPO_PARENT}" \
  "${REPO_NAME}"

chmod 600 "${DIST_DIR}/${PACKAGE_NAME}"
echo "system package written: ${DIST_DIR}/${PACKAGE_NAME}"
