# 本机使用 kubectl

如果你不想每次都 SSH 到 master 再执行 `kubectl`，可以把 master 上的 kubeconfig 拉到本机。

## 1. 本机执行：拉取 kubeconfig

```bash
mkdir -p ~/.kube
scp root@157.230.140.91:/etc/rancher/k3s/k3s.yaml ~/.kube/k3s-do.yaml
chmod 600 ~/.kube/k3s-do.yaml
```

## 2. 本机执行：修改 server 地址

打开：

```text
~/.kube/k3s-do.yaml
```

如果看到：

```yaml
server: https://127.0.0.1:6443
```

改成：

```yaml
server: https://157.230.140.91:6443
```

`127.0.0.1` 在本机代表你自己的电脑，不代表远程 master。

## 3. 本机执行：验证

```bash
KUBECONFIG=~/.kube/k3s-do.yaml kubectl get nodes -o wide
```

正常应看到：

```text
k3s-worker-1
k3s-worker-2
```

## 4. 本机执行：设为默认 kubeconfig

如果确认没问题，可以写到 `~/.zshrc`：

```bash
export KUBECONFIG=~/.kube/k3s-do.yaml
```

然后重新打开终端，直接执行：

```bash
kubectl get nodes -o wide
```

## 安全提醒

`~/.kube/k3s-do.yaml` 是管理员凭证。不要提交到仓库，不要发到群里，不要放到公开网盘。
