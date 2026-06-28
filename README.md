# KADM Platform System

KADM Platform System 是首台服务器安装、客户端初始化和 Day-2 运维的主入口。它负责把平台离线资源导入本地缓存，并用 `kadmctl` 安装 K3s、Cilium、Gateway API、Argo CD、Argo Rollouts 和 KADM Release Console。

## 仓库边界

| 仓库 | 职责 |
| --- | --- |
| `kadm-platform-system` | 安装脚本、`kadmctl`、平台组件部署、运维命令，以及 `console/` 下的 Release Console 源码和部署 overlay |
| `kadm-platform-assets` | 平台离线资源包构建和 Release 发布 |
| `kadm-app-configs` | 应用 GitOps 配置和应用注册表 |
| 应用仓库 | 只负责源码、测试、镜像构建和推送 |

平台离线包不包含业务应用镜像。业务应用完全离线分发以后应独立设计应用镜像包。

## 服务器安装

默认安装会下载最新平台离线包：

```bash
export KADM_GITHUB_TOKEN=<github-token>

curl -fsSL https://raw.githubusercontent.com/ccq18/kadm-platform-system/main/bootstrap/install-kadm.sh | \
  bash -s -- all \
    --cluster kadm-test \
    --access-host root@<public-ip> \
    --private-ip <private-ip> \
    --dns-upstream 1.1.1.1 \
    --dns-upstream 8.8.8.8
```

默认资源包：

- Release page: <https://github.com/ccq18/kadm-platform-assets/releases/tag/bundle-latest>
- Stable asset URL: <https://github.com/ccq18/kadm-platform-assets/releases/download/bundle-latest/kadm-platform-assets.tgz>

如果执行安装脚本的服务器本地已有资源包：

```bash
export KADM_ASSET_BUNDLE_URL=file:///opt/kadm/kadm-platform-assets.tgz
export KADM_GITHUB_TOKEN=<github-token>

curl -fsSL https://raw.githubusercontent.com/ccq18/kadm-platform-system/main/bootstrap/install-kadm.sh | \
  bash -s -- all \
    --cluster kadm-test \
    --access-host root@<public-ip> \
    --private-ip <private-ip>
```

`KADM_ASSET_BUNDLE_URL` 支持 `https://...` 和 `file://...`。`file://` 路径必须是服务器上的绝对路径。

## 安装阶段

| 阶段 | 行为 |
| --- | --- |
| `prepare` | 下载或读取 `kadm-platform-assets.tgz`，恢复 bundle 内的 KADM 仓库，导入 `~/.kadm/cache`，安装本地工具 |
| `deploy` | 使用本地缓存安装 K3s 和平台组件，导入 platform runtime images 到 K3s containerd，配置 Release Console 和 GitOps |
| `all` | 先执行 `prepare`，再执行 `deploy` |

`prepare` 是离线优先准备阶段。`deploy/all` 仍需要 `KADM_GITHUB_TOKEN`，因为 Release Console 需要 GitHub Actions、仓库内容和 GHCR 访问能力。不要把 token 写进命令参数或提交到仓库。

## 客户端初始化

在操作员本机执行：

```bash
curl -fsSL https://raw.githubusercontent.com/ccq18/kadm-platform-system/main/bootstrap/install-kadm-client.sh | \
  bash -s -- \
    --cluster kadm-test \
    --server root@<public-ip>
```

脚本会安装 `kadmctl` 并写入：

```text
~/.kadm/clusters/kadm-test/cluster.env
~/.kube/kadm/kadm-test.yaml
~/.local/bin/kadmctl
```

## 访问控制台

```bash
~/.local/bin/kadmctl connect kadm-test
```

然后打开：

```text
http://127.0.0.1:18080
```

`connect` 会在前台保持 SSH tunnel 和 `kubectl port-forward`。控制台不默认暴露公网。

## 常用 Day-2 命令

```bash
# 查看集群状态
kadmctl status kadm-test

# 清理节点，默认建议先 dry-run
kadmctl reset-node root@<host> --dry-run
kadmctl reset-node root@<host> --apply

# 发布/更新 Release Console 镜像
export KADM_GITHUB_TOKEN=<github-token>
kadmctl publish-release-console --tag <image-tag> --apply

# 重新配置交付凭据和应用注册表
export KADM_GITHUB_TOKEN=<github-token>
export KADM_GHCR_USERNAME=<github-user>
export KADM_GHCR_TOKEN=<ghcr-token>
kadmctl configure-delivery kadm-test --app-configs-dir /path/to/kadm-app-configs --apply
```

`KADM_*` 是当前环境变量接口。`ONECD_*` 仅作为迁移兼容别名保留。

## 离线资源内容

当前平台离线包包含：

- K3s install script、binary 和 airgap image bundle
- Helm archive
- Gateway API experimental manifest
- Argo CD install manifest
- Argo Rollouts install manifest
- Cilium chart
- 平台组件运行镜像，包括 Cilium、Argo CD、Argo Rollouts 和 KADM Release Console
- `kadm-platform-system` 仓库归档，包含 `console/`
- `kadm-app-configs` 仓库归档

业务应用镜像不包含在该 bundle 中。

---

# KADM Platform System

KADM Platform System is the main entrypoint for first-server installation, local client setup, and Day-2 operations. It imports the offline platform bundle into local cache and uses `kadmctl` to install K3s, Cilium, Gateway API, Argo CD, Argo Rollouts, and KADM Release Console.

## Repository Boundaries

| Repository | Responsibility |
| --- | --- |
| `kadm-platform-system` | Installer scripts, `kadmctl`, platform component deployment, operations commands, and Release Console source/deployment overlay under `console/` |
| `kadm-platform-assets` | Offline platform bundle build and Release publishing |
| `kadm-app-configs` | Application GitOps configuration and app registry |
| Application repositories | Source code, tests, image build, and image push only |

The platform offline bundle does not include business application images. Fully offline business application distribution should be designed as a separate application image bundle.

## Server Install

The default install downloads the latest platform offline bundle:

```bash
export KADM_GITHUB_TOKEN=<github-token>

curl -fsSL https://raw.githubusercontent.com/ccq18/kadm-platform-system/main/bootstrap/install-kadm.sh | \
  bash -s -- all \
    --cluster kadm-test \
    --access-host root@<public-ip> \
    --private-ip <private-ip> \
    --dns-upstream 1.1.1.1 \
    --dns-upstream 8.8.8.8
```

Default bundle:

- Release page: <https://github.com/ccq18/kadm-platform-assets/releases/tag/bundle-latest>
- Stable asset URL: <https://github.com/ccq18/kadm-platform-assets/releases/download/bundle-latest/kadm-platform-assets.tgz>

If the bundle already exists on the server that runs the installer:

```bash
export KADM_ASSET_BUNDLE_URL=file:///opt/kadm/kadm-platform-assets.tgz
export KADM_GITHUB_TOKEN=<github-token>

curl -fsSL https://raw.githubusercontent.com/ccq18/kadm-platform-system/main/bootstrap/install-kadm.sh | \
  bash -s -- all \
    --cluster kadm-test \
    --access-host root@<public-ip> \
    --private-ip <private-ip>
```

`KADM_ASSET_BUNDLE_URL` supports `https://...` and `file://...`. A `file://` path must be an absolute path on the server.

## Install Phases

| Phase | Behavior |
| --- | --- |
| `prepare` | Downloads or reads `kadm-platform-assets.tgz`, restores bundled KADM repositories, imports `~/.kadm/cache`, and installs local tools |
| `deploy` | Uses local cache to install K3s and platform components, imports platform runtime images into K3s containerd, and configures Release Console and GitOps |
| `all` | Runs `prepare`, then `deploy` |

`prepare` is the offline-first preparation phase. `deploy/all` still require `KADM_GITHUB_TOKEN` because Release Console needs GitHub Actions, repository content, and GHCR access. Do not pass tokens as command-line arguments or commit them to Git.

## Local Client Setup

Run on the operator machine:

```bash
curl -fsSL https://raw.githubusercontent.com/ccq18/kadm-platform-system/main/bootstrap/install-kadm-client.sh | \
  bash -s -- \
    --cluster kadm-test \
    --server root@<public-ip>
```

The script installs `kadmctl` and writes:

```text
~/.kadm/clusters/kadm-test/cluster.env
~/.kube/kadm/kadm-test.yaml
~/.local/bin/kadmctl
```

## Console Access

```bash
~/.local/bin/kadmctl connect kadm-test
```

Then open:

```text
http://127.0.0.1:18080
```

`connect` keeps the SSH tunnel and `kubectl port-forward` in the foreground. The console is not exposed publicly by default.

## Common Day-2 Commands

```bash
kadmctl status kadm-test

kadmctl reset-node root@<host> --dry-run
kadmctl reset-node root@<host> --apply

export KADM_GITHUB_TOKEN=<github-token>
kadmctl publish-release-console --tag <image-tag> --apply

export KADM_GITHUB_TOKEN=<github-token>
export KADM_GHCR_USERNAME=<github-user>
export KADM_GHCR_TOKEN=<ghcr-token>
kadmctl configure-delivery kadm-test --app-configs-dir /path/to/kadm-app-configs --apply
```

`KADM_*` is the current environment variable interface. `ONECD_*` names remain only as migration compatibility aliases.
