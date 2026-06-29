# 常见排查

这篇文档按“先集群、再入口、再节点、再应用”的顺序排查。

## 第一步：master 上查节点

登录 master：

```bash
ssh root@157.230.140.91
```

执行：

```bash
kubectl get nodes -o wide
```

正常应看到两个 worker 都是 `Ready`。

如果有 worker 是 `NotReady`，再登录对应 worker 查：

```bash
systemctl status k3s-agent --no-pager -l
journalctl -u k3s-agent -n 200 --no-pager
```

## 第二步：master 上查 Pod

```bash
kubectl get pods -A -o wide
```

重点看：

- `Running`：正常
- `CrashLoopBackOff`：容器反复崩溃
- `ImagePullBackOff`：镜像拉取失败
- `Pending`：调度不出来
- `ContainerCreating` 很久不变：容器创建卡住

## 第三步：master 上查入口

```bash
kubectl get svc,ingress -A -o wide
```

如果是 `hello` 应用，重点看：

```bash
kubectl -n apps get deploy,pod,svc,ingress,endpoints -o wide
```

## 第四步：master 上查事件

```bash
kubectl get events -A --sort-by=.lastTimestamp | tail -50
```

事件通常能看到调度失败、镜像失败、探针失败等原因。

## 第五步：worker 上查本机状态

如果 Pod 跑在 worker1：

```bash
ssh root@138.68.15.99
```

如果 Pod 跑在 worker2：

```bash
ssh root@157.230.152.21
```

查看 agent：

```bash
systemctl status k3s-agent --no-pager -l
journalctl -u k3s-agent -n 200 --no-pager
```

查看容器：

```bash
k3s crictl ps -a
k3s crictl stats
```

## 第六步：如果是 MySQL 问题

MySQL 在 worker1 上。

登录 worker1：

```bash
ssh root@138.68.15.99
```

检查：

```bash
systemctl status mysql --no-pager -l
mysql -uroot -e "SELECT @@bind_address;"
ss -lntp | grep 3306
```

从 worker2 测试连通：

```bash
ssh root@157.230.152.21 'nc -vz 10.120.0.6 3306'
```

## 哪些现象不一定是真问题

### `helm-install-traefik-*` 是 `Completed`

这是正常的。它是安装 Traefik 的 Job，执行完后显示 `Completed`。

### 启动初期短暂的 readiness probe failed

Pod 刚启动时，应用还没准备好，readiness probe 短暂失败可能是正常的。只要后面变成 `Running` 且 `READY` 为 `1/1`，通常不用处理。

### `InvalidDiskCapacity`

节点刚启动时可能短暂出现，后续节点正常 `Ready` 就不用太紧张。

## Metrics API 问题

如果：

```bash
kubectl top nodes
kubectl top pods -A
```

报：

```text
Metrics API not available
```

优先确认 master 配置里有：

```yaml
egress-selector-mode: "pod"
```

这套集群之前已经因为 agentless master 访问集群内部 Service 的链路问题修过一次。修复记录见：

```text
deployment-2026-06-25.md
```
