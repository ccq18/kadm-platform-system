# 集群结构说明

当前是 1 台 master + 2 台 worker 的 K3s 集群。

| 角色 | 节点名 | 公网 IP | 内网 IP | 说明 |
| --- | --- | --- | --- | --- |
| Master / 控制面 | 不作为 Node 注册 | `157.230.140.91` | `10.120.0.2` | 管理 Kubernetes API，不跑业务 Pod |
| Worker 1 | `k3s-worker-1` | `138.68.15.99` | `10.120.0.6` | 跑系统组件、业务 Pod、Traefik 入口、本机 MySQL |
| Worker 2 | `k3s-worker-2` | `157.230.152.21` | `10.120.0.7` | 跑系统组件、业务 Pod、Traefik 入口 |

## 为什么 `kubectl get nodes` 只看到两个节点

master 配置了：

```yaml
disable-agent: true
```

所以 master 只运行控制面，不作为 worker 注册到集群里。正常情况下，`kubectl get nodes -o wide` 只会看到：

```text
k3s-worker-1
k3s-worker-2
```

## 默认组件

当前保留了 K3s 默认组件：

- `coredns`
- `local-path-provisioner`
- `metrics-server`
- `traefik`
- `servicelb`

## 外部入口

Traefik / ServiceLB 在两个 worker 上对外提供入口：

```text
138.68.15.99:80
157.230.152.21:80
138.68.15.99:443
157.230.152.21:443
```

master `157.230.140.91` 主要是管理入口，不建议作为业务入口。

## 当前示例应用

`hello` 示例应用文档在：

```text
hello/k8s/README.md
```

当前 Ingress Host：

```text
hello.ai47.cc
```
