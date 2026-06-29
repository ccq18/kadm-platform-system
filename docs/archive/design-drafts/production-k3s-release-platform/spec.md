# Feature: Kubernetes Application Delivery Platform Target

**作者**: Codex  
**日期**: 2026-06-26  
**状态**: Draft

---

## 1. 背景 (Background)
### 1.1 问题描述
- 当前仓库记录的是一个学习和验证用途的 K3s 环境：1 台 master 加 2 台 worker，master 不作为 Node 注册，业务入口依赖 worker 上的 K3s 默认 Traefik / ServiceLB。
- 当前已经有 OneCD、Argo CD、Argo Rollouts、GitHub Actions 和 GHCR 串起来的发布链路雏形，但它仍是示例应用和薄发布控制台级别的能力，不是完整生产平台。
- 需要把现有学习环境的经验沉淀成目标产品：不是替代 Kubernetes，也不是做新的 Cloud Run，而是把 Kubernetes 封装成普通研发团队能直接使用的应用交付与运维平台。
- 平台要解决的核心矛盾是：Kubernetes 能力很强，但安装、发布、网络、证书、排障和升级太复杂；通过默认最佳实践、自动化和可理解的 UI，让小团队也能安全使用 Kubernetes。
- 初始产品路径支持从 1 台 ECS 起步，业务增长后通过“升级为高可用集群”一次性扩展到 3 台 Server，再通过 Worker 节点继续横向扩容；应用、域名、发布方式和使用习惯在扩容过程中保持不变。
- 当前集群定位为测试集群，可以直接按新方案重建；本期不要求在现有 `1 master + 2 worker` 形态上做原地迁移。
- 该目标文档只固定“要达到什么目标”和“必须满足哪些约束”，不在本阶段决定完整实施方案。

### 1.2 现状分析
- 当前集群形态记录在 `docs/cluster-overview.md` 和 `docs/deployment-2026-06-25.md`：
  - 1 个 agentless K3s master：`157.230.140.91` / `10.120.0.2`。
  - 2 个 worker：`k3s-worker-1`、`k3s-worker-2`，承担业务 Pod 和入口流量。
  - K3s 版本记录为 `v1.35.5+k3s1`，安装方式为 `stable` channel。
  - 当前保留 K3s 默认组件，包括 `traefik` 和 `servicelb`。
- 当前发布链路记录在 `docs/onecd-release-system.md`：
  - OneCD UI/API 触发 GitHub Actions workflow。
  - GitHub Actions 构建镜像并更新应用仓库 `k8s/overlays/prod` 的镜像 tag。
  - Argo CD 读取 GitHub 并同步 Application。
  - Argo Rollouts 执行 canary 发布。
  - OneCD 当前默认只通过 `kubectl port-forward` 内部访问，不暴露公网。
- 当前与目标生产形态的主要差距：
  - 当前集群不是从单成员 embedded etcd 开始的可成长拓扑，也不是 3 Server embedded-etcd HA，不能平滑扩展为目标形态。
  - 入口仍是 K3s 默认 Traefik / ServiceLB，没有切换到基于标准 Gateway API 的目标入口模型。
  - 网络、Service 数据面、Gateway 和网络观测还没有形成稳定的集群级配置与内部 Provider 边界；当前自建 K3s 默认实现计划采用 Cilium，但 Cilium 不能成为平台核心业务模型。
  - 备份、恢复演练、升级策略、监控告警、密钥管理、发布审批和审计尚未形成完整生产闭环。
  - OneCD 仍是示例级薄封装，没有生产级用户、权限、审批、发布锁、审计、通知和持久化发布单模型。

### 1.3 主要使用场景
- 从当前学习型 K3s 环境演进到可从单节点平滑成长的 Kubernetes 应用交付平台。
- 用户从 1 台服务器开始运行平台和业务，业务增长后点击“升级为高可用集群”，平台自动加入另外 2 台 Server 并形成 3 成员 embedded-etcd 集群。
- 3 台 Server 后继续增长时，用户点击“添加节点”，平台默认以 Worker 身份加入新节点，不要求用户选择 Server / Agent、CNI、Pod CIDR 或 GatewayClass。
- 普通研发用户通过“应用、环境、版本、配置、域名、日志、发布、回滚”完成日常交付，而不是直接操作 Deployment、Service、HTTPRoute、Argo CD Application 等 Kubernetes 对象。
- 运维和平台开发者通过高级模式查看 YAML、事件、Pod、Argo CD 状态、网络策略、集群规格和底层能力。
- 使用 GitHub Actions、镜像仓库、GitOps 仓库、Argo CD、Argo Rollouts、标准 Gateway API 和默认自建路径完成生产应用发布。
- 通过应用交付门户发起发布、查看状态、人工推进 canary、执行 Promote / Abort / 永久回滚。
- 在单台 ECS 故障、入口 Pod 故障、发布组件故障、构建系统故障等场景下保持业务运行或明确降级边界。
- 将 Kubernetes 原始错误翻译成用户可理解的原因、影响和建议，例如把 Pod Pending 解释成资源不足、调度约束不满足或镜像拉取失败。
- 定期进行 etcd 备份、异地对象存储保存、隔离环境恢复演练和升级演练。

## 2. 目标 (Goals)
- 产品定位见 `docs/design-docs/platform/production-k3s-release-platform/product-positioning.md`：平台是可以从单台服务器平滑成长为高可用 Kubernetes 集群的应用交付与运维平台，核心价值是固定黄金路径、自动化扩容、应用模型、发布模型、健康诊断、运维自动化和默认最佳实践。
- 集群成长路径见 `docs/design-docs/platform/production-k3s-release-platform/cluster-growth-path.md`：默认固定为 `1 Server -> 3 Server HA -> 3 Server + N Worker -> 必要时迁移到托管 Kubernetes`。
- 实施路线见 `docs/design-docs/platform/production-k3s-release-platform/implementation-plan.md`：按 P0 准备、P1 单节点起步、P2 应用交付 MVP、P3 `1 -> 3` HA、P4 Worker 扩容、P5 生产治理、P6 托管 Kubernetes 迁移验证推进。
- 建立一套 1 台 ECS 可起步、3 台 ECS 可达到控制面高可用的目标生产平台架构：第一台即使用 K3s Server + 单成员 embedded etcd，后续通过原子化任务扩展为 3 Server embedded-etcd HA。
- Kubernetes API + Gateway API + GitOps 作为稳定平台内核，Argo CD 管理 GitOps，Argo Rollouts 管理渐进式发布，应用交付门户负责产品化编排、权限审计、状态聚合和诊断翻译。
- 默认自建 K3s 集群固定使用 Cilium、Cilium Gateway API Host Network 和 Argo CD；底层可替换只作为平台内部边界和高级/企业场景能力，不作为普通用户首次安装时的选择题。
- 目标平台需要在成本、可用性、可迁移性和学习价值之间取得平衡：初期可用 1 台 ECS 完成起步，3 台 4C8G ECS 达到基础 HA，后续可以增加 Worker、拆分状态服务、增强权限审批和扩展到多集群。
- 面向普通研发提供接近 PaaS 的使用体验：应用创建、配置、域名、HTTPS、日志、资源使用、发布、回滚和基础诊断；默认不要求用户理解 Kubernetes 对象。
- 面向运维和平台开发者保留 Kubernetes 深入管理能力：查看 YAML、事件、Pod、Argo CD 状态、网络策略、集群规格、底层能力和节点扩容状态。
- 生产发布链路的真实状态必须以 Git、Argo CD、Rollout CRD、Gateway / HTTPRoute 和 Kubernetes 对象为准；发布门户不能成为线上流量状态的唯一来源。
- 当前阶段发布链路、门户状态模型和仓库边界沿用现有 OneCD 方案：Build -> Sync -> Promote / Abort，门户不引入持久化数据库，仓库仍以 `onecd`、`demo-hello`、`demo-hello-spring` 的当前边界推进。GitOps 边界说明见 `docs/design-docs/platform/production-k3s-release-platform/gitops-boundary.md`。
- 网络入口目标见 `docs/design-docs/platform/production-k3s-release-platform/network-architecture.md`：单节点起步时原节点继续作为业务入口；升级到 3 Server HA 后三台 ECS 均可通过 Cilium Gateway Host Network 直接提供 8080/8443 业务入口，云 SLB / NLB 只是可选增强。
- 所有关键组件优先使用开源组件，并通过明确版本、GitOps、变更审查、备份恢复和验收测试降低长期维护风险。

### 2.1 非目标 (Non-Goals)
- 实施路线已单独记录在 `docs/design-docs/platform/production-k3s-release-platform/implementation-plan.md`；本目标文档不展开具体 YAML、Terraform 模块拆分、命令手册和逐步操作细节。
- 不要求保留当前测试集群的 Kubernetes 对象、节点角色和入口形态；允许清空后按目标生产形态重新部署。
- 不替代 Kubernetes，不重新实现 Kubernetes 调度器、CNI 数据面、Git 引擎、CI 执行器、镜像仓库、Argo CD 对账逻辑、Prometheus 或云负载均衡器。
- 不把产品定位成 Cloud Run、SAE 或完全隐藏基础设施的通用 PaaS；这些系统可以作为体验参考，但不是平台的技术边界。
- 不把发布门户设计成 Kubernetes 控制器、CI/CD 系统、流量控制器或 Pod 编排器；它做产品化编排、流程、权限、审计、状态聚合和诊断翻译。
- 不让 GitHub Actions 直接操作生产集群，不保存生产 kubeconfig，不执行 `kubectl apply`、`helm upgrade`、`kubectl set image` 或 `argocd app sync`。
- 不在 3 台 4C8G ECS 的初始生产形态中部署重型集群内状态组件，例如 Elasticsearch、Ceph、Longhorn、大型 Loki 集群或生产数据库。
- 不在未完成认证、HTTPS、访问控制和审计前暴露发布门户公网入口。
- 不在目标确认阶段承诺具体组件版本为最终生产版本；附件中的版本号和维护状态需要在实施前按实际日期复核。
- 不覆盖异地多活、跨地域自动容灾、完整企业级 PaaS、自助建集群和通用多租户平台能力。
- 当前阶段不建设生产级发布门户数据库，不实现发布单、审批流、通知中心、发布锁和持久化审计表；这些作为后续增强项。
- 当前阶段不强制拆分为独立基础设施仓库、平台 GitOps 仓库、业务部署 GitOps 仓库和业务源码仓库；仓库拆分作为后续规模化治理项。
- 不承诺在一个正在运行的生产集群内一键热切换 CNI；CNI 替换默认按“新集群规格 -> 新集群 -> Argo CD 重新部署应用 -> 验证 -> 切换入口 -> 下线旧集群”的方式处理。
- 第一版不把 CNI Provider、Service Dataplane Provider、Gateway Provider、Observability Provider、ClusterProfile 自定义、任意插件替换、Cilium / Calico 选择做成面向普通用户的产品功能；这些只保留为内部边界或高级/企业场景能力。
- 不把 CNI、Service Dataplane、Gateway Controller、IPAM 模式等底层选择暴露为普通用户首次安装时必须理解的选项。

## 3. 需求细化 (Requirements)
### 3.1 功能性需求
- 产品模型与用户体验：
  - 普通模式必须围绕应用生命周期组织页面和 API，核心对象包括应用、环境、版本、配置、域名、日志、发布和回滚。
  - 普通模式默认不暴露 Deployment、ReplicaSet、Pod、Service、HTTPRoute、GatewayClass、ConfigMap、Secret、PDB、HPA、Argo CD Application 等 Kubernetes 对象名称作为用户完成发布的必备概念。
  - 高级模式必须允许运维和平台人员查看 Kubernetes YAML、事件、Pod、容器、Argo CD 状态、网络策略、Gateway / HTTPRoute、集群规格、底层能力、节点加入状态和再均衡状态。
  - 平台应将 Kubernetes 原始状态翻译成可理解的诊断结论，至少包含问题、原因、影响范围、关键证据和建议动作。
  - 普通用户的部署模式选择应收敛为“单台服务器起步”“升级为高可用集群”“添加计算节点”“导入已有 Kubernetes”这类产品选项；底层 Provider 选择不作为普通模式功能。
- 自动化黄金路径：
  - 集群层需要覆盖添加第一台服务器、系统和网络参数检查、安装 K3s Server + 单成员 embedded etcd、安装 Cilium、安装 Gateway、安装 Argo CD、配置备份和验证集群健康。
  - 高可用升级需要提供单一操作入口“升级为高可用集群”，用户只提供另外两台服务器，平台连续完成 Server 2 和 Server 3 加入、etcd 三成员健康检查、Kubernetes API 检查、Cilium 检查、系统组件副本提升和入口更新。
  - Worker 扩容需要提供单一操作入口“添加节点”，3 Server 之后默认以 Agent Worker 身份加入新节点，不让普通用户选择 etcd、Server / Agent 参数、Pod CIDR、GatewayClass 或系统组件副本数。
  - 集群扩容后需要执行受控工作负载再均衡，避免新增节点长期空置，也避免一次性驱逐全部 Pod。
  - 应用层需要覆盖连接代码仓库、识别 Dockerfile 或构建方式、生成 CI 模板、构建镜像、生成标准 Kubernetes / Gateway API 资源、配置域名和 HTTPS、发布和观测发布结果。
  - 运维层需要覆盖节点预检、安全加入集群、故障节点替换、版本一致性检查、证书到期检测、etcd 备份检查、磁盘容量检测、Pod 异常诊断、版本升级检查、容量建议和发布失败回滚。
- 基础设施与集群：
  - 单节点起步形态使用 1 台 ECS，运行 K3s Server、单成员 embedded etcd、Worker 工作负载、Cilium Gateway、平台组件和业务 Pod。
  - 第一台节点必须从第一天使用 embedded etcd 和 `cluster-init`，不默认使用 SQLite，避免后续从 SQLite 转换 datastore。
  - 第一次安装必须生成并保存集群级配置，包括 ClusterSpec、Cluster Token、K3s Version、Cilium Version、网络 CIDR、组件开关、证书 SAN 和节点清单。
  - 后续 Server 加入必须复用同一份关键配置；K3s 的 Cluster CIDR、Service CIDR、Cluster DNS、禁用组件、禁用 kube-proxy / NetworkPolicy 等关键参数不得在 Server 间不一致。
  - 从 1 Server 升级到 3 Server 必须作为一个原子化任务处理，不允许集群长期停留在 2 Server 状态。
  - HA 形态使用 3 台 ECS，每台同时承担 K3s Server、Kubernetes 控制面、embedded etcd、Worker 工作负载和默认 Gateway 入口。
  - 3 台以后默认增加 Worker 节点，控制面 Server 数量保持 3；只有确实需要容忍两个控制面节点故障时，才评估扩展到 5 Server。
  - 默认自建路径下，基础业务入口不依赖云 NLB / SLB；单节点时原 ECS 提供入口，三节点 HA 后三台 ECS 均通过 Cilium Gateway Host Network 提供 8080/8443；云 NLB / SLB 作为入口自动故障转移的可选增强。
  - Kubernetes API 可在基础模式下访问任意 ECS:6443，生产增强模式可使用内部 NLB 或带健康检查的内部 DNS；业务入口和 API 入口必须相互独立。
  - 节点间通信优先走私网，安全组必须限制 etcd、默认 Profile 的 Cilium VXLAN / health、kubelet、SSH、API 和业务入口来源；替换网络实现时必须给出等价端口和来源限制。
  - 基础设施需要通过 IaC 和可重复自动化方式管理，目标包括 Terraform、cloud-init 和 k3s-ansible 这类职责分离的工具链。
- 底层 Provider 边界：
  - 平台稳定核心依赖 Kubernetes API、Gateway API 和 GitOps，而不是依赖 Cilium 私有 API。
  - 第一版普通用户路径固定为 K3s + embedded etcd + Cilium + Gateway API + Argo CD，不向用户暴露 Provider 选择。
  - 代码和文档内部仍保留 NetworkProvider、ServiceDataplaneProvider、GatewayProvider 和 ObservabilityProvider 边界，方便后续托管 Kubernetes、企业私有云或高级插件接入。
  - Provider 必须通过 capability 声明能力，例如 `nodeDirectAccess`、`managedLoadBalancer`、`standardGatewayAPI`、`standardNetworkPolicy`、`flowVisibility`、`kubeProxyReplacement` 和 `advancedEgressPolicy`；门户和模板逻辑不能写死 `provider == cilium`。
  - Cilium 专属资源应限制在默认集群 Profile 或高级插件中，不进入默认业务应用模板。
- GitOps 与仓库边界：
  - 当前阶段沿用现有 `onecd`、`demo-hello`、`demo-hello-spring` 仓库边界。
  - 后续规模化阶段再评估是否拆分基础设施仓库、平台 GitOps 仓库、业务部署 GitOps 仓库和业务源码仓库。
  - 平台组件和业务应用的期望状态都应由 GitOps 仓库表达，并由 Argo CD 同步到集群。
  - Argo CD 初始 bootstrap 后，默认集群 Profile、Cilium 相关资源、Gateway API 相关资源、cert-manager、Argo Rollouts、监控、密钥集成、升级控制器和发布门户应逐步纳入 GitOps 管理。
- 流量入口与渐进式发布：
  - 平台应用层入口契约使用标准 Gateway API、Gateway 和 HTTPRoute；默认自建路径的实现是 Cilium Gateway API Host Network 和 Cilium Envoy Gateway。
  - 默认自建路径下 K3s 需要禁用默认 Flannel、内置 NetworkPolicy、kube-proxy、Traefik 和 ServiceLB；托管 Kubernetes 或高级企业场景按自身 Provider 要求配置。
  - 默认自建路径下单节点由 ECS-1 提供 Gateway Listener，三节点 HA 后三台 ECS 都提供 Gateway Listener；后续增加专用入口 Worker 后，可通过节点标签把 Gateway Listener 限制到专用入口节点。
  - 外部 HTTP/HTTPS 通过 Gateway + HTTPRoute 路由到 Kubernetes Service；内部服务调用不经过 Gateway、不经过 Envoy、不引入服务网格。
  - Argo Rollouts 仍负责发布状态机、暂停、Promote 和 Abort；精确百分比流量权重是否通过 Gateway API / Cilium Gateway 实现，需要在系统设计阶段验证。
- 应用资源契约：
  - 默认业务模板只能生成标准 Kubernetes / Gateway API 资源，包括 Deployment、Service、Gateway、HTTPRoute、NetworkPolicy、HPA、PDB、ConfigMap 和 Secret 引用。
  - 应用模板从第一天就应包含软分散策略，例如 `topologySpreadConstraints` 使用 `whenUnsatisfiable: ScheduleAnyway`，保证单节点可调度，多节点后新 Pod 优先跨节点分布。
  - 零停机再均衡要求应用至少有 `replicas >= 2`、正确的 Readiness Probe，并使用 `maxUnavailable: 0`、`maxSurge: 1` 的滚动策略；单副本应用再均衡时平台必须提示风险，必要时临时扩为 2 副本后再恢复。
  - 默认业务模板不得生成 CiliumNetworkPolicy、CiliumEnvoyConfig、CiliumBGPPeeringPolicy、CiliumEgressGatewayPolicy 等 Cilium 专属资源。
  - 企业需要高级网络能力时，应通过 Profile 扩展、平台插件或显式高级选项生成 Provider 专属资源，并在能力矩阵中标注不可跨 Provider 迁移。
- CI 与镜像：
  - GitHub Actions 只负责代码检查、测试、构建镜像、镜像扫描、推送镜像、生成镜像 digest 和创建 GitOps 变更。
  - 生产镜像引用必须使用 digest，避免使用 `latest` 这类不可追踪标签。
  - 生产环境凭证应优先使用 OIDC、短期凭证、GitHub App 或受保护 Environment，避免长期密钥。
- 发布门户：
  - 当前阶段沿用 OneCD 薄门户能力，支持应用列表、状态查看、Build、Sync、Promote、Abort 和 Restart。
  - 当前阶段发布流程沿用 Build -> Sync -> Promote / Abort，不强制引入 GitOps PR 审批流。
  - 当前阶段门户不引入数据库；运行时任务可以保持进程内状态，重启后从 GitHub Actions、Argo CD、Rollout CRD 和 Kubernetes 状态重新推导。
  - 项目管理、环境管理、镜像版本列表、发布审批、发布锁、持久化审计记录和通知作为后续生产增强项。
  - 门户查看线上真实状态时应聚合 Git、Argo CD、Rollout CRD、Gateway / HTTPRoute 和 Kubernetes Pod 状态。
  - 门户操作 Rollouts 时优先通过 Argo CD Resource Actions 或等价受限接口，不直接持有高权限 kubeconfig。
- 回滚与恢复：
  - 紧急故障回切通过 Rollouts Abort 将流量切回 stable。
  - 永久回滚必须通过 GitOps 变更恢复旧镜像 digest，再由 Argo CD 对账。
  - etcd 快照需要定期生成、压缩、远程保存，并和 K3s Server Token 一起纳入灾难恢复材料。
  - 必须支持在隔离 VPC 中恢复三节点集群并验证关键资源存在。
- 升级与验收：
  - 正式上线前必须验证单节点安装、1 -> 3 HA 升级、Worker 横向扩容、受控再均衡、故障节点替换和托管 Kubernetes 迁移边界。
  - K3s 升级需要支持逐台 Server 升级、健康检查和回滚预案。
  - Argo CD、Rollouts、默认自建路径中的 Cilium 或其他内部 Provider 组件升级应通过 Git PR、测试环境验证、Release Notes 检查和生产同步完成。
  - 正式上线前必须通过节点故障、发布故障、管理面故障、备份恢复、网络与流量切换等验收测试。

### 3.2 非功能性需求
- 可用性：
  - 单节点起步形态不是高可用，节点故障会中断业务；平台必须明确展示该风险，并引导用户升级到 3 Server HA。
  - 目标三节点 embedded-etcd 集群需要承受任意一台 ECS 故障，剩余两台保持 etcd 多数派和业务服务能力。
  - 1 -> 3 扩容过程中，2 Server 只是短暂中间态，不应被平台标记为高可用状态。
  - 两台 ECS 同时故障、整个地域故障不在单集群高可用能力范围内，需要通过恢复方案或后续多地域方案处理。
  - 发布门户、GitHub Actions、Argo CD 或 Rollouts Controller 故障不应直接中断已稳定运行的业务请求；若后续引入门户数据库，其故障也不应影响线上业务流量。
- 容量与成本：
  - 初始生产目标以 3 台 4 vCPU / 8 GB ECS 为基线，正常运行时 CPU 平均使用率建议不超过 50% 到 60%，内存平均使用率建议不超过 65%，磁盘使用率建议不超过 70%。
  - 状态数据优先外置到云数据库、对象存储、镜像仓库或云日志服务，减少三节点集群内部资源压力。
- 安全：
  - etcd 端口、VXLAN 端口、数据库端口和管理端口不得暴露公网。
  - Kubernetes API 优先限制为 VPN、堡垒机和集群节点访问；基础模式可手动切换不同 ECS:6443，增强模式使用内部 NLB 或健康检查 DNS。
  - 业务入口基础模式开放 8080/8443，增强模式由 SLB / NLB 80/443 转发到三台 ECS:8080/8443。
  - Secret、Token、kubeconfig、SSH 私钥、数据库密码和对象存储密钥不得提交到 Git。
  - 发布门户上线前必须具备认证、授权、HTTPS、审计日志和最小权限访问策略。
- 可维护性：
  - 关键组件版本必须固定到明确版本、tag 或 commit，不使用 `latest` 或无约束的 `main`。
  - 所有平台变更应通过 PR、审查、测试环境验证和 Argo CD 同步落地。
  - 组件维护状态、版本安全补丁和兼容性需要在实施前按实际日期复核。
- 可迁移性：
  - 架构应尽量避免绑定 K3s 或 Cilium 私有能力到不可替换的业务流程中；将来需要可迁移到其他 Kubernetes 发行版和网络实现。
  - 业务应用、发布流程和门户状态聚合应优先依赖标准 Kubernetes API、Gateway API、GitOps、Argo CD 和 Rollout CRD；Provider 专属能力必须通过内部集群规格与 capability 隔离。
  - K3s 不能原地转换成 ACK、EKS 或 GKE；迁移到托管 Kubernetes 的边界是创建新集群、通过 GitOps 重建应用、验证后切换 DNS / SLB。
  - 发布门户依赖应面向 GitOps、Argo CD API 和标准 Kubernetes 对象，避免把线上状态绑定在门户私有数据库中。
- 可观测性与审计：
  - 平台需要具备指标、日志、告警、发布记录、审批记录和操作审计。
  - 发布状态判断不能只依赖门户本地状态，必须可从 Argo CD、Rollout、Gateway / HTTPRoute 和 Pod 状态重新推导。
  - 当前阶段若不引入门户数据库，发布记录、审批记录和操作审计只能达到基础日志级别；持久化审计作为后续增强项。
- 备份与演练：
  - etcd 快照需要远程加密保存，Server Token 需要单独安全保存。
  - 备份恢复需要至少按季度演练；未经恢复验证的备份不能视为有效备份。
- 兼容性：
  - 默认自建路径下，Cilium、Gateway API、Rollouts、Argo CD、K3s、cert-manager 和监控组件的版本兼容矩阵需要在系统设计和实施前明确。
  - 托管 Kubernetes 或高级企业场景必须给出等价兼容矩阵、能力矩阵和不支持能力清单。
  - K3s、Cilium 或替代 Provider、Argo CD、Rollouts 的升级不能跳过不支持的版本跨度，并应避开正在进行的生产发布窗口。

## 4. 设计方案 (Design)
### 4.1 方案概览
- 整体思路、架构图（如有）
### 4.2 组件设计 (Component Design)
#### 4.2.1 核心类/模块设计
- 类职责、继承关系、模块划分
#### 4.2.2 接口设计
- 对外暴露的 public API（签名、参数、返回值、错误码）
#### 4.2.3 数据模型
- Schema、索引、存储格式（如适用）
#### 4.2.4 并发模型
- 线程模型、锁策略、异步边界（如适用）
#### 4.2.5 错误处理
- 失败模式、重试策略、恢复机制（如适用）
### 4.3 核心逻辑实现
- 关键代码路径、算法说明
### 4.4 方案优劣分析
- 本方案的优点和局限性

## 5. 备选方案 (Alternatives Considered)
- 考虑过但最终未采用的方案，及其被放弃的原因

## 6. 业界调研 (Industry Research)

> **注意**：本章节应在完成自主设计后填写，用于验证方案、确保下限，而非作为设计的起点。

### 6.1 业界方案
- 业界其他系统如何解决类似问题？
- 相关论文或技术博客中的方案
### 6.2 对比分析
- 我们的方案与业界方案有何异同？
- 业界方案中有哪些值得借鉴的点？
- 有哪些已知的坑需要避免？

## 7. 测试计划 (Test Plan)
### 7.1 单元测试
### 7.2 集成测试
### 7.3 性能测试（如适用）

## 8. 可观测性 & 运维 (Observability & Operations)

### 8.1 可观测性
- **日志 (Logging)**: 新增的日志输出点、日志级别、关键日志格式
- **监控指标 (Metrics)**: 新增的监控指标名称、含义、采集方式
- **告警 (Alerting)**: 建议的告警规则和阈值

### 8.2 配置参数 (Configuration)
| 参数名 | 类型 | 默认值 | 说明 | 是否支持动态修改 |
|--------|------|--------|------|------------------|
| `xxx_enabled` | bool | true | 功能开关 | 是 |
| `xxx_threshold` | int | 1000 | 阈值设置 | 否（需重启） |

### 8.3 运维接口 (Operations Interfaces)
- **新增命令/API**: 如管理命令、HTTP 接口、CLI 工具
- **示例**:
  ```
  # 查看功能状态
  your-tool status xxx

  # 动态调整参数
  your-tool config set xxx_threshold 2000
  ```

### 8.4 运维注意事项 (Operations Considerations)
- **升级兼容性**: 是否需要特殊的升级步骤？滚动升级是否安全？
- **回滚方案**: 如何快速回滚？是否有数据格式变更？
- **资源影响**: 对 CPU/内存/磁盘/网络的影响预估
- **故障处理**: 功能异常时的应急处理步骤

## 9. Changelog
| 日期 | 变更内容 | 作者 |
|------|----------|------|
| ...  | ...      | ...  |

## 10. 参考资料 (References)
- 相关论文、文档、Wiki 链接
