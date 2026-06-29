# Worker1 MySQL 运维

worker1 上额外安装了系统级 MySQL。它不是 Kubernetes 里的 Pod。

## 基本信息

| 项 | 值 |
| --- | --- |
| 所在机器 | worker1 |
| 公网 IP | `138.68.15.99` |
| 内网 IP | `10.120.0.6` |
| 服务名 | `mysql` |
| 端口 | `3306` |
| 当前用途 | 给 `hello` 示例应用使用 |

当前为了让多个 worker 上的 Pod 都能访问 MySQL，MySQL 监听在：

```text
10.120.0.6:3306
```

## worker1 上执行：检查状态

先登录 worker1：

```bash
ssh root@138.68.15.99
```

检查 MySQL 服务：

```bash
systemctl status mysql --no-pager -l
systemctl is-active mysql
```

检查监听地址：

```bash
ss -lntp | grep 3306
mysql -uroot -e "SELECT VERSION(), @@hostname, @@port, @@bind_address;"
```

预期 `@@bind_address` 是：

```text
10.120.0.6
```

## worker1 上执行：登录 MySQL

```bash
mysql -uroot
```

当前 `root@localhost` 使用 `auth_socket`，所以推荐先 SSH 到 worker1，再用 Linux root 用户执行 `mysql -uroot`。

## worker1 上执行：查看 hello 应用用户

```bash
mysql -uroot -e "SELECT user, host, plugin FROM mysql.user WHERE user='hello_app' ORDER BY host;"
```

预期包含：

```text
hello_app  10.42.%
hello_app  10.120.0.%
hello_app  127.0.0.1
hello_app  localhost
```

## 本机执行：重新初始化 hello 数据库用户

在本机仓库目录执行：

```bash
ssh root@138.68.15.99 'mysql -uroot' < hello/scripts/init-db.sql
```

## 本机执行：重新配置 MySQL 私网监听

在本机仓库目录执行：

```bash
scp hello/scripts/configure-mysql-private.sh root@138.68.15.99:/tmp/configure-mysql-private.sh
ssh root@138.68.15.99 'sh /tmp/configure-mysql-private.sh'
```

脚本会备份原始配置到：

```text
/etc/mysql/mysql.conf.d/mysqld.cnf.hello.bak
```

## worker2 上执行：验证能连到 MySQL

登录 worker2：

```bash
ssh root@157.230.152.21
```

测试 TCP 连通：

```bash
nc -vz 10.120.0.6 3306
```

预期看到连接成功。

## 安全提醒

- 不要把真实数据库密码提交到仓库。
- MySQL 当前绑定 worker1 私网 IP，不要改成 `0.0.0.0`，除非你明确知道公网防火墙已经收紧。
- 如果后续正式使用，建议把数据库迁入 Kubernetes、托管数据库或单独数据库节点，并补备份策略。
