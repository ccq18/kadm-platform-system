# 日常运维命令

这篇文档只放日常最常用的命令，并且明确区分在哪里执行。

## 本机执行

本机一般做这些事：

- SSH 登录服务器
- 从服务器复制文件
- 同步应用源码
- 在已配置 kubeconfig 后执行 `kubectl`

登录 master：

```bash
ssh root@157.230.140.91
```

登录 worker1：

```bash
ssh root@138.68.15.99
```

登录 worker2：

```bash
ssh root@157.230.152.21
```

如果本机已经配置 kubeconfig，可以在本机执行：

```bash
KUBECONFIG=~/.kube/k3s-do.yaml kubectl get nodes -o wide
```

如果没有配置 kubeconfig，就先登录 master，在 master 上执行 `kubectl`。

## master 上执行

master 适合执行集群管理命令。

先登录 master：

```bash
ssh root@157.230.140.91
```

查看节点：

```bash
kubectl get nodes -o wide
```

查看所有 Pod：

```bash
kubectl get pods -A -o wide
```

查看 Service 和 Ingress：

```bash
kubectl get svc,ingress -A -o wide
```

查看最近事件：

```bash
kubectl get events -A --sort-by=.lastTimestamp | tail -50
```

查看资源使用：

```bash
kubectl top nodes
kubectl top pods -A
```

查看 API 健康：

```bash
kubectl get --raw=/readyz?verbose
```

查看 master 自己的 K3s 服务：

```bash
systemctl status k3s --no-pager -l
journalctl -u k3s -n 200 --no-pager
```

## worker1 上执行

worker1 适合查看本机 agent、容器、系统资源、MySQL。

先登录 worker1：

```bash
ssh root@138.68.15.99
```

查看 K3s agent：

```bash
systemctl status k3s-agent --no-pager -l
journalctl -u k3s-agent -n 200 --no-pager
```

查看资源：

```bash
free -h
df -h /
ss -lntp
```

查看容器运行时：

```bash
k3s crictl ps -a
k3s crictl images
k3s crictl stats
```

查看 MySQL：

```bash
systemctl status mysql --no-pager -l
mysql -uroot -e "SELECT VERSION(), @@hostname, @@port, @@bind_address;"
ss -lntp | grep 3306
```

## worker2 上执行

worker2 适合查看本机 agent、容器、系统资源。

先登录 worker2：

```bash
ssh root@157.230.152.21
```

查看 K3s agent：

```bash
systemctl status k3s-agent --no-pager -l
journalctl -u k3s-agent -n 200 --no-pager
```

查看资源：

```bash
free -h
df -h /
ss -lntp
```

查看容器运行时：

```bash
k3s crictl ps -a
k3s crictl images
k3s crictl stats
```

测试 worker2 到 worker1 MySQL 的私网连通性：

```bash
nc -vz 10.120.0.6 3306
```

## 不建议混用的命令

默认不要在 worker 上执行 `kubectl`。worker 上没有默认管理员 kubeconfig，日常集群管理优先在 master 上执行。

默认不要在 master 上排查业务容器运行时。master 不跑业务 Pod，业务 Pod 在 worker 上。
