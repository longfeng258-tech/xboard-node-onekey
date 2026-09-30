# Xboard-Node 一键首装

[![Checks](https://github.com/longfeng258-tech/xboard-node-onekey/actions/workflows/check.yml/badge.svg)](https://github.com/longfeng258-tech/xboard-node-onekey/actions/workflows/check.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

面向干净 Linux 服务器的交互安装器。粘贴 Xboard 后台提供的完整 **machine** 安装命令，即可导入面板地址、机器 ID 和 Token；接入信息不预置在公开代码里。

复用 [官方 Xboard-Node](https://github.com/cedar2025/Xboard-Node) 预编译程序和 `xbctl` 配置生成能力。当前固定 **v1.13**，分别校验 amd64 / arm64 官方 release 的 SHA256；内核可选 **sing-box** 或 **Xray**，默认推荐 sing-box。

## 支持范围

| 项目 | 范围 |
| --- | --- |
| 系统 | Debian / Ubuntu，且 systemd 正在运行；Alpine，且 OpenRC 正在运行 |
| 架构 | x86_64 / amd64、aarch64 / arm64 |
| 资源 | 有效内存至少 64MiB；安装前磁盘至少剩余 150MiB；建议 128MiB 以上 |
| 面板 | 支持 Xboard machine API，HTTPS 证书有效 |
| 使用场景 | 全新安装；发现已有 Node、服务或相关文件即退出 |

识别的是 `/proc/meminfo` 和当前进程可见 cgroup 及父级限额中的较小值，适用于容器里 `free` 显示宿主内存的情况。容器隐藏且未暴露的外部限额无法从内部准确读取。低内存适配不等于能承受任意节点数量或并发量。

## 安装

以 root 在服务器终端运行（需要已有 `curl`）：

```sh
curl -fsSL https://raw.githubusercontent.com/longfeng258-tech/xboard-node-onekey/main/install.sh | sh
```

普通 sudo 用户：

```sh
curl -fsSL https://raw.githubusercontent.com/longfeng258-tech/xboard-node-onekey/main/install.sh | sudo sh
```

Alpine 没有 curl 时，先运行 `apk add --no-cache curl ca-certificates`。建议先下载并阅读脚本，再执行：

```sh
curl -fsSL https://raw.githubusercontent.com/longfeng258-tech/xboard-node-onekey/main/install.sh -o install.sh
less install.sh
sudo sh install.sh
```

交互流程：

1. 检测已有安装、系统、服务管理器、架构、有效内存和磁盘。
2. 提示粘贴后台完整安装命令；输入隐藏，**不会执行所粘贴的命令**。
3. 选择 sing-box / Xray。
4. 选择推荐 Go 内存预算，或输入自己的 MiB 数值。
5. 安装缺少的工具，检查面板机器鉴权，下载并校验官方程序，生成配置。
6. 启动服务并设置开机启动；分别报告进程状态和面板节点分配情况。

后台命令必须包含完整的 `--machine-id` 数值。接受的格式示例仅用于说明，示例不是可用凭据：

```text
curl -fsSL https://raw.githubusercontent.com/cedar2025/xboard-node/dev/install.sh | sudo bash -s -- --mode machine --panel 'https://panel.example.com' --token 'example-machine-token' --machine-id 1
```

接受单引号、双引号、空白和可选 `sudo`；四个参数顺序可变。只接受上述官方来源和四个参数，不接受额外 shell 命令、重定向、反斜线、变量展开、换行、额外参数或省略 ID。Token 字符集限英文字母、数字、`.`、`_`、`~`、`-`，最多 512 字符。面板 URL 支持 HTTPS 域名或 IPv4、端口和基本路径；暂不支持 IPv6 字面量、URL 用户名密码、查询或片段。

**不要把自己的后台命令提交到 Issue、README、终端截图或公开聊天里。**

## 内存和日志

推荐值是起点：64–80MiB 的服务器使用 28MiB Go 软预算；更大内存取有效容量约 40%。256MiB 以下使用 `GOGC=50`，更大使用 `100`。手动预算至少 16MiB，并为系统和非 Go 占用预留至少 32MiB。

`GOMEMLIMIT` 对 Go 管理的内存生效，**不是 RSS 硬上限**，也不保证不会 OOM。预算写入 Node 配置的 `runtime`，避免配置和环境变量互相覆盖。systemd 在 256MiB 以下另设进程 `MemoryHigh` / `MemoryMax` 留出余量；它们依赖可用的 memory controller。OpenRC 不假定容器允许创建子 cgroup，不伪装为有硬限制。保留 Go 自身的 CPU 配额识别，不强制单核运行。

默认核心及内核日志为 `warn`，日志目录仅 root 可读。logrotate 每 15 分钟检查，超过 1MiB 时轮转、保留两份。**这是定时轮转，不是实时容量硬上限**；突发日志在检查前可能超过 1MiB，`copytruncate` 的复制窗口可能丢失少量日志。systemd 用专用 timer；Alpine 用标准 periodic/crond。Alpine 会启用 crond；失败清理不卸载依赖包、不关闭系统 cron。

不修改全局网络参数、现有 tc 限速、swap 或全局 journald 配置。

## 安装后

| 路径 | 内容 |
| --- | --- |
| `/usr/local/lib/xboard-node/` | 固定版本 Node 和 xbctl |
| `/etc/xboard-node/config.yml` | 机器模式、内核和内存配置，权限 600 |
| `/etc/xboard-node/credentials.env` | 私有 Token，权限 600，目录 700 |
| `/var/log/xboard-node/node.log` | 私有错误日志 |

systemd：

```sh
systemctl status xboard-node --no-pager
systemctl restart xboard-node
systemctl list-timers xboard-node-logrotate.timer
```

OpenRC：

```sh
rc-service xboard-node status
rc-service xboard-node restart
rc-service crond status
```

节点协议、端口、用户及证书由自己的 Xboard 后台配置。本脚本不添加域名或申请证书。面板未分配节点时，服务等待后台添加；以后添加节点无需重装。内核选择须与面板下发配置兼容，面板策略也可能覆盖内核日志等级。

安装完成代表机器 API 鉴权通过且服务进程启动稳定，**不代表所有节点协议或客户端连通性已验证**。请在面板确认节点在线，再测试客户端。默认不开启官方静态 `/healthz` 监听端口。

重复运行不会更新、重装或更改现有配置。首装中普通失败或中断会清理本次新建的 Node 文件；`kill -9` 或断电可能留下文件或锁，此时停止并核查残留，不自动覆盖。安装器使用 `/run/xboard-node-install.lock` 防止并发运行。

凭据不会传给 GitHub，也不会作为安装器的命令行参数或终端输出。Node 自身的部分面板 HTTP / WebSocket 请求仍由官方实现使用 Token；面板、代理和运行日志需要保持私有。脚本不能替代面板安全、正确的防火墙配置或凭据轮换。

## 开发和贡献

参见 [CONTRIBUTING.md](CONTRIBUTING.md) 和 [SECURITY.md](SECURITY.md)。Linux 离线验证（需要 Python 3、jq、logrotate、ShellCheck）：

```sh
shellcheck -S warning install.sh
python3 tests/check.py
TEST_SHELL='busybox sh' python3 tests/check.py
```

检查覆盖受限命令解析与注入拒绝、cgroup v1/v2 及父级内存、私有鉴权、服务配置、并发锁和首装失败清理。服务管理器由隔离替身验证，不能当作真实 VPS / ARM64 部署或压力测试。维护者可使用 `XBOARD_TEST_BINARIES` 指向已下载的官方 amd64 二进制目录，额外验证摘要、版本、真实 `xbctl` 配置生成，以及两种内核连接本地模拟 HTTPS 面板和 VLESS TCP 转发；此项还需要 OpenSSL。CI 会执行这些检查。

安装器自身使用 MIT 许可证；Node、内核及下载依赖属于各自上游项目，其许可和分发条款由上游负责。本项目与 Xboard 官方没有隶属关系。
