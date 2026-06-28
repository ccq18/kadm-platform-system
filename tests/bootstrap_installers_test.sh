#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SERVER_INSTALLER="${ROOT_DIR}/bootstrap/install-kadm.sh"
CLIENT_INSTALLER="${ROOT_DIR}/bootstrap/install-kadm-client.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  [[ "${haystack}" == *"${needle}"* ]] || fail "expected output to contain: ${needle}"
}

assert_file_contains() {
  local file="$1"
  local needle="$2"
  [[ -f "${file}" ]] || fail "missing file ${file}"
  grep -Fq -- "${needle}" "${file}" || {
    echo "Expected ${file} to contain ${needle}" >&2
    echo "--- ${file}" >&2
    cat "${file}" >&2
    exit 1
  }
}

make_repo_archive() {
  local archive="$1"
  local repo_name="$2"
  local calls_file="$3"
  local tmp
  tmp="$(mktemp -d)"
  mkdir -p "${tmp}/${repo_name}/bin" "${tmp}/${repo_name}/apps"

  if [[ "${repo_name}" == "kadm-platform-system" ]]; then
    mkdir -p "${tmp}/${repo_name}/console/k8s/overlays/prod"
    cat > "${tmp}/${repo_name}/bin/kadmctl" <<STUB
#!/usr/bin/env bash
set -euo pipefail
printf 'kadmctl %s\n' "\$*" >> "${calls_file}"
STUB
    chmod +x "${tmp}/${repo_name}/bin/kadmctl"
    printf 'resources: []\n' > "${tmp}/${repo_name}/console/k8s/overlays/prod/kustomization.yaml"
  fi

  if [[ "${repo_name}" == "kadm-app-configs" ]]; then
    printf '[]\n' > "${tmp}/${repo_name}/apps/apps.json"
  fi

  tar -czf "${archive}" -C "${tmp}" "${repo_name}"
  rm -rf "${tmp}"
}

test_server_prepare_downloads_workspace_and_imports_assets() {
  local tmp_home tmp_root tmp_bin calls_file archives_dir bundle_file
  tmp_home="$(mktemp -d)"
  tmp_root="$(mktemp -d)"
  tmp_bin="$(mktemp -d)"
  calls_file="${tmp_root}/calls.log"
  archives_dir="${tmp_root}/archives"
  bundle_file="${archives_dir}/kadm-platform-assets.tgz"
  mkdir -p "${archives_dir}"

  make_repo_archive "${archives_dir}/kadm-platform-system.tgz" "kadm-platform-system" "${calls_file}"
  make_repo_archive "${archives_dir}/kadm-app-configs.tgz" "kadm-app-configs" "${calls_file}"
  printf 'bundle\n' > "${bundle_file}"

  cat > "${tmp_bin}/curl" <<STUB
#!/usr/bin/env bash
set -euo pipefail
output=""
url=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    -o)
      output="\${2:-}"
      shift 2
      ;;
    *)
      url="\$1"
      shift
      ;;
  esac
done
case "\${url}" in
  *"/commits/"*)
    printf '{\n  "sha": "1111111111111111111111111111111111111111"\n}\n'
    ;;
  *"/kadm-platform-system/"*)
    cp "${archives_dir}/kadm-platform-system.tgz" "\${output}"
    ;;
  *"/kadm-app-configs/"*)
    cp "${archives_dir}/kadm-app-configs.tgz" "\${output}"
    ;;
  *"kadm-platform-assets.tgz"*)
    cp "${bundle_file}" "\${output}"
    ;;
  *)
    exit 1
    ;;
esac
STUB
  chmod +x "${tmp_bin}/curl"

  HOME="${tmp_home}" \
    KADM_BOOTSTRAP_ROOT="${tmp_root}/bootstrap" \
    KADM_LOCAL_BIN_DIR="${tmp_root}/bin" \
    KADM_ASSET_BUNDLE_URL="https://example.invalid/kadm-platform-assets.tgz" \
    PATH="${tmp_bin}:${PATH}" \
    bash "${SERVER_INSTALLER}" prepare

  assert_file_contains "${calls_file}" "kadmctl import-assets ${tmp_root}/bootstrap/downloads/kadm-platform-assets.tgz"
  assert_file_contains "${calls_file}" "kadmctl install-tools --apply"
  [[ -L "${tmp_root}/bin/kadmctl" ]] || fail "prepare did not install kadmctl symlink"
}

test_server_prepare_restores_workspace_from_offline_bundle_repos() {
  local tmp_home tmp_root tmp_bin calls_file archives_dir bundle_dir bundle_file
  tmp_home="$(mktemp -d)"
  tmp_root="$(mktemp -d)"
  tmp_bin="$(mktemp -d)"
  calls_file="${tmp_root}/calls.log"
  archives_dir="${tmp_root}/archives"
  bundle_dir="${tmp_root}/bundle"
  bundle_file="${archives_dir}/kadm-platform-assets.tgz"
  mkdir -p "${archives_dir}" "${bundle_dir}/cache/repos" "${bundle_dir}/metadata"

  make_repo_archive "${bundle_dir}/cache/repos/kadm-platform-system.tgz" "kadm-platform-system" "${calls_file}"
  make_repo_archive "${bundle_dir}/cache/repos/kadm-app-configs.tgz" "kadm-app-configs" "${calls_file}"
  cat > "${bundle_dir}/metadata/offline-bundle.env" <<'ENV'
KADM_OFFLINE_BUNDLE_FORMAT=2
KADM_OFFLINE_COMPLETE=true
ENV
  tar -czf "${bundle_file}" -C "${bundle_dir}" cache metadata

  cat > "${tmp_bin}/curl" <<STUB
#!/usr/bin/env bash
set -euo pipefail
printf 'curl %s\n' "\$*" >> "${calls_file}"
output=""
url=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    -o)
      output="\${2:-}"
      shift 2
      ;;
    *)
      url="\$1"
      shift
      ;;
  esac
done
case "\${url}" in
  *"kadm-platform-assets.tgz"*)
    cp "${bundle_file}" "\${output}"
    ;;
  *)
    exit 1
    ;;
esac
STUB
  chmod +x "${tmp_bin}/curl"

  HOME="${tmp_home}" \
    KADM_BOOTSTRAP_ROOT="${tmp_root}/bootstrap" \
    KADM_LOCAL_BIN_DIR="${tmp_root}/bin" \
    KADM_ASSET_BUNDLE_URL="https://example.invalid/kadm-platform-assets.tgz" \
    PATH="${tmp_bin}:${PATH}" \
    bash "${SERVER_INSTALLER}" prepare

  assert_file_contains "${calls_file}" "kadmctl import-assets ${tmp_root}/bootstrap/downloads/kadm-platform-assets.tgz"
  assert_file_contains "${calls_file}" "kadmctl install-tools --apply"
  [[ -x "${tmp_root}/bootstrap/workspace/kadm-platform-system/bin/kadmctl" ]] || fail "prepare did not restore system repo"
  [[ -f "${tmp_root}/bootstrap/workspace/kadm-platform-system/console/k8s/overlays/prod/kustomization.yaml" ]] || fail "prepare did not restore release console from system repo"
  [[ -f "${tmp_root}/bootstrap/workspace/kadm-app-configs/apps/apps.json" ]] || fail "prepare did not restore app configs repo"
  if grep -Fq "api.github.com" "${calls_file}"; then
    fail "prepare downloaded GitHub repos despite bundled repo archives"
  fi
}

test_server_deploy_calls_local_deploy_and_configure_delivery() {
  local tmp_home tmp_root calls_file system_dir release_dir app_dir
  tmp_home="$(mktemp -d)"
  tmp_root="$(mktemp -d)"
  calls_file="${tmp_root}/calls.log"
  system_dir="${tmp_root}/bootstrap/workspace/kadm-platform-system"
  release_dir="${system_dir}/console"
  app_dir="${tmp_root}/bootstrap/workspace/kadm-app-configs"

  mkdir -p "${system_dir}/bin" "${release_dir}/k8s/overlays/prod" "${app_dir}/apps"
  cat > "${system_dir}/bin/kadmctl" <<STUB
#!/usr/bin/env bash
set -euo pipefail
printf 'kadmctl %s\n' "\$*" >> "${calls_file}"
STUB
  chmod +x "${system_dir}/bin/kadmctl"
  printf 'resources: []\n' > "${release_dir}/k8s/overlays/prod/kustomization.yaml"
  printf '[]\n' > "${app_dir}/apps/apps.json"

  HOME="${tmp_home}" \
    KADM_BOOTSTRAP_ROOT="${tmp_root}/bootstrap" \
    KADM_GITHUB_TOKEN="test-token" \
    bash "${SERVER_INSTALLER}" deploy \
      --cluster home-prod \
      --access-host root@203.0.113.11 \
      --private-ip 10.0.0.11 \
      --dns-upstream 1.1.1.1

  assert_file_contains "${calls_file}" "kadmctl deploy --name home-prod --access-host root@203.0.113.11 --api-port 16443 --console-port 18080 --apply --private-ip 10.0.0.11 --dns-upstream 1.1.1.1"
  assert_file_contains "${calls_file}" "kadmctl configure-delivery home-prod --onecd-overlay ${release_dir}/k8s/overlays/prod --app-configs-dir ${app_dir} --apply"
}

test_client_installer_fetches_profile_and_kubeconfig() {
  local tmp_home tmp_root tmp_bin calls_file archives_dir
  tmp_home="$(mktemp -d)"
  tmp_root="$(mktemp -d)"
  tmp_bin="$(mktemp -d)"
  calls_file="${tmp_root}/calls.log"
  archives_dir="${tmp_root}/archives"
  mkdir -p "${archives_dir}"

  make_repo_archive "${archives_dir}/kadm-platform-system.tgz" "kadm-platform-system" "${calls_file}"

  cat > "${tmp_bin}/curl" <<STUB
#!/usr/bin/env bash
set -euo pipefail
output=""
url=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    -o)
      output="\${2:-}"
      shift 2
      ;;
    *)
      url="\$1"
      shift
      ;;
  esac
done
case "\${url}" in
  *"/commits/"*)
    printf '{\n  "sha": "1111111111111111111111111111111111111111"\n}\n'
    ;;
  *"/kadm-platform-system/"*)
    cp "${archives_dir}/kadm-platform-system.tgz" "\${output}"
    ;;
  *)
    exit 1
    ;;
esac
STUB
  cat > "${tmp_bin}/ssh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == *"/root/.kadm/clusters/home-prod/cluster.env"* ]]; then
  cat <<'PROFILE'
CLUSTER_NAME=home-prod
MASTER_SSH=root@203.0.113.11
MASTER_PRIVATE_IP=10.0.0.11
KUBECONFIG_PATH=/root/.kube/kadm/home-prod.yaml
API_LOCAL_PORT=16443
CONSOLE_LOCAL_PORT=18080
K3S_JOIN_SERVER_URL=https://10.0.0.11:6443
K3S_JOIN_TOKEN=k10token
PROFILE
  exit 0
fi
if [[ "$*" == *"/etc/rancher/k3s/k3s.yaml"* ]]; then
  cat <<'KUBECONFIG'
apiVersion: v1
clusters:
- cluster:
    certificate-authority-data: TEST
    server: https://127.0.0.1:6443
  name: default
contexts:
- context:
    cluster: default
    user: default
  name: default
current-context: default
kind: Config
preferences: {}
users:
- name: default
  user:
    client-certificate-data: TEST
    client-key-data: TEST
KUBECONFIG
  exit 0
fi
exit 1
STUB
  chmod +x "${tmp_bin}/curl" "${tmp_bin}/ssh"

  HOME="${tmp_home}" \
    KADM_CLIENT_WORKSPACE_ROOT="${tmp_home}/workspace" \
    KADM_CLIENT_BIN_DIR="${tmp_home}/bin" \
    PATH="${tmp_bin}:${PATH}" \
    bash "${CLIENT_INSTALLER}" --cluster home-prod --server root@203.0.113.11

  [[ -L "${tmp_home}/bin/kadmctl" ]] || fail "client installer did not install kadmctl symlink"
  assert_file_contains "${tmp_home}/.kadm/clusters/home-prod/cluster.env" "KUBECONFIG_PATH=${tmp_home}/.kube/kadm/home-prod.yaml"
  assert_file_contains "${tmp_home}/.kadm/clusters/home-prod/cluster.env" "API_LOCAL_PORT=16443"
  assert_file_contains "${tmp_home}/.kube/kadm/home-prod.yaml" "server: https://127.0.0.1:16443"
}

test_server_prepare_downloads_workspace_and_imports_assets
test_server_prepare_restores_workspace_from_offline_bundle_repos
test_server_deploy_calls_local_deploy_and_configure_delivery
test_client_installer_fetches_profile_and_kubeconfig

echo "bootstrap installer tests passed"
