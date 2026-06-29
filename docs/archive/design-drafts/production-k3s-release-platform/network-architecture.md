# Network Architecture For Fixed Growth Path

**日期**: 2026-06-26  
**状态**: Draft  
**范围**: 单节点起步、三节点 HA、Worker 横向扩容的默认网络架构

## 核心原则

第一版网络架构服务于固定成长路径：

```text
1 Server
-> 3 Server HA
-> 3 Server + N Worker
-> 必要时迁移到托管 Kubernetes
```

自建集群默认固定使用：

```text
K3s + embedded etcd + Cilium + Gateway API + Argo CD
```

Cilium 是固定默认网络实现，不是普通用户需要选择的选项。第一版产品界面不暴露 CNI Provider、Service Dataplane Provider、Gateway Provider、Observability Provider 或 Cilium / Calico 选择。

平台的稳定应用契约仍依赖标准 Kubernetes API、Gateway API 和 GitOps，不把业务发布流程绑定到 Cilium 私有 API。

普通研发用户不应该感知 CNI、Service Dataplane、Gateway Controller 或 IPAM 模式。普通用户看到的是：

```text
应用
环境
版本
域名
HTTPS
发布
回滚
日志
诊断
```

运维和平台开发者可以在高级模式查看 Gateway、HTTPRoute、NetworkPolicy、集群规格、底层能力和 YAML。

## 固定成长路径

```text
阶段一：1 台服务器
ECS-1
├── K3s Server
├── 单成员 embedded etcd
├── Cilium Agent
├── Cilium Gateway
├── 平台组件
└── 业务 Pod

阶段二：3 台高可用服务器
ECS-1 / ECS-2 / ECS-3
├── K3s Server
├── embedded etcd
├── Cilium Agent
├── Cilium Gateway
├── 平台组件
└── 业务 Pod

阶段三：3 Server + N Worker
Server 1 ~ 3
├── K3s 控制面
├── embedded etcd
├── Cilium Gateway
└── 少量平台组件

Worker 1 ~ N
└── 业务 Pod
```

单节点阶段就使用 embedded etcd 和集群级网络配置，避免后续 SQLite 到 etcd 的 datastore 转换。

## 内部扩展边界

代码和架构内部可以保留 Provider 边界，但第一版不把它做成普通用户功能。

内部边界：

| 内部边界 | 默认实现 | 说明 |
| --- | --- | --- |
| NetworkProvider | Cilium | Pod 网络和基础 NetworkPolicy |
| ServiceDataplaneProvider | Cilium eBPF | ClusterIP、NodePort、LoadBalancer 等 Service 数据面 |
| GatewayProvider | Cilium Gateway | 外部 HTTP/HTTPS 入口 |
| ObservabilityProvider | Hubble 或后续观测集成 | 网络流量、依赖、丢包和健康观测 |

普通用户不选择这些实现。高级/企业场景需要替换底层时，应以新集群或导入已有 Kubernetes 的方式处理，并保持应用、镜像、GitOps 仓库和发布界面不变。

## 应用资源契约

业务应用默认只生成标准 Kubernetes / Gateway API 资源：

```text
Deployment
Service
Gateway
HTTPRoute
NetworkPolicy
HPA
PDB
ConfigMap
Secret 引用
```

默认业务模板不得生成 Cilium 专属资源：

```text
CiliumNetworkPolicy
CiliumEnvoyConfig
CiliumBGPPeeringPolicy
CiliumEgressGatewayPolicy
```

Cilium 专属资源只能放在：

```text
cluster-profiles/k3s-cilium/
```

或显式高级插件中，并且必须在能力矩阵里标注不可跨 Provider 迁移。

## 默认自建网络结构

默认自建网络的核心原则：

```text
单节点起步时，ECS-1 直接作为业务入口。
升级到三节点 HA 后，三台 ECS 都能直接作为业务入口。
云厂商 SLB / NLB 是可选增强，不是必需组件。
```

单节点基础模式：

```text
客户端
  |
  |-- http://ECS-1-IP:8080
  |-- https://ECS-1-IP:8443
```

三节点基础模式：

```text
客户端
  |
  |-- http://ECS-1-IP:8080
  |-- http://ECS-2-IP:8080
  |-- http://ECS-3-IP:8080
  |
  |-- https://ECS-1-IP:8443
  |-- https://ECS-2-IP:8443
  |-- https://ECS-3-IP:8443
```

可选增强模式：

```text
客户端
  |
  v
云 SLB / NLB
  |-- 80  -> ECS-1/2/3:8080
  |-- 443 -> ECS-1/2/3:8443
  v
Cilium Gateway Host Network
```

这个“节点直连入口”是默认自建路径的能力。迁移到托管 Kubernetes 时，可以改为云托管负载均衡入口，但普通用户的应用、域名、发布和回滚模型不应改变。

## 节点结构演进

单节点起步：

```text
ECS-1
├── K3s Server
├── 单成员 embedded etcd
├── Cilium Agent
├── Cilium Envoy Gateway
├── 平台组件
└── 业务 Pod
```

升级到三节点 HA 后：

```text
ECS-1
├── K3s Server
├── embedded etcd
├── Cilium Agent
├── Cilium Envoy Gateway
├── 平台组件
└── 业务 Pod

ECS-2
├── K3s Server
├── embedded etcd
├── Cilium Agent
├── Cilium Envoy Gateway
├── 平台组件
└── 业务 Pod

ECS-3
├── K3s Server
├── embedded etcd
├── Cilium Agent
├── Cilium Envoy Gateway
├── 平台组件
└── 业务 Pod
```

继续增加 Worker 后：

```text
Server 1 ~ 3
├── K3s 控制面
├── embedded etcd
├── Cilium Agent
├── Cilium Envoy Gateway
└── 少量平台组件

Worker 1 ~ N
├── Cilium Agent
└── 业务 Pod
```

平台可以在至少有两个 Worker 后，逐步将普通业务从 Server 节点迁到 Worker，但保留 Server 节点的 Gateway 能力。

## 外部业务入口

单节点基础模式下，用户访问 ECS-1 的业务入口端口：

```text
HTTP:  ECS-1:8080
HTTPS: ECS-1:8443
```

升级到三节点 HA 后，用户可以直接访问任意 ECS 节点的业务入口端口：

```text
HTTP:  ECS-1/2/3:8080
HTTPS: ECS-1/2/3:8443
```

正式域名可以配置多个 A 记录：

```text
app.example.com
├── ECS-1 public IP
├── ECS-2 public IP
└── ECS-3 public IP
```

扩容过程中不迁移入口：

```text
扩容前:
用户 -> ECS-1 -> 应用

扩容过程中:
用户 -> ECS-1 -> 应用

扩容完成:
用户 -> ECS-1 / ECS-2 / ECS-3 -> 应用
```

普通 DNS 多 A 记录没有主动健康检查。一台 ECS 故障后，部分客户端可能继续缓存故障节点 IP。因此基础模式下：

- 集群本身仍可用。
- 另外两台 ECS 仍可提供服务。
- 客户端入口不一定能快速避开故障节点。

当需要入口自动故障转移时，在前面增加 SLB / NLB：

```text
客户端
  |
  v
云 SLB / NLB
  |-- 80  -> ECS-1/2/3:8080
  |-- 443 -> ECS-1/2/3:8443
  v
Cilium Gateway
```

增加 SLB / NLB 不要求重装 K3s，不要求修改 Cilium 基础架构，不要求修改业务 Deployment，也不要求修改 HTTPRoute。它只是默认自建路径下的外层入口增强。

## 默认入口流量链路

以 `api.example.com` 为例：

```text
用户请求
  |
  v
ECS-1:8443
  |
  v
Cilium Envoy Gateway
  |
  v
Gateway Listener
  |
  v
HTTPRoute 匹配 api.example.com
  |
  v
api-service ClusterIP
  |
  v
Cilium eBPF Service LB
  |
  v
Ready api Pod
```

Gateway 示例：

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: public-gateway
  namespace: gateway-system
spec:
  gatewayClassName: cilium
  listeners:
    - name: http
      protocol: HTTP
      port: 8080
      allowedRoutes:
        namespaces:
          from: All
    - name: https
      protocol: HTTPS
      port: 8443
      tls:
        mode: Terminate
        certificateRefs:
          - name: wildcard-example-com
      allowedRoutes:
        namespaces:
          from: All
```

HTTPRoute 示例：

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: api
  namespace: production
spec:
  parentRefs:
    - name: public-gateway
      namespace: gateway-system
  hostnames:
    - api.example.com
  rules:
    - backendRefs:
        - name: api-service
          port: 80
```

## 集群内部服务调用

默认自建路径下，内部服务调用不经过 Gateway，也不经过 Envoy：

```text
订单服务 Pod
  |
  v
http://user-service.production.svc
  |
  v
CoreDNS 返回 ClusterIP
  |
  v
Cilium eBPF Service Load Balancer
  |
  v
用户服务 Ready Pod
```

第一阶段不引入：

- Istio
- Sidecar
- Cilium GAMMA
- 内部 HTTPRoute
- Header 灰度
- 内部服务权重切流
- 服务网格

内部服务流量保持 L3/L4 数据路径。迁移到托管 Kubernetes 后，底层 Service 数据面可以变化，但不应影响应用层的 Service 调用模型。

## Kubernetes API 入口

单节点时，ECS-1 提供 Kubernetes API：

```text
https://ECS-1-IP:6443
```

三节点 HA 后，三台 K3s Server 都能提供 Kubernetes API：

```text
https://ECS-1-IP:6443
https://ECS-2-IP:6443
https://ECS-3-IP:6443
```

基础模式可以选择其中一个作为 kubeconfig 地址，故障时切换到另一个。

生产增强模式可以单独增加内部 NLB 或带健康检查的内部 DNS：

```text
k8s-api.internal.example.com
  |
  v
内部 NLB / DNS health check
  |
  v
ECS-1/2/3:6443
```

业务入口和 Kubernetes API 入口相互独立：

```text
业务入口:      8080 / 8443
集群管理入口:  6443
```

`6443` 不应向全公网开放，建议只允许 VPN、堡垒机和集群节点访问。

## 默认 K3s 网络配置方向

默认自建路径下，K3s 不再启用默认 Flannel、内置 NetworkPolicy、kube-proxy、Traefik 和 ServiceLB。

```yaml
# /etc/rancher/k3s/config.yaml

cluster-init: true

flannel-backend: none
disable-network-policy: true
disable-kube-proxy: true

disable:
  - traefik
  - servicelb

cluster-cidr: 10.32.0.0/16
service-cidr: 10.48.0.0/16
cluster-dns: 10.48.0.10
```

第一台节点就使用这份集群级配置。后续 Server 加入必须复用同一组关键参数，包括 Cluster CIDR、Service CIDR、Cluster DNS、禁用组件、禁用 kube-proxy 和禁用内置 NetworkPolicy。

## 默认 Cilium 配置方向

默认自建路径第一阶段不配置 Gateway 节点选择器，因此单节点时 ECS-1 提供 Gateway Listener，三节点 HA 后三台 ECS 都提供 Gateway Listener。

Single 模式：

```yaml
kubeProxyReplacement: true

routingMode: tunnel
tunnelProtocol: vxlan

gatewayAPI:
  enabled: true
  hostNetwork:
    enabled: true

l7Proxy: true

operator:
  replicas: 1

hubble:
  enabled: true
  relay:
    enabled: false
  ui:
    enabled: false
```

HA 模式升级完成后，平台自动把 Cilium Operator 提升到 2 副本：

```yaml
operator:
  replicas: 2
```

后续增加专用入口 Worker 或需要收敛入口节点时，再用节点标签限制 Gateway Listener：

```yaml
gatewayAPI:
  enabled: true
  hostNetwork:
    enabled: true
    nodes:
      matchLabels:
        node-role: gateway
```

## 安全组

默认自建路径的安全组方向如下。

公网或业务访问：

| 端口 | 来源 | 用途 |
| --- | --- | --- |
| TCP 8080 | 用户或 SLB / NLB | HTTP |
| TCP 8443 | 用户或 SLB / NLB | HTTPS |

管理访问：

| 端口 | 来源 | 用途 |
| --- | --- | --- |
| TCP 22 | VPN / 堡垒机 | SSH |
| TCP 6443 | VPN、堡垒机、集群节点 | Kubernetes API |

节点内部：

| 端口 | 来源 | 用途 |
| --- | --- | --- |
| TCP 2379-2380 | 仅 3 个 Server | etcd |
| UDP 8472 | 所有集群节点 | Cilium VXLAN |
| TCP 10250 | 集群内部 | kubelet |
| TCP 4240 | 集群内部 | Cilium health |
| ICMP | 集群内部 | Cilium health / 基础连通性诊断 |

## 扩容健康检查

节点加入后，平台需要自动等待：

```text
Node Ready
Cilium Agent Ready
CiliumNode Ready
节点间网络测试通过
Gateway Listener Ready
```

这些检查通过后，才允许业务 Pod 调度到新节点。

扩容完成后，平台需要触发受控再均衡：

```text
逐个 Deployment
-> 创建新 Pod
-> 新 Pod 在新节点 Ready
-> 删除旧节点上的一个 Pod
-> 继续下一个
```

默认应用模板应包含软分散策略，使单节点可调度、多节点后新 Pod 优先分布到不同节点。

## 托管 Kubernetes 迁移边界

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
-> 验证
                 ↓
切换 DNS / SLB
```

这里的“平滑”是应用、镜像、GitOps 仓库和发布界面不变，只替换运行集群并最终切换入口。

## 内部 Provider 替换规则

Provider 替换不是第一版普通用户功能。若企业高级场景确实需要替换 Gateway 或 CNI：

- Gateway 替换通常以标准 Gateway / HTTPRoute 为边界，影响 GatewayClass、Gateway 参数、TLS、负载均衡配置和少量实现相关注解。
- CNI 不建议在生产集群中原地频繁替换，应按“新集群 -> GitOps 重新部署应用 -> 验证 -> 切换入口 -> 下线旧集群”处理。

```text
生产集群运行中
-> 点击按钮把 Cilium 换成另一个 CNI
```

不是平台默认承诺。

## 对发布架构的影响

本网络架构把平台核心入口契约定义为 Gateway API，并把默认自建入口固定为 Cilium Gateway API Host Network。因此：

- 业务入口不再默认依赖云 SLB / NLB。
- 业务入口不再默认依赖 K3s bundled Traefik 或独立 Traefik。
- 单节点起步时 ECS-1 继续作为入口，1 -> 3 扩容过程中不迁移入口。
- 三节点 HA 后三台 ECS 都可以作为入口。
- 后续增加 Worker 默认只增加业务容量，不改变用户发布入口模型。
- Gateway 和 HTTPRoute 成为外部 HTTP/HTTPS 路由的主要对象。
- 内部服务调用不进入 Gateway，不使用服务网格。
- Argo Rollouts 仍负责发布状态机、暂停、Promote 和 Abort。

需要在系统设计阶段单独确认：

- Argo Rollouts 与 Gateway API / Cilium Gateway 的精确流量权重集成方式。
- 如果第一阶段不做精确 10% / 30% / 50% 外部流量权重切换，是否接受先用 Rollout 的副本级 canary、暂停和人工 Promote / Abort。
- 如果必须保留精确百分比流量切换，是否引入 Gateway API backend weight、Rollouts plugin、或保留一个专用 traffic-routing 组件。

## 当前结论

```text
产品核心:
  从单台服务器平滑成长为高可用 Kubernetes 集群的应用交付与运维平台
  + 应用模型
  + 发布模型
  + 健康诊断
  + 运维自动化
  + 企业扩展接口

稳定技术内核:
  Kubernetes API
  + Gateway API
  + GitOps

固定成长路径:
  1 Server
  -> 3 Server HA
  -> 3 Server + N Worker
  -> 必要时迁移到托管 Kubernetes

默认基础设施起点:
  1 台 ECS
  + 单成员 embedded etcd

默认 HA 形态:
  3 台 ECS
  + 可选 SLB / NLB
  + 可选 DNS 多 A 记录

默认 Kubernetes:
  K3s embedded-etcd
  + 第一台 cluster-init
  + 1 -> 3 原子化 HA 升级

默认网络实现:
  Cilium CNI
  + Cilium eBPF Service Dataplane
  + VXLAN Overlay
  + Hubble

默认外部入口:
  Cilium Gateway API Host Network
  + Gateway
  + HTTPRoute

默认基础访问方式:
  单节点: ECS-1 IP:8080/8443
  三节点: 任意 ECS IP:8080/8443

默认可选高可用入口:
  SLB/NLB 80/443 -> 三台 ECS:8080/8443

API 入口:
  基础模式手动选择任意 ECS:6443
  增强模式使用内部 NLB / DNS health check -> 三台 ECS:6443
```
