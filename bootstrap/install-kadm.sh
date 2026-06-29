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
    die "usage: install-kadm.sh <prepare|deploy|all> [--cluster <name>] [--access-host <ssh-target>] [--private-ip <ip>] [--api-port <port>] [--console-port <port>] [--k3s-version <version>] [--dns-upstream <ip>]... [--ingress-mode <gateway|traefik>]"
    ;;
esac

bootstrap_root="${KADM_BOOTSTRAP_ROOT:-/opt/kadm}"
github_owner="${KADM_GITHUB_OWNER:-ccq18}"
system_repo="${KADM_SYSTEM_REPO:-kadm-platform-system}"
system_release_tag="${KADM_SYSTEM_RELEASE_TAG:-system-latest}"
system_package_name="${KADM_SYSTEM_PACKAGE_NAME:-${system_repo}.tgz}"
system_package_url="${KADM_SYSTEM_PACKAGE_URL:-https://github.com/${github_owner}/${system_repo}/releases/download/${system_release_tag}/${system_package_name}}"
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
ingress_mode="${KADM_INGRESS_MODE:-gateway}"
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
    --ingress-mode)
      ingress_mode="${2:-}"
      shift 2
      ;;
    --help|-h)
      die "usage: install-kadm.sh <prepare|deploy|all> [--cluster <name>] [--access-host <ssh-target>] [--private-ip <ip>] [--api-port <port>] [--console-port <port>] [--k3s-version <version>] [--dns-upstream <ip>]... [--ingress-mode <gateway|traefik>]"
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
done

system_dir="${workspace_root}/${system_repo}"
release_console_dir="${system_dir}/console"
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
  local archive resolved_sha

  resolved_sha="$(resolve_repo_ref_sha "${repo}" "${ref}")"
  archive="$(mktemp)"
  download_url "https://api.github.com/repos/${github_owner}/${repo}/tarball/${resolved_sha}" "${archive}"
  extract_archive_to_dir "${archive}" "${target_dir}"
  rm -f "${archive}"
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

extract_archive_to_dir() {
  local archive="$1"
  local target_dir="$2"
  local tmp_extract extracted_dir
  tmp_extract="$(mktemp -d)"
  tar -xzf "${archive}" -C "${tmp_extract}"
  extracted_dir="$(find "${tmp_extract}" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
  [[ -n "${extracted_dir}" ]] || die "failed to extract ${archive}"

  rm -rf "${target_dir}"
  mkdir -p "$(dirname "${target_dir}")"
  mv "${extracted_dir}" "${target_dir}"
  rm -rf "${tmp_extract}"
}

download_system_package() {
  require_command tar
  require_command find
  require_command curl

  mkdir -p "${workspace_root}" "${download_root}"
  info "Downloading ${system_repo} package"
  download_url "${system_package_url}" "${download_root}/${system_package_name}"
  extract_archive_to_dir "${download_root}/${system_package_name}" "${system_dir}"
}

ensure_app_configs_workspace() {
  if [[ -f "${app_configs_dir}/apps/apps.json" ]]; then
    return 0
  fi

  require_command tar
  require_command find
  require_command curl
  mkdir -p "${workspace_root}" "${download_root}"
  info "Downloading ${app_configs_repo}@${app_configs_ref}"
  download_repo_archive "${app_configs_repo}" "${app_configs_ref}" "${app_configs_dir}"
}

resolve_release_console_dir() {
  if [[ -d "${release_console_dir}/k8s/overlays/prod" ]]; then
    printf '%s\n' "${release_console_dir}"
    return 0
  fi
  return 1
}

install_local_kadmctl() {
  require_command ln
  mkdir -p "${local_bin_dir}"
  ln -sf "${system_dir}/bin/kadmctl" "${local_bin_dir}/kadmctl"
}

prepare_phase() {
  info "Downloading offline asset bundle"
  download_url "${asset_bundle_url}" "${bundle_path}"
  download_system_package

  info "Importing offline asset bundle"
  "${system_dir}/bin/kadmctl" import-assets "${bundle_path}"

  info "Installing local operator tools"
  "${system_dir}/bin/kadmctl" install-tools --apply

  install_local_kadmctl
  info "prepare completed"
}

deploy_phase() {
  [[ -x "${system_dir}/bin/kadmctl" ]] || die "missing ${system_dir}/bin/kadmctl; run prepare first"
  local active_release_console_dir
  active_release_console_dir="$(resolve_release_console_dir)" || die "missing release console overlay at ${release_console_dir}/k8s/overlays/prod"
  [[ -n "${access_host}" ]] || die "deploy requires --access-host <ssh-target>"
  [[ -n "${KADM_GITHUB_TOKEN:-}" ]] || die "deploy requires KADM_GITHUB_TOKEN in the environment"
  case "${ingress_mode}" in
    gateway|traefik) ;;
    *) die "--ingress-mode must be gateway or traefik" ;;
  esac

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

  ensure_app_configs_workspace
  [[ -f "${app_configs_dir}/apps/apps.json" ]] || die "missing app configs at ${app_configs_dir}/apps/apps.json"
  info "Configuring release console and GitOps repositories"
  KADM_GITHUB_TOKEN="${KADM_GITHUB_TOKEN}" \
    KADM_ARGOCD_TOKEN="${KADM_ARGOCD_TOKEN:-}" \
    KADM_GHCR_USERNAME="${KADM_GHCR_USERNAME:-}" \
    KADM_GHCR_TOKEN="${KADM_GHCR_TOKEN:-}" \
    "${system_dir}/bin/kadmctl" configure-delivery "${cluster_name}" \
      --onecd-overlay "${active_release_console_dir}/k8s/overlays/prod" \
      --app-configs-dir "${app_configs_dir}" \
      --ingress-mode "${ingress_mode}" \
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
