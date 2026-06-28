#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
KADMCTL="${ROOT_DIR}/bin/kadmctl"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  if [[ "${haystack}" != *"${needle}"* ]]; then
    printf 'Expected output to contain:\n%s\n\nActual output:\n%s\n' "${needle}" "${haystack}" >&2
    exit 1
  fi
}

assert_file_contains() {
  local file="$1"
  local needle="$2"
  [[ -f "${file}" ]] || fail "missing file ${file}"
  grep -Fq "${needle}" "${file}" || {
    echo "Expected ${file} to contain ${needle}" >&2
    echo "--- ${file}" >&2
    cat "${file}" >&2
    exit 1
  }
}

assert_file_line_order() {
  local file="$1"
  local first="$2"
  local second="$3"
  local first_line second_line
  [[ -f "${file}" ]] || fail "missing file ${file}"
  first_line="$(grep -nF "${first}" "${file}" | head -n 1 | cut -d: -f1)"
  second_line="$(grep -nF "${second}" "${file}" | head -n 1 | cut -d: -f1)"
  [[ -n "${first_line}" ]] || fail "missing ordered line: ${first}"
  [[ -n "${second_line}" ]] || fail "missing ordered line: ${second}"
  (( first_line < second_line )) || fail "expected ${first} before ${second}"
}

run_in_temp_home() {
  local tmp_home="$1"
  shift
  HOME="${tmp_home}" "$@"
}

test_bootstrap_dry_run_prints_safe_plan() {
  local tmp_home
  tmp_home="$(mktemp -d)"
  local output
  output="$(run_in_temp_home "${tmp_home}" "${KADMCTL}" bootstrap root@203.0.113.11 --name home-prod --private-ip 10.0.0.11 --dry-run)"

  assert_contains "${output}" "DRY RUN: no remote changes will be made"
  assert_contains "${output}" "cluster: home-prod"
  assert_contains "${output}" "first master: root@203.0.113.11"
  assert_contains "${output}" "K3s Server + embedded etcd"
  assert_contains "${output}" "components: Gateway API, Cilium, Argo CD, Argo Rollouts"
  assert_contains "${output}" "delivery credentials: not required for base components"
  assert_contains "${output}" "local kubeconfig: ${tmp_home}/.kube/kadm/home-prod.yaml"

  [[ ! -e "${tmp_home}/.kadm/clusters/home-prod/cluster.env" ]] || fail "dry-run wrote profile"
}

test_bootstrap_apply_writes_profile_rewrites_kubeconfig_and_installs_base_components() {
  local tmp_home tmp_bin calls_file cache_dir chart_dir wait_state_file
  tmp_home="$(mktemp -d)"
  tmp_bin="$(mktemp -d)"
  calls_file="${tmp_home}/calls.log"
  wait_state_file="${tmp_home}/wait-state"
  cache_dir="${tmp_home}/.kadm/cache/manifests"
  chart_dir="${tmp_home}/.kadm/cache/charts"
  mkdir -p "${cache_dir}" "${chart_dir}"
  for manifest in \
    https___github.com_kubernetes-sigs_gateway-api_releases_download_v1.5.1_experimental-install.yaml.yaml \
    https___raw.githubusercontent.com_argoproj_argo-cd_v3.4.4_manifests_install.yaml.yaml \
    https___github.com_argoproj_argo-rollouts_releases_download_v1.9.0_install.yaml.yaml; do
    cat > "${cache_dir}/${manifest}" <<'YAML'
apiVersion: v1
kind: ConfigMap
metadata:
  name: cached-manifest
YAML
  done
  printf 'gateway.networking.k8s.io/channel: experimental\n' >> "${cache_dir}/https___github.com_kubernetes-sigs_gateway-api_releases_download_v1.5.1_experimental-install.yaml.yaml"
  printf 'chart' > "${chart_dir}/cilium-1.19.5.tgz"
  cat > "${tmp_bin}/ssh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'ssh %s\n' "$*" >> "${ONECDCTL_TEST_CALLS}"
if [[ "$*" == *"-N -L"* ]]; then
  trap 'exit 0' TERM INT
  while true; do
    sleep 1
  done
fi
if [[ "$*" == *"cat /etc/rancher/k3s/k3s.yaml"* ]]; then
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
if [[ "$*" == *"cat /var/lib/rancher/k3s/server/node-token"* ]]; then
  printf 'k10test-token::server:test\n'
  exit 0
fi
exit 0
STUB
  cat > "${tmp_bin}/kubectl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'kubectl %s\n' "$*" >> "${ONECDCTL_TEST_CALLS}"
if [[ "$*" == *"wait --for=condition=Established crd/gatewayclasses.gateway.networking.k8s.io"* ]]; then
  count="$(cat "${ONECDCTL_TEST_WAIT_STATE}" 2>/dev/null || printf '0')"
  if [[ "${count}" == "0" ]]; then
    printf '1' > "${ONECDCTL_TEST_WAIT_STATE}"
    printf 'simulated connection loss\n' >> "${ONECDCTL_TEST_CALLS}"
    exit 1
  fi
fi
if [[ "$*" == *"get daemonset cilium"* && "$*" == *"jsonpath"* ]]; then
  printf '1 1'
  exit 0
fi
if [[ "$*" == *"get deploy argocd-server"* && "$*" == *"jsonpath"* ]]; then
  printf '1 1'
  exit 0
fi
if [[ "$*" == *"get deploy argo-rollouts"* && "$*" == *"jsonpath"* ]]; then
  printf '1 1'
  exit 0
fi
if [[ "$*" == *"create namespace"* ]]; then
  printf 'apiVersion: v1\nkind: Namespace\nmetadata:\n  name: test\n'
fi
exit 0
STUB
  cat > "${tmp_bin}/helm" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'helm %s\n' "$*" >> "${ONECDCTL_TEST_CALLS}"
exit 0
STUB
  cat > "${tmp_bin}/curl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'curl %s\n' "$*" >> "${ONECDCTL_TEST_CALLS}"
exit 1
STUB
  chmod +x "${tmp_bin}/ssh" "${tmp_bin}/kubectl" "${tmp_bin}/helm" "${tmp_bin}/curl"

  local output
  output="$(ONECDCTL_TEST_CALLS="${calls_file}" ONECDCTL_TEST_WAIT_STATE="${wait_state_file}" PATH="${tmp_bin}:${PATH}" HOME="${tmp_home}" "${KADMCTL}" bootstrap root@203.0.113.11 --name home-prod --private-ip 10.0.0.11 --api-port 16445 --console-port 18081 --apply)"

  assert_contains "${output}" "cluster profile written"
  assert_file_contains "${tmp_home}/.kadm/clusters/home-prod/cluster.env" "CLUSTER_NAME=home-prod"
  assert_file_contains "${tmp_home}/.kadm/clusters/home-prod/cluster.env" "MASTER_SSH=root@203.0.113.11"
  assert_file_contains "${tmp_home}/.kadm/clusters/home-prod/cluster.env" "K3S_JOIN_SERVER_URL=https://10.0.0.11:6443"
  assert_file_contains "${tmp_home}/.kadm/clusters/home-prod/cluster.env" "K3S_JOIN_TOKEN=k10test-token::server:test"
  assert_file_contains "${tmp_home}/.kadm/clusters/home-prod/cluster.env" "API_LOCAL_PORT=16445"
  assert_file_contains "${tmp_home}/.kadm/clusters/home-prod/cluster.env" "CONSOLE_LOCAL_PORT=18081"
  assert_file_contains "${tmp_home}/.kube/kadm/home-prod.yaml" "server: https://127.0.0.1:16445"
  assert_file_contains "${calls_file}" "kubectl --kubeconfig ${tmp_home}/.kube/kadm/home-prod.yaml --request-timeout=30s apply --server-side --force-conflicts -f ${tmp_home}/.kadm/cache/manifests/"
  assert_file_contains "${calls_file}" "kubectl --kubeconfig ${tmp_home}/.kube/kadm/home-prod.yaml --request-timeout=30s delete validatingadmissionpolicybinding safe-upgrades.gateway.networking.k8s.io --ignore-not-found"
  assert_file_contains "${calls_file}" "kubectl --kubeconfig ${tmp_home}/.kube/kadm/home-prod.yaml --request-timeout=30s delete validatingadmissionpolicy safe-upgrades.gateway.networking.k8s.io --ignore-not-found"
  assert_file_contains "${calls_file}" "kubectl --kubeconfig ${tmp_home}/.kube/kadm/home-prod.yaml --request-timeout=30s wait --for=condition=Established crd/tlsroutes.gateway.networking.k8s.io --timeout=180s"
  [[ "$(grep -Fc "wait --for=condition=Established crd/gatewayclasses.gateway.networking.k8s.io" "${calls_file}")" -ge 2 ]] || fail "Gateway API CRD wait was not retried"
  assert_file_contains "${calls_file}" "helm --kubeconfig ${tmp_home}/.kube/kadm/home-prod.yaml upgrade --install cilium ${tmp_home}/.kadm/cache/charts/cilium-1.19.5.tgz --timeout 10m --disable-openapi-validation"
  assert_file_contains "${calls_file}" "--set gatewayAPI.enabled=true"
  assert_file_contains "${calls_file}" "--set gatewayAPI.hostNetwork.enabled=true"
  assert_file_contains "${calls_file}" "--set envoy.enabled=true"
  assert_file_contains "${calls_file}" "--set envoy.securityContext.capabilities.keepCapNetBindService=true"
  assert_file_contains "${calls_file}" "--set envoy.securityContext.capabilities.envoy[0]=NET_BIND_SERVICE"
  assert_file_contains "${calls_file}" "kubectl --kubeconfig ${tmp_home}/.kube/kadm/home-prod.yaml --request-timeout=30s -n kube-system get daemonset cilium -o jsonpath="
  assert_file_contains "${calls_file}" "kubectl --kubeconfig ${tmp_home}/.kube/kadm/home-prod.yaml --request-timeout=30s apply --server-side --force-conflicts -n argocd -f ${tmp_home}/.kadm/cache/manifests/"
  assert_file_contains "${calls_file}" "kubectl --kubeconfig ${tmp_home}/.kube/kadm/home-prod.yaml --request-timeout=30s -n argocd get deploy argocd-server -o jsonpath="
  assert_file_contains "${calls_file}" "kubectl --kubeconfig ${tmp_home}/.kube/kadm/home-prod.yaml --request-timeout=30s apply --server-side --force-conflicts -n argo-rollouts -f ${tmp_home}/.kadm/cache/manifests/"
  assert_file_contains "${calls_file}" "kubectl --kubeconfig ${tmp_home}/.kube/kadm/home-prod.yaml --request-timeout=30s -n argo-rollouts get deploy argo-rollouts -o jsonpath="
  if grep -Fq "rollout status" "${calls_file}"; then
    fail "bootstrap used watch-based rollout status"
  fi
  if grep -Fq "curl " "${calls_file}" || grep -Fq "helm repo" "${calls_file}"; then
    fail "bootstrap performed network setup instead of using cached assets"
  fi
}

test_bootstrap_retries_transient_manifest_apply_failures() {
  local tmp_home tmp_bin calls_file cache_dir chart_dir apply_state_file
  tmp_home="$(mktemp -d)"
  tmp_bin="$(mktemp -d)"
  calls_file="${tmp_home}/calls.log"
  apply_state_file="${tmp_home}/argocd-apply-state"
  cache_dir="${tmp_home}/.kadm/cache/manifests"
  chart_dir="${tmp_home}/.kadm/cache/charts"
  mkdir -p "${cache_dir}" "${chart_dir}"
  for manifest in \
    https___github.com_kubernetes-sigs_gateway-api_releases_download_v1.5.1_experimental-install.yaml.yaml \
    https___raw.githubusercontent.com_argoproj_argo-cd_v3.4.4_manifests_install.yaml.yaml \
    https___github.com_argoproj_argo-rollouts_releases_download_v1.9.0_install.yaml.yaml; do
    cat > "${cache_dir}/${manifest}" <<'YAML'
apiVersion: v1
kind: ConfigMap
metadata:
  name: cached-manifest
YAML
  done
  printf 'gateway.networking.k8s.io/channel: experimental\n' >> "${cache_dir}/https___github.com_kubernetes-sigs_gateway-api_releases_download_v1.5.1_experimental-install.yaml.yaml"
  printf 'chart' > "${chart_dir}/cilium-1.19.5.tgz"

  cat > "${tmp_bin}/ssh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'ssh %s\n' "$*" >> "${ONECDCTL_TEST_CALLS}"
if [[ "$*" == *"-N -L"* ]]; then
  trap 'exit 0' TERM INT
  while true; do
    sleep 1
  done
fi
if [[ "$*" == *"cat /etc/rancher/k3s/k3s.yaml"* ]]; then
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
if [[ "$*" == *"cat /var/lib/rancher/k3s/server/node-token"* ]]; then
  printf 'k10test-token::server:test\n'
  exit 0
fi
exit 0
STUB
  cat > "${tmp_bin}/kubectl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'kubectl %s\n' "$*" >> "${ONECDCTL_TEST_CALLS}"
if [[ "$*" == *"get --raw=/readyz"* ]]; then
  exit 0
fi
if [[ "$*" == *"wait --for=condition=Established"* ]]; then
  exit 0
fi
if [[ "$*" == *"get daemonset cilium"* && "$*" == *"jsonpath"* ]]; then
  printf '1 1'
  exit 0
fi
if [[ "$*" == *"get deploy argocd-server"* && "$*" == *"jsonpath"* ]]; then
  printf '1 1'
  exit 0
fi
if [[ "$*" == *"get deploy argo-rollouts"* && "$*" == *"jsonpath"* ]]; then
  printf '1 1'
  exit 0
fi
if [[ "$*" == *"get namespace"* ]]; then
  exit 1
fi
if [[ "$*" == *"create namespace"* && "$*" == *"--dry-run=client"* ]]; then
  printf 'apiVersion: v1\nkind: Namespace\nmetadata:\n  name: test\n'
  exit 0
fi
if [[ "$*" == *"-n argocd -f"* ]]; then
  count="$(cat "${ONECDCTL_TEST_ARGOCD_APPLY_STATE}" 2>/dev/null || printf '0')"
  if [[ "${count}" == "0" ]]; then
    printf '1' > "${ONECDCTL_TEST_ARGOCD_APPLY_STATE}"
    printf 'simulated TLS handshake timeout\n' >> "${ONECDCTL_TEST_CALLS}"
    exit 1
  fi
fi
exit 0
STUB
  cat > "${tmp_bin}/helm" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'helm %s\n' "$*" >> "${ONECDCTL_TEST_CALLS}"
exit 0
STUB
  cat > "${tmp_bin}/curl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'curl %s\n' "$*" >> "${ONECDCTL_TEST_CALLS}"
exit 1
STUB
  chmod +x "${tmp_bin}/ssh" "${tmp_bin}/kubectl" "${tmp_bin}/helm" "${tmp_bin}/curl"

  local output
  output="$(ONECDCTL_TEST_CALLS="${calls_file}" ONECDCTL_TEST_ARGOCD_APPLY_STATE="${apply_state_file}" PATH="${tmp_bin}:${PATH}" HOME="${tmp_home}" "${KADMCTL}" bootstrap root@203.0.113.11 --name home-prod --private-ip 10.0.0.11 --api-port 16445 --apply)"

  assert_contains "${output}" "cluster profile written"
  [[ "$(grep -Fc -- "-n argocd -f" "${calls_file}")" -ge 2 ]] || fail "Argo CD manifest apply was not retried"
}

test_bootstrap_uses_cached_manifests_without_network() {
  local tmp_home tmp_bin calls_file cache_dir chart_dir
  tmp_home="$(mktemp -d)"
  tmp_bin="$(mktemp -d)"
  calls_file="${tmp_home}/calls.log"
  cache_dir="${tmp_home}/.kadm/cache/manifests"
  chart_dir="${tmp_home}/.kadm/cache/charts"
  mkdir -p "${cache_dir}" "${chart_dir}"
  for manifest in \
    https___github.com_kubernetes-sigs_gateway-api_releases_download_v1.5.1_experimental-install.yaml.yaml \
    https___raw.githubusercontent.com_argoproj_argo-cd_v3.4.4_manifests_install.yaml.yaml \
    https___github.com_argoproj_argo-rollouts_releases_download_v1.9.0_install.yaml.yaml; do
    cat > "${cache_dir}/${manifest}" <<'YAML'
apiVersion: v1
kind: ConfigMap
metadata:
  name: cached-manifest
YAML
  done
  printf 'gateway.networking.k8s.io/channel: experimental\n' >> "${cache_dir}/https___github.com_kubernetes-sigs_gateway-api_releases_download_v1.5.1_experimental-install.yaml.yaml"
  printf 'chart' > "${chart_dir}/cilium-1.19.5.tgz"

  cat > "${tmp_bin}/ssh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'ssh %s\n' "$*" >> "${ONECDCTL_TEST_CALLS}"
if [[ "$*" == *"-N -L"* ]]; then
  trap 'exit 0' TERM INT
  while true; do
    /bin/sleep 1
  done
fi
if [[ "$*" == *"cat /etc/rancher/k3s/k3s.yaml"* ]]; then
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
if [[ "$*" == *"cat /var/lib/rancher/k3s/server/node-token"* ]]; then
  printf 'k10test-token::server:test\n'
  exit 0
fi
exit 0
STUB
cat > "${tmp_bin}/kubectl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'kubectl %s\n' "$*" >> "${ONECDCTL_TEST_CALLS}"
if [[ "$*" == *"get daemonset cilium"* && "$*" == *"jsonpath"* ]]; then
  printf '1 1'
  exit 0
fi
if [[ "$*" == *"get deploy argocd-server"* && "$*" == *"jsonpath"* ]]; then
  printf '1 1'
  exit 0
fi
if [[ "$*" == *"get deploy argo-rollouts"* && "$*" == *"jsonpath"* ]]; then
  printf '1 1'
  exit 0
fi
if [[ "$*" == *"create namespace"* ]]; then
  printf 'apiVersion: v1\nkind: Namespace\nmetadata:\n  name: test\n'
fi
exit 0
STUB
  cat > "${tmp_bin}/helm" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'helm %s\n' "$*" >> "${ONECDCTL_TEST_CALLS}"
exit 0
STUB
  cat > "${tmp_bin}/curl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'curl %s\n' "$*" >> "${ONECDCTL_TEST_CALLS}"
exit 1
STUB
  cat > "${tmp_bin}/sleep" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
  chmod +x "${tmp_bin}/ssh" "${tmp_bin}/kubectl" "${tmp_bin}/helm" "${tmp_bin}/curl" "${tmp_bin}/sleep"

  local output
  output="$(ONECDCTL_TEST_CALLS="${calls_file}" PATH="${tmp_bin}:${PATH}" HOME="${tmp_home}" "${KADMCTL}" bootstrap root@203.0.113.11 --name home-prod --private-ip 10.0.0.11 --api-port 16445 --apply)"

  assert_contains "${output}" "Using cached Gateway API manifest: ${cache_dir}/https___github.com_kubernetes-sigs_gateway-api_releases_download_v1.5.1_experimental-install.yaml.yaml"
  assert_contains "${output}" "Using cached Cilium chart: ${chart_dir}/cilium-1.19.5.tgz"
  assert_file_contains "${calls_file}" "kubectl --kubeconfig ${tmp_home}/.kube/kadm/home-prod.yaml --request-timeout=30s apply --server-side --force-conflicts -f ${cache_dir}/https___github.com_kubernetes-sigs_gateway-api_releases_download_v1.5.1_experimental-install.yaml.yaml"
  if grep -Fq "curl " "${calls_file}"; then
    fail "cached bootstrap called curl"
  fi
}

test_deploy_apply_imports_runtime_images_before_components() {
  local tmp_home tmp_bin calls_file cache_dir chart_dir k3s_dir image_dir metadata_dir
  tmp_home="$(mktemp -d)"
  tmp_bin="$(mktemp -d)"
  calls_file="${tmp_home}/calls.log"
  cache_dir="${tmp_home}/.kadm/cache/manifests"
  chart_dir="${tmp_home}/.kadm/cache/charts"
  k3s_dir="${tmp_home}/.kadm/cache/k3s"
  image_dir="${tmp_home}/.kadm/cache/images"
  metadata_dir="${tmp_home}/.kadm/cache/metadata"
  mkdir -p "${cache_dir}" "${chart_dir}" "${k3s_dir}" "${image_dir}" "${metadata_dir}" "${tmp_home}/.kadm/bin"
  for manifest in \
    https___github.com_kubernetes-sigs_gateway-api_releases_download_v1.5.1_experimental-install.yaml.yaml \
    https___raw.githubusercontent.com_argoproj_argo-cd_v3.4.4_manifests_install.yaml.yaml \
    https___github.com_argoproj_argo-rollouts_releases_download_v1.9.0_install.yaml.yaml; do
    cat > "${cache_dir}/${manifest}" <<'YAML'
apiVersion: v1
kind: ConfigMap
metadata:
  name: cached-manifest
YAML
  done
  printf 'gateway.networking.k8s.io/channel: experimental\n' >> "${cache_dir}/https___github.com_kubernetes-sigs_gateway-api_releases_download_v1.5.1_experimental-install.yaml.yaml"
  printf 'chart\n' > "${chart_dir}/cilium-1.19.5.tgz"
  printf 'install\n' > "${k3s_dir}/install-v1.36.2+k3s1.sh"
  printf 'binary\n' > "${k3s_dir}/k3s-v1.36.2+k3s1"
  printf 'airgap\n' > "${k3s_dir}/k3s-airgap-images-v1.36.2+k3s1-amd64.tar.zst"
  printf 'archive\n' > "${image_dir}/runtime-images.tar.zst"
  printf 'quay.io/argoproj/argocd:v3.4.4\n' > "${image_dir}/runtime-images.txt"
  printf 'checksum\n' > "${image_dir}/runtime-images.sha256"
  cat > "${metadata_dir}/offline-bundle.env" <<'ENV'
KADM_OFFLINE_BUNDLE_FORMAT=2
KADM_OFFLINE_COMPLETE=true
KADM_OFFLINE_IMAGE_IMPORT=containerd
ENV

  cat > "${tmp_home}/.kadm/bin/helm" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'helm %s\n' "$*" >> "${ONECDCTL_TEST_CALLS}"
STUB
  chmod +x "${tmp_home}/.kadm/bin/helm"

  cat > "${tmp_bin}/sudo" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'sudo %s\n' "$*" >> "${ONECDCTL_TEST_CALLS}"
if [[ "$*" == *"cat /etc/rancher/k3s/k3s.yaml"* ]]; then
  printf 'apiVersion: v1\nclusters:\n- cluster:\n    server: https://127.0.0.1:6443\n'
  exit 0
fi
if [[ "$*" == *"cat /var/lib/rancher/k3s/server/node-token"* ]]; then
  printf 'k10token\n'
  exit 0
fi
if [[ "$*" == *"k3s ctr -n k8s.io images ls -q"* ]]; then
  printf 'quay.io/argoproj/argocd:v3.4.4\n'
  exit 0
fi
cat >/dev/null || true
STUB
  cat > "${tmp_bin}/zstd" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'zstd %s\n' "$*" >> "${ONECDCTL_TEST_CALLS}"
printf 'image tar stream\n'
STUB
  cat > "${tmp_bin}/kubectl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'kubectl %s\n' "$*" >> "${ONECDCTL_TEST_CALLS}"
if [[ "$*" == *"get --raw=/readyz"* ]]; then
  printf 'ok\n'
  exit 0
fi
if [[ "$*" == *"create namespace"* ]]; then
  printf 'apiVersion: v1\nkind: Namespace\nmetadata:\n  name: test\n'
  exit 0
fi
if [[ "$*" == *"get daemonset"* || "$*" == *"get deploy"* || "$*" == *"get statefulset"* ]]; then
  printf '1 1\n'
  exit 0
fi
exit 0
STUB
  chmod +x "${tmp_bin}/sudo" "${tmp_bin}/zstd" "${tmp_bin}/kubectl"

  local output
  output="$(ONECDCTL_TEST_CALLS="${calls_file}" PATH="${tmp_bin}:${PATH}" HOME="${tmp_home}" "${KADMCTL}" deploy --name home-prod --access-host root@127.0.0.1 --private-ip 10.0.0.11 --apply)"

  assert_contains "${output}" "Importing runtime container images"
  assert_file_contains "${calls_file}" "zstd -dc ${image_dir}/runtime-images.tar.zst"
  assert_file_contains "${calls_file}" "sudo k3s ctr -n k8s.io images import -"
  assert_file_line_order "${calls_file}" "sudo k3s ctr -n k8s.io images import -" "helm --kubeconfig ${tmp_home}/.kube/kadm/home-prod.yaml upgrade --install cilium"
}

test_connect_dry_run_uses_profile() {
  local tmp_home
  tmp_home="$(mktemp -d)"
  mkdir -p "${tmp_home}/.kadm/clusters/home-prod" "${tmp_home}/.kube/kadm"
  cat > "${tmp_home}/.kadm/clusters/home-prod/cluster.env" <<'PROFILE'
CLUSTER_NAME=home-prod
MASTER_SSH=root@203.0.113.11
MASTER_PRIVATE_IP=10.0.0.11
KUBECONFIG_PATH=${HOME}/.kube/kadm/home-prod.yaml
API_LOCAL_PORT=16445
CONSOLE_LOCAL_PORT=18081
K3S_JOIN_SERVER_URL=https://10.0.0.11:6443
K3S_JOIN_TOKEN=k10test-token::server:test
PROFILE
  touch "${tmp_home}/.kube/kadm/home-prod.yaml"

  local output
  output="$(run_in_temp_home "${tmp_home}" "${KADMCTL}" connect home-prod --dry-run)"

  assert_contains "${output}" "DRY RUN: no tunnel or port-forward will be started"
  assert_contains "${output}" "ssh -N -L 16445:127.0.0.1:6443 root@203.0.113.11"
  assert_contains "${output}" "kubectl --kubeconfig ${tmp_home}/.kube/kadm/home-prod.yaml -n kadm port-forward svc/kadm 18081:80"
  assert_contains "${output}" "http://127.0.0.1:18081"
}

test_connect_waits_for_api_before_starting_port_forward() {
  local tmp_home tmp_bin calls_file
  tmp_home="$(mktemp -d)"
  tmp_bin="$(mktemp -d)"
  calls_file="${tmp_home}/calls.log"
  mkdir -p "${tmp_home}/.kadm/clusters/home-prod" "${tmp_home}/.kube/kadm"
  cat > "${tmp_home}/.kadm/clusters/home-prod/cluster.env" <<'PROFILE'
CLUSTER_NAME=home-prod
MASTER_SSH=root@203.0.113.11
MASTER_PRIVATE_IP=10.0.0.11
KUBECONFIG_PATH=${HOME}/.kube/kadm/home-prod.yaml
API_LOCAL_PORT=16445
CONSOLE_LOCAL_PORT=18081
K3S_JOIN_SERVER_URL=https://10.0.0.11:6443
K3S_JOIN_TOKEN=k10test-token::server:test
PROFILE
  touch "${tmp_home}/.kube/kadm/home-prod.yaml"

  cat > "${tmp_bin}/ssh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'ssh %s\n' "$*" >> "${ONECDCTL_TEST_CALLS}"
if [[ "$*" == *"-N -L"* ]]; then
  trap 'exit 0' TERM INT
  while true; do /bin/sleep 1; done
fi
STUB
  cat > "${tmp_bin}/kubectl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'kubectl %s\n' "$*" >> "${ONECDCTL_TEST_CALLS}"
if [[ "$*" == *"get --raw=/readyz"* ]]; then
  printf 'ok\n'
  exit 0
fi
if [[ "$*" == *"port-forward svc/kadm"* ]]; then
  printf 'Forwarding from 127.0.0.1:18081 -> 80\n'
  /bin/sleep 2
  exit 0
fi
printf 'ok\n'
STUB
  chmod +x "${tmp_bin}/ssh" "${tmp_bin}/kubectl"

  local output
  output="$(ONECDCTL_TEST_CALLS="${calls_file}" PATH="${tmp_bin}:${PATH}" HOME="${tmp_home}" "${KADMCTL}" connect home-prod)"

  assert_contains "${output}" "Connected to cluster: home-prod"
  assert_file_contains "${calls_file}" "ssh -N -L 16445:127.0.0.1:6443 -o ExitOnForwardFailure=yes root@203.0.113.11"
  assert_file_contains "${calls_file}" "kubectl --kubeconfig ${tmp_home}/.kube/kadm/home-prod.yaml --request-timeout=30s get --raw=/readyz"
  assert_file_contains "${calls_file}" "kubectl --kubeconfig ${tmp_home}/.kube/kadm/home-prod.yaml --request-timeout=30s -n kadm port-forward svc/kadm 18081:80"
}

test_status_uses_profile_and_api_tunnel() {
  local tmp_home tmp_bin calls_file
  tmp_home="$(mktemp -d)"
  tmp_bin="$(mktemp -d)"
  calls_file="${tmp_home}/calls.log"
  mkdir -p "${tmp_home}/.kadm/clusters/home-prod" "${tmp_home}/.kube/kadm"
  cat > "${tmp_home}/.kadm/clusters/home-prod/cluster.env" <<'PROFILE'
CLUSTER_NAME=home-prod
MASTER_SSH=root@203.0.113.11
MASTER_PRIVATE_IP=10.0.0.11
KUBECONFIG_PATH=${HOME}/.kube/kadm/home-prod.yaml
API_LOCAL_PORT=16445
CONSOLE_LOCAL_PORT=18081
K3S_JOIN_SERVER_URL=https://10.0.0.11:6443
K3S_JOIN_TOKEN=k10test-token::server:test
PROFILE
  touch "${tmp_home}/.kube/kadm/home-prod.yaml"

  cat > "${tmp_bin}/ssh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'ssh %s\n' "$*" >> "${ONECDCTL_TEST_CALLS}"
if [[ "$*" == *"-N -L"* ]]; then
  trap 'exit 0' TERM INT
  while true; do /bin/sleep 1; done
fi
STUB
  cat > "${tmp_bin}/kubectl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'kubectl %s\n' "$*" >> "${ONECDCTL_TEST_CALLS}"
printf 'ok\n'
STUB
  chmod +x "${tmp_bin}/ssh" "${tmp_bin}/kubectl"

  local output
  output="$(ONECDCTL_TEST_CALLS="${calls_file}" PATH="${tmp_bin}:${PATH}" HOME="${tmp_home}" "${KADMCTL}" status home-prod)"

  assert_contains "${output}" "Cluster status: home-prod"
  assert_file_contains "${calls_file}" "ssh -N -L 16445:127.0.0.1:6443 -o ExitOnForwardFailure=yes root@203.0.113.11"
  assert_file_contains "${calls_file}" "kubectl --kubeconfig ${tmp_home}/.kube/kadm/home-prod.yaml --request-timeout=30s get --raw=/readyz"
  assert_file_contains "${calls_file}" "kubectl --kubeconfig ${tmp_home}/.kube/kadm/home-prod.yaml --request-timeout=30s get nodes -o wide"
  assert_file_contains "${calls_file}" "kubectl --kubeconfig ${tmp_home}/.kube/kadm/home-prod.yaml --request-timeout=30s get pods -A -o wide"
  assert_file_contains "${calls_file}" "kubectl --kubeconfig ${tmp_home}/.kube/kadm/home-prod.yaml --request-timeout=30s -n kube-system get daemonset cilium -o wide"
  assert_file_contains "${calls_file}" "kubectl --kubeconfig ${tmp_home}/.kube/kadm/home-prod.yaml --request-timeout=30s -n kube-system logs -l k8s-app=cilium --all-containers=true --tail=160"
  assert_file_contains "${calls_file}" "kubectl --kubeconfig ${tmp_home}/.kube/kadm/home-prod.yaml --request-timeout=30s -n kube-system logs deployment/cilium-operator --all-containers=true --tail=160"
  assert_file_contains "${calls_file}" "kubectl --kubeconfig ${tmp_home}/.kube/kadm/home-prod.yaml --request-timeout=30s -n kube-system logs deployment/cilium-operator --all-containers=true --tail=160 --previous"
}

test_bootstrap_rejects_unsafe_profile_values() {
  local tmp_home
  tmp_home="$(mktemp -d)"
  local output status
  set +e
  output="$(run_in_temp_home "${tmp_home}" "${KADMCTL}" bootstrap 'root@203.0.113.11;touch-/tmp/bad' --name home-prod --dry-run 2>&1)"
  status="$?"
  set -e

  [[ "${status}" -ne 0 ]] || fail "unsafe ssh target was accepted"
  assert_contains "${output}" "ssh target contains unsupported characters"
}

test_configure_delivery_dry_run_describes_required_inputs() {
  local tmp_home tmp_app_configs
  tmp_home="$(mktemp -d)"
  tmp_app_configs="$(mktemp -d)"
  mkdir -p "${tmp_home}/.kadm/clusters/home-prod" "${tmp_home}/.kube/kadm"
  mkdir -p "${tmp_app_configs}/apps"
  cat > "${tmp_home}/.kadm/clusters/home-prod/cluster.env" <<'PROFILE'
CLUSTER_NAME=home-prod
MASTER_SSH=root@203.0.113.11
MASTER_PRIVATE_IP=10.0.0.11
KUBECONFIG_PATH=${HOME}/.kube/kadm/home-prod.yaml
API_LOCAL_PORT=16445
CONSOLE_LOCAL_PORT=18081
PROFILE
  touch "${tmp_home}/.kube/kadm/home-prod.yaml"
  printf '[]\n' > "${tmp_app_configs}/apps/apps.json"

  local output
  output="$(run_in_temp_home "${tmp_home}" "${KADMCTL}" configure-delivery home-prod --app-configs-dir "${tmp_app_configs}" --dry-run)"

  assert_contains "${output}" "DRY RUN: delivery credentials will not be written"
  assert_contains "${output}" "requires env: KADM_GITHUB_TOKEN"
  assert_contains "${output}" "optional env: KADM_ARGOCD_TOKEN"
  assert_contains "${output}" "creates: kadm/kadm-secrets"
  assert_contains "${output}" "creates: argocd repository credentials"
  assert_contains "${output}" "creates: kadm/kadm-apps-config"
  assert_contains "${output}" "deploys: KADM release console kustomize overlay"
}

test_configure_delivery_apply_creates_secrets_without_token_in_arguments() {
  local tmp_home tmp_bin calls_file stdin_file port_ready_file tmp_app_configs
  tmp_home="$(mktemp -d)"
  tmp_bin="$(mktemp -d)"
  calls_file="${tmp_home}/calls.log"
  stdin_file="${tmp_home}/stdin.log"
  port_ready_file="${tmp_home}/argocd-port-ready"
  tmp_app_configs="$(mktemp -d)"
  mkdir -p "${tmp_home}/.kadm/clusters/home-prod" "${tmp_home}/.kube/kadm" "${tmp_home}/onecd-overlay"
  mkdir -p "${tmp_app_configs}/apps"
  cat > "${tmp_home}/.kadm/clusters/home-prod/cluster.env" <<'PROFILE'
CLUSTER_NAME=home-prod
MASTER_SSH=root@203.0.113.11
MASTER_PRIVATE_IP=10.0.0.11
KUBECONFIG_PATH=${HOME}/.kube/kadm/home-prod.yaml
API_LOCAL_PORT=16445
CONSOLE_LOCAL_PORT=18081
PROFILE
  touch "${tmp_home}/.kube/kadm/home-prod.yaml"
  cat > "${tmp_app_configs}/apps/apps.json" <<'JSON'
[
  {
    "id": "demo-hello",
    "name": "Demo Hello",
    "github": {
      "owner": "ccq18",
      "repo": "demo-hello",
      "workflow": "build-and-publish.yaml",
      "ref": "main"
    },
    "argocd": {
      "application": "demo-hello"
    },
    "rollout": {
      "namespace": "apps",
      "name": "hello"
    }
  },
  {
    "id": "demo-hello-spring",
    "name": "Demo Hello Spring",
    "github": {
      "owner": "ccq18",
      "repo": "demo-hello-spring",
      "workflow": "build-and-publish.yaml",
      "ref": "main"
    },
    "argocd": {
      "application": "demo-hello-spring"
    },
    "rollout": {
      "namespace": "apps",
      "name": "hellospring"
    }
  }
]
JSON

  cat > "${tmp_bin}/ssh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'ssh %s\n' "$*" >> "${ONECDCTL_TEST_CALLS}"
if [[ "$*" == *"-N -L"* ]]; then
  trap 'exit 0' TERM INT
  while true; do sleep 1; done
fi
exit 0
STUB
  cat > "${tmp_bin}/kubectl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'kubectl %s\n' "$*" >> "${ONECDCTL_TEST_CALLS}"
if [[ "$*" == *"get secret argocd-initial-admin-secret"* ]]; then
  printf 'YWRtaW4tcGFzcw=='
  exit 0
fi
if [[ "$*" == *"patch configmap argocd-cm"* && "$*" == *"--patch-file"* ]]; then
  cat "${@: -1}" >> "${ONECDCTL_TEST_STDIN}"
  exit 0
fi
if [[ "$*" == *"get statefulset argocd-application-controller"* && "$*" == *"jsonpath"* ]]; then
  printf '1 1'
  exit 0
fi
if [[ "$*" == *"get deploy kadm"* && "$*" == *"jsonpath"* ]]; then
  printf '1 1'
  exit 0
fi
if [[ "$*" == *"port-forward svc/argocd-server"* ]]; then
  sleep 3
  touch "${ONECDCTL_TEST_PORT_READY}"
  printf 'Forwarding from 127.0.0.1:18081 -> 80\n'
  trap 'exit 0' TERM INT
  while true; do sleep 1; done
fi
if [[ "$*" == *"apply -f "* ]]; then
  file="${@: -1}"
  if [[ "${file}" == "-" ]]; then
    cat >> "${ONECDCTL_TEST_STDIN}"
  else
    cat "${file}" >> "${ONECDCTL_TEST_STDIN}"
  fi
fi
if [[ "$*" == *"create namespace"* ]]; then
  printf 'apiVersion: v1\nkind: Namespace\nmetadata:\n  name: test\n'
fi
exit 0
STUB
  cat > "${tmp_bin}/curl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'curl %s\n' "$*" >> "${ONECDCTL_TEST_CALLS}"
[[ -f "${ONECDCTL_TEST_PORT_READY}" ]] || exit 7
cat >/dev/null
printf '{"token":"generated-argocd-token"}'
STUB
  chmod +x "${tmp_bin}/ssh" "${tmp_bin}/kubectl" "${tmp_bin}/curl"

  local output
  output="$(ONECDCTL_TEST_CALLS="${calls_file}" ONECDCTL_TEST_STDIN="${stdin_file}" ONECDCTL_TEST_PORT_READY="${port_ready_file}" PATH="${tmp_bin}:${PATH}" HOME="${tmp_home}" ONECD_GITHUB_TOKEN="secret-token" ONECD_GHCR_USERNAME="ccq18" ONECD_GHCR_TOKEN="ghcr-token" ONECD_GATEWAY_TLS_WILDCARD_DOMAIN="ai47.cc" "${KADMCTL}" configure-delivery home-prod --onecd-overlay "${tmp_home}/onecd-overlay" --app-configs-dir "${tmp_app_configs}" --apply)"

  assert_contains "${output}" "delivery configuration applied"
  assert_contains "${output}" "Generating Argo CD session token for KADM release console"
  assert_file_contains "${calls_file}" "kubectl --kubeconfig ${tmp_home}/.kube/kadm/home-prod.yaml --request-timeout=30s get --raw=/readyz"
  assert_file_contains "${calls_file}" "kubectl --kubeconfig ${tmp_home}/.kube/kadm/home-prod.yaml --request-timeout=30s -n argocd get secret argocd-initial-admin-secret"
  assert_file_contains "${calls_file}" "kubectl --kubeconfig ${tmp_home}/.kube/kadm/home-prod.yaml --request-timeout=30s -n argocd port-forward svc/argocd-server 18081:80"
  assert_file_contains "${calls_file}" "curl -fksSL --connect-timeout 10 --max-time 60"
  assert_file_contains "${calls_file}" "kubectl --kubeconfig ${tmp_home}/.kube/kadm/home-prod.yaml --request-timeout=30s create namespace kadm"
  assert_file_contains "${calls_file}" "kubectl --kubeconfig ${tmp_home}/.kube/kadm/home-prod.yaml --request-timeout=30s create namespace argocd"
  assert_file_contains "${calls_file}" "kubectl --kubeconfig ${tmp_home}/.kube/kadm/home-prod.yaml --request-timeout=30s create namespace apps"
  assert_file_contains "${calls_file}" "kubectl --kubeconfig ${tmp_home}/.kube/kadm/home-prod.yaml --request-timeout=30s -n argocd patch configmap argocd-cm --type merge --patch-file"
  assert_file_contains "${calls_file}" "kubectl --kubeconfig ${tmp_home}/.kube/kadm/home-prod.yaml --request-timeout=30s -n argocd rollout restart statefulset/argocd-application-controller"
  assert_file_contains "${calls_file}" "kubectl --kubeconfig ${tmp_home}/.kube/kadm/home-prod.yaml --request-timeout=30s -n argocd get statefulset argocd-application-controller -o jsonpath="
  assert_file_contains "${calls_file}" "kubectl --kubeconfig ${tmp_home}/.kube/kadm/home-prod.yaml --request-timeout=30s apply -k ${tmp_home}/onecd-overlay"
  assert_file_contains "${calls_file}" "kubectl --kubeconfig ${tmp_home}/.kube/kadm/home-prod.yaml --request-timeout=30s -n kadm rollout restart deployment/kadm"
  assert_file_contains "${calls_file}" "kubectl --kubeconfig ${tmp_home}/.kube/kadm/home-prod.yaml --request-timeout=30s -n kadm get deploy kadm -o jsonpath="
  assert_file_contains "${stdin_file}" "name: kadm-secrets"
  assert_file_contains "${stdin_file}" "name: kadm-apps-config"
  assert_file_contains "${stdin_file}" "generated-argocd-token"
  assert_file_contains "${stdin_file}" "KADM_CLUSTER_NAME"
  assert_file_contains "${stdin_file}" "K3S_JOIN_SERVER_URL"
  assert_file_contains "${stdin_file}" "K3S_JOIN_TOKEN"
  assert_file_contains "${stdin_file}" "argocd.argoproj.io/secret-type: repository"
  assert_file_contains "${stdin_file}" "resource.customizations.health.argoproj.io_Rollout"
  assert_file_contains "${stdin_file}" "kind: Gateway"
  assert_file_contains "${stdin_file}" "name: apps-gateway"
  assert_file_contains "${stdin_file}" "gatewayClassName: cilium"
  assert_file_contains "${stdin_file}" "name: apps-gateway-tls"
  assert_file_contains "${stdin_file}" "protocol: HTTPS"
  assert_file_contains "${stdin_file}" "\"id\": \"demo-hello\""
  assert_file_contains "${stdin_file}" "name: ghcr-cred"
  assert_file_contains "${stdin_file}" "kind: Application"
  assert_file_contains "${stdin_file}" "name: kadm-release-console"
  assert_file_contains "${stdin_file}" "name: demo-hello"
  assert_file_contains "${stdin_file}" "name: demo-hello-spring"
  assert_file_contains "${stdin_file}" "repoURL: https://github.com/ccq18/kadm-release-console.git"
  assert_file_contains "${stdin_file}" "repoURL: https://github.com/ccq18/kadm-app-configs.git"
  assert_file_contains "${stdin_file}" "path: apps/demo-hello/overlays/prod"
  assert_file_contains "${stdin_file}" "path: apps/demo-hello-spring/overlays/prod"
  if grep -Fq "secret-token" "${calls_file}" || grep -Fq "generated-argocd-token" "${calls_file}" || grep -Fq "admin-pass" "${calls_file}" || grep -Fq "ghcr-token" "${calls_file}"; then
    fail "token leaked into command arguments"
  fi
}

test_publish_release_console_dry_run_prints_ci_plan() {
  local tmp_onecd tmp_bin
  tmp_onecd="$(mktemp -d)"
  tmp_bin="$(mktemp -d)"
  mkdir -p "${tmp_onecd}/k8s/overlays/prod"
  cat > "${tmp_onecd}/k8s/overlays/prod/kustomization.yaml" <<'YAML'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
images:
- name: ghcr.io/ccq18/kadm-release-console
  newName: ghcr.io/ccq18/kadm-release-console
  newTag: old
YAML

  cat > "${tmp_bin}/git" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "-C" ]]; then
  shift 2
fi
if [[ "${1:-}" == "config" ]]; then
  printf 'git@github.com:ccq18/kadm-release-console.git\n'
fi
exit 0
STUB
  chmod +x "${tmp_bin}/git"

  local output
  output="$(PATH="${tmp_bin}:${PATH}" "${KADMCTL}" publish-release-console --repo-dir "${tmp_onecd}" --tag test-123 --dry-run)"

  assert_contains "${output}" "DRY RUN: KADM release console release will not be triggered"
  assert_contains "${output}" "repo dir: ${tmp_onecd}"
  assert_contains "${output}" "image: ghcr.io/ccq18/kadm-release-console:test-123"
  assert_contains "${output}" "workflow: build-and-publish.yaml"
  assert_contains "${output}" "ref: main"
  assert_contains "${output}" "updates overlay: ${tmp_onecd}/k8s/overlays/prod/kustomization.yaml"
}

test_publish_release_console_apply_triggers_github_actions_and_pulls_overlay() {
  local tmp_onecd tmp_bin calls_file gh_state_file
  tmp_onecd="$(mktemp -d)"
  tmp_bin="$(mktemp -d)"
  calls_file="${tmp_onecd}/calls.log"
  gh_state_file="${tmp_onecd}/gh-state"
  mkdir -p "${tmp_onecd}/k8s/overlays/prod"
  cat > "${tmp_onecd}/k8s/overlays/prod/kustomization.yaml" <<'YAML'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
- ../../base
images:
- name: ghcr.io/ccq18/kadm-release-console
  newName: ghcr.io/ccq18/kadm-release-console
  newTag: old
YAML

  cat > "${tmp_bin}/git" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'git %s\n' "$*" >> "${ONECDCTL_TEST_CALLS}"
if [[ "${1:-}" == "-C" ]]; then
  shift 2
fi
case "${1:-}" in
  config)
    printf 'git@github.com:ccq18/kadm-release-console.git\n'
    ;;
  diff)
    exit 0
    ;;
  ls-files)
    exit 0
    ;;
  fetch)
    exit 0
    ;;
  rev-parse)
    if [[ "${2:-}" == "HEAD" || "${2:-}" == "FETCH_HEAD" ]]; then
      printf 'abc1234\n'
    fi
    ;;
  pull)
    exit 0
    ;;
esac
exit 0
STUB
  cat > "${tmp_bin}/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'gh %s\n' "$*" >> "${ONECDCTL_TEST_CALLS}"
case "${1:-}" in
  workflow)
    printf 'run queued\n'
    printf 'new\n' > "${ONECDCTL_TEST_GH_STATE}"
    ;;
  run)
    if [[ "${2:-}" == "list" ]]; then
      if [[ -f "${ONECDCTL_TEST_GH_STATE}" ]]; then
        printf '12345\n'
      fi
      exit 0
    fi
    if [[ "${2:-}" == "watch" ]]; then
      exit 0
    fi
    ;;
esac
exit 0
STUB
  chmod +x "${tmp_bin}/git" "${tmp_bin}/gh"

  local output
  output="$(ONECDCTL_TEST_CALLS="${calls_file}" ONECDCTL_TEST_GH_STATE="${gh_state_file}" PATH="${tmp_bin}:${PATH}" "${KADMCTL}" publish-release-console --repo-dir "${tmp_onecd}" --tag test-123 --apply)"

  assert_contains "${output}" "triggered KADM release console workflow run: 12345"
  assert_contains "${output}" "updated overlay from git: ${tmp_onecd}/k8s/overlays/prod/kustomization.yaml"
  assert_file_contains "${calls_file}" "git -C ${tmp_onecd} config --get remote.origin.url"
  assert_file_contains "${calls_file}" "git -C ${tmp_onecd} fetch origin main --quiet"
  assert_file_contains "${calls_file}" "gh workflow run build-and-publish.yaml --repo ccq18/kadm-release-console --ref main -f image_tag=test-123"
  assert_file_contains "${calls_file}" "gh run watch 12345 --repo ccq18/kadm-release-console --exit-status"
  assert_file_contains "${calls_file}" "git -C ${tmp_onecd} pull --ff-only origin main"
}

test_publish_release_console_rejects_dirty_repo() {
  local tmp_onecd tmp_bin calls_file
  tmp_onecd="$(mktemp -d)"
  tmp_bin="$(mktemp -d)"
  calls_file="${tmp_onecd}/calls.log"
  mkdir -p "${tmp_onecd}/k8s/overlays/prod"
  cat > "${tmp_onecd}/k8s/overlays/prod/kustomization.yaml" <<'YAML'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
images:
- name: ghcr.io/ccq18/kadm-release-console
  newName: ghcr.io/ccq18/kadm-release-console
  newTag: old
YAML

  cat > "${tmp_bin}/git" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'git %s\n' "$*" >> "${ONECDCTL_TEST_CALLS}"
if [[ "${1:-}" == "-C" ]]; then
  shift 2
fi
case "${1:-}" in
  config)
    printf 'git@github.com:ccq18/kadm-release-console.git\n'
    ;;
  diff)
    exit 1
    ;;
esac
exit 0
STUB
  chmod +x "${tmp_bin}/git"

  local output status
  set +e
  output="$(ONECDCTL_TEST_CALLS="${calls_file}" PATH="${tmp_bin}:${PATH}" "${KADMCTL}" publish-release-console --repo-dir "${tmp_onecd}" --tag test-123 --apply 2>&1)"
  status="$?"
  set -e

  [[ "${status}" -ne 0 ]] || fail "dirty repo was accepted"
  assert_contains "${output}" "release console repo has uncommitted changes"
}

test_publish_onecd_alias_still_works() {
  local tmp_onecd tmp_bin
  tmp_onecd="$(mktemp -d)"
  tmp_bin="$(mktemp -d)"
  mkdir -p "${tmp_onecd}/k8s/overlays/prod"
  cat > "${tmp_onecd}/k8s/overlays/prod/kustomization.yaml" <<'YAML'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
images:
- name: ghcr.io/ccq18/kadm-release-console
  newName: ghcr.io/ccq18/kadm-release-console
  newTag: old
YAML

  cat > "${tmp_bin}/git" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "-C" ]]; then
  shift 2
fi
if [[ "${1:-}" == "config" ]]; then
  printf 'git@github.com:ccq18/kadm-release-console.git\n'
fi
exit 0
STUB
  chmod +x "${tmp_bin}/git"

  local output
  output="$(PATH="${tmp_bin}:${PATH}" "${KADMCTL}" publish-onecd --onecd-dir "${tmp_onecd}" --tag test-123 --dry-run)"

  assert_contains "${output}" "DRY RUN: KADM release console release will not be triggered"
}

test_install_tools_dry_run_is_script_managed() {
  local tmp_home
  tmp_home="$(mktemp -d)"
  local output
  output="$(run_in_temp_home "${tmp_home}" "${KADMCTL}" install-tools --dry-run)"

  assert_contains "${output}" "DRY RUN: local tools will not be installed"
  assert_contains "${output}" "tool: helm"
  assert_contains "${output}" "${tmp_home}/.kadm/bin"
  [[ ! -e "${tmp_home}/.kadm/bin/helm" ]] || fail "dry-run installed helm"
}

test_install_tools_uses_cached_helm_archive() {
  local tmp_home tmp_bin calls_file platform archive_root archive
  tmp_home="$(mktemp -d)"
  tmp_bin="$(mktemp -d)"
  calls_file="${tmp_home}/calls.log"
  case "$(uname -s):$(uname -m)" in
    Darwin:arm64) platform="darwin-arm64" ;;
    Darwin:x86_64) platform="darwin-amd64" ;;
    Linux:x86_64) platform="linux-amd64" ;;
    Linux:aarch64|Linux:arm64) platform="linux-arm64" ;;
    *) fail "unsupported test platform" ;;
  esac
  archive_root="${tmp_home}/archive-root"
  archive="${tmp_home}/.kadm/cache/tools/helm-v3.15.4-${platform}.tar.gz"
  mkdir -p "${archive_root}/${platform}" "$(dirname "${archive}")"
  cat > "${archive_root}/${platform}/helm" <<'STUB'
#!/usr/bin/env bash
printf 'cached helm\n'
STUB
  chmod +x "${archive_root}/${platform}/helm"
  tar -czf "${archive}" -C "${archive_root}" "${platform}"

  cat > "${tmp_bin}/curl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'curl %s\n' "$*" >> "${ONECDCTL_TEST_CALLS}"
exit 1
STUB
  chmod +x "${tmp_bin}/curl"

  local output
  output="$(ONECDCTL_TEST_CALLS="${calls_file}" PATH="${tmp_bin}:${PATH}" HOME="${tmp_home}" "${KADMCTL}" install-tools --apply)"

  assert_contains "${output}" "Using cached helm archive: ${archive}"
  [[ -x "${tmp_home}/.kadm/bin/helm" ]] || fail "cached helm was not installed"
  [[ ! -f "${calls_file}" ]] || fail "install-tools called curl despite cached Helm archive"
}

test_prepare_assets_dry_run_prints_pinned_assets() {
  local tmp_home
  tmp_home="$(mktemp -d)"
  local output
  output="$(run_in_temp_home "${tmp_home}" "${KADMCTL}" prepare-assets --dry-run)"

  assert_contains "${output}" "DRY RUN: installer assets will not be downloaded"
  assert_contains "${output}" "Gateway API manifest: https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.5.1/experimental-install.yaml"
  assert_contains "${output}" "Argo CD manifest: https://raw.githubusercontent.com/argoproj/argo-cd/v3.4.4/manifests/install.yaml"
  assert_contains "${output}" "Argo Rollouts manifest: https://github.com/argoproj/argo-rollouts/releases/download/v1.9.0/install.yaml"
  assert_contains "${output}" "Cilium chart: https://helm.cilium.io/cilium-1.19.5.tgz"
  [[ ! -e "${tmp_home}/.kadm/cache/charts/cilium-1.19.5.tgz" ]] || fail "dry-run downloaded chart"
}

test_prepare_assets_apply_downloads_pinned_assets() {
  local tmp_home tmp_bin calls_file
  tmp_home="$(mktemp -d)"
  tmp_bin="$(mktemp -d)"
  calls_file="${tmp_home}/calls.log"

  cat > "${tmp_bin}/curl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'curl %s\n' "$*" >> "${ONECDCTL_TEST_CALLS}"
output=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o)
      output="${2:-}"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
[[ -n "${output}" ]] || exit 1
printf 'asset\n' > "${output}"
STUB
  chmod +x "${tmp_bin}/curl"

  local output
  output="$(ONECDCTL_TEST_CALLS="${calls_file}" PATH="${tmp_bin}:${PATH}" HOME="${tmp_home}" "${KADMCTL}" prepare-assets --apply)"

  assert_contains "${output}" "installer assets are ready"
  assert_file_contains "${calls_file}" "https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.5.1/experimental-install.yaml"
  assert_file_contains "${calls_file}" "https://raw.githubusercontent.com/argoproj/argo-cd/v3.4.4/manifests/install.yaml"
  assert_file_contains "${calls_file}" "https://github.com/argoproj/argo-rollouts/releases/download/v1.9.0/install.yaml"
  assert_file_contains "${calls_file}" "https://helm.cilium.io/cilium-1.19.5.tgz"
  [[ -s "${tmp_home}/.kadm/cache/manifests/https___github.com_kubernetes-sigs_gateway-api_releases_download_v1.5.1_experimental-install.yaml.yaml" ]] || fail "missing Gateway API cache"
  [[ -s "${tmp_home}/.kadm/cache/charts/cilium-1.19.5.tgz" ]] || fail "missing Cilium chart cache"
}

test_prepare_assets_reuses_compatible_legacy_manifest_cache() {
  local tmp_home tmp_bin calls_file cache_dir chart_dir k3s_dir
  tmp_home="$(mktemp -d)"
  tmp_bin="$(mktemp -d)"
  calls_file="${tmp_home}/calls.log"
  cache_dir="${tmp_home}/.kadm/cache/manifests"
  chart_dir="${tmp_home}/.kadm/cache/charts"
  k3s_dir="${tmp_home}/.kadm/cache/k3s"
  mkdir -p "${cache_dir}" "${chart_dir}" "${k3s_dir}"
  cat > "${cache_dir}/https___raw.githubusercontent.com_argoproj_argo-cd_stable_manifests_install.yaml.yaml" <<'YAML'
apiVersion: apps/v1
kind: Deployment
spec:
  template:
    spec:
      containers:
      - image: quay.io/argoproj/argocd:v3.4.4
YAML
  cat > "${cache_dir}/https___github.com_argoproj_argo-rollouts_releases_latest_download_install.yaml.yaml" <<'YAML'
apiVersion: apps/v1
kind: Deployment
spec:
  template:
    spec:
      containers:
      - image: quay.io/argoproj/argo-rollouts:v1.9.0
YAML
  cat > "${cache_dir}/https___github.com_kubernetes-sigs_gateway-api_releases_latest_download_experimental-install.yaml.yaml" <<'YAML'
metadata:
  annotations:
    gateway.networking.k8s.io/channel: experimental
    gateway.networking.k8s.io/bundle-version: v1.5.1
YAML
  printf 'chart\n' > "${chart_dir}/cilium-1.19.5.tgz"
  printf 'install\n' > "${k3s_dir}/install-v1.36.2+k3s1.sh"
  printf 'binary\n' > "${k3s_dir}/k3s-v1.36.2+k3s1"
  printf 'airgap\n' > "${k3s_dir}/k3s-airgap-images-v1.36.2+k3s1-amd64.tar.zst"

  cat > "${tmp_bin}/curl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'curl %s\n' "$*" >> "${ONECDCTL_TEST_CALLS}"
exit 1
STUB
  cat > "${tmp_bin}/sleep" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
  chmod +x "${tmp_bin}/curl" "${tmp_bin}/sleep"

  local output
  output="$(ONECDCTL_TEST_CALLS="${calls_file}" PATH="${tmp_bin}:${PATH}" HOME="${tmp_home}" "${KADMCTL}" prepare-assets --apply)"

  assert_contains "${output}" "Using compatible cached Gateway API manifest"
  assert_contains "${output}" "Using compatible cached Argo CD manifest"
  assert_contains "${output}" "Using compatible cached Argo Rollouts manifest"
  [[ -s "${cache_dir}/https___raw.githubusercontent.com_argoproj_argo-cd_v3.4.4_manifests_install.yaml.yaml" ]] || fail "Argo CD fixed cache was not created"
  [[ -s "${cache_dir}/https___github.com_argoproj_argo-rollouts_releases_download_v1.9.0_install.yaml.yaml" ]] || fail "Rollouts fixed cache was not created"
  [[ -s "${cache_dir}/https___github.com_kubernetes-sigs_gateway-api_releases_download_v1.5.1_experimental-install.yaml.yaml" ]] || fail "Gateway API fixed cache was not created"
  if [[ -f "${calls_file}" ]] && grep -Fq "curl " "${calls_file}"; then
    fail "prepare-assets called curl despite compatible legacy cache"
  fi
}

test_export_assets_packages_offline_cache() {
  local tmp_home bundle
  tmp_home="$(mktemp -d)"
  bundle="${tmp_home}/kadm-platform-assets.tgz"
  mkdir -p "${tmp_home}/.kadm/cache/manifests" "${tmp_home}/.kadm/cache/charts"
  printf 'gateway\n' > "${tmp_home}/.kadm/cache/manifests/https___github.com_kubernetes-sigs_gateway-api_releases_download_v1.5.1_experimental-install.yaml.yaml"
  printf 'argocd\n' > "${tmp_home}/.kadm/cache/manifests/https___raw.githubusercontent.com_argoproj_argo-cd_v3.4.4_manifests_install.yaml.yaml"
  printf 'rollouts\n' > "${tmp_home}/.kadm/cache/manifests/https___github.com_argoproj_argo-rollouts_releases_download_v1.9.0_install.yaml.yaml"
  printf 'chart\n' > "${tmp_home}/.kadm/cache/charts/cilium-1.19.5.tgz"

  local output
  output="$(run_in_temp_home "${tmp_home}" "${KADMCTL}" export-assets --output "${bundle}")"

  assert_contains "${output}" "offline asset bundle written: ${bundle}"
  [[ -s "${bundle}" ]] || fail "missing offline asset bundle"
  tar -tzf "${bundle}" | grep -Fq "cache/charts/cilium-1.19.5.tgz" || fail "bundle missing Cilium chart"
}

test_import_assets_restores_offline_cache() {
  local src_home dst_home bundle
  src_home="$(mktemp -d)"
  dst_home="$(mktemp -d)"
  bundle="${src_home}/kadm-platform-assets.tgz"
  mkdir -p "${src_home}/.kadm/cache/manifests" "${src_home}/.kadm/cache/charts"
  printf 'gateway\n' > "${src_home}/.kadm/cache/manifests/https___github.com_kubernetes-sigs_gateway-api_releases_download_v1.5.1_experimental-install.yaml.yaml"
  printf 'argocd\n' > "${src_home}/.kadm/cache/manifests/https___raw.githubusercontent.com_argoproj_argo-cd_v3.4.4_manifests_install.yaml.yaml"
  printf 'rollouts\n' > "${src_home}/.kadm/cache/manifests/https___github.com_argoproj_argo-rollouts_releases_download_v1.9.0_install.yaml.yaml"
  printf 'chart\n' > "${src_home}/.kadm/cache/charts/cilium-1.19.5.tgz"
  HOME="${src_home}" "${KADMCTL}" export-assets --output "${bundle}" >/dev/null

  local output
  output="$(HOME="${dst_home}" "${KADMCTL}" import-assets "${bundle}")"

  assert_contains "${output}" "offline asset bundle imported"
  [[ -s "${dst_home}/.kadm/cache/charts/cilium-1.19.5.tgz" ]] || fail "import missing Cilium chart"
  [[ -s "${dst_home}/.kadm/cache/manifests/https___github.com_kubernetes-sigs_gateway-api_releases_download_v1.5.1_experimental-install.yaml.yaml" ]] || fail "import missing Gateway API manifest"
}

test_import_assets_restores_complete_bundle_metadata() {
  local src_dir dst_home bundle
  src_dir="$(mktemp -d)"
  dst_home="$(mktemp -d)"
  bundle="${src_dir}/kadm-platform-assets.tgz"
  mkdir -p \
    "${src_dir}/bundle/cache/manifests" \
    "${src_dir}/bundle/cache/charts" \
    "${src_dir}/bundle/cache/k3s" \
    "${src_dir}/bundle/cache/tools" \
    "${src_dir}/bundle/cache/images" \
    "${src_dir}/bundle/cache/repos" \
    "${src_dir}/bundle/metadata"

  printf 'gateway\n' > "${src_dir}/bundle/cache/manifests/https___github.com_kubernetes-sigs_gateway-api_releases_download_v1.5.1_experimental-install.yaml.yaml"
  printf 'argocd\n' > "${src_dir}/bundle/cache/manifests/https___raw.githubusercontent.com_argoproj_argo-cd_v3.4.4_manifests_install.yaml.yaml"
  printf 'rollouts\n' > "${src_dir}/bundle/cache/manifests/https___github.com_argoproj_argo-rollouts_releases_download_v1.9.0_install.yaml.yaml"
  printf 'chart\n' > "${src_dir}/bundle/cache/charts/cilium-1.19.5.tgz"
  printf 'helm\n' > "${src_dir}/bundle/cache/tools/helm-v3.15.4-linux-amd64.tar.gz"
  printf 'image archive\n' > "${src_dir}/bundle/cache/images/runtime-images.tar.zst"
  printf 'quay.io/argoproj/argocd:v3.4.4\n' > "${src_dir}/bundle/cache/images/runtime-images.txt"
  printf 'checksum\n' > "${src_dir}/bundle/cache/images/runtime-images.sha256"
  printf 'system\n' > "${src_dir}/bundle/cache/repos/kadm-platform-system.tgz"
  printf 'console\n' > "${src_dir}/bundle/cache/repos/kadm-release-console.tgz"
  printf 'apps\n' > "${src_dir}/bundle/cache/repos/kadm-app-configs.tgz"
  cat > "${src_dir}/bundle/metadata/offline-bundle.env" <<'ENV'
KADM_OFFLINE_BUNDLE_FORMAT=2
KADM_OFFLINE_COMPLETE=true
KADM_OFFLINE_IMAGE_IMPORT=containerd
KADM_OFFLINE_ARCH=linux-amd64
ENV
  tar -czf "${bundle}" -C "${src_dir}/bundle" cache metadata

  local output
  output="$(HOME="${dst_home}" "${KADMCTL}" import-assets "${bundle}")"

  assert_contains "${output}" "offline asset bundle imported"
  assert_contains "${output}" "offline bundle mode: complete"
  [[ -s "${dst_home}/.kadm/cache/metadata/offline-bundle.env" ]] || fail "import missing bundle metadata"
  [[ -s "${dst_home}/.kadm/cache/tools/helm-v3.15.4-linux-amd64.tar.gz" ]] || fail "import missing cached Helm archive"
  [[ -s "${dst_home}/.kadm/cache/images/runtime-images.tar.zst" ]] || fail "import missing runtime images archive"
  [[ -s "${dst_home}/.kadm/cache/repos/kadm-platform-system.tgz" ]] || fail "import missing system repo archive"
}

test_import_assets_clears_stale_complete_metadata_for_partial_bundle() {
  local src_dir dst_home bundle
  src_dir="$(mktemp -d)"
  dst_home="$(mktemp -d)"
  bundle="${src_dir}/kadm-platform-assets.tgz"
  mkdir -p \
    "${src_dir}/bundle/cache/manifests" \
    "${src_dir}/bundle/cache/charts" \
    "${dst_home}/.kadm/cache/metadata"

  printf 'gateway\n' > "${src_dir}/bundle/cache/manifests/https___github.com_kubernetes-sigs_gateway-api_releases_download_v1.5.1_experimental-install.yaml.yaml"
  printf 'argocd\n' > "${src_dir}/bundle/cache/manifests/https___raw.githubusercontent.com_argoproj_argo-cd_v3.4.4_manifests_install.yaml.yaml"
  printf 'rollouts\n' > "${src_dir}/bundle/cache/manifests/https___github.com_argoproj_argo-rollouts_releases_download_v1.9.0_install.yaml.yaml"
  printf 'chart\n' > "${src_dir}/bundle/cache/charts/cilium-1.19.5.tgz"
  cat > "${dst_home}/.kadm/cache/metadata/offline-bundle.env" <<'ENV'
KADM_OFFLINE_BUNDLE_FORMAT=2
KADM_OFFLINE_COMPLETE=true
ENV
  tar -czf "${bundle}" -C "${src_dir}/bundle" cache

  local output
  output="$(HOME="${dst_home}" "${KADMCTL}" import-assets "${bundle}")"

  assert_contains "${output}" "offline bundle mode: partial"
  [[ ! -e "${dst_home}/.kadm/cache/metadata/offline-bundle.env" ]] || fail "partial import left stale complete metadata"
}

test_reset_node_dry_run_is_safe() {
  local tmp_home
  tmp_home="$(mktemp -d)"
  local output
  output="$(run_in_temp_home "${tmp_home}" "${KADMCTL}" reset-node root@203.0.113.11 --dry-run)"

  assert_contains "${output}" "DRY RUN: no remote cleanup will be made"
  assert_contains "${output}" "target: root@203.0.113.11"
  assert_contains "${output}" "removes: K3s server/agent services and data directories"
}

test_reset_node_apply_runs_remote_cleanup_script() {
  local tmp_home tmp_bin calls_file stdin_file
  tmp_home="$(mktemp -d)"
  tmp_bin="$(mktemp -d)"
  calls_file="${tmp_home}/calls.log"
  stdin_file="${tmp_home}/stdin.log"

  cat > "${tmp_bin}/ssh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'ssh %s\n' "$*" >> "${ONECDCTL_TEST_CALLS}"
cat > "${ONECDCTL_TEST_STDIN}"
STUB
  chmod +x "${tmp_bin}/ssh"

  local output
  output="$(ONECDCTL_TEST_CALLS="${calls_file}" ONECDCTL_TEST_STDIN="${stdin_file}" PATH="${tmp_bin}:${PATH}" HOME="${tmp_home}" "${KADMCTL}" reset-node root@203.0.113.11 --apply)"

  assert_contains "${output}" "Resetting node root@203.0.113.11"
  assert_contains "${output}" "node reset completed"
  assert_file_contains "${calls_file}" "ssh root@203.0.113.11 sudo sh -s"
  assert_file_contains "${stdin_file}" "k3s-uninstall.sh"
  assert_file_contains "${stdin_file}" "k3s-agent-uninstall.sh"
  assert_file_contains "${stdin_file}" "/var/lib/rancher/k3s"
  assert_file_contains "${stdin_file}" "/etc/rancher/k3s"
}

test_cleanup_legacy_onecd_dry_run_describes_legacy_resources() {
  local tmp_home
  tmp_home="$(mktemp -d)"
  mkdir -p "${tmp_home}/.kadm/clusters/home-prod" "${tmp_home}/.kube/kadm"
  cat > "${tmp_home}/.kadm/clusters/home-prod/cluster.env" <<'PROFILE'
CLUSTER_NAME=home-prod
MASTER_SSH=root@203.0.113.11
MASTER_PRIVATE_IP=10.0.0.11
KUBECONFIG_PATH=${HOME}/.kube/kadm/home-prod.yaml
API_LOCAL_PORT=16445
CONSOLE_LOCAL_PORT=18081
PROFILE
  touch "${tmp_home}/.kube/kadm/home-prod.yaml"

  local output
  output="$(HOME="${tmp_home}" "${KADMCTL}" cleanup-legacy-onecd home-prod --dry-run)"

  assert_contains "${output}" "DRY RUN: no legacy cluster resources will be deleted"
  assert_contains "${output}" "cluster: home-prod"
  assert_contains "${output}" "deletes: argocd application onecd"
  assert_contains "${output}" "deletes: argocd repo secret repo-onecd"
  assert_contains "${output}" "deletes: namespace onecd"
}

test_cleanup_legacy_onecd_apply_deletes_legacy_resources() {
  local tmp_home tmp_bin calls_file
  tmp_home="$(mktemp -d)"
  tmp_bin="$(mktemp -d)"
  calls_file="${tmp_home}/calls.log"
  mkdir -p "${tmp_home}/.kadm/clusters/home-prod" "${tmp_home}/.kube/kadm"
  cat > "${tmp_home}/.kadm/clusters/home-prod/cluster.env" <<'PROFILE'
CLUSTER_NAME=home-prod
MASTER_SSH=root@203.0.113.11
MASTER_PRIVATE_IP=10.0.0.11
KUBECONFIG_PATH=${HOME}/.kube/kadm/home-prod.yaml
API_LOCAL_PORT=16445
CONSOLE_LOCAL_PORT=18081
PROFILE
  touch "${tmp_home}/.kube/kadm/home-prod.yaml"

  cat > "${tmp_bin}/ssh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'ssh %s\n' "$*" >> "${ONECDCTL_TEST_CALLS}"
if [[ "$*" == *"-N -L"* ]]; then
  trap 'exit 0' TERM INT
  while true; do /bin/sleep 1; done
fi
STUB
  cat > "${tmp_bin}/kubectl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'kubectl %s\n' "$*" >> "${ONECDCTL_TEST_CALLS}"
if [[ "$*" == *"get --raw=/readyz"* ]]; then
  printf 'ok\n'
fi
exit 0
STUB
  chmod +x "${tmp_bin}/ssh" "${tmp_bin}/kubectl"

  local output
  output="$(ONECDCTL_TEST_CALLS="${calls_file}" PATH="${tmp_bin}:${PATH}" HOME="${tmp_home}" "${KADMCTL}" cleanup-legacy-onecd home-prod --apply)"

  assert_contains "${output}" "legacy onecd resources deleted"
  assert_file_contains "${calls_file}" "ssh -N -L 16445:127.0.0.1:6443 -o ExitOnForwardFailure=yes root@203.0.113.11"
  assert_file_contains "${calls_file}" "kubectl --kubeconfig ${tmp_home}/.kube/kadm/home-prod.yaml --request-timeout=30s get --raw=/readyz"
  assert_file_contains "${calls_file}" "kubectl --kubeconfig ${tmp_home}/.kube/kadm/home-prod.yaml --request-timeout=30s -n argocd delete application onecd --ignore-not-found"
  assert_file_contains "${calls_file}" "kubectl --kubeconfig ${tmp_home}/.kube/kadm/home-prod.yaml --request-timeout=30s -n argocd delete secret repo-onecd --ignore-not-found"
  assert_file_contains "${calls_file}" "kubectl --kubeconfig ${tmp_home}/.kube/kadm/home-prod.yaml --request-timeout=30s -n apps delete role onecd-rollouts --ignore-not-found"
  assert_file_contains "${calls_file}" "kubectl --kubeconfig ${tmp_home}/.kube/kadm/home-prod.yaml --request-timeout=30s delete clusterrole onecd-cluster-read --ignore-not-found"
  assert_file_contains "${calls_file}" "kubectl --kubeconfig ${tmp_home}/.kube/kadm/home-prod.yaml --request-timeout=30s delete namespace onecd --ignore-not-found"
}

test_connect_migrates_legacy_local_state_to_kadm_dirs() {
  local tmp_home
  tmp_home="$(mktemp -d)"
  mkdir -p "${tmp_home}/.onecd/clusters/home-prod" "${tmp_home}/.kube/onecd"
  cat > "${tmp_home}/.onecd/clusters/home-prod/cluster.env" <<'PROFILE'
CLUSTER_NAME=home-prod
MASTER_SSH=root@203.0.113.11
MASTER_PRIVATE_IP=10.0.0.11
KUBECONFIG_PATH=${HOME}/.kube/onecd/home-prod.yaml
API_LOCAL_PORT=16445
CONSOLE_LOCAL_PORT=18081
K3S_JOIN_SERVER_URL=https://10.0.0.11:6443
K3S_JOIN_TOKEN=k10test-token::server:test
PROFILE
  printf 'apiVersion: v1\n' > "${tmp_home}/.kube/onecd/home-prod.yaml"

  local output
  output="$(HOME="${tmp_home}" "${KADMCTL}" connect home-prod --dry-run)"

  assert_contains "${output}" "kubectl --kubeconfig ${tmp_home}/.kube/kadm/home-prod.yaml -n kadm port-forward svc/kadm 18081:80"
  [[ -f "${tmp_home}/.kadm/clusters/home-prod/cluster.env" ]] || fail "legacy profile was not migrated"
  [[ -f "${tmp_home}/.kube/kadm/home-prod.yaml" ]] || fail "legacy kubeconfig was not migrated"
  [[ ! -e "${tmp_home}/.onecd/clusters/home-prod/cluster.env" ]] || fail "legacy profile was not moved"
  [[ ! -e "${tmp_home}/.kube/onecd/home-prod.yaml" ]] || fail "legacy kubeconfig was not moved"
  assert_file_contains "${tmp_home}/.kadm/clusters/home-prod/cluster.env" "KUBECONFIG_PATH=${tmp_home}/.kube/kadm/home-prod.yaml"
}

test_configure_demo_apps_dry_run_describes_secret_and_db_setup() {
  local tmp_home tmp_apps
  tmp_home="$(mktemp -d)"
  tmp_apps="$(mktemp -d)"
  mkdir -p "${tmp_home}/.kadm/clusters/home-prod" "${tmp_home}/.kube/kadm"
  mkdir -p "${tmp_apps}/apps/demo-hello/base" "${tmp_apps}/apps/demo-hello-spring/base"
  cat > "${tmp_home}/.kadm/clusters/home-prod/cluster.env" <<'PROFILE'
CLUSTER_NAME=home-prod
MASTER_SSH=root@203.0.113.11
MASTER_PRIVATE_IP=10.0.0.11
KUBECONFIG_PATH=${HOME}/.kube/kadm/home-prod.yaml
API_LOCAL_PORT=16445
CONSOLE_LOCAL_PORT=18081
PROFILE
  touch "${tmp_home}/.kube/kadm/home-prod.yaml"
  cat > "${tmp_apps}/apps/demo-hello/base/secret.example.yaml" <<'YAML'
apiVersion: v1
kind: Secret
metadata:
  name: hello-db
  namespace: apps
type: Opaque
stringData:
  DB_USER: hello_app
  DB_PASSWORD: hello_password_change_me
  DB_NAME: hello_app
YAML
  cat > "${tmp_apps}/apps/demo-hello/base/rollout.yaml" <<'YAML'
apiVersion: argoproj.io/v1alpha1
kind: Rollout
spec:
  template:
    spec:
      containers:
        - name: hello
          env:
            - name: DB_HOST
              value: "10.120.0.6"
YAML
  cat > "${tmp_apps}/apps/demo-hello-spring/base/secret.example.yaml" <<'YAML'
apiVersion: v1
kind: Secret
metadata:
  name: hellospring-db
  namespace: apps
type: Opaque
stringData:
  DB_USER: hellospring_app
  DB_PASSWORD: hellospring_password_change_me
  DB_NAME: hellospring_app
YAML
  cat > "${tmp_apps}/apps/demo-hello-spring/base/rollout.yaml" <<'YAML'
apiVersion: argoproj.io/v1alpha1
kind: Rollout
spec:
  template:
    spec:
      containers:
        - name: hellospring
          env:
            - name: DB_HOST
              value: "10.120.0.6"
YAML

  local output
  output="$(HOME="${tmp_home}" "${KADMCTL}" configure-demo-apps home-prod --app-configs-dir "${tmp_apps}" --db-ssh-target root@203.0.113.22 --dry-run)"

  assert_contains "${output}" "DRY RUN: no demo app dependencies will be configured"
  assert_contains "${output}" "cluster: home-prod"
  assert_contains "${output}" "app configs: ${tmp_apps}"
  assert_contains "${output}" "db ssh target: root@203.0.113.22"
  assert_contains "${output}" "creates: apps/hello-db"
  assert_contains "${output}" "creates: apps/hellospring-db"
}

test_configure_demo_apps_apply_syncs_secrets_and_mysql_users() {
  local tmp_home tmp_apps tmp_bin calls_file stdin_file
  tmp_home="$(mktemp -d)"
  tmp_apps="$(mktemp -d)"
  tmp_bin="$(mktemp -d)"
  calls_file="${tmp_home}/calls.log"
  stdin_file="${tmp_home}/stdin.log"
  mkdir -p "${tmp_home}/.kadm/clusters/home-prod" "${tmp_home}/.kube/kadm"
  mkdir -p "${tmp_apps}/apps/demo-hello/base" "${tmp_apps}/apps/demo-hello-spring/base"
  cat > "${tmp_home}/.kadm/clusters/home-prod/cluster.env" <<'PROFILE'
CLUSTER_NAME=home-prod
MASTER_SSH=root@203.0.113.11
MASTER_PRIVATE_IP=10.0.0.11
KUBECONFIG_PATH=${HOME}/.kube/kadm/home-prod.yaml
API_LOCAL_PORT=16445
CONSOLE_LOCAL_PORT=18081
PROFILE
  touch "${tmp_home}/.kube/kadm/home-prod.yaml"
  cat > "${tmp_apps}/apps/demo-hello/base/secret.example.yaml" <<'YAML'
apiVersion: v1
kind: Secret
metadata:
  name: hello-db
  namespace: apps
type: Opaque
stringData:
  DB_USER: hello_app
  DB_PASSWORD: hello_password_change_me
  DB_NAME: hello_app
YAML
  cat > "${tmp_apps}/apps/demo-hello/base/rollout.yaml" <<'YAML'
apiVersion: argoproj.io/v1alpha1
kind: Rollout
spec:
  template:
    spec:
      containers:
        - name: hello
          env:
            - name: DB_HOST
              value: "10.120.0.6"
YAML
  cat > "${tmp_apps}/apps/demo-hello-spring/base/secret.example.yaml" <<'YAML'
apiVersion: v1
kind: Secret
metadata:
  name: hellospring-db
  namespace: apps
type: Opaque
stringData:
  DB_USER: hellospring_app
  DB_PASSWORD: hellospring_password_change_me
  DB_NAME: hellospring_app
YAML
  cat > "${tmp_apps}/apps/demo-hello-spring/base/rollout.yaml" <<'YAML'
apiVersion: argoproj.io/v1alpha1
kind: Rollout
spec:
  template:
    spec:
      containers:
        - name: hellospring
          env:
            - name: DB_HOST
              value: "10.120.0.6"
YAML

  cat > "${tmp_bin}/ssh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'ssh %s\n' "$*" >> "${ONECDCTL_TEST_CALLS}"
if [[ "$*" == *"-N -L"* ]]; then
  trap 'exit 0' TERM INT
  while true; do /bin/sleep 1; done
fi
cat >> "${ONECDCTL_TEST_STDIN}"
STUB
  cat > "${tmp_bin}/kubectl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'kubectl %s\n' "$*" >> "${ONECDCTL_TEST_CALLS}"
if [[ "$*" == *"get --raw=/readyz"* ]]; then
  printf 'ok\n'
  exit 0
fi
if [[ "$*" == *"get pods"* && "$*" == *"app.kubernetes.io/name=hello"* ]]; then
  printf 'true Running\n'
  exit 0
fi
if [[ "$*" == *"get pods"* && "$*" == *"app.kubernetes.io/name=hellospring"* ]]; then
  printf 'true Running\n'
  exit 0
fi
if [[ "$*" == *"apply -f "* ]]; then
  file="${@: -1}"
  cat "${file}" >> "${ONECDCTL_TEST_STDIN}"
fi
exit 0
STUB
  chmod +x "${tmp_bin}/ssh" "${tmp_bin}/kubectl"

  local output
  output="$(ONECDCTL_TEST_CALLS="${calls_file}" ONECDCTL_TEST_STDIN="${stdin_file}" PATH="${tmp_bin}:${PATH}" HOME="${tmp_home}" "${KADMCTL}" configure-demo-apps home-prod --app-configs-dir "${tmp_apps}" --db-ssh-target root@203.0.113.22 --apply)"

  assert_contains "${output}" "demo app dependencies configured"
  assert_file_contains "${calls_file}" "ssh -N -L 16445:127.0.0.1:6443 -o ExitOnForwardFailure=yes root@203.0.113.11"
  assert_file_contains "${calls_file}" "kubectl --kubeconfig ${tmp_home}/.kube/kadm/home-prod.yaml --request-timeout=30s apply -f "
  assert_file_contains "${calls_file}" "ssh root@203.0.113.22 sudo sh -s"
  assert_file_contains "${calls_file}" "kubectl --kubeconfig ${tmp_home}/.kube/kadm/home-prod.yaml --request-timeout=30s -n apps delete pod -l app.kubernetes.io/name=hello --ignore-not-found"
  assert_file_contains "${calls_file}" "kubectl --kubeconfig ${tmp_home}/.kube/kadm/home-prod.yaml --request-timeout=30s -n apps delete pod -l app.kubernetes.io/name=hellospring --ignore-not-found"
  assert_file_contains "${stdin_file}" "name: hello-db"
  assert_file_contains "${stdin_file}" "name: hellospring-db"
  assert_file_contains "${stdin_file}" "CREATE DATABASE IF NOT EXISTS hello_app"
  assert_file_contains "${stdin_file}" "CREATE DATABASE IF NOT EXISTS hellospring_app"
  assert_file_contains "${stdin_file}" "'10.0.%'"
  assert_file_contains "${stdin_file}" "IDENTIFIED BY 'hello_password_change_me'"
  assert_file_contains "${stdin_file}" "IDENTIFIED BY 'hellospring_password_change_me'"
}

test_bootstrap_dry_run_prints_safe_plan
test_bootstrap_apply_writes_profile_rewrites_kubeconfig_and_installs_base_components
test_bootstrap_retries_transient_manifest_apply_failures
test_bootstrap_uses_cached_manifests_without_network
test_deploy_apply_imports_runtime_images_before_components
test_connect_dry_run_uses_profile
test_connect_waits_for_api_before_starting_port_forward
test_status_uses_profile_and_api_tunnel
test_bootstrap_rejects_unsafe_profile_values
test_configure_delivery_dry_run_describes_required_inputs
test_configure_delivery_apply_creates_secrets_without_token_in_arguments
test_publish_release_console_dry_run_prints_ci_plan
test_publish_release_console_apply_triggers_github_actions_and_pulls_overlay
test_publish_release_console_rejects_dirty_repo
test_publish_onecd_alias_still_works
test_install_tools_dry_run_is_script_managed
test_install_tools_uses_cached_helm_archive
test_prepare_assets_dry_run_prints_pinned_assets
test_prepare_assets_apply_downloads_pinned_assets
test_prepare_assets_reuses_compatible_legacy_manifest_cache
test_export_assets_packages_offline_cache
test_import_assets_restores_offline_cache
test_import_assets_restores_complete_bundle_metadata
test_import_assets_clears_stale_complete_metadata_for_partial_bundle
test_reset_node_dry_run_is_safe
test_reset_node_apply_runs_remote_cleanup_script
test_cleanup_legacy_onecd_dry_run_describes_legacy_resources
test_cleanup_legacy_onecd_apply_deletes_legacy_resources
test_connect_migrates_legacy_local_state_to_kadm_dirs
test_configure_demo_apps_dry_run_describes_secret_and_db_setup
test_configure_demo_apps_apply_syncs_secrets_and_mysql_users

echo "kadmctl tests passed"
