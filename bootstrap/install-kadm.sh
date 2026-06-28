#!/usr/bin/env bash
set -euo pipefail

info() {
  echo "$*"
}

die() {
  echo "error: $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

action="${1:-all}"
if [[ $# -gt 0 ]]; then
  shift
fi

case "${action}" in
  prepare|deploy|all)
    ;;
  *)
    die "usage: install-kadm.sh <prepare|deploy|all> [--cluster <name>] [--access-host <ssh-target>] [--private-ip <ip>] [--api-port <port>] [--console-port <port>] [--k3s-version <version>] [--dns-upstream <ip>]..."
    ;;
esac

bootstrap_root="${KADM_BOOTSTRAP_ROOT:-/opt/kadm}"
github_owner="${KADM_GITHUB_OWNER:-ccq18}"
system_repo="${KADM_SYSTEM_REPO:-kadm-platform-system}"
system_ref="${KADM_SYSTEM_REF:-main}"
release_console_repo="${KADM_RELEASE_CONSOLE_REPO:-kadm-release-console}"
release_console_ref="${KADM_RELEASE_CONSOLE_REF:-main}"
app_configs_repo="${KADM_APP_CONFIGS_REPO:-kadm-app-configs}"
app_configs_ref="${KADM_APP_CONFIGS_REF:-main}"
assets_repo="${KADM_PLATFORM_ASSETS_REPO:-kadm-platform-assets}"
asset_bundle_url="${KADM_ASSET_BUNDLE_URL:-https://github.com/${github_owner}/${assets_repo}/releases/download/bundle-latest/kadm-platform-assets.tgz}"
workspace_root="${bootstrap_root}/workspace"
download_root="${bootstrap_root}/downloads"
local_bin_dir="${KADM_LOCAL_BIN_DIR:-/usr/local/bin}"
cluster_name="${KADM_CLUSTER_NAME:-default}"
access_host="${KADM_ACCESS_HOST:-}"
private_ip="${KADM_PRIVATE_IP:-}"
api_port="${KADM_API_PORT:-16443}"
console_port="${KADM_CONSOLE_PORT:-18080}"
k3s_version="${KADM_K3S_VERSION:-}"
dns_upstreams=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cluster|--name)
      cluster_name="${2:-}"
      shift 2
      ;;
    --access-host)
      access_host="${2:-}"
      shift 2
      ;;
    --private-ip)
      private_ip="${2:-}"
      shift 2
      ;;
    --api-port)
      api_port="${2:-}"
      shift 2
      ;;
    --console-port)
      console_port="${2:-}"
      shift 2
      ;;
    --k3s-version)
      k3s_version="${2:-}"
      shift 2
      ;;
    --dns-upstream)
      dns_upstreams+=("${2:-}")
      shift 2
      ;;
    --help|-h)
      die "usage: install-kadm.sh <prepare|deploy|all> [--cluster <name>] [--access-host <ssh-target>] [--private-ip <ip>] [--api-port <port>] [--console-port <port>] [--k3s-version <version>] [--dns-upstream <ip>]..."
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
done

system_dir="${workspace_root}/${system_repo}"
release_console_dir="${workspace_root}/${release_console_repo}"
app_configs_dir="${workspace_root}/${app_configs_repo}"
bundle_path="${download_root}/kadm-platform-assets.tgz"

github_url_uses_token() {
  local url="$1"
  [[ "${url}" == https://api.github.com/* || "${url}" == https://github.com/* || "${url}" == https://raw.githubusercontent.com/* ]]
}

curl_supports_retry_all_errors() {
  curl --help all 2>/dev/null | grep -q -- "--retry-all-errors"
}

download_url() {
  local url="$1"
  local output="$2"
  local tmp="${output}.tmp"
  local curl_args=(
    --http1.1
    -fsSL
    --retry 5
    --retry-delay 3
    --connect-timeout 30
    --max-time 1800
  )

  if curl_supports_retry_all_errors; then
    curl_args+=(--retry-all-errors)
  fi

  if [[ -n "${KADM_GITHUB_TOKEN:-}" ]] && github_url_uses_token "${url}"; then
    curl_args+=(
      -H "Authorization: Bearer ${KADM_GITHUB_TOKEN}"
      -H "X-GitHub-Api-Version: 2022-11-28"
    )
  fi

  mkdir -p "$(dirname "${output}")"
  curl "${curl_args[@]}" "${url}" -o "${tmp}"
  mv "${tmp}" "${output}"
}

download_repo_archive() {
  local repo="$1"
  local ref="$2"
  local target_dir="$3"
  local archive tmp_extract extracted_dir resolved_sha

  resolved_sha="$(resolve_repo_ref_sha "${repo}" "${ref}")"

  archive="$(mktemp)"
  tmp_extract="$(mktemp -d)"
  download_url "https://api.github.com/repos/${github_owner}/${repo}/tarball/${resolved_sha}" "${archive}"
  tar -xzf "${archive}" -C "${tmp_extract}"
  extracted_dir="$(find "${tmp_extract}" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
  [[ -n "${extracted_dir}" ]] || die "failed to extract ${repo}@${ref}"

  rm -rf "${target_dir}"
  mkdir -p "$(dirname "${target_dir}")"
  mv "${extracted_dir}" "${target_dir}"
  rm -rf "${tmp_extract}" "${archive}"
}

resolve_repo_ref_sha() {
  local repo="$1"
  local ref="$2"
  local response sha curl_args
  curl_args=(
    --http1.1
    -fsSL
    --retry 5
    --retry-delay 3
    --connect-timeout 30
    --max-time 120
  )

  if curl_supports_retry_all_errors; then
    curl_args+=(--retry-all-errors)
  fi

  if [[ -n "${KADM_GITHUB_TOKEN:-}" ]]; then
    curl_args+=(
      -H "Authorization: Bearer ${KADM_GITHUB_TOKEN}"
      -H "X-GitHub-Api-Version: 2022-11-28"
    )
  fi

  response="$(curl "${curl_args[@]}" "https://api.github.com/repos/${github_owner}/${repo}/commits/${ref}")"
  sha="$(printf '%s\n' "${response}" | sed -n 's/^[[:space:]]*"sha":[[:space:]]*"\([0-9a-f]\{40\}\)".*/\1/p' | head -n 1)"
  [[ -n "${sha}" ]] || die "failed to resolve ${repo}@${ref} to a commit sha"
  printf '%s\n' "${sha}"
}

bundle_extract_entry_to_file() {
  local bundle="$1"
  local path="$2"
  local output="$3"

  if tar -xOf "${bundle}" "${path}" > "${output}" 2>/dev/null; then
    return 0
  fi
  tar -xOf "${bundle}" "./${path}" > "${output}" 2>/dev/null
}

bundle_declares_complete() {
  local bundle="$1"
  local metadata_file
  metadata_file="$(mktemp)"
  if ! bundle_extract_entry_to_file "${bundle}" "metadata/offline-bundle.env" "${metadata_file}"; then
    rm -f "${metadata_file}"
    return 1
  fi
  local result
  if grep -Fxq "KADM_OFFLINE_COMPLETE=true" "${metadata_file}"; then
    result=0
  else
    result=1
  fi
  rm -f "${metadata_file}"
  return "${result}"
}

restore_repo_archive_from_bundle() {
  local bundle="$1"
  local repo="$2"
  local target_dir="$3"
  local archive tmp_extract extracted_dir

  archive="$(mktemp)"
  if ! bundle_extract_entry_to_file "${bundle}" "cache/repos/${repo}.tgz" "${archive}"; then
    rm -f "${archive}"
    return 1
  fi
  tmp_extract="$(mktemp -d)"
  tar -xzf "${archive}" -C "${tmp_extract}"
  extracted_dir="$(find "${tmp_extract}" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
  [[ -n "${extracted_dir}" ]] || die "failed to extract bundled ${repo}"

  rm -rf "${target_dir}"
  mkdir -p "$(dirname "${target_dir}")"
  mv "${extracted_dir}" "${target_dir}"
  rm -rf "${tmp_extract}" "${archive}"
}

restore_workspace_from_bundle() {
  local bundle="$1"
  require_command tar
  require_command find

  restore_repo_archive_from_bundle "${bundle}" "${system_repo}" "${system_dir}" || return 1
  restore_repo_archive_from_bundle "${bundle}" "${release_console_repo}" "${release_console_dir}" || return 1
  restore_repo_archive_from_bundle "${bundle}" "${app_configs_repo}" "${app_configs_dir}" || return 1
  info "Restored workspace repositories from offline asset bundle"
}

ensure_workspace() {
  require_command curl
  require_command tar
  require_command find

  mkdir -p "${workspace_root}" "${download_root}"

  info "Downloading ${system_repo}@${system_ref}"
  download_repo_archive "${system_repo}" "${system_ref}" "${system_dir}"
  info "Downloading ${release_console_repo}@${release_console_ref}"
  download_repo_archive "${release_console_repo}" "${release_console_ref}" "${release_console_dir}"
  info "Downloading ${app_configs_repo}@${app_configs_ref}"
  download_repo_archive "${app_configs_repo}" "${app_configs_ref}" "${app_configs_dir}"
}

install_local_kadmctl() {
  require_command ln
  mkdir -p "${local_bin_dir}"
  ln -sf "${system_dir}/bin/kadmctl" "${local_bin_dir}/kadmctl"
}

prepare_phase() {
  info "Downloading offline asset bundle"
  download_url "${asset_bundle_url}" "${bundle_path}"

  if ! restore_workspace_from_bundle "${bundle_path}"; then
    if bundle_declares_complete "${bundle_path}"; then
      die "complete offline bundle is missing cache/repos workspace archives"
    fi
    ensure_workspace
  fi

  info "Importing offline asset bundle"
  "${system_dir}/bin/kadmctl" import-assets "${bundle_path}"

  info "Installing local operator tools"
  "${system_dir}/bin/kadmctl" install-tools --apply

  install_local_kadmctl
  info "prepare completed"
}

deploy_phase() {
  [[ -x "${system_dir}/bin/kadmctl" ]] || die "missing ${system_dir}/bin/kadmctl; run prepare first"
  [[ -d "${release_console_dir}/k8s/overlays/prod" ]] || die "missing release console overlay at ${release_console_dir}/k8s/overlays/prod"
  [[ -f "${app_configs_dir}/apps/apps.json" ]] || die "missing app configs at ${app_configs_dir}/apps/apps.json"
  [[ -n "${access_host}" ]] || die "deploy requires --access-host <ssh-target>"
  [[ -n "${KADM_GITHUB_TOKEN:-}" ]] || die "deploy requires KADM_GITHUB_TOKEN in the environment"

  local deploy_args=(
    --name "${cluster_name}"
    --access-host "${access_host}"
    --api-port "${api_port}"
    --console-port "${console_port}"
    --apply
  )

  if [[ -n "${private_ip}" ]]; then
    deploy_args+=(--private-ip "${private_ip}")
  fi
  if [[ -n "${k3s_version}" ]]; then
    deploy_args+=(--k3s-version "${k3s_version}")
  fi
  if [[ "${#dns_upstreams[@]}" -gt 0 ]]; then
    local upstream
    for upstream in "${dns_upstreams[@]}"; do
      deploy_args+=(--dns-upstream "${upstream}")
    done
  fi

  info "Deploying local K3s control plane and platform components"
  "${system_dir}/bin/kadmctl" deploy "${deploy_args[@]}"

  info "Configuring release console and GitOps repositories"
  KADM_GITHUB_TOKEN="${KADM_GITHUB_TOKEN}" \
    KADM_ARGOCD_TOKEN="${KADM_ARGOCD_TOKEN:-}" \
    KADM_GHCR_USERNAME="${KADM_GHCR_USERNAME:-}" \
    KADM_GHCR_TOKEN="${KADM_GHCR_TOKEN:-}" \
    "${system_dir}/bin/kadmctl" configure-delivery "${cluster_name}" \
      --onecd-overlay "${release_console_dir}/k8s/overlays/prod" \
      --app-configs-dir "${app_configs_dir}" \
      --apply

  info "deploy completed"
}

case "${action}" in
  prepare)
    prepare_phase
    ;;
  deploy)
    deploy_phase
    ;;
  all)
    prepare_phase
    deploy_phase
    ;;
esac
