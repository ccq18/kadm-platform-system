# 节点运维

这篇文档区分 master 和 worker 上应该执行的系统命令。

## master 上执行

登录 master：

```bash
ssh root@157.230.140.91
```

查看 K3s server 服务：

```bash
systemctl status k3s --no-pager -l
systemctl is-active k3s
journalctl -u k3s -n 200 --no-pager
```

查看监听端口：

```bash
ss -lntp
```

查看资源：

```bash
free -h
df -h /
```

master 是控制面，不跑业务 Pod。业务容器问题通常去 worker 查。

## worker 上执行

登录 worker1：

```bash
ssh root@138.68.15.99
```

登录 worker2：

```bash
ssh root@157.230.152.21
```

查看 K3s agent 服务：

```bash
systemctl status k3s-agent --no-pager -l
systemctl is-active k3s-agent
journalctl -u k3s-agent -n 200 --no-pager
```

查看容器运行时：

```bash
k3s crictl ps -a
k3s crictl images
k3s crictl stats
```

查看资源：

```bash
free -h
df -h /
ss -lntp
```

## 本机远程执行

如果只是快速看一眼，也可以从本机远程执行：

```bash
ssh root@157.230.140.91 'systemctl is-active k3s'
ssh root@138.68.15.99 'systemctl is-active k3s-agent'
ssh root@157.230.152.21 'systemctl is-active k3s-agent'
```
