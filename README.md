# KADM Platform System

This repository contains the local automation skeleton for the fixed growth path:

```text
1 Server
-> 3 Server HA
-> 3 Server + N Worker
```

The first implementation slice is intentionally conservative. Files here define configuration contracts and templates only. Runtime scripts added in later tasks must default to `DRY_RUN=1`; any command that changes a remote host or cluster must require an explicit `--apply`.

## Safety Rules

- Do not commit real secrets, kubeconfig files, SSH private keys, K3s server tokens, database passwords, object-storage keys, or GitHub tokens.
- 示例配置只保留占位符，不包含真实密钥；真实值必须放在密钥管理系统或本地忽略文件中。
- Use `config/cluster.env.example` as a template and keep real values in an ignored local file.
- Treat single-node mode as a starting point, not high availability.
- Treat two-server mode as a temporary `1 -> 3` upgrade state, not a supported long-term topology.
- Keep Cilium as the fixed default self-hosted network implementation for the first version.
- Do not expose CNI, service dataplane, Gateway controller, or IPAM choices to ordinary users.

## Files

| Path | Purpose |
| --- | --- |
| `config/cluster.env.example` | Example ClusterSpec input. It contains placeholders only and does not include real secrets. |
| `templates/k3s-server-config.yaml` | Default K3s Server configuration template for the self-hosted path. |
| `templates/cilium-values.yaml` | Default Cilium Helm values template for the self-hosted path. |

## Default Growth Path

The self-hosted path starts with one K3s Server using embedded etcd from day one:

```text
ECS-1
├── K3s Server
├── single-member embedded etcd
├── Cilium Agent
├── Cilium Gateway
├── platform components
└── application Pods
```

Later, the platform upgrades the cluster to three Servers in one controlled operation:

```text
ECS-1 / ECS-2 / ECS-3
├── K3s Server
├── embedded etcd
├── Cilium Agent
├── Cilium Gateway
├── platform components
└── application Pods
```

After three Servers, normal capacity expansion adds Agent Workers rather than more etcd members.

## Execution Policy

Later scripts under `bin/` must follow this policy:

```text
default: DRY_RUN=1
real changes: require --apply
```

Examples:

```bash
# Safe planning mode
bin/install-single-server.sh --env config/cluster.env.example --dry-run

# Real execution, only after reviewing the plan
bin/install-single-server.sh --env /secure/path/cluster.env --apply
```

The `--apply` mode must not be added casually. It must print the target host, cluster id, operation type, and expected blast radius before running any remote command.

## Local Installer

`bin/kadmctl` provides the first local installer workflow.

Day-0 entrypoints are now the bootstrap scripts under [`bootstrap/`](/Users/lrd/mnt/homepc/data/homepcdata/kadm-platform-system/bootstrap):

```bash
# On the first server. This downloads the latest platform offline bundle by default.
curl -fsSL https://raw.githubusercontent.com/ccq18/kadm-platform-system/main/bootstrap/install-kadm.sh | \
  bash -s -- all \
    --cluster home-prod \
    --access-host root@203.0.113.11 \
    --private-ip 10.0.0.11

# On the operator laptop.
curl -fsSL https://raw.githubusercontent.com/ccq18/kadm-platform-system/main/bootstrap/install-kadm-client.sh | \
  bash -s -- --cluster home-prod --server root@203.0.113.11
```

The default server installer bundle is:

- Release page: <https://github.com/ccq18/kadm-platform-assets/releases/tag/bundle-latest>
- Stable asset URL: <https://github.com/ccq18/kadm-platform-assets/releases/download/bundle-latest/kadm-platform-assets.tgz>

Override the bundle source when testing a different build:

```bash
export KADM_ASSET_BUNDLE_URL=https://github.com/ccq18/kadm-platform-assets/releases/download/bundle-latest/kadm-platform-assets.tgz

curl -fsSL https://raw.githubusercontent.com/ccq18/kadm-platform-system/main/bootstrap/install-kadm.sh | \
  bash -s -- prepare
```

`install-kadm.sh` splits first install into:

- `prepare`: download repos, import the offline bundle, install local helper tools
- `deploy`: install local K3s, install platform components, configure release-console delivery
- `all`: run both phases

`kadmctl` remains the day-2 tool after bootstrap.

Bootstrap always starts from one empty server:

```bash
# Install local helper tools through the installer, not by ad-hoc terminal commands.
bin/kadmctl install-tools --apply

# Prepare pinned installer assets through the installer before any cluster changes.
bin/kadmctl prepare-assets --dry-run
bin/kadmctl prepare-assets --apply
bin/kadmctl export-assets --output kadm-platform-assets.tgz

# On an offline/local installer machine, import the prepared bundle.
bin/kadmctl import-assets kadm-platform-assets.tgz

# Destructive node cleanup is also script-managed and defaults to dry-run.
bin/kadmctl reset-node root@1.2.3.4 --dry-run
bin/kadmctl reset-node root@1.2.3.4 --apply

# Preview only. This is the default safety mode.
bin/kadmctl bootstrap root@1.2.3.4 \
  --name home-prod \
  --private-ip 10.0.0.11 \
  --dry-run

# Real first-node install. This changes the remote host.
bin/kadmctl bootstrap root@1.2.3.4 \
  --name home-prod \
  --private-ip 10.0.0.11 \
  --apply
```

The current bootstrap command installs the first K3s Server with embedded etcd, retrieves kubeconfig, rewrites it to a local tunnel endpoint, installs the base platform components, and writes:

```text
~/.kadm/clusters/home-prod/cluster.env
~/.kube/kadm/home-prod.yaml
```

Base component installation includes Gateway API CRDs, Cilium, Argo CD, and Argo Rollouts. These components do not require GitHub or image registry credentials after the offline bundle is imported.
The preferred install path is offline-first: `install-kadm.sh prepare` downloads the published `kadm-platform-assets.tgz`, restores bundled repositories, imports cached assets, and installs local helper tools. `install-kadm.sh deploy` then consumes only `~/.kadm/cache`, installs K3s, imports platform runtime images into K3s containerd, and installs platform components. The bundle pins Gateway API `v1.5.1` experimental assets, Argo CD `v3.4.4`, Argo Rollouts `v1.9.0`, and Cilium `1.19.5`. The Gateway API experimental bundle is intentional because Cilium Gateway support still expects `TLSRoute v1alpha2`.

Manual `kadmctl prepare-assets`, `export-assets`, and `import-assets` remain available for custom bundles, but the normal server bootstrap should use the published `bundle-latest` release asset.

Kubernetes API operations still go through the SSH tunnel. The installer bounds `kubectl` calls with `--request-timeout=30s` and retries idempotent apply/delete/wait operations so transient tunnel failures surface as retries or clear installer failures instead of hung terminal sessions.

Configure delivery credentials after bootstrap:

```bash
# Optional, when triggering a KADM release console build through GitHub Actions.
export KADM_GITHUB_TOKEN=<github-token>
bin/kadmctl publish-release-console --tag <image-tag> --apply

export KADM_GITHUB_TOKEN=<new-token>
export KADM_GHCR_USERNAME=<github-user>
export KADM_GHCR_TOKEN=<ghcr-token>

bin/kadmctl configure-delivery home-prod --app-configs-dir /path/to/kadm-app-configs --apply
```

`publish-release-console` triggers the `kadm-release-console` GitHub Actions workflow, waits for it to finish, and fast-forwards the local repo so the overlay tag matches the build output. `configure-delivery` reads secrets from environment variables, generates an Argo CD session token when `KADM_ARGOCD_TOKEN` is not provided, applies Kubernetes Secrets through transient local manifests so failed API calls can be retried, configures Argo CD repository credentials for `kadm-release-console` and `kadm-app-configs`, injects `kadm-app-configs/apps/apps.json` into the `kadm-apps-config` ConfigMap, includes the K3s join token from the local bootstrap profile, and deploys the KADM release console Kustomize overlay. `KADM_*` environment variables are the preferred interface; `ONECD_*` names remain supported as compatibility aliases. Do not pass tokens as command-line arguments.

Access the platform through an SSH tunnel instead of exposing the Kubernetes API publicly:

```bash
bin/kadmctl connect home-prod
```

When the `kadm` Service exists, `connect` starts:

```text
127.0.0.1:16443 -> first-master:6443
127.0.0.1:18080 -> svc/kadm:80
```

Then open:

```text
http://127.0.0.1:18080
```

Keep the command running while using the console. Press `Ctrl-C` to stop the tunnel and port-forward.

## Template Variables

The templates use shell-style placeholders such as `${CLUSTER_CIDR}` and `${SERVICE_CIDR}`. Later tasks will add rendering and validation scripts. Until then, these templates are design contracts, not directly applied manifests.

## Secret Handling

`cluster.env.example` intentionally uses placeholder references:

```text
K3S_TOKEN_SECRET_REF=secret://example/k3s-token
BACKUP_ACCESS_KEY_REF=secret://example/object-storage-access-key
BACKUP_SECRET_KEY_REF=secret://example/object-storage-secret-key
```

Real secret values must live in a secret manager or an ignored local file, never in this repository.
