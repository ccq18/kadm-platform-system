# Cluster Growth Path

**日期**: 2026-06-26  
**状态**: Draft  
**范围**: 从单节点平滑成长为高可用 Kubernetes 集群

## 核心原则

产品要解决的核心不是让普通用户定制底层，而是：

```text
用户从一台服务器开始
业务增长后直接加机器
平台自动把单节点升级为高可用集群
应用、域名、发布方式和使用习惯都不改变
```

用户始终使用：

```text
应用
环境
版本
域名
发布
日志
回滚
```

用户不需要理解：

```text
etcd quorum
Cilium Agent
GatewayClass
Pod CIDR
Server / Agent 参数
taint / toleration
topologySpreadConstraints
```

## 固定成长路线

```text
阶段一：1 台服务器
K3s Server + 单成员 embedded etcd
+ Cilium
+ Argo CD
+ 平台
+ 业务应用

          ↓ 添加两台服务器

阶段二：3 台高可用服务器
K3s Server x 3
+ embedded etcd x 3
+ Cilium Gateway x 3
+ 应用跨节点运行

          ↓ 继续添加计算节点

阶段三：3 台 Server + N 台 Worker
控制面保持 3 台
业务容量通过 Worker 横向扩展

          ↓ 企业需要托管 Kubernetes

阶段四：创建 ACK / EKS / GKE
GitOps 重新部署应用
切换 DNS 或负载均衡入口
```

## 单节点从第一天使用 embedded etcd

第一台节点不要默认使用 SQLite。第一天直接使用：

```yaml
cluster-init: true
```

即：

```text
K3s Server
+ 单成员 embedded etcd
```

原因：

```text
单节点 embedded etcd
        ↓
加入 Server 2
        ↓
加入 Server 3
        ↓
直接形成三成员 etcd
```

这避免中途执行：

```text
SQLite
-> 停止 K3s
-> 转换 datastore
-> 验证转换
-> 再增加节点
```

单节点 embedded etcd 不是高可用，只是为了后续扩容时不更换 datastore 架构。

## 集群级配置必须从第一天固定

第一台节点不能使用临时配置，后续再重新生成。平台第一次安装时就创建一份集群级配置：

```yaml
cluster:
  id: cluster-001
  tokenSecretRef: cluster-001-token

kubernetes:
  clusterCIDR: 10.32.0.0/16
  serviceCIDR: 10.48.0.0/16
  clusterDNS: 10.48.0.10

network:
  provider: cilium
  routingMode: tunnel

components:
  disable:
    - flannel
    - servicelb
    - traefik
```

后续 Server 加入时必须使用同一份关键配置。平台内部需要保存：

```text
ClusterSpec
Cluster Token
K3s Version
Cilium Version
网络 CIDR
组件开关
证书 SAN
节点清单
```

这些配置不让普通用户反复填写。

## 1 到 3 必须是原子化操作

产品中只提供：

```text
[升级为高可用集群]
```

用户提供另外两台服务器：

```text
服务器 2: 10.0.0.12
服务器 3: 10.0.0.13
SSH 凭证: 已保存
```

平台自动执行：

```text
1. 检查两台新服务器
2. 检查私网连通性
3. 检查磁盘、时间同步和系统参数
4. 对当前 etcd 创建远程快照
5. 将相同 K3s 配置写入 Server 2
6. Server 2 加入 etcd
7. 立即将 Server 3 加入 etcd
8. 等待 etcd 三成员健康
9. 检查 Kubernetes API
10. 检查 Cilium
11. 扩展系统组件副本
12. 受控再均衡业务 Pod
13. 将新节点加入入口地址
```

不应让用户分别执行：

```text
添加第二台
等待
再添加第三台
```

原因是 etcd 需要多数派。从 1 个成员添加到 2 个成员后，法定人数变成 2，此时失去任意一个成员都会失去仲裁。因此第二、第三个 Server 应在同一次扩容任务中连续加入，不应让集群长期停留在 2 Server 状态。

扩容过程中的 UI 可以显示：

```text
高可用升级进行中

当前阶段: 2/3 个 Server 已加入
注意: 第三个 Server 加入前尚未达到高可用状态
```

## 扩容过程中业务不迁移入口

原来的 ECS-1 始终保留：

```text
扩容前:
用户 -> ECS-1 -> 应用

扩容过程中:
用户 -> ECS-1 -> 应用

扩容完成:
用户 -> ECS-1 / ECS-2 / ECS-3 -> 应用
```

因此无论有没有 SLB：

- 原节点 IP 不变。
- 原域名可以继续指向 ECS-1。
- 原来的 Gateway 继续运行。
- 原来的 Pod 不需要先搬走。
- 新节点只是在后台加入。

扩容完成后，再将 ECS-2、ECS-3 加入：

```text
DNS 多 A 记录
```

或者：

```text
云 SLB / NLB 后端列表
```

没有外部负载均衡时，用户仍然可以直接访问：

```text
ECS-1-IP:8443
ECS-2-IP:8443
ECS-3-IP:8443
```

## Cilium 扩容自动化

Cilium 作为固定默认网络，不作为普通用户安装选项。

节点加入后：

```text
K3s 节点加入
      ↓
Kubernetes 创建 Node
      ↓
Cilium DaemonSet 自动调度到新节点
      ↓
Cilium 分配 Pod CIDR
      ↓
新节点网络 Ready
```

平台必须等待：

```text
Node Ready
Cilium Agent Ready
CiliumNode Ready
节点间网络测试通过
Gateway Listener Ready
```

通过以后，才允许业务 Pod 调度到新节点。

## 业务工作负载需要受控再均衡

已有 Pod 不会因为增加节点自动重新分布。

单节点原来可能是：

```text
ECS-1
├── order-api Pod 1
├── order-api Pod 2
├── user-api Pod 1
└── user-api Pod 2
```

加入 ECS-2 和 ECS-3 后，Kubernetes 通常不会主动移动已经正常运行的 Pod：

```text
ECS-1: 仍然放着全部旧 Pod
ECS-2: 空
ECS-3: 空
```

因此平台扩容完成后需要执行一次受控再均衡：

```text
逐个 Deployment
-> 创建新 Pod
-> 新 Pod 在新节点 Ready
-> 删除旧节点上的一个 Pod
-> 继续下一个
```

不要一次性驱逐所有 Pod。

应用模板从第一天就应带软分散策略：

```yaml
topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: kubernetes.io/hostname
    whenUnsatisfiable: ScheduleAnyway
    labelSelector:
      matchLabels:
        app: order-api
```

单节点时不会阻止调度；有多个节点后，新 Pod 会优先分布到不同节点。

## 零停机条件

应用至少需要：

```yaml
replicas: 2

strategy:
  rollingUpdate:
    maxUnavailable: 0
    maxSurge: 1
```

同时必须有正确的 Readiness Probe。

如果应用只有一个副本，平台可以平滑增加节点，但不能保证重新均衡过程中绝对不中断。平台可以选择：

```text
临时扩为 2 个副本
-> 等新副本 Ready
-> 再均衡
-> 恢复原副本数
```

这一步必须在 UI 中提示用户风险和自动动作。

## 系统组件从 Single 模式切到 HA 模式

单节点时：

```text
Cilium Operator      1 副本
Argo CD Server       1 副本
Argo CD Controller   默认单实例模式
平台 API             1 副本
平台 UI              1 副本
平台数据库           外置或单独处理
```

三节点完成后，平台自动调整：

```text
Cilium Operator      2 副本
CoreDNS              2 副本
Argo CD Server       2 副本
Repo Server          2 副本
平台 API             2 副本
平台 UI              2 副本
```

并增加：

```text
Pod Anti-Affinity
topologySpreadConstraints
PodDisruptionBudget
```

这些不是用户定制项，而是部署规模对应的自动策略：

```text
Single 模式
-> 系统组件低资源配置

HA 模式
-> 系统组件高可用配置
```

## 超过 3 台以后默认只加 Worker

推荐固定扩展模型：

```text
1 台:
1 Server，兼做 Worker

3 台:
3 Server，兼做 Worker

4 台以上:
3 Server
+ N 个 Agent Worker
```

示例：

```text
3 台:
Server 1
Server 2
Server 3

扩展到 5 台:
Server 1
Server 2
Server 3
Worker 1
Worker 2

扩展到 20 台:
Server 1
Server 2
Server 3
Worker 1 ~ 17
```

一般容量扩展只增加 Worker，不增加 etcd 成员。这样：

- 控制面拓扑不变。
- etcd 成员数量不膨胀。
- 新节点加入更简单。
- 业务容量可持续横向增长。

只有确实需要容忍两个控制面节点故障时，才考虑从 3 个 Server 扩到 5 个 Server。

## 节点角色演进

1 台：

```text
ECS-1
├── Server
├── etcd
├── Gateway
├── 平台组件
└── 业务 Pod
```

3 台：

```text
ECS-1 / ECS-2 / ECS-3
├── Server
├── etcd
├── Gateway
├── 平台组件
└── 业务 Pod
```

3 Server + 2 Worker 后：

```text
Server 1 ~ 3
├── K3s 控制面
├── etcd
├── Gateway
└── 少量平台组件

Worker 1 ~ 2
└── 业务 Pod
```

平台可以在拥有至少两个 Worker 后，自动逐步将普通业务从 Server 节点迁走，但保留 Gateway：

```text
Server 节点:
控制面 + Gateway

Worker 节点:
业务负载
```

这一步不需要用户理解 taint 和 toleration。

## 迁移到托管 Kubernetes 的边界

K3s 不能原地转换成 ACK、EKS 或 GKE。

正确方式是：

```text
现有 K3s 集群
        |
        |-- GitOps 应用定义
        |-- 外部数据库
        |-- 外部 Redis
        |-- 对象存储
                 ↓
创建托管 Kubernetes 集群
                 ↓
Argo CD 重建应用
                 ↓
验证
                 ↓
切换 DNS / SLB
```

这里的“平滑”是：

- 应用不改。
- 镜像不改。
- GitOps 仓库不改。
- 发布界面不改。
- 数据库不迁或独立迁移。
- 只替换运行集群。
- 最后切入口。

不是把旧集群原地变成云厂商集群。

## 第一版重点能力

第一版重点开发：

```text
节点预检
安全加入集群
1 -> 3 HA 升级
Worker 横向扩容
自动再均衡
故障节点替换
版本一致性检查
etcd 备份和恢复
集群升级
容量建议
```

第一版不要向普通用户暴露：

```text
CNI Provider
Service Dataplane Provider
Gateway Provider
Observability Provider
ClusterProfile 自定义
任意插件替换
Cilium / Calico 选择
```

产品内部可以保持清晰 Provider 边界，但产品界面应把默认路径固定为：

```text
自建集群:
K3s + embedded etcd + Cilium + Gateway API + Argo CD

托管集群:
导入标准 Kubernetes
```

## 参考资料

实施前需要按目标版本复核官方文档：

- K3s High Availability Embedded etcd: `https://docs.k3s.io/datastore/ha-embedded`
- K3s Server 参数与关键配置: `https://docs.k3s.io/cli/server`
- K3s Architecture: `https://docs.k3s.io/architecture`
- Cilium Kubernetes Concepts: `https://docs.cilium.io/en/stable/network/kubernetes/concepts/`
