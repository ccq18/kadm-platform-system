# Git 改动生效规则

本文说明 `kadm-app-configs`、应用源码和发布系统自身发生 Git 改动后，是否会自动影响已部署集群，以及需要通过哪个显式动作让改动生效。

核心原则：

- `应用 Git 定义` 只处理项目注册表，也就是 `kadm-app-configs/apps/apps.json` 到集群内有效项目注册表、Argo CD Application 的同步。
- `发布` 处理已存在项目的一次版本交付：构建或选择镜像、更新 GitOps 镜像版本、触发 Argo CD 同步，并进入 Rollout 检查/放量流程。
- 业务应用的 Argo CD Application 应保持手动同步。Git push 只改变期望配置，不应直接影响线上运行版本。
- 发布系统自身也应按显式发布处理。CI 可以构建镜像，但上线某个镜像 tag 需要手动执行发布系统发布命令。

## 生效矩阵

| 改动位置 | 是否需要点“应用 Git 定义” | 是否需要点“发布” | 会不会自动生效 |
|---|---:|---:|---|
| `apps/apps.json` 新增项目 | 需要 | 不需要 | 不会自动创建 Argo CD Application；点“应用 Git 定义”后项目才进入发布系统 |
| `apps/apps.json` 删除项目 | 需要 | 不需要 | 不会自动删除 Argo CD Application；点“应用 Git 定义”后才从有效项目中下线 |
| `apps/apps.json` 修改已有项目的仓库、workflow、GitOps 路径、Rollout 名称等注册信息 | 需要 | 不需要 | 不会自动更新有效项目注册表；点“应用 Git 定义”后发布系统才按新注册信息工作 |
| `apps/<app>/base/rollout.yaml` | 不需要 | 需要 | 不会自动影响线上；下次发布或显式同步该应用时随 GitOps 一起生效 |
| `apps/<app>/base/service.yaml` | 不需要 | 需要 | 不会自动影响线上；下次发布或显式同步该应用时更新 Service |
| `apps/<app>/base/httproute.yaml` | 不需要 | 需要 | 不会自动影响线上；下次发布或显式同步该应用时更新路由 |
| `apps/<app>/base/secret.yaml` | 不需要 | 需要 | 不会自动影响线上；同步后 Secret 对象会更新，但运行中的 Pod 是否读取新值取决于应用加载方式，通常需要新 Pod 或重启 |
| `apps/<app>/overlays/prod/kustomization.yaml` 的非镜像配置 | 不需要 | 需要 | 不会自动影响线上；下次发布或显式同步该应用时生效 |
| `apps/<app>/overlays/prod/kustomization.yaml` 的镜像 tag | 不需要 | 需要 | 不会自动部署；发布动作通常负责更新这个 tag 并同步，手工改 tag 后仍需要显式同步 |
| 应用源码代码变更 | 不需要 | 需要 | 代码不会自动变成线上版本；CI 可以构建镜像，但只有发布选择/生成镜像 tag 并同步 GitOps 后才上线 |
| 发布系统源码 `kadm-platform-system/console/**` | 不需要 | 需要发布系统自身 | CI 可以构建发布系统镜像，但不应自动更新线上发布系统；需要手动发布指定镜像 tag |
| 发布系统 `console/k8s/overlays/prod/kustomization.yaml` 镜像 tag | 不需要 | 需要发布系统自身 | 不应自动同步；手动发布系统发布命令会更新 tag 并同步 `kadm-platform-system` |

## 操作口径

### 新增或删除项目

1. 修改并提交 `kadm-app-configs/apps/apps.json`。
2. 在 Release Console 的 `项目管理` 页面点 `应用 Git 定义`。
3. 新项目出现后，再按需点该项目的 `发布`。

### 修改已存在应用的 Kubernetes 配置

例如修改：

```text
kadm-app-configs/apps/<app>/base/rollout.yaml
kadm-app-configs/apps/<app>/base/service.yaml
kadm-app-configs/apps/<app>/base/httproute.yaml
kadm-app-configs/apps/<app>/base/secret.yaml
kadm-app-configs/apps/<app>/overlays/prod/kustomization.yaml
```

这些文件不需要点 `应用 Git 定义`，因为项目本身已经存在。改动提交后不会自动影响线上，需要通过该应用的 `发布` 流程，或等价的显式 Argo CD 同步动作，让 GitOps 期望状态进入集群。

如果改的是 `rollout.yaml` 里的副本数、资源限制、环境变量、探针、策略等配置，应把它当成一次发布的一部分处理，避免 Git push 直接改变当前线上版本。

### 修改应用源码

应用源码改动首先需要构建镜像。Release Console 的业务应用 `发布` 流程会触发源码仓库 CI，等待镜像构建完成，然后更新 `kadm-app-configs` 中该应用的镜像 tag 并同步 Argo CD。

如果源码仓库 CI 只是自动构建并推送镜像，但没有经过发布系统更新 GitOps tag 和同步 Argo CD，线上不会自动使用新镜像。

### 发布系统自身更新

发布系统自身也按手动发布处理：

1. 提交并推送 `kadm-platform-system/console/**` 等代码改动。
2. CI 构建并推送 `ghcr.io/ccq18/kadm-platform-system:<tag>`。
3. 运维人员确认要上线的镜像 tag。
4. 运维人员用发布系统发布命令指定镜像 tag。

示例：

```bash
kadmctl publish-release-console kadm-test --tag <image-tag> --apply
```

该命令的目标是发布一个已经构建好的发布系统镜像，而不是把代码 push 直接上线。

## 发布系统镜像版本查看和手动发布

本节只描述发布系统自身，也就是镜像：

```text
ghcr.io/ccq18/kadm-platform-system
```

### 构建新镜像

提交并推送发布系统代码后，GitHub Actions 会构建镜像：

```bash
cd /Users/lrd/Mounts/homepc-root/data/homepcdata/k3s/kadm-platform-system

git status
git add <changed-files>
git commit -m "feat: update release console"
git push origin main
```

触发条件来自 `.github/workflows/build-platform-system-image.yaml`：

```text
push main 且改动命中 console/** 或 .github/workflows/build-platform-system-image.yaml
```

CI 只负责：

```text
测试
Lint
构建镜像
推送 ghcr.io/ccq18/kadm-platform-system:<tag>
打印最终镜像名
```

CI 不负责：

```text
更新 console/k8s/overlays/prod/kustomization.yaml
同步 Argo CD
滚动更新集群里的 kadm Deployment
```

这些上线动作必须通过手动发布命令完成。

### 查看 GitHub Actions 构建结果

打开：

```text
https://github.com/ccq18/kadm-platform-system/actions
```

进入最近一次 `Build Platform System Image` workflow，查看 `Print image` 步骤。成功后会输出完整镜像名，例如：

```text
ghcr.io/ccq18/kadm-platform-system:20260630153045
```

其中 `20260630153045` 就是后续发布命令要使用的 `<image-tag>`。

### 查看 GHCR 镜像版本列表

浏览器打开：

```text
https://github.com/ccq18/kadm-platform-system/pkgs/container/kadm-platform-system/versions
```

这里显示已经推送到 GHCR 的发布系统镜像版本。若 package 是私有的，需要登录有权限的 GitHub 账号。

也可以用 GitHub CLI 查看：

```bash
gh api /users/ccq18/packages/container/kadm-platform-system/versions \
  --jq '.[] | [.metadata.container.tags[0], .created_at] | @tsv'
```

如果没有权限，先确认 GitHub CLI 已登录，并且 token 具备读取 package 的权限：

```bash
gh auth status
```

### 手动发布指定镜像

拿到镜像 tag 后，先做 dry-run：

```bash
cd /Users/lrd/Mounts/homepc-root/data/homepcdata/k3s

/Users/lrd/Mounts/homepc-root/data/homepcdata/k3s/kadm-platform-system/bin/kadmctl \
  publish-release-console kadm-test \
  --tag <image-tag> \
  --dry-run
```

确认输出里的 `image`、`updates overlay` 和 `syncs Argo CD application` 正确后执行：

```bash
/Users/lrd/Mounts/homepc-root/data/homepcdata/k3s/kadm-platform-system/bin/kadmctl \
  publish-release-console kadm-test \
  --tag <image-tag> \
  --apply
```

也可以直接指定完整镜像：

```bash
/Users/lrd/Mounts/homepc-root/data/homepcdata/k3s/kadm-platform-system/bin/kadmctl \
  publish-release-console kadm-test \
  --image ghcr.io/ccq18/kadm-platform-system:<image-tag> \
  --apply
```

`--apply` 会执行以下动作：

```text
更新 console/k8s/overlays/prod/kustomization.yaml 的 newName/newTag
提交 chore: release kadm-platform-system <image-tag>
push 到 origin main
触发 Argo CD Application kadm-platform-system sync
等待 kadm namespace 下的 kadm Deployment ready
```

执行前要求：

```text
本地 kadm-platform-system 工作区干净
本地 HEAD 已经和 origin/main 一致
本地 kubeconfig 能访问目标集群
目标镜像已经存在于 GHCR，且集群具备拉取权限
```

### 查看 GitOps 期望版本

GitOps 期望发布系统使用的镜像 tag 写在：

```text
kadm-platform-system/console/k8s/overlays/prod/kustomization.yaml
```

查看命令：

```bash
sed -n '1,80p' /Users/lrd/Mounts/homepc-root/data/homepcdata/k3s/kadm-platform-system/console/k8s/overlays/prod/kustomization.yaml
```

重点看：

```yaml
images:
- name: ghcr.io/ccq18/kadm-platform-system
  newName: ghcr.io/ccq18/kadm-platform-system
  newTag: <image-tag>
```

### 查看集群实际运行版本

查看当前集群里实际运行的发布系统镜像：

```bash
/Applications/Docker.app/Contents/Resources/bin/kubectl \
  --kubeconfig=/Users/lrd/.kube/kadm/kadm-test.yaml \
  -n kadm get deploy kadm \
  -o jsonpath='{.spec.template.spec.containers[*].image}{"\n"}'
```

等待发布系统滚动更新完成：

```bash
/Applications/Docker.app/Contents/Resources/bin/kubectl \
  --kubeconfig=/Users/lrd/.kube/kadm/kadm-test.yaml \
  -n kadm rollout status deploy/kadm
```

### 常见判断口径

| 想确认什么 | 去哪里看 |
|---|---|
| CI 有没有构建成功 | GitHub Actions 的 `Build Platform System Image` |
| CI 构建出了哪个镜像 | GitHub Actions 运行日志里的 `Print image` |
| GHCR 里有哪些可用镜像 tag | GitHub Packages / GHCR versions 页面 |
| GitOps 期望发布哪个 tag | `console/k8s/overlays/prod/kustomization.yaml` |
| 集群当前实际跑哪个 tag | `kubectl -n kadm get deploy kadm -o jsonpath=...` |

如果 GHCR 版本列表里没有新 tag，先确认代码是否已经 commit 并 push 到 GitHub；本地文件修改不会触发 GitHub Actions。
