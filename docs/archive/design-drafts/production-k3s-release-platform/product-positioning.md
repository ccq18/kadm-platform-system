# Product Positioning

**日期**: 2026-06-26  
**状态**: Draft  
**范围**: Production K3s release platform target

## 一句话定位

这是一个可以从单台服务器平滑成长为高可用 Kubernetes 集群的应用交付与运维平台。它通过固定黄金路径、自动化扩容、自动化诊断和简化的应用模型，降低 Kubernetes 的部署和使用门槛，同时保留标准 Kubernetes 的开放性与企业二次开发能力。

更直接地说：

```text
让团队使用 Kubernetes，但不必先成为 Kubernetes 专家。
```

更贴近第一版产品价值的表达是：

```text
从一台服务器开始，业务增长后直接加机器；
应用、域名、发布方式和使用习惯都不改变。
```

## 产品不是做什么

平台不是替代 Kubernetes，也不是重新做一个 Cloud Run、SAE 或新的通用云 PaaS。

平台要做的是：

```text
Kubernetes 能力很强
        ↓
但安装、发布、网络、证书、排障、升级太复杂
        ↓
通过默认最佳实践 + 自动化 + 可理解的 UI
        ↓
让小团队也能安全使用 Kubernetes
```

第一版最重要的产品主线不是允许用户定制底层，而是提供一条稳定、固定、自动化的成长路径：

```text
1 Server
-> 3 Server HA
-> 3 Server + N Worker
-> 必要时迁移到托管 Kubernetes
```

对用户而言，整个过程中：

```text
应用不重建
发布流程不变化
域名不变化
GitOps 不变化
无需理解 etcd 和 Cilium
只需要添加服务器
```

Cloud Run、SAE 这类产品可以作为使用体验参考，但不是主要技术边界。它们通过隐藏基础设施换取简单体验，用户也因此放弃了大量控制权。本平台的取舍是保留 Kubernetes 的开放性、可迁移性和企业可扩展性，同时尽量提供接近 PaaS 的日常使用体验。

## 真正的竞争对象

主要对比对象是：

```text
裸 Kubernetes
Rancher
Argo CD
Devtron
Portainer
企业内部发布平台
```

这些对象共同说明了用户的真实痛点：Kubernetes 本身足够强，但从集群安装、应用发布、域名证书、网络策略、健康诊断、备份恢复到升级维护，中小团队很难持续稳定地把它用好。

## 用户心智模型

普通研发用户不应该先看到 Kubernetes 对象。默认界面面向应用生命周期：

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

普通用户不需要直接理解：

```text
Deployment
ReplicaSet
Pod
Service
HTTPRoute
GatewayClass
ConfigMap
Secret
PDB
HPA
Argo CD Application
```

例如用户操作的是：

```text
应用: order-api
环境: 生产环境
版本: v1.8.3
副本: 3
域名: order.example.com

[发布]
```

平台内部完成：

```text
更新 GitOps 仓库
-> Argo CD 同步
-> 创建或更新 Kubernetes 工作负载
-> 检查 Pod Readiness
-> 检查 Service Endpoint
-> 检查 HTTPRoute
-> 返回发布结果
```

Kubernetes 对象是平台的实现证据和高级管理入口，不是普通用户完成发布的前置知识。

## 两层界面

平台必须提供两层界面：默认降低门槛，高级模式保留深入管理能力。

### 普通模式

普通模式面向研发，围绕应用生命周期组织能力：

```text
应用发布
环境变量
Secret 引用
日志
事件摘要
资源使用
域名
HTTPS
扩缩容
回滚
```

普通模式展示结论、原因和建议，而不是原样倾倒 Kubernetes 状态。

### 高级模式

高级模式面向运维、平台工程师和熟悉 Kubernetes 的研发：

```text
查看 Kubernetes YAML
查看 Kubernetes 事件
查看 Pod 和容器
进入受控终端
查看 Argo CD 状态
查看网络策略
查看 Gateway / HTTPRoute
查看集群规格和底层能力
查看节点加入、再均衡和组件健康状态
```

核心原则是：

```text
默认不要求懂 Kubernetes，但不能阻止懂 Kubernetes 的人深入管理。
```

## 黄金路径

平台价值不止是安装 K3s。安装集群只是入口，应用生命周期管理才是核心。

正确的产品演进路线：

```text
阶段一：1 台服务器
K3s Server + 单成员 embedded etcd
+ Cilium
+ Argo CD
+ 平台
+ 业务应用

          ↓ 升级为高可用集群

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
切换域名或负载均衡入口
```

### 集群层

```text
添加第一台服务器
-> 自动检查网络和系统参数
-> 安装 K3s Server + 单成员 embedded etcd
-> 安装默认 CNI
-> 安装 Gateway
-> 安装 Argo CD
-> 配置备份
-> 验证集群健康
```

业务增长后，用户不需要重装集群，只执行：

```text
[升级为高可用集群]
-> 填写或选择另外两台服务器
-> 平台自动预检
-> 创建 etcd 远程快照
-> 连续加入 Server 2 和 Server 3
-> 等待 etcd 三成员健康
-> 检查 Kubernetes API、Cilium 和 Gateway
-> 扩展系统组件副本
-> 受控再均衡业务 Pod
-> 将新节点加入入口地址
```

继续增长时：

```text
[添加节点]
-> 平台按 Worker 身份加入
-> 自动安装网络组件
-> 等待 Node / Cilium / Gateway 相关健康检查
-> 根据策略调度新工作负载
```

用户在普通安装流程中只选择部署模式：

```text
部署模式:
○ 单台服务器起步
○ 升级为高可用集群
○ 添加计算节点
○ 导入已有 Kubernetes
```

不要把 CNI、Service Dataplane、Gateway Controller、IPAM 模式作为普通用户首次安装时必须理解的选项。第一版固定默认路径，底层实现只作为内部边界和高级能力保留。

### 应用层

```text
连接代码仓库
-> 识别 Dockerfile 或构建方式
-> 生成 CI 模板
-> 构建镜像
-> 生成标准 Kubernetes / Gateway API 资源
-> 配置域名和 HTTPS
-> 发布
-> 观测发布结果
```

### 运维层

```text
节点异常检测
证书到期检测
etcd 备份检查
磁盘容量检测
Pod 异常诊断
版本升级检查
发布失败回滚
```

### 诊断层

平台需要把 Kubernetes 原始错误翻译成人能理解的问题。

原始信息：

```text
Pod Pending
0/3 nodes available: insufficient memory
```

平台展示：

```text
应用无法启动

原因: 集群剩余内存不足。
需要: 2 GiB
当前最大可用节点: 1.3 GiB

建议:
1. 降低应用内存配置
2. 增加节点
3. 停止不再使用的应用
```

这种“诊断翻译层”是平台相对裸 Kubernetes、Argo CD 或普通控制面 UI 的关键差异化。

## 固定成长路径与可替换边界

为了易用性和稳定性，产品默认只提供一条经过完整测试的自建集群路径：

```text
K3s + embedded etcd
+ Cilium
+ Gateway API
+ Argo CD
+ 基础发布策略
```

这条路径的核心不是“用户选择 Cilium”，而是平台自动完成：

```text
单节点安装
1 -> 3 HA 升级
Worker 横向扩容
系统组件从 Single 模式切到 HA 模式
业务工作负载受控再均衡
故障节点替换
etcd 备份和恢复
集群升级前检查
```

架构内部仍允许平台开发者替换：

```text
K3s              -> ACK / EKS / GKE / 标准 Kubernetes
Cilium           -> Calico / Terway / 云厂商网络
Cilium Gateway   -> ALB / GKE Gateway / Envoy Gateway
GitHub Actions   -> GitLab CI / Jenkins
GitHub           -> GitLab / Gitea
Hubble           -> 云监控 / Prometheus
```

关键原则：

```text
固定成长路径是用户价值。
可替换是平台开发者能力，不是普通用户安装时必须做的选择。
```

第一版不应把这些能力做成普通用户功能：

```text
CNI Provider 自定义
Service Dataplane Provider 自定义
Gateway Provider 自定义
Observability Provider 自定义
任意插件替换
Cilium / Calico 选择
```

## 产品负责范围

平台负责成熟组件之上的产品化、编排和诊断层：

- 集群安装和接入
- 单节点到三节点 HA 升级
- Worker 横向扩容
- 自动再均衡
- 故障节点替换
- 版本一致性检查
- 应用创建
- GitOps 发布
- 域名和 HTTPS
- 环境变量与 Secret 引用
- 日志和事件摘要
- 健康检查
- 回滚
- 节点和集群状态
- etcd 备份检查
- 升级前检查
- 权限、审计和扩展接口
- Kubernetes 错误诊断翻译

## 不重新实现的部分

平台不重新实现：

- Kubernetes 调度器
- CNI 数据面
- Git 引擎
- CI 执行器
- 镜像仓库
- Argo CD 对账逻辑
- Prometheus
- 云负载均衡器

这些组件应该作为 Provider、Adapter 或外部依赖接入。平台的长期价值来自应用模型、发布模型、健康诊断、运维自动化、默认最佳实践和企业扩展接口。

## 定位结论

最终产品定位：

> 一个可以从单台服务器平滑成长为高可用 Kubernetes 集群的应用交付与运维平台，通过固定黄金路径、自动化扩容、自动化诊断和简化的应用模型，降低 Kubernetes 的部署和使用门槛，同时保留标准 Kubernetes 的开放性与企业二次开发能力。

产品核心不是 K3s、Cilium 或 Argo CD 本身。它们只是默认实现。真正的产品是 Kubernetes 易用性层。
