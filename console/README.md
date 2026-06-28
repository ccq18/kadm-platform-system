# KADM Release Console

KADM Release Console 是 KADM 的内部发布控制台。它面向当前两个示例应用：

- `demo-hello`
- `demo-hello-spring`

它协调三类系统：

- GitHub Actions：触发应用镜像构建并读取工作流状态
- `kadm-app-configs`：更新生产 GitOps image tag
- Argo CD / Argo Rollouts：同步应用并控制发布切换

Release Console 默认只作为 ClusterIP 内部服务部署。没有认证、HTTPS 和访问策略前，不要暴露公网入口。

## 仓库边界

| 仓库 | Release Console 如何使用 |
| --- | --- |
| 应用源码仓库 | 触发 `build-and-publish.yaml`，等待镜像构建完成 |
| `kadm-app-configs` | 更新 `apps/<app>/overlays/prod/kustomization.yaml` |
| `kadm-platform-system/console` | 保存控制台代码和自己的部署 overlay |

应用生产 Kubernetes YAML 不在应用源码仓库中维护。

## 本地开发

```bash
npm ci
cp .env.example .env
cp config/apps.example.json config/apps.json
npm run dev
```

环境变量见 `docs/configuration.md`。

## 集群访问

推荐通过 `kadmctl` 建立 tunnel：

```bash
kadmctl connect <cluster>
```

也可以使用 kubectl port-forward：

```bash
kubectl -n kadm port-forward svc/kadm 18080:80
```

打开：

```text
http://127.0.0.1:18080
```

## API

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/api/apps` | List configured apps |
| `GET` | `/api/apps/:id/status` | Read GitHub, Argo CD, Rollout, task, and version state |
| `GET` | `/api/apps/:id/versions` | Read stable/current/candidate version hints |
| `POST` | `/api/apps/:id/release` | Build image, update GitOps, sync, and wait for rollout check |
| `POST` | `/api/apps/:id/release/cancel` | Cancel the in-memory publish task |
| `POST` | `/api/apps/:id/promote` | Promote the current candidate version |
| `POST` | `/api/apps/:id/rollout/abort` | Abort the Rollout |
| `POST` | `/api/apps/:id/rollout/restart` | Restart Rollout pods |
| `GET` | `/api/cluster` | Read cluster node summary |
| `POST` | `/api/cluster/join-script` | Generate a K3s join script |

## 文档

- `docs/architecture.md`
- `docs/configuration.md`
- `docs/deploy.md`

---

# KADM Release Console

KADM Release Console is the internal release console for KADM. It currently targets two demo applications:

- `demo-hello`
- `demo-hello-spring`

It coordinates three systems:

- GitHub Actions: trigger application image builds and read workflow status
- `kadm-app-configs`: update production GitOps image tags
- Argo CD / Argo Rollouts: sync applications and control promotion

Release Console is deployed as a ClusterIP-only internal service by default. Do not expose it publicly before authentication, HTTPS, and an access policy are in place.

## Repository Boundary

| Repository | How Release Console uses it |
| --- | --- |
| Application source repositories | Trigger `build-and-publish.yaml` and wait for the image build |
| `kadm-app-configs` | Update `apps/<app>/overlays/prod/kustomization.yaml` |
| `kadm-platform-system/console` | Store console code and its own deployment overlay |

Production application Kubernetes YAML is not maintained in application source repositories.

## Local Development

```bash
npm ci
cp .env.example .env
cp config/apps.example.json config/apps.json
npm run dev
```

Environment variables are documented in `docs/configuration.md`.

## Cluster Access

Prefer the `kadmctl` tunnel:

```bash
kadmctl connect <cluster>
```

Or use kubectl port-forward:

```bash
kubectl -n kadm port-forward svc/kadm 18080:80
```

Open:

```text
http://127.0.0.1:18080
```

## API

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/api/apps` | List configured apps |
| `GET` | `/api/apps/:id/status` | Read GitHub, Argo CD, Rollout, task, and version state |
| `GET` | `/api/apps/:id/versions` | Read stable/current/candidate version hints |
| `POST` | `/api/apps/:id/release` | Build image, update GitOps, sync, and wait for rollout check |
| `POST` | `/api/apps/:id/release/cancel` | Cancel the in-memory publish task |
| `POST` | `/api/apps/:id/promote` | Promote the current candidate version |
| `POST` | `/api/apps/:id/rollout/abort` | Abort the Rollout |
| `POST` | `/api/apps/:id/rollout/restart` | Restart Rollout pods |
| `GET` | `/api/cluster` | Read cluster node summary |
| `POST` | `/api/cluster/join-script` | Generate a K3s join script |
