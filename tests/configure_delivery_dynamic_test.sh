#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
KADMCTL="${ROOT_DIR}/bin/kadmctl"

fail() {
  echo "FAIL: $*" >&2
  exit 1
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

test_configure_delivery_uses_apps_json_to_reconcile_applications() {
  local tmp_home tmp_bin calls_file stdin_file tmp_app_configs
  tmp_home="$(mktemp -d)"
  tmp_bin="$(mktemp -d)"
  calls_file="${tmp_home}/calls.log"
  stdin_file="${tmp_home}/stdin.log"
  tmp_app_configs="$(mktemp -d)"

  mkdir -p "${tmp_home}/.kadm/clusters/home-prod" "${tmp_home}/.kube/kadm" "${tmp_home}/overlay" "${tmp_app_configs}/apps"
  cat > "${tmp_home}/.kadm/clusters/home-prod/cluster.env" <<'PROFILE'
CLUSTER_NAME=home-prod
MASTER_SSH=root@127.0.0.1
MASTER_PRIVATE_IP=127.0.0.1
KUBECONFIG_PATH=${HOME}/.kube/kadm/home-prod.yaml
API_LOCAL_PORT=16443
CONSOLE_LOCAL_PORT=18080
PROFILE
  touch "${tmp_home}/.kube/kadm/home-prod.yaml"
  printf 'resources: []\n' > "${tmp_home}/overlay/kustomization.yaml"

  cat > "${tmp_app_configs}/apps/apps.json" <<'JSON'
[
  {
    "id": "alpha",
    "name": "Alpha",
    "github": {
      "owner": "ccq18",
      "repo": "alpha",
      "workflow": "build-and-publish.yaml",
      "ref": "main"
    },
    "gitops": {
      "owner": "ccq18",
      "repo": "kadm-app-configs",
      "path": "apps/alpha/overlays/prod",
      "image": "ghcr.io/ccq18/alpha",
      "ref": "main"
    },
    "argocd": {
      "application": "alpha"
    },
    "rollout": {
      "namespace": "apps",
      "name": "alpha"
    }
  },
  {
    "id": "beta",
    "name": "Beta",
    "github": {
      "owner": "ccq18",
      "repo": "beta",
      "workflow": "build-and-publish.yaml",
      "ref": "main"
    },
    "gitops": {
      "owner": "ccq18",
      "repo": "kadm-app-configs",
      "path": "apps/beta/overlays/prod",
      "image": "ghcr.io/ccq18/beta",
      "ref": "main"
    },
    "argocd": {
      "application": "beta"
    },
    "rollout": {
      "namespace": "beta-space",
      "name": "beta"
    }
  }
]
JSON

  cat > "${tmp_bin}/kubectl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'kubectl %s\n' "$*" >> "${ONECDCTL_TEST_CALLS}"
if [[ "$*" == *"get --raw=/readyz"* ]]; then
  printf 'ok\n'
  exit 0
fi
if [[ "$*" == *"create namespace"* && "$*" == *"--dry-run=client"* ]]; then
  printf 'apiVersion: v1\nkind: Namespace\nmetadata:\n  name: test\n'
  exit 0
fi
if [[ "$*" == *"apply -f "* ]]; then
  file="${@: -1}"
  cat "${file}" >> "${ONECDCTL_TEST_STDIN}"
  exit 0
fi
if [[ "$*" == *"patch configmap argocd-cm"* && "$*" == *"--patch-file"* ]]; then
  cat "${@: -1}" >> "${ONECDCTL_TEST_STDIN}"
  exit 0
fi
if [[ "$*" == *"apply -k "* ]]; then
  exit 0
fi
if [[ "$*" == *"get applications"* && "$*" == *"jsonpath"* ]]; then
  printf 'legacy-one\n'
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
exit 0
STUB
  chmod +x "${tmp_bin}/kubectl"

  ONECDCTL_TEST_CALLS="${calls_file}" \
    ONECDCTL_TEST_STDIN="${stdin_file}" \
    PATH="${tmp_bin}:${PATH}" \
    HOME="${tmp_home}" \
    ONECD_GITHUB_TOKEN="secret-token" \
    ONECD_GATEWAY_TLS_WILDCARD_DOMAIN="ai47.cc" \
    ONECD_ARGOCD_TOKEN="argocd-token" \
    "${KADMCTL}" configure-delivery home-prod \
      --onecd-overlay "${tmp_home}/overlay" \
      --app-configs-dir "${tmp_app_configs}" \
      --apply

  assert_file_contains "${stdin_file}" "name: alpha"
  assert_file_contains "${stdin_file}" "path: apps/alpha/overlays/prod"
  assert_file_contains "${stdin_file}" "name: beta"
  assert_file_contains "${stdin_file}" "namespace: beta-space"
  assert_file_contains "${stdin_file}" "name: kadm-source-apps-config"
  assert_file_contains "${stdin_file}" "resource.customizations.health.argoproj.io_Rollout"
  assert_file_contains "${stdin_file}" "kind: Gateway"
  assert_file_contains "${stdin_file}" "name: apps-gateway"
  assert_file_contains "${stdin_file}" "gatewayClassName: cilium"
  assert_file_contains "${stdin_file}" "name: apps-gateway-tls"
  assert_file_contains "${stdin_file}" "protocol: HTTPS"
  assert_file_contains "${calls_file}" "kubectl --kubeconfig ${tmp_home}/.kube/kadm/home-prod.yaml --request-timeout=30s -n argocd patch configmap argocd-cm --type merge --patch-file"
  assert_file_contains "${calls_file}" "kubectl --kubeconfig ${tmp_home}/.kube/kadm/home-prod.yaml --request-timeout=30s -n argocd delete application legacy-one --ignore-not-found"
}

test_configure_delivery_uses_apps_json_to_reconcile_applications

echo "configure-delivery dynamic tests passed"
