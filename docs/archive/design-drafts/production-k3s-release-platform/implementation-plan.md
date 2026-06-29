# Implementation Plan

**日期**: 2026-06-26  
**状态**: Draft  
**范围**: 从当前测试集群落地到“单节点起步、三节点 HA、Worker 横向扩容”的应用交付平台

## 实施目标

本实施方案把前面的产品和架构设计落成可执行路线。第一版不追求通用可插拔平台，而是优先打穿一条固定黄金路径：

```text
1 Server
-> 3 Server HA
-> 3 Server + N Worker
-> 必要时迁移到托管 Kubernetes
```

用户侧保持稳定：

```text
应用
环境
版本
域名
发布
日志
回滚
```

平台侧承担复杂度：

```text
节点预检
K3s 安装
Cilium 安装
Gateway 安装
Argo CD bootstrap
1 -> 3 HA 升级
Worker 扩容
受控再均衡
健康诊断
etcd 备份恢复
```

## 实施原则

- 先打通固定路径，再扩展企业能力。
- 先做可验证的自动化闭环，再做漂亮的 UI。
- 所有长任务必须可重试、可恢复、可审计。
- 集群真实状态以 Kubernetes、etcd、Argo CD、Rollout CRD、Gateway / HTTPRoute 和 GitOps 仓库为准。
- 普通用户不选择 CNI、Service Dataplane、Gateway Controller、IPAM、Server / Agent 参数。
- 双 Server 只作为 `1 -> 3` 升级过程中的短暂中间态，不作为产品长期形态。
- 任何阶段没有验收通过，不进入下一阶段。

## 阶段总览

| 阶段 | 目标 | 用户可见价值 | 进入下一阶段的门槛 |
| --- | --- | --- | --- |
| P0 准备与基线 | 明确版本、机器、凭证、域名、备份目标和仓库边界 | 可以安全重建测试集群 | 所有前置资源和版本矩阵确认 |
| P1 单节点起步闭环 | 1 台 ECS 跑起 K3s embedded etcd + Cilium + Gateway + Argo CD + OneCD | 一台机器可发布应用 | 单节点安装、发布、回滚、备份通过 |
| P2 应用交付 MVP | 应用模型、模板、Build / Sync / Promote / Abort、基础诊断 | 普通研发能按应用视角发布 | 两个 demo 应用通过完整发布链路 |
| P3 1 -> 3 HA 升级 | 自动加入 Server 2 / Server 3，形成三成员 etcd | 点击升级为高可用 | 任意 1 台 Server 故障后业务和控制面可用 |
| P4 Worker 扩容与再均衡 | 添加 Worker、健康门禁、受控再均衡、容量建议 | 业务增长后直接加机器 | 新 Worker 可承载业务，旧节点负载可受控迁移 |
| P5 生产治理增强 | 安全、审计、监控、告警、恢复演练、升级策略 | 接近生产可用平台 | 备份恢复、升级演练、故障演练通过 |
| P6 托管 Kubernetes 迁移 | 新建 ACK / EKS / GKE，GitOps 重建应用，切入口 | 保留发布体验，替换运行集群 | 应用、镜像、GitOps、发布界面不变 |

## P0 准备与基线

### 目标

在动手重建前，把不可逆决策和外部资源准备好。

### 任务

- 确认当前测试集群可以清空重建。
- 确认是否需要导出旧 worker 上的本地 MySQL 或其他测试数据。
- 确认三台初始 ECS 的规格、地域、VPC、私网网段和安全组。
- 确认后续 Worker 节点的同 VPC 私网连通方式。
- 确认域名策略：
  - 起步阶段是否使用 `ECS-1:8080/8443`。
  - 三节点阶段是否使用 DNS 多 A 记录。
  - 是否提前预留 SLB / NLB。
- 确认对象存储或远程备份位置，用于 etcd 快照和灾备材料。
- 确认镜像仓库、GitHub Actions、GitHub deploy key、GHCR 凭证和 Argo CD repo 凭证。
- 固定版本矩阵：
  - K3s
  - Cilium
  - Gateway API CRD
  - Argo CD
  - Argo Rollouts
  - cert-manager
  - OneCD

### 产物

```text
ClusterSpec v1
K3s config baseline
Cilium values baseline
安全组端口矩阵
版本矩阵
备份目标
测试域名策略
```

### 验收

- 当前集群数据保留 / 清空策略明确。
- 三台目标 ECS 可以通过 SSH 管理。
- 三台 ECS 私网互通。
- 目标安全组规则已审查。
- 对象存储或远程备份目标可写入测试文件。
- GitHub Actions 和 Argo CD 仓库访问凭证可用。

## P1 单节点起步闭环

### 目标

先让平台从一台服务器稳定起步。单节点不是 HA，但必须使用未来可扩展的 datastore 和网络结构。

### 关键设计

第一台节点直接使用：

```yaml
cluster-init: true
```

即：

```text
K3s Server
+ 单成员 embedded etcd
```

不使用 SQLite。

### 任务

- 编写或整理单节点安装自动化：
  - 系统参数预检。
  - 私网 IP、hostname、时间同步检查。
  - 磁盘空间检查。
  - 端口占用检查。
  - K3s 安装。
  - 禁用 Flannel、内置 NetworkPolicy、kube-proxy、Traefik、ServiceLB。
- 安装 Cilium：
  - kube-proxy replacement。
  - VXLAN tunnel。
  - Gateway API enabled。
  - Host Network Gateway。
  - Cilium Operator 单副本。
- 安装 Argo CD 和 Argo Rollouts。
- 部署 OneCD。
- 配置 Gateway / HTTPRoute 基础入口。
- 配置 etcd 快照：
  - 本地生成。
  - 远程上传。
  - 保存 K3s Server Token。
- 部署 `demo-hello` 和 `demo-hello-spring`。

### 单节点健康门禁

必须全部通过：

```text
K3s API 可访问
etcd 单成员健康
Node Ready
Cilium Agent Ready
CiliumNode Ready
Gateway Listener Ready
CoreDNS Ready
Argo CD Ready
Argo Rollouts Ready
OneCD Ready
demo 应用可访问
etcd 快照可生成并远程保存
```

### 验收

- 通过 OneCD 完成一次 `Build -> Sync -> Promote`。
- 故意发布一个坏版本后可以 `Abort`。
- 永久回滚通过 GitOps 变更完成。
- 重启 OneCD 后，页面可以从 GitHub Actions、Argo CD、Rollout 和 Kubernetes 状态重新推导发布状态。
- 生成 etcd 快照并上传远程备份位置。

### 暂不做

- 生产级门户数据库。
- 审批流。
- 发布锁。
- 多租户权限。
- 完整监控平台。

## P2 应用交付 MVP

### 目标

把用户入口从 Kubernetes 对象收敛为应用交付模型。

### 产品能力

普通模式展示：

```text
应用
环境
版本
配置
域名
日志
发布
回滚
```

高级模式展示：

```text
YAML
Pod
Event
Argo CD Application
Rollout
Service
Gateway
HTTPRoute
节点和组件健康
```

### 任务

- 定义应用元数据：
  - 应用名。
  - 仓库地址。
  - 镜像仓库。
  - 环境。
  - 域名。
  - 副本数。
  - 资源 request / limit。
  - 健康检查路径。
- 生成默认应用模板：
  - Deployment 或 Rollout。
  - Service。
  - Gateway / HTTPRoute。
  - ConfigMap。
  - Secret 引用。
  - PDB。
  - HPA 预留。
  - topologySpreadConstraints。
- 更新 OneCD：
  - 应用列表。
  - Build。
  - Sync。
  - Promote。
  - Abort。
  - Restart。
  - 状态聚合。
  - 基础诊断。
- 补充诊断规则 v1：
  - Pod Pending。
  - ImagePullBackOff。
  - CrashLoopBackOff。
  - Readiness Probe failed。
  - Service 无 Endpoint。
  - HTTPRoute 未绑定 Gateway。
  - Rollout paused / degraded。

### 诊断输出格式

```text
问题:
  应用无法启动

原因:
  集群剩余内存不足

证据:
  Pod Pending
  0/3 nodes available: insufficient memory

建议:
  1. 降低内存 request
  2. 增加节点
  3. 停止不再使用的应用
```

### 验收

- 普通研发用户不需要看 Kubernetes YAML，也能完成一次发布和回滚。
- 高级模式可以定位到原始 Kubernetes 对象。
- 两个 demo 应用都使用标准模板部署。
- 默认模板不生成 Cilium 专属资源。
- 应用模板在单节点可以调度，在多节点后具备软分散能力。

## P3 1 -> 3 HA 升级

### 目标

把“升级为高可用集群”做成平台核心能力。

### 必须先补的工程能力

`1 -> 3` 是长任务，不能只存在进程内状态。进入本阶段前，平台必须具备最小持久任务模型。

建议新增：

```text
Operation
OperationStep
ClusterSpec
NodeInventory
PreflightReport
BackupRecord
```

如果当前阶段仍不引入完整门户数据库，至少需要一个轻量持久状态存储，例如 SQLite 或文件型状态目录。它只用于平台操作状态，不作为线上真实发布状态来源。

### 任务状态机

```text
Preflight
SnapshotEtcd
JoinSecondServer
JoinThirdServer
ValidateEtcdQuorum
ValidateKubeAPI
ValidateCilium
ValidateGateway
ScaleSystemComponents
RebalanceWorkloads
UpdateEntrypoints
Completed
FailedRecoverable
FailedManualIntervention
```

每一步必须具备：

```text
幂等执行
超时控制
重试策略
前置检查
后置验证
结构化日志
人工接管提示
```

### 预检

两台新 Server 必须通过：

```text
SSH 可连接
私网互通
hostname 唯一
时间同步
磁盘空间满足要求
CPU / 内存满足要求
必要端口未占用
安全组允许 etcd / kubelet / Cilium / API 内部通信
操作系统版本和内核参数满足要求
```

### 执行步骤

```text
1. 锁定集群升级任务
2. 读取 ClusterSpec
3. 创建 etcd 远程快照
4. 校验 Server Token 可用
5. 写入 Server 2 配置
6. 加入 Server 2
7. 短暂进入 2 Server 中间态
8. 立即写入 Server 3 配置
9. 加入 Server 3
10. 等待三成员 etcd 健康
11. 检查 Kubernetes API
12. 检查 Cilium Agent / CiliumNode
13. 检查 Gateway Listener
14. 提升系统组件副本
15. 执行业务再均衡
16. 更新 DNS 多 A 或 SLB / NLB 后端
17. 标记 HA 完成
```

### 双 Server 中间态规则

UI 必须显示：

```text
高可用升级进行中
当前阶段: 2/3 个 Server 已加入
注意: 第三个 Server 加入前尚未达到高可用状态
```

不得显示：

```text
高可用已完成
```

### 系统组件 HA 调整

三节点完成后自动调整：

```text
Cilium Operator: 2 副本
CoreDNS: 2 副本
Argo CD Server: 2 副本
Repo Server: 2 副本
OneCD API: 2 副本
OneCD UI: 2 副本
```

并补充：

```text
PodDisruptionBudget
topologySpreadConstraints
Pod Anti-Affinity
```

### 验收

- `1 -> 3` 升级任务可完整执行。
- 任务执行过程中平台进程重启后，可恢复任务状态。
- 三个 Server 都能访问 Kubernetes API。
- etcd 三成员健康。
- 任意关闭 1 台 Server 后：
  - etcd 仍有 quorum。
  - Kubernetes API 仍可访问。
  - 已运行业务仍可访问。
  - Argo CD / Rollouts 状态可查询。
- Gateway 在三台 Server 上都可用。
- DNS 多 A 或 SLB / NLB 后端更新后可访问。

### 失败处理

- Server 2 加入失败：保持单节点，提示恢复步骤。
- Server 2 已加入、Server 3 加入失败：标记 `FailedManualIntervention`，明确提示当前不是 HA，优先修复并加入 Server 3。
- etcd 健康检查失败：停止后续步骤，不执行再均衡。
- Cilium 未 Ready：禁止业务调度到新节点。
- Gateway 未 Ready：不把新节点加入入口地址。

## P4 Worker 扩容与再均衡

### 目标

三节点 HA 后，普通容量扩展只加 Worker，不继续增加 etcd 成员。

### 任务

- 新增“添加节点”产品入口。
- 默认以 Agent Worker 身份加入。
- 执行 Worker 预检。
- 安装 K3s Agent。
- 等待 Node Ready。
- 等待 Cilium Agent Ready。
- 等待跨节点网络测试通过。
- 标记节点可调度。
- 触发受控再均衡。
- 根据资源使用率输出容量建议。

### 再均衡策略

默认策略：

```text
逐个应用
逐个副本
先创建新 Pod
等待新 Pod Ready
再删除旧节点 Pod
失败即暂停
```

对单副本应用：

```text
提示风险
可选择临时扩到 2 副本
新副本 Ready 后迁移
最后恢复原副本数
```

### 验收

- 添加 Worker 后，业务 Pod 可以调度到 Worker。
- 新 Worker 不会在 Cilium Ready 前承载业务。
- 再均衡不会一次性驱逐全部 Pod。
- 再均衡失败可以暂停并显示原因。
- Worker 下线或故障时，平台能给出替换建议。

## P5 生产治理增强

### 目标

把平台从“能跑”提升到“可长期维护”。

### 安全

- OneCD / 平台门户接入认证。
- 管理入口使用 HTTPS。
- Kubernetes API 只允许 VPN、堡垒机和集群节点访问。
- SSH 私钥、K3s Token、kubeconfig、GitHub Token、数据库密码不入 Git。
- 平台运行权限最小化。
- Rollout 操作优先通过 Argo CD Resource Actions 或受限内部接口完成。

### 备份恢复

- 定期 etcd 快照。
- 快照远程加密保存。
- Server Token 单独安全保存。
- 每季度至少一次隔离 VPC 恢复演练。
- 恢复演练必须验证：
  - Kubernetes API 可用。
  - Argo CD Application 存在。
  - Gateway / HTTPRoute 存在。
  - demo 应用可访问。

### 可观测性

- 节点 CPU / 内存 / 磁盘。
- Pod 重启次数。
- Cilium Agent 状态。
- Gateway Listener 状态。
- Argo CD sync / health 状态。
- Rollout 状态。
- etcd 快照成功率。
- 证书到期时间。
- 发布任务成功率和失败原因。

### 升级

- K3s 升级前检查。
- Cilium 升级前兼容性检查。
- Argo CD / Rollouts 升级前 Release Notes 检查。
- 每次升级先在测试集群跑：
  - 应用发布。
  - Abort。
  - Gateway 访问。
  - 节点重启。
  - etcd 快照。

### 验收

- 一次完整恢复演练通过。
- 一次 K3s 小版本升级演练通过。
- 一次 Cilium 升级演练通过。
- 一次单 Server 故障演练通过。
- 一次发布失败诊断闭环通过。

## P6 托管 Kubernetes 迁移

### 目标

证明平台不是绑定自建 K3s，而是保留应用和发布模型，替换运行集群。

### 边界

K3s 不能原地转换成 ACK、EKS 或 GKE。迁移方式是：

```text
创建托管 Kubernetes
-> 安装 Argo CD / Rollouts / Gateway 实现
-> 导入 GitOps 应用定义
-> 重建应用
-> 验证
-> 切换 DNS / SLB
-> 下线旧集群
```

### 验收

- demo 应用不改源码。
- 镜像不改。
- GitOps 仓库结构尽量不改。
- 发布界面不改。
- 通过新集群发布和回滚。
- 入口切换后旧集群可下线。

## 推荐模块拆分

| 模块 | 职责 | 第一版要求 |
| --- | --- | --- |
| Portal / OneCD UI | 普通模式和高级模式入口 | 应用发布、状态、诊断、扩容入口 |
| Release Orchestrator | Build / Sync / Promote / Abort 编排 | 沿用现有 OneCD 流程 |
| Cluster Orchestrator | 单节点安装、HA 升级、Worker 扩容 | P1-P4 核心模块 |
| Operation Engine | 长任务状态机 | P3 前必须持久化 |
| Preflight Engine | 节点、网络、系统参数检查 | P1 开始建设 |
| Health Checker | K8s、etcd、Cilium、Gateway、Argo 健康检查 | 每阶段门禁 |
| Rebalance Controller | 受控再均衡 | P4 核心模块 |
| Diagnosis Engine | Kubernetes 原始错误翻译 | P2 起步，P5 增强 |
| GitOps Renderer | 生成标准资源和 GitOps 变更 | P2 核心模块 |
| Backup Manager | etcd 快照、上传、恢复材料 | P1 起步，P5 演练 |

## 关键数据模型

### ClusterSpec

平台保存的集群级配置，不让普通用户反复填写：

```text
clusterId
k3sVersion
ciliumVersion
clusterCIDR
serviceCIDR
clusterDNS
disabledComponents
apiServerSANs
tokenSecretRef
nodes
entrypoints
```

### Operation

用于长任务恢复：

```text
operationId
type
clusterId
status
currentStep
createdAt
updatedAt
startedBy
input
stepResults
error
recoveryHint
```

### NodeInventory

```text
nodeId
hostname
privateIP
publicIP
role
status
k3sVersion
ciliumStatus
gatewayStatus
lastCheckAt
```

### BackupRecord

```text
backupId
clusterId
snapshotTime
storageLocation
serverTokenRef
checksum
restoreVerified
```

## 验收矩阵

| 场景 | 必须验证 |
| --- | --- |
| 单节点安装 | API、etcd、Cilium、Gateway、Argo CD、OneCD、demo 应用 |
| 应用发布 | Build、Sync、Promote、Abort、永久回滚 |
| 坏版本发布 | Rollout 停止、Abort 恢复、诊断显示 |
| 1 -> 3 HA | 三成员 etcd、三节点 Gateway、系统组件 HA |
| Server 故障 | 任意 1 台 Server 下线后 API 和业务可用 |
| Worker 扩容 | Worker Ready、Cilium Ready、业务调度、再均衡 |
| Pod Pending | 诊断能解释资源不足或调度约束 |
| 镜像拉取失败 | 诊断能指出镜像或凭证问题 |
| Gateway 异常 | 诊断能指出 Gateway / HTTPRoute / Service Endpoint 问题 |
| etcd 备份 | 快照生成、远程保存、校验 |
| 恢复演练 | 隔离环境恢复并访问 demo 应用 |
| 升级演练 | K3s / Cilium / Argo 组件升级前后核心链路通过 |

## 风险与缓解

| 风险 | 影响 | 缓解 |
| --- | --- | --- |
| `1 -> 3` 中 Server 3 加入失败 | 集群停在非 HA 中间态 | 状态机标记失败，禁止宣称 HA，提供修复和继续加入入口 |
| Server 关键配置不一致 | 新 Server 加入失败或集群异常 | ClusterSpec 统一生成，加入前校验配置 hash |
| Cilium 未 Ready 就调度业务 | 新节点业务不可达 | Node Ready gate，Cilium / CiliumNode / 网络测试通过后再开放调度 |
| 再均衡导致中断 | 应用不可用 | 逐 Pod 滚动，必须等新 Pod Ready，单副本应用提示风险 |
| DNS 多 A 无健康检查 | 客户端可能访问故障节点 | 生产增强使用 SLB / NLB 健康检查 |
| 门户进程重启丢任务 | HA 升级不可恢复 | P3 前引入持久 Operation 状态 |
| etcd 快照未经恢复验证 | 灾备不可用 | P5 要求隔离环境恢复演练 |
| 凭证泄露 | 集群或仓库被接管 | Secret 不入 Git，最小权限，短期凭证优先 |

## 第一版最小可交付范围

第一版建议只承诺：

```text
1. 单节点安装
2. demo 应用发布
3. etcd 备份
4. 1 -> 3 HA 升级
5. Worker 添加
6. 基础再均衡
7. 基础诊断
```

第一版不承诺：

```text
审批流
发布锁
完整多租户
自定义 CNI / Gateway
托管 Kubernetes 自动迁移
完整监控大盘
跨地域容灾
```

## 实施顺序建议

```text
P0 准备与基线
  ↓
P1 单节点起步闭环
  ↓
P2 应用交付 MVP
  ↓
P3 1 -> 3 HA 升级
  ↓
P4 Worker 扩容与再均衡
  ↓
P5 生产治理增强
  ↓
P6 托管 Kubernetes 迁移验证
```

如果资源有限，优先级应是：

```text
单节点起步
> 应用发布
> 1 -> 3 HA
> Worker 扩容
> 诊断增强
> 企业治理
```

因为产品最核心的承诺是：

```text
从一台服务器开始，业务增长后直接加机器；
应用、域名、发布方式和使用习惯都不改变。
```
