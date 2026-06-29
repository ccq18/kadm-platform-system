# KADM 发布系统

KADM 当前发布链路由 Release Console、GitHub Actions、`kadm-app-configs`、Argo CD 和 Argo Rollouts 组成。

## 仓库职责

| 仓库 | 职责 |
| --- | --- |
| `kadm-platform-system/console` | 发布控制台 Web/API，触发构建、更新 GitOps、同步 Argo CD、执行 promote/abort |
| `kadm-app-configs` | 生产应用 GitOps 配置和 image tag |
| `demo-hello` | Node.js 示例应用源码和镜像构建 |
| `demo-hello-spring` | Spring Boot 示例应用源码和镜像构建 |

应用源码仓库不再维护生产 Kubernetes YAML。生产部署入口统一在：

```text
kadm-app-configs/apps/demo-hello/overlays/prod
kadm-app-configs/apps/demo-hello-spring/overlays/prod
```

## 发布流程

```text
KADM Release Console
  -> GitHub Actions build image
  -> GHCR stores image
  -> update kadm-app-configs image tag
  -> Argo CD sync
  -> Argo Rollouts waits at switch point
  -> operator promotes
```

## 访问方式

控制台默认不暴露公网。使用本机 tunnel：

```bash
~/.local/bin/kadmctl connect kadm-test
```

打开：

```text
http://127.0.0.1:18080
```

## 凭据

不要在文档、命令历史或 Git 仓库中写入真实 token。运行时通过环境变量提供：

```bash
export KADM_GITHUB_TOKEN=<github-token>
export KADM_GHCR_USERNAME=<github-user>
export KADM_GHCR_TOKEN=<ghcr-token>
```

## 离线边界

平台离线包包含平台组件运行镜像和安装缓存，不包含业务应用镜像。业务应用镜像由应用仓库 CI 推送到 GHCR。完全离线应用分发应独立构建应用镜像包。

---

# KADM Release System

The current KADM release flow is built from Release Console, GitHub Actions, `kadm-app-configs`, Argo CD, and Argo Rollouts.

## Repository Responsibilities

| Repository | Responsibility |
| --- | --- |
| `kadm-platform-system/console` | Release Console Web/API for build trigger, GitOps update, Argo CD sync, promote, and abort |
| `kadm-app-configs` | Production application GitOps configuration and image tags |
| `demo-hello` | Node.js demo application source and image build |
| `demo-hello-spring` | Spring Boot demo application source and image build |

Application source repositories no longer maintain production Kubernetes YAML. Production deployment entrypoints are:

```text
kadm-app-configs/apps/demo-hello/overlays/prod
kadm-app-configs/apps/demo-hello-spring/overlays/prod
```

## Release Flow

```text
KADM Release Console
  -> GitHub Actions build image
  -> GHCR stores image
  -> update kadm-app-configs image tag
  -> Argo CD sync
  -> Argo Rollouts waits at switch point
  -> operator promotes
```

## Access

The console is not exposed publicly by default. Use the local tunnel:

```bash
~/.local/bin/kadmctl connect kadm-test
```

Open:

```text
http://127.0.0.1:18080
```

## Credentials

Do not write real tokens in documentation, shell history, or Git repositories. Provide runtime credentials through environment variables:

```bash
export KADM_GITHUB_TOKEN=<github-token>
export KADM_GHCR_USERNAME=<github-user>
export KADM_GHCR_TOKEN=<ghcr-token>
```

## Offline Boundary

The platform offline bundle includes platform runtime images and installer cache. It does not include business application images. Application images are pushed to GHCR by application repository CI. Fully offline application distribution should use a separate application image bundle.
