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

github_owner="${KADM_GITHUB_OWNER:-ccq18}"
system_repo="${KADM_SYSTEM_REPO:-kadm-platform-system}"
system_release_tag="${KADM_SYSTEM_RELEASE_TAG:-system-latest}"
system_package_name="${KADM_SYSTEM_PACKAGE_NAME:-${system_repo}.tgz}"
system_package_url="${KADM_SYSTEM_PACKAGE_URL:-https://github.com/${github_owner}/${system_repo}/releases/download/${system_release_tag}/${system_package_name}}"
workspace_root="${KADM_CLIENT_WORKSPACE_ROOT:-${HOME}/.kadm/workspace}"
system_dir="${workspace_root}/${system_repo}"
client_bin_dir="${KADM_CLIENT_BIN_DIR:-${HOME}/.local/bin}"
cluster_name="${KADM_CLUSTER_NAME:-default}"
server_ssh="${KADM_SERVER_SSH:-}"
api_port="${KADM_API_PORT:-16443}"
console_port="${KADM_CONSOLE_PORT:-18080}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cluster|--name)
      cluster_name="${2:-}"
      shift 2
      ;;
    --server|--access-host)
      server_ssh="${2:-}"
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
    --help|-h)
      die "usage: install-kadm-client.sh --cluster <name> --server <ssh-target> [--api-port <port>] [--console-port <port>]"
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
done

[[ -n "${server_ssh}" ]] || die "install-kadm-client.sh requires --server <ssh-target>"

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
    --max-time 600
  )

  if [[ -n "${KADM_GITHUB_TOKEN:-}" ]]; then
    curl_args+=(
      -H "Authorization: Bearer ${KADM_GITHUB_TOKEN}"
      -H "X-GitHub-Api-Version: 2022-11-28"
    )
  fi

  mkdir -p "$(dirname "${output}")"
  curl "${curl_args[@]}" "${url}" -o "${tmp}"
  mv "${tmp}" "${output}"
}

extract_archive_to_dir() {
  local archive="$1"
  local target_dir="$2"
  local tmp_extract extracted_dir

  require_command tar
  require_command find

  tmp_extract="$(mktemp -d)"
  tar -xzf "${archive}" -C "${tmp_extract}"
  extracted_dir="$(find "${tmp_extract}" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
  [[ -n "${extracted_dir}" ]] || die "failed to extract ${archive}"

  rm -rf "${target_dir}"
  mkdir -p "$(dirname "${target_dir}")"
  mv "${extracted_dir}" "${target_dir}"
  rm -rf "${tmp_extract}" "${archive}"
}

install_system_package() {
  local archive
  archive="$(mktemp)"

  require_command curl
  require_command tar
  require_command find

  download_url "${system_package_url}" "${archive}"
  extract_archive_to_dir "${archive}" "${system_dir}"
}

install_local_kadmctl() {
  mkdir -p "${client_bin_dir}"
  ln -sf "${system_dir}/bin/kadmctl" "${client_bin_dir}/kadmctl"
  info "kadmctl installed at ${client_bin_dir}/kadmctl"
}

rewrite_profile_kubeconfig_path() {
  local profile_path="$1"
  local kubeconfig_path="$2"
  local tmp
  tmp="$(mktemp)"
  sed -E "s#^KUBECONFIG_PATH=.*#KUBECONFIG_PATH=${kubeconfig_path}#" "${profile_path}" > "${tmp}"
  cat "${tmp}" > "${profile_path}"
  rm -f "${tmp}"
}

rewrite_profile_port() {
  local profile_path="$1"
  local key="$2"
  local value="$3"
  local tmp
  tmp="$(mktemp)"
  sed -E "s#^${key}=.*#${key}=${value}#" "${profile_path}" > "${tmp}"
  cat "${tmp}" > "${profile_path}"
  rm -f "${tmp}"
}

rewrite_kubeconfig() {
  local source_file="$1"
  local target_file="$2"
  local port="$3"
  mkdir -p "$(dirname "${target_file}")"
  sed -E "s#server: https://[^[:space:]]+#server: https://127.0.0.1:${port}#" "${source_file}" > "${target_file}"
  chmod 600 "${target_file}"
}

fetch_cluster_state() {
  local profile_path="$1"
  local kubeconfig_path="$2"
  local remote_profile="/root/.kadm/clusters/${cluster_name}/cluster.env"
  local tmp_kubeconfig
  tmp_kubeconfig="$(mktemp)"

  require_command ssh
  ssh "${server_ssh}" "sudo cat ${remote_profile}" > "${profile_path}"
  ssh "${server_ssh}" "sudo cat /etc/rancher/k3s/k3s.yaml" > "${tmp_kubeconfig}"

  rewrite_profile_kubeconfig_path "${profile_path}" "${kubeconfig_path}"
  rewrite_profile_port "${profile_path}" "API_LOCAL_PORT" "${api_port}"
  rewrite_profile_port "${profile_path}" "CONSOLE_LOCAL_PORT" "${console_port}"
  rewrite_kubeconfig "${tmp_kubeconfig}" "${kubeconfig_path}" "${api_port}"
  rm -f "${tmp_kubeconfig}"
}

main() {
  local profile_dir="${HOME}/.kadm/clusters/${cluster_name}"
  local kubeconfig_path="${HOME}/.kube/kadm/${cluster_name}.yaml"
  local profile_path="${profile_dir}/cluster.env"

  install_system_package
  install_local_kadmctl

  mkdir -p "${profile_dir}" "$(dirname "${kubeconfig_path}")"
  fetch_cluster_state "${profile_path}" "${kubeconfig_path}"

  info "cluster profile written: ${profile_path}"
  info "local kubeconfig written: ${kubeconfig_path}"
  info "next: ${client_bin_dir}/kadmctl connect ${cluster_name}"
}

main
