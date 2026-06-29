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
  *"kadm-platform-system.tgz"*)
    cp "${archives_dir}/kadm-platform-system.tgz" "\${output}"
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
    KADM_SYSTEM_PACKAGE_URL="https://example.invalid/kadm-platform-system.tgz" \
    PATH="${tmp_bin}:${PATH}" \
    bash "${SERVER_INSTALLER}" prepare

  assert_file_contains "${calls_file}" "kadmctl import-assets ${tmp_root}/bootstrap/downloads/kadm-platform-assets.tgz"
  assert_file_contains "${calls_file}" "kadmctl install-tools --apply"
  [[ -L "${tmp_root}/bin/kadmctl" ]] || fail "prepare did not install kadmctl symlink"
}

test_server_prepare_succeeds_with_complete_base_bundle_without_repo_archives() {
  local tmp_home tmp_root tmp_bin calls_file archives_dir bundle_dir bundle_file
  tmp_home="$(mktemp -d)"
  tmp_root="$(mktemp -d)"
  tmp_bin="$(mktemp -d)"
  calls_file="${tmp_root}/calls.log"
  archives_dir="${tmp_root}/archives"
  bundle_dir="${tmp_root}/bundle"
  bundle_file="${archives_dir}/kadm-platform-assets.tgz"
  mkdir -p \
    "${archives_dir}" \
    "${bundle_dir}/cache/manifests" \
    "${bundle_dir}/cache/charts" \
    "${bundle_dir}/cache/k3s" \
    "${bundle_dir}/cache/tools" \
    "${bundle_dir}/cache/images" \
    "${bundle_dir}/metadata"

  make_repo_archive "${archives_dir}/kadm-platform-system.tgz" "kadm-platform-system" "${calls_file}"
  printf 'gateway\n' > "${bundle_dir}/cache/manifests/https___github.com_kubernetes-sigs_gateway-api_releases_download_v1.5.1_experimental-install.yaml.yaml"
  printf 'argocd\n' > "${bundle_dir}/cache/manifests/https___raw.githubusercontent.com_argoproj_argo-cd_v3.4.4_manifests_install.yaml.yaml"
  printf 'rollouts\n' > "${bundle_dir}/cache/manifests/https___github.com_argoproj_argo-rollouts_releases_download_v1.9.0_install.yaml.yaml"
  printf 'chart\n' > "${bundle_dir}/cache/charts/cilium-1.19.5.tgz"
  printf 'install\n' > "${bundle_dir}/cache/k3s/install-v1.36.2+k3s1.sh"
  printf 'binary\n' > "${bundle_dir}/cache/k3s/k3s-v1.36.2+k3s1"
  printf 'airgap\n' > "${bundle_dir}/cache/k3s/k3s-airgap-images-v1.36.2+k3s1-amd64.tar.zst"
  printf 'helm\n' > "${bundle_dir}/cache/tools/helm-v3.15.4-linux-amd64.tar.gz"
  printf 'image archive\n' > "${bundle_dir}/cache/images/runtime-images.tar.zst"
  printf 'quay.io/argoproj/argocd:v3.4.4\n' > "${bundle_dir}/cache/images/runtime-images.txt"
  printf 'checksum\n' > "${bundle_dir}/cache/images/runtime-images.sha256"
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
  *"kadm-platform-system.tgz"*)
    cp "${archives_dir}/kadm-platform-system.tgz" "\${output}"
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
    KADM_SYSTEM_PACKAGE_URL="https://example.invalid/kadm-platform-system.tgz" \
    PATH="${tmp_bin}:${PATH}" \
    bash "${SERVER_INSTALLER}" prepare

  assert_file_contains "${calls_file}" "kadmctl import-assets ${tmp_root}/bootstrap/downloads/kadm-platform-assets.tgz"
  assert_file_contains "${calls_file}" "kadmctl install-tools --apply"
  [[ -x "${tmp_root}/bootstrap/workspace/kadm-platform-system/bin/kadmctl" ]] || fail "prepare did not restore system package"
  [[ -f "${tmp_root}/bootstrap/workspace/kadm-platform-system/console/k8s/overlays/prod/kustomization.yaml" ]] || fail "prepare did not restore release console from system package"
  [[ ! -e "${tmp_root}/bootstrap/workspace/kadm-app-configs/apps/apps.json" ]] || fail "prepare unexpectedly restored app configs workspace"
}

test_server_deploy_calls_local_deploy_and_configure_delivery() {
  local tmp_home tmp_root tmp_bin calls_file system_dir release_dir app_dir
  tmp_home="$(mktemp -d)"
  tmp_root="$(mktemp -d)"
  tmp_bin="$(mktemp -d)"
  calls_file="${tmp_root}/calls.log"
  system_dir="${tmp_root}/bootstrap/workspace/kadm-platform-system"
  release_dir="${system_dir}/console"
  app_dir="${tmp_root}/bootstrap/workspace/kadm-app-configs"
  mkdir -p "${tmp_root}/archives"

  mkdir -p "${system_dir}/bin" "${release_dir}/k8s/overlays/prod"
  cat > "${system_dir}/bin/kadmctl" <<STUB
#!/usr/bin/env bash
set -euo pipefail
printf 'kadmctl %s\n' "\$*" >> "${calls_file}"
STUB
  chmod +x "${system_dir}/bin/kadmctl"
  printf 'resources: []\n' > "${release_dir}/k8s/overlays/prod/kustomization.yaml"
  make_repo_archive "${tmp_root}/archives/kadm-app-configs.tgz" "kadm-app-configs" "${calls_file}"
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
  *"/kadm-app-configs/"*)
    cp "${tmp_root}/archives/kadm-app-configs.tgz" "\${output}"
    ;;
  *)
    exit 1
    ;;
esac
STUB
  chmod +x "${tmp_bin}/curl"

  HOME="${tmp_home}" \
    KADM_BOOTSTRAP_ROOT="${tmp_root}/bootstrap" \
    KADM_GITHUB_TOKEN="test-token" \
    PATH="${tmp_bin}:${PATH}" \
    bash "${SERVER_INSTALLER}" deploy \
      --cluster home-prod \
      --access-host root@203.0.113.11 \
      --private-ip 10.0.0.11 \
      --dns-upstream 1.1.1.1

  assert_file_contains "${calls_file}" "kadmctl deploy --name home-prod --access-host root@203.0.113.11 --api-port 16443 --console-port 18080 --apply --private-ip 10.0.0.11 --dns-upstream 1.1.1.1"
  assert_file_contains "${calls_file}" "kadmctl configure-delivery home-prod --onecd-overlay ${release_dir}/k8s/overlays/prod --app-configs-dir ${app_dir} --ingress-mode gateway --apply"
  [[ -f "${app_dir}/apps/apps.json" ]] || fail "deploy did not download app configs workspace"
}

test_server_deploy_passes_traefik_ingress_mode_to_configure_delivery() {
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
      --ingress-mode traefik

  assert_file_contains "${calls_file}" "kadmctl configure-delivery home-prod --onecd-overlay ${release_dir}/k8s/overlays/prod --app-configs-dir ${app_dir} --ingress-mode traefik --apply"
}

test_server_deploy_rejects_invalid_ingress_mode() {
  local tmp_home tmp_root calls_file system_dir release_dir app_dir output status
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

  set +e
  output="$(HOME="${tmp_home}" KADM_BOOTSTRAP_ROOT="${tmp_root}/bootstrap" KADM_GITHUB_TOKEN="test-token" bash "${SERVER_INSTALLER}" deploy --cluster home-prod --access-host root@203.0.113.11 --ingress-mode invalid 2>&1)"
  status="$?"
  set -e

  [[ "${status}" -ne 0 ]] || fail "server installer accepted an invalid ingress mode"
  assert_contains "${output}" "--ingress-mode must be gateway or traefik"
  [[ ! -s "${calls_file}" ]] || fail "server installer called kadmctl after invalid ingress mode"
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
  *"kadm-platform-system.tgz"*)
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
    KADM_SYSTEM_PACKAGE_URL="https://example.invalid/kadm-platform-system.tgz" \
    PATH="${tmp_bin}:${PATH}" \
    bash "${CLIENT_INSTALLER}" --cluster home-prod --server root@203.0.113.11

  [[ -L "${tmp_home}/bin/kadmctl" ]] || fail "client installer did not install kadmctl symlink"
  assert_file_contains "${tmp_home}/.kadm/clusters/home-prod/cluster.env" "KUBECONFIG_PATH=${tmp_home}/.kube/kadm/home-prod.yaml"
  assert_file_contains "${tmp_home}/.kadm/clusters/home-prod/cluster.env" "API_LOCAL_PORT=16443"
  assert_file_contains "${tmp_home}/.kube/kadm/home-prod.yaml" "server: https://127.0.0.1:16443"
}

test_server_prepare_downloads_workspace_and_imports_assets
test_server_prepare_succeeds_with_complete_base_bundle_without_repo_archives
test_server_deploy_calls_local_deploy_and_configure_delivery
test_server_deploy_passes_traefik_ingress_mode_to_configure_delivery
test_server_deploy_rejects_invalid_ingress_mode
test_client_installer_fetches_profile_and_kubeconfig

echo "bootstrap installer tests passed"
