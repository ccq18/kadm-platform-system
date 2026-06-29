# 实施任务清单

> 由 spec.md、implementation-plan.md、cluster-growth-path.md、network-architecture.md 生成  
> 任务总数: 8  
> 核心原则: 先建后迁后删——先建立本地可审阅自动化骨架和配置契约，再实现单节点安装、HA 升级、Worker 扩容和应用模板迁移。

## 依赖关系总览

```text
Task 1 (平台自动化目录与配置契约)
  ↓
Task 2 (节点预检与 ClusterSpec 渲染)
  ↓
Task 3 (单节点安装与健康检查)
  ↓
Task 4 (GitOps bootstrap 与应用资源模板)
  ↓
Task 5 (demo 应用模板迁移到可成长默认约束)
  ↓
Task 6 (Operation 状态机与 1 -> 3 HA 升级骨架)
  ↓
Task 7 (Worker 扩容与受控再均衡骨架)
  ↓
Task 8 (备份恢复、诊断与验收脚本)
```

## 变更影响概览

### 文件变更清单

| 文件 | 操作 | 涉及任务 | 说明 |
| --- | --- | --- | --- |
| `ops/platform/README.md` | 新建 | Task 1 | 平台自动化入口和安全说明 |
| `ops/platform/config/cluster.env.example` | 新建 | Task 1 | ClusterSpec 的 env 示例，不含真实密钥 |
| `ops/platform/templates/k3s-server-config.yaml` | 新建 | Task 1, 3 | K3s Server 默认配置模板 |
| `ops/platform/templates/cilium-values.yaml` | 新建 | Task 1, 3 | Cilium 默认 values 模板 |
| `docs/design-docs/platform/production-k3s-release-platform/reviews/task1-review.md` | 新建 | Task 1 | Task 1 本地静态 review 与验收记录 |
| `ops/platform/templates/public-gateway.yaml` | 新建 | Task 4 | Gateway API Host Network 入口示例 |
| `ops/platform/bin/lib.sh` | 新建 | Task 2 | shell 脚本公共函数 |
| `ops/platform/bin/preflight-node.sh` | 新建 | Task 2 | 节点预检 |
| `ops/platform/bin/render-cluster-spec.sh` | 新建 | Task 2 | 从 env 渲染本地 ClusterSpec 摘要 |
| `ops/platform/bin/install-single-server.sh` | 新建 | Task 3 | 单节点安装流程骨架，默认 dry-run |
| `ops/platform/bin/check-cluster-health.sh` | 新建 | Task 3 | K3s / Cilium / Gateway / Argo 健康检查 |
| `ops/platform/gitops/bootstrap/` | 新建 | Task 4 | bootstrap 资源目录 |
| `ops/platform/templates/app/` | 新建 | Task 4 | 默认应用资源模板 |
| `hello/k8s/deployment.yaml` | 修改 | Task 5 | topologySpreadConstraints 调整为单节点可调度 |
| `hellospring/k8s/deployment.yaml` | 修改 | Task 5 | topologySpreadConstraints 调整为单节点可调度 |
| `hello/k8s/pdb.yaml` | 新建 | Task 5 | hello PDB |
| `hellospring/k8s/pdb.yaml` | 新建 | Task 5 | hellospring PDB |
| `ops/platform/state/README.md` | 新建 | Task 6 | Operation 状态目录说明 |
| `ops/platform/bin/operation.sh` | 新建 | Task 6 | 持久 Operation 状态读写工具 |
| `ops/platform/bin/upgrade-ha.sh` | 新建 | Task 6 | `1 -> 3` HA 升级状态机骨架，默认 dry-run |
| `ops/platform/bin/add-worker.sh` | 新建 | Task 7 | Worker 加入骨架，默认 dry-run |
| `ops/platform/bin/rebalance-workloads.sh` | 新建 | Task 7 | 受控再均衡骨架，默认 dry-run |
| `ops/platform/bin/backup-etcd.sh` | 新建 | Task 8 | etcd 快照与远程保存骨架 |
| `ops/platform/bin/diagnose-app.sh` | 新建 | Task 8 | 基础诊断规则 |
| `ops/platform/bin/acceptance.sh` | 新建 | Task 8 | 本地静态验收入口 |

### 受影响接口

| 接口 | 变更类型 | 调用方 | 涉及任务 |
| --- | --- | --- | --- |
| `ops/platform/bin/*.sh` CLI | 新增 | 运维人员、本地执行脚本、未来 OneCD 后端 | Task 2-8 |
| Kubernetes 应用模板 | 变更 | Argo CD、Kubernetes 调度器、平台再均衡流程 | Task 4-5 |
| Operation 状态文件 | 新增 | `upgrade-ha.sh`、未来 OneCD 后端 | Task 6 |

### 构建系统变更

- 暂无统一构建系统变更。
- shell 脚本验收使用 `bash -n ops/platform/bin/*.sh`。
- YAML 模板先使用 `rg` 做关键字段静态检查；后续可引入 `kubectl --dry-run=client` 或 YAML lint。

## 风险与假设

| # | 描述 | 影响任务 | 假设/处理 |
| --- | --- | --- | --- |
| 1 | 当前仓库不是 git 仓库，无法使用分支/worktree 隔离 | 全部 | 不执行 git 操作；只改工作区文件 |
| 2 | 当前只有 k3s 运维仓库，没有 OneCD 源码 | Task 2-8 | 先用本地 shell CLI 和模板落自动化骨架，未来再接入 OneCD 后端 |
| 3 | 真实远程 ECS 操作有破坏性 | Task 3、6、7、8 | 所有安装/扩容/备份脚本默认 dry-run，真实执行必须显式传入 `--apply` |
| 4 | K3s、Cilium、Gateway API 版本需实施前复核 | Task 1、3、4 | 配置模板提供变量和默认占位，不写死不可验证版本 |
| 5 | 现有 demo Deployment 使用 `DoNotSchedule`，单节点会和固定成长路径冲突 | Task 5 | 改为 `ScheduleAnyway`，并补 PDB |
| 6 | P3 要求持久 Operation，但第一阶段没有门户数据库 | Task 6 | 先实现文件型状态目录，后续可迁移到数据库 |

## 任务列表

### 任务 1: [x] 平台自动化目录与配置契约

- 文件:
  - `ops/platform/README.md`（新建）
  - `ops/platform/config/cluster.env.example`（新建）
  - `ops/platform/templates/k3s-server-config.yaml`（新建）
  - `ops/platform/templates/cilium-values.yaml`（新建）
  - `docs/design-docs/platform/production-k3s-release-platform/reviews/task1-review.md`（新建）
- 依赖: 无
- spec 映射: `spec.md` 2 目标、3.1 基础设施与集群、3.1 底层 Provider 边界；`implementation-plan.md` P0、P1
- 说明: 建立平台自动化文件结构和集群级配置契约，只提供模板和说明，不执行真实部署。
- context:
  - `docs/design-docs/platform/production-k3s-release-platform/spec.md` — 目标和约束来源
  - `docs/design-docs/platform/production-k3s-release-platform/implementation-plan.md` — 实施阶段来源
  - `docs/design-docs/platform/production-k3s-release-platform/cluster-growth-path.md` — 单节点和 HA 约束来源
  - `docs/design-docs/platform/production-k3s-release-platform/network-architecture.md` — K3s/Cilium/Gateway 配置来源
- 验收标准:
  - [x] `test -f ops/platform/README.md`
  - [x] `test -f ops/platform/config/cluster.env.example`
  - [x] `rg -n "cluster-init: true|disable-kube-proxy: true|servicelb|traefik" ops/platform/templates/k3s-server-config.yaml`
  - [x] `rg -n "kubeProxyReplacement|gatewayAPI|hostNetwork|operator:" ops/platform/templates/cilium-values.yaml`
  - [x] `rg -n "DRY_RUN|--apply|不包含真实密钥" ops/platform/README.md ops/platform/config/cluster.env.example`
  - [x] Task 1 本地静态 review PASS，记录见 `reviews/task1-review.md`
- 子任务:
  - [x] 1.1: 创建 `ops/platform/` 目录结构。
  - [x] 1.2: 编写 `cluster.env.example`，包含 cluster id、CIDR、DNS、版本、节点、备份目标等占位变量。
  - [x] 1.3: 编写 K3s Server 配置模板，第一台默认 `cluster-init: true`。
  - [x] 1.4: 编写 Cilium values 模板，默认 kube-proxy replacement、Gateway API、Host Network。
  - [x] 1.5: 编写 README，说明默认 dry-run 和禁止提交真实密钥。

### 任务 2: [ ] 节点预检与 ClusterSpec 渲染

- 文件:
  - `ops/platform/bin/lib.sh`（新建）
  - `ops/platform/bin/preflight-node.sh`（新建）
  - `ops/platform/bin/render-cluster-spec.sh`（新建）
- 依赖: Task 1
- spec 映射: `spec.md` 3.1 自动化黄金路径、3.1 基础设施与集群；`implementation-plan.md` P0、P1、P3 预检
- 说明: 实现本地可运行的预检和配置摘要工具，为安装和扩容提供统一输入校验。
- context:
  - `ops/platform/config/cluster.env.example` — 配置输入样例
  - `ops/platform/templates/k3s-server-config.yaml` — 需要校验的关键配置
  - `docs/design-docs/platform/production-k3s-release-platform/implementation-plan.md` — P0/P3 预检项
- 验收标准:
  - [ ] `bash -n ops/platform/bin/lib.sh ops/platform/bin/preflight-node.sh ops/platform/bin/render-cluster-spec.sh`
  - [ ] `ops/platform/bin/render-cluster-spec.sh --env ops/platform/config/cluster.env.example --dry-run` 输出 `clusterId`、`clusterCIDR`、`serviceCIDR`
  - [ ] `ops/platform/bin/preflight-node.sh --host 127.0.0.1 --dry-run` 输出磁盘、端口、时间同步、SSH 连通性检查项名称
  - [ ] `rg -n "clusterCIDR|serviceCIDR|clusterDNS|serverToken|backup" ops/platform/bin/render-cluster-spec.sh`
- 子任务:
  - [ ] 2.1: 编写 `lib.sh`，包含日志、错误、dry-run、参数校验、命令存在性检查。
  - [ ] 2.2: 编写 `render-cluster-spec.sh`，从 env 读取并输出无密钥摘要。
  - [ ] 2.3: 编写 `preflight-node.sh`，默认 dry-run，列出 SSH、私网、磁盘、端口、时间同步、系统参数检查。
  - [ ] 2.4: 所有脚本支持 `--help`。

### 任务 3: [ ] 单节点安装与健康检查骨架

- 文件:
  - `ops/platform/bin/install-single-server.sh`（新建）
  - `ops/platform/bin/check-cluster-health.sh`（新建）
  - `ops/platform/README.md`（修改）
- 依赖: Task 2
- spec 映射: `spec.md` 3.1 自动化黄金路径、3.1 基础设施与集群、3.2 可用性；`implementation-plan.md` P1
- 说明: 落地 P1 单节点起步闭环脚本骨架，真实执行必须显式 `--apply`。
- context:
  - `ops/platform/bin/lib.sh` — 公共函数
  - `ops/platform/bin/preflight-node.sh` — 安装前预检
  - `ops/platform/templates/k3s-server-config.yaml` — 安装配置模板
  - `ops/platform/templates/cilium-values.yaml` — Cilium 配置模板
- 验收标准:
  - [ ] `bash -n ops/platform/bin/install-single-server.sh ops/platform/bin/check-cluster-health.sh`
  - [ ] `ops/platform/bin/install-single-server.sh --env ops/platform/config/cluster.env.example --dry-run` 输出 K3s、Cilium、Argo CD、Rollouts、OneCD 的计划步骤
  - [ ] `ops/platform/bin/check-cluster-health.sh --dry-run` 输出 API、etcd、Node、Cilium、Gateway、Argo CD、Rollouts、OneCD 检查项
  - [ ] `rg -n "--apply|dry-run|cluster-init|embedded etcd" ops/platform/bin/install-single-server.sh ops/platform/README.md`
- 子任务:
  - [ ] 3.1: 编写单节点安装 dry-run 计划输出。
  - [ ] 3.2: 编写健康检查 dry-run 计划输出。
  - [ ] 3.3: README 补充 P1 执行顺序和真实执行保护。

### 任务 4: [ ] GitOps bootstrap 与默认应用资源模板

- 文件:
  - `ops/platform/gitops/bootstrap/README.md`（新建）
  - `ops/platform/gitops/bootstrap/namespaces.yaml`（新建）
  - `ops/platform/templates/public-gateway.yaml`（新建）
  - `ops/platform/templates/app/deployment.yaml`（新建）
  - `ops/platform/templates/app/service.yaml`（新建）
  - `ops/platform/templates/app/httproute.yaml`（新建）
  - `ops/platform/templates/app/pdb.yaml`（新建）
- 依赖: Task 3
- spec 映射: `spec.md` 3.1 GitOps 与仓库边界、3.1 流量入口与渐进式发布、3.1 应用资源契约；`gitops-boundary.md` Product Surface Boundary
- 说明: 建立平台默认 GitOps 和应用资源模板，不替换现有 demo 应用，先并存。
- context:
  - `hello/k8s/*.yaml` — 当前 demo 资源形态
  - `hellospring/k8s/*.yaml` — 当前 demo 资源形态
  - `docs/design-docs/platform/production-k3s-release-platform/gitops-boundary.md` — GitOps 边界
  - `docs/design-docs/platform/production-k3s-release-platform/network-architecture.md` — Gateway / HTTPRoute 入口模型
- 验收标准:
  - [ ] `test -f ops/platform/templates/app/deployment.yaml`
  - [ ] `rg -n "topologySpreadConstraints|ScheduleAnyway|readinessProbe|maxUnavailable: 0|maxSurge: 1" ops/platform/templates/app/deployment.yaml`
  - [ ] `rg -n "kind: Gateway|gatewayClassName: cilium|port: 8080|port: 8443" ops/platform/templates/public-gateway.yaml`
  - [ ] `rg -n "kind: HTTPRoute|parentRefs|backendRefs" ops/platform/templates/app/httproute.yaml`
  - [ ] `! rg -n "CiliumNetworkPolicy|CiliumEnvoyConfig|CiliumBGPPeeringPolicy|CiliumEgressGatewayPolicy" ops/platform/templates/app ops/platform/gitops/bootstrap`
- 子任务:
  - [ ] 4.1: 创建 bootstrap 命名空间资源。
  - [ ] 4.2: 创建默认 Gateway 模板。
  - [ ] 4.3: 创建默认应用 Deployment / Service / HTTPRoute / PDB 模板。
  - [ ] 4.4: README 说明这些模板是新路径，现有 demo 迁移在 Task 5。

### 任务 5: [ ] demo 应用模板迁移到可成长默认约束

- 文件:
  - `hello/k8s/deployment.yaml`（修改）
  - `hellospring/k8s/deployment.yaml`（修改）
  - `hello/k8s/pdb.yaml`（新建）
  - `hellospring/k8s/pdb.yaml`（新建）
  - `hello/k8s/README.md`（修改）
  - `hellospring/README.md`（修改）
- 依赖: Task 4
- spec 映射: `spec.md` 3.1 应用资源契约；`cluster-growth-path.md` 业务工作负载需要受控再均衡、零停机条件
- 说明: 让现有 demo 应用符合单节点可调度、多节点优先分散、可受控再均衡的默认约束。
- context:
  - `hello/k8s/deployment.yaml` — 当前 Node demo Deployment，现有 `DoNotSchedule` 需要调整
  - `hellospring/k8s/deployment.yaml` — 当前 Spring demo Deployment，现有 `DoNotSchedule` 需要调整
  - `ops/platform/templates/app/deployment.yaml` — 新默认模板
- 验收标准:
  - [ ] `rg -n "whenUnsatisfiable: ScheduleAnyway" hello/k8s/deployment.yaml hellospring/k8s/deployment.yaml`
  - [ ] `rg -n "maxUnavailable: 0|maxSurge: 1" hello/k8s/deployment.yaml hellospring/k8s/deployment.yaml`
  - [ ] `test -f hello/k8s/pdb.yaml && test -f hellospring/k8s/pdb.yaml`
  - [ ] `rg -n "kind: PodDisruptionBudget|minAvailable" hello/k8s/pdb.yaml hellospring/k8s/pdb.yaml`
  - [ ] `rg -n "单节点|多节点|再均衡|ScheduleAnyway" hello/k8s/README.md hellospring/README.md`
- 子任务:
  - [ ] 5.1: 将两个 demo 的 topology spread 改为 `ScheduleAnyway`。
  - [ ] 5.2: 补充滚动发布策略 `maxUnavailable: 0` / `maxSurge: 1`。
  - [ ] 5.3: 为两个 demo 添加 PDB。
  - [ ] 5.4: 更新 README，解释单节点和多节点行为。

### 任务 6: [ ] Operation 状态机与 `1 -> 3` HA 升级骨架

- 文件:
  - `ops/platform/state/README.md`（新建）
  - `ops/platform/bin/operation.sh`（新建）
  - `ops/platform/bin/upgrade-ha.sh`（新建）
- 依赖: Task 5
- spec 映射: `spec.md` 3.1 自动化黄金路径、3.1 基础设施与集群、3.2 可用性；`implementation-plan.md` P3
- 说明: 引入文件型 Operation 状态和 HA 升级状态机骨架，为未来接入 OneCD 后端做准备。
- context:
  - `ops/platform/bin/lib.sh` — 公共函数
  - `ops/platform/bin/preflight-node.sh` — 新 Server 预检
  - `ops/platform/bin/check-cluster-health.sh` — 升级后检查
  - `docs/design-docs/platform/production-k3s-release-platform/implementation-plan.md` — P3 状态机定义
- 验收标准:
  - [ ] `bash -n ops/platform/bin/operation.sh ops/platform/bin/upgrade-ha.sh`
  - [ ] `ops/platform/bin/operation.sh create --type ha-upgrade --cluster test --dry-run` 输出 operation id 和状态路径
  - [ ] `ops/platform/bin/upgrade-ha.sh --env ops/platform/config/cluster.env.example --server2 10.0.0.12 --server3 10.0.0.13 --dry-run` 按顺序输出 Preflight、SnapshotEtcd、JoinSecondServer、JoinThirdServer、ValidateEtcdQuorum、ValidateKubeAPI、ValidateCilium、ValidateGateway、ScaleSystemComponents、RebalanceWorkloads、UpdateEntrypoints
  - [ ] `rg -n "FailedRecoverable|FailedManualIntervention|2/3|not.*HA|不是高可用" ops/platform/bin/upgrade-ha.sh ops/platform/state/README.md`
- 子任务:
  - [ ] 6.1: 定义文件型 Operation 状态目录和 JSON/kv 状态格式。
  - [ ] 6.2: 编写 `operation.sh` create / update / show dry-run 能力。
  - [ ] 6.3: 编写 `upgrade-ha.sh` 状态机 dry-run 步骤。
  - [ ] 6.4: 明确 Server 2 成功、Server 3 失败时的人工接管提示。

### 任务 7: [ ] Worker 扩容与受控再均衡骨架

- 文件:
  - `ops/platform/bin/add-worker.sh`（新建）
  - `ops/platform/bin/rebalance-workloads.sh`（新建）
  - `ops/platform/README.md`（修改）
- 依赖: Task 6
- spec 映射: `spec.md` 3.1 自动化黄金路径、3.1 应用资源契约；`cluster-growth-path.md` 超过 3 台以后默认只加 Worker、业务工作负载需要受控再均衡
- 说明: 落 Worker 加入和再均衡命令骨架，默认 dry-run，不真实驱逐 Pod。
- context:
  - `ops/platform/bin/preflight-node.sh` — Worker 预检
  - `ops/platform/bin/check-cluster-health.sh` — 节点和 Cilium 检查
  - `hello/k8s/deployment.yaml`、`hellospring/k8s/deployment.yaml` — demo 再均衡目标
- 验收标准:
  - [ ] `bash -n ops/platform/bin/add-worker.sh ops/platform/bin/rebalance-workloads.sh`
  - [ ] `ops/platform/bin/add-worker.sh --env ops/platform/config/cluster.env.example --worker 10.0.0.21 --dry-run` 输出 Agent Worker 加入、Node Ready、Cilium Ready、开放调度步骤
  - [ ] `ops/platform/bin/rebalance-workloads.sh --namespace apps --dry-run` 输出逐应用、逐 Pod、先建新 Pod、等待 Ready、再删旧 Pod 的计划
  - [ ] `rg -n "replicas.*2|single replica|单副本|暂停|Ready" ops/platform/bin/rebalance-workloads.sh`
- 子任务:
  - [ ] 7.1: 编写 Worker 加入 dry-run 步骤。
  - [ ] 7.2: 编写再均衡 dry-run 策略。
  - [ ] 7.3: README 补充 Worker 扩容与再均衡入口。

### 任务 8: [ ] 备份恢复、诊断与验收脚本

- 文件:
  - `ops/platform/bin/backup-etcd.sh`（新建）
  - `ops/platform/bin/diagnose-app.sh`（新建）
  - `ops/platform/bin/acceptance.sh`（新建）
  - `ops/platform/README.md`（修改）
- 依赖: Task 7
- spec 映射: `spec.md` 3.1 回滚与恢复、3.2 可观测性与审计、3.2 备份与演练；`implementation-plan.md` P5、验收矩阵
- 说明: 补齐第一版最小备份、诊断和验收入口。
- context:
  - `ops/platform/bin/check-cluster-health.sh` — 健康检查复用
  - `docs/design-docs/platform/production-k3s-release-platform/implementation-plan.md` — 验收矩阵
  - `docs/troubleshooting.md` — 现有排障文档
- 验收标准:
  - [ ] `bash -n ops/platform/bin/backup-etcd.sh ops/platform/bin/diagnose-app.sh ops/platform/bin/acceptance.sh`
  - [ ] `ops/platform/bin/backup-etcd.sh --env ops/platform/config/cluster.env.example --dry-run` 输出 snapshot、checksum、upload、server token 提醒
  - [ ] `ops/platform/bin/diagnose-app.sh --namespace apps --app hello --dry-run` 输出 Pod Pending、ImagePullBackOff、CrashLoopBackOff、Readiness failed、Service endpoint、HTTPRoute 检查项
  - [ ] `ops/platform/bin/acceptance.sh --dry-run` 输出单节点安装、应用发布、1 -> 3 HA、Worker 扩容、再均衡、etcd 备份的验收项
  - [ ] `rg -n "snapshot|checksum|Server Token|Pod Pending|ImagePullBackOff|CrashLoopBackOff|HTTPRoute" ops/platform/bin`
- 子任务:
  - [ ] 8.1: 编写 etcd 备份 dry-run 脚本。
  - [ ] 8.2: 编写应用诊断 dry-run 脚本。
  - [ ] 8.3: 编写 acceptance 汇总脚本。
  - [ ] 8.4: README 补充备份、诊断、验收说明。

## Spec 覆盖映射

| Spec / 设计章节 | 任务 | 说明 |
| --- | --- | --- |
| `spec.md` 2 目标 | Task 1-8 | 固定成长路径、GitOps、默认自建路径、普通/高级模式 |
| `spec.md` 3.1 产品模型与用户体验 | Task 2、3、8 | CLI 骨架先服务高级/运维入口，未来接 UI |
| `spec.md` 3.1 自动化黄金路径 | Task 2、3、6、7、8 | 节点预检、单节点、HA、Worker、验收 |
| `spec.md` 3.1 基础设施与集群 | Task 1、2、3、6、7 | ClusterSpec、K3s embedded etcd、Cilium、Server/Worker |
| `spec.md` 3.1 底层 Provider 边界 | Task 1、4 | 保留内部边界，不暴露普通用户选择 |
| `spec.md` 3.1 GitOps 与仓库边界 | Task 4、5 | bootstrap 和应用模板 |
| `spec.md` 3.1 流量入口与渐进式发布 | Task 3、4、5 | Gateway / HTTPRoute / demo 模板 |
| `spec.md` 3.1 应用资源契约 | Task 4、5、7 | 标准资源、ScheduleAnyway、PDB、再均衡 |
| `spec.md` 3.1 CI 与镜像 | Task 4、5 | 保持 GitHub Actions / GHCR 既有边界，不改 CI |
| `spec.md` 3.1 发布门户 | Task 2、6、8 | 先以 CLI 和状态文件实现未来门户后端能力 |
| `spec.md` 3.1 回滚与恢复 | Task 8 | etcd 备份、诊断、验收 |
| `spec.md` 3.1 升级与验收 | Task 6、7、8 | HA、Worker、acceptance |
| `cluster-growth-path.md` 单节点 embedded etcd | Task 1、3 | K3s 模板和单节点安装 |
| `cluster-growth-path.md` 1 到 3 原子化 | Task 6 | Operation 状态机 |
| `cluster-growth-path.md` Worker 扩容与再均衡 | Task 7 | Worker 加入和再均衡 |
| `network-architecture.md` 默认网络结构 | Task 1、3、4 | Cilium / Gateway 模板 |
| `gitops-boundary.md` GitOps 边界 | Task 4、5 | GitOps bootstrap 和应用模板 |
| `implementation-plan.md` P0-P6 | Task 1-8 | 第一版覆盖 P0-P5 骨架，P6 暂以迁移边界保留在文档 |
