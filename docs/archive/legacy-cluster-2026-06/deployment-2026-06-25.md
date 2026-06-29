# K3s 部署记录（2026-06-25）

这份文档记录当前 K3s 集群的实际部署过程、关键配置和验证结果，便于后续维护、排查和重建。

## 1. 部署目标

- 形态：`1 master + 2 worker`
- 安装方式：全新部署
- 入口策略：保留 K3s 默认组件，包含 `Traefik` 和 `ServiceLB`
- 目标版本：K3s `stable` 通道

## 2. 服务器信息

| 角色 | 公网 IP | 内网 IP | 主机名 | 规格 |
| --- | --- | --- | --- | --- |
| Master | `157.230.140.91` | `10.120.0.2` | `ubuntu-s-2vcpu-4gb-sfo2` | 2 vCPU / 4GB / 77GB |
| Worker 1 | `138.68.15.99` | `10.120.0.6` | `ubuntu-s-2vcpu-4gb-sfo2-02` | 2 vCPU / 4GB / 77GB |
| Worker 2 | `157.230.152.21` | `10.120.0.7` | `ubuntu-s-2vcpu-4gb-sfo2-03` | 2 vCPU / 4GB / 77GB |

系统信息：

- OS：Ubuntu 24.04.3 LTS
- Kernel：`6.8.0-71-generic`
- 供应商：DigitalOcean

## 3. 部署前检查

部署前确认：

- 三台机器均可通过 `root` SSH 登录。
- 三台机器无现有 `k3s` / `k3s-agent` 运行状态。
- 三台机器之间私网互通：
  - `10.120.0.2`
  - `10.120.0.6`
  - `10.120.0.7`
- 宿主机 `systemd-resolved` 上游 DNS 存在重复 nameserver，因此额外准备独立的 `resolv.conf` 供 kubelet 使用。

## 4. 实际配置

### 4.1 Master 配置

路径：

```text
/etc/rancher/k3s/config.yaml
```

内容：

```yaml
node-name: "k3s-master-1"
node-ip: "10.120.0.2"
node-external-ip: "157.230.140.91"
flannel-iface: "eth1"
write-kubeconfig-mode: "600"
egress-selector-mode: "pod"
disable-agent: true
tls-san:
  - "157.230.140.91"
  - "10.120.0.2"
kubelet-arg:
  - "resolv-conf=/etc/rancher/k3s/resolv.conf"
```

### 4.2 Worker 1 配置

路径：

```text
/etc/rancher/k3s/config.yaml
```

内容：

```yaml
node-name: "k3s-worker-1"
node-ip: "10.120.0.6"
node-external-ip: "138.68.15.99"
flannel-iface: "eth1"
kubelet-arg:
  - "resolv-conf=/etc/rancher/k3s/resolv.conf"
```

### 4.3 Worker 2 配置

路径：

```text
/etc/rancher/k3s/config.yaml
```

内容：

```yaml
node-name: "k3s-worker-2"
node-ip: "10.120.0.7"
node-external-ip: "157.230.152.21"
flannel-iface: "eth1"
kubelet-arg:
  - "resolv-conf=/etc/rancher/k3s/resolv.conf"
```

### 4.4 独立 DNS 配置

三台机器都创建了：

```text
/etc/rancher/k3s/resolv.conf
```

内容：

```text
nameserver 67.207.67.2
nameserver 67.207.67.3
search .
```

用途：

- 避免 Pod 继承宿主机重复 nameserver。
- 降低 `DNSConfigForming / Nameserver limits exceeded` 这类噪音告警出现的概率。

## 5. 安装命令

### 5.1 Master

```bash
curl -sfL https://get.k3s.io | INSTALL_K3S_CHANNEL=stable sh -
```

### 5.2 Worker

worker 通过以下形式加入：

```bash
curl -sfL https://get.k3s.io | \
  K3S_URL=https://10.120.0.2:6443 \
  K3S_TOKEN="<server node token>" \
  INSTALL_K3S_CHANNEL=stable \
  sh -
```

注意：

- 实际 `K3S_TOKEN` 为敏感信息，本文档不保留明文。
- worker 连接地址使用的是 master 私网地址 `10.120.0.2:6443`。

## 6. 部署结果

### 6.1 版本

- K3s：`v1.35.5+k3s1`
- Container runtime：`containerd://2.2.3-k3s1`

### 6.2 Node 状态

最终节点：

```text
NAME           STATUS   ROLES    VERSION        INTERNAL-IP   EXTERNAL-IP
k3s-worker-1   Ready    <none>   v1.35.5+k3s1   10.120.0.6    138.68.15.99
k3s-worker-2   Ready    <none>   v1.35.5+k3s1   10.120.0.7    157.230.152.21
```

说明：

- master 设置了 `disable-agent: true`，因此不会注册为调度节点。
- master 额外启用了 `egress-selector-mode: "pod"`，用于让 agentless control-plane 正常访问集群内 Pod / Service。

### 6.3 默认系统组件

部署完成后已确认以下系统组件运行正常：

- `coredns`
- `local-path-provisioner`
- `metrics-server`
- `traefik`
- `svclb-traefik`

### 6.4 Traefik 对外暴露

`traefik` 当前为 `LoadBalancer`：

```text
EXTERNAL-IP: 138.68.15.99,157.230.152.21
PORTS: 80, 443
```

对应的 NodePort：

```text
80:32675/TCP
443:31552/TCP
```

## 7. 验证结果

### 7.1 服务状态

已验证：

- master `systemctl is-active k3s` = `active`
- worker `systemctl is-active k3s-agent` = `active`

### 7.2 API 健康

已验证：

```bash
kubectl get --raw=/readyz?verbose
```

结果：`readyz check passed`

### 7.3 Pod DNS 与集群 Service

已执行临时 smoke Pod 验证，结果如下：

- Pod 可正常调度。
- `nslookup kubernetes.default.svc.cluster.local` 成功。
- 通过 Pod 访问 `http://kube-dns.kube-system.svc.cluster.local:9153/metrics` 成功。
- 测试 Pod 已删除。

### 7.4 Metrics API

本次部署后曾发现一个真实问题：

- `kubectl top nodes`
- `kubectl top pods -A`

最初返回：

```text
error: Metrics API not available
```

根因确认如下：

- master 采用 `disable-agent: true` 的 agentless 形态
- 初始配置中未显式设置 `egress-selector-mode`
- 导致 apiserver 访问集群内部 `metrics-server` Service / Pod 链路异常

修复动作：

- 在 master 的 `/etc/rancher/k3s/config.yaml` 中加入：

```yaml
egress-selector-mode: "pod"
```

- 重启 master 的 `k3s`
- 重启两个 worker 的 `k3s-agent`

修复后已验证：

```bash
kubectl top nodes
kubectl top pods -A
```

现在均可正常返回 CPU / 内存指标。

## 8. 运维常用命令

查看节点和 Pod：

```bash
kubectl get nodes -o wide
kubectl get pods -A -o wide
kubectl get svc,endpoints -A -o wide
```

查看事件：

```bash
kubectl get events -A --sort-by=.lastTimestamp | tail -50
```

查看 master 日志：

```bash
journalctl -u k3s -n 200 --no-pager
```

查看 worker 日志：

```bash
journalctl -u k3s-agent -n 200 --no-pager
```

## 9. 风险和后续建议

- 当前未额外配置云防火墙和主机防火墙，建议后续限制：
  - `22` 仅允许管理出口 IP。
  - `6443` 仅允许管理 IP 和 worker 节点访问。
- 如需正式承载业务，建议补充：
  - 备份策略
  - 命名空间规划
  - Ingress 域名和 TLS
  - 资源限制（requests / limits）
  - 监控和日志
- 如果以后要重建集群，可以直接复用本文档中的私网拓扑和配置结构。

## 10. Worker 1 本机 MySQL

除 K3s 组件外，`worker1 (138.68.15.99 / 10.120.0.6)` 上额外安装了一个系统级 MySQL。

### 10.1 安装结果

已确认：

- 包名：`mysql-server`
- 版本：`8.0.46-0ubuntu0.24.04.3`
- 服务名：`mysql.service`
- 状态：`active (running)`
- 开机自启：`enabled`

### 10.2 当前监听

当前端口监听如下：

```text
127.0.0.1:3306
127.0.0.1:33060
```

说明：

- `3306` 是传统 MySQL 端口
- `33060` 是 MySQL X Plugin 端口
- 当前都只监听本地回环地址，所以默认只能本机访问

### 10.3 当前登录方式

当前 MySQL 用户中，`root@localhost` 使用：

```text
auth_socket
```

因此推荐登录方式是：

```bash
ssh root@138.68.15.99
mysql -uroot
```

这不是基于远程 TCP 密码认证，而是基于本机 root 用户登录后的 socket 认证。

### 10.4 已验证内容

已实际验证：

```bash
systemctl is-active mysql
mysql --version
mysql -uroot -e "SELECT VERSION(), @@hostname, @@port, @@bind_address;"
```

验证结果：

- MySQL 服务正常运行
- 版本正确
- 当前绑定地址为 `127.0.0.1`

### 10.5 后续说明

如果以后要开放远程访问，需要额外处理：

- 修改 MySQL `bind-address`
- 创建允许远程来源的数据库用户
- 收紧云防火墙 / 主机防火墙来源

当前为了安全，未开放远程 TCP 访问。
