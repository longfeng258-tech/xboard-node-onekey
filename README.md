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

以 root 在服务器终端运行（需要已有 `curl`）。先完整下载，下载成功才执行；临时脚本退出后自动删除：

```sh
(
  installer=$(mktemp) || exit 1
  trap 'rm -f "$installer"' EXIT
  curl -fL --retry 2 --connect-timeout 15 --max-time 120 \
    https://raw.githubusercontent.com/longfeng258-tech/xboard-node-onekey/main/install.sh -o "$installer" &&
    sh "$installer"
)
```

普通 sudo 用户将最后一行改为 `sudo sh "$installer"`。原管道入口仍兼容：

```sh
curl -fsSL https://raw.githubusercontent.com/longfeng258-tech/xboard-node-onekey/main/install.sh | sh
```

POSIX sh 的管道返回最后一个命令的状态：下载失败且没有内容时，`curl | sh` 可能仍返回 0。因此优先使用上面的下载后执行方式。

Alpine 没有 curl 时，先以 root 运行 `apk add --no-cache curl ca-certificates`。Alpine 上的 Node 服务由本脚本通过 OpenRC 配置，不需要安装 `sudo`、Bash 或 systemd；后台命令中的 `sudo bash` 仅用于导入参数，不会被执行。也可以先下载并阅读脚本，再执行：

```sh
curl -fsSL https://raw.githubusercontent.com/longfeng258-tech/xboard-node-onekey/main/install.sh -o install.sh &&
  less install.sh &&
  sh install.sh
```

上面的下载后执行方式适用于 root；普通 sudo 用户将最后一行改为 `sudo sh install.sh`。

交互流程：

1. 检测已有安装、系统、服务管理器、架构、有效内存和磁盘。
2. 提示粘贴后台完整安装命令；输入隐藏，**不会执行所粘贴的命令**。格式有误可重新粘贴，最多三次。
3. 选择 sing-box / Xray，输错时在本步骤重试，回车使用推荐值。
4. 选择推荐 Go 内存预算，或输入自己的 MiB 数值；无效数值可重输，回车可返回推荐预算，不需要再次粘贴接入命令。
5. 安装缺少的工具，检查面板机器鉴权和 Alpine cron，下载并校验官方程序，生成配置。
6. 启动服务并设置开机启动；分别报告进程状态和面板节点分配情况。

每个阶段都有 `==>` 进度提示。看到“面板机器鉴权通过”时仍会继续安装，只有最后出现“安装完成”才代表首装成功；节点数为 0 也可以完成首装。

官方二进制下载使用 curl 自带进度条、有限重试和超时；连续 60 秒平均传输速度低于 1 字节/秒时中止该次传输，再按 curl 的临时错误规则重试。仍校验固定 SHA256，不用第三方下载代理或自制下载器。

后台命令必须包含完整的 `--machine-id` 数值。接受的格式示例仅用于说明，示例不是可用凭据：

```text
curl -fsSL https://raw.githubusercontent.com/cedar2025/xboard-node/dev/install.sh | sudo bash -s -- --mode machine --panel 'https://panel.example.com' --token 'example-machine-token' --machine-id 1
```

接受单引号、双引号、空白和可选 `sudo`；四个参数顺序可变。只接受上述官方来源和四个参数，不接受额外 shell 命令、重定向、反斜线、变量展开、换行、额外参数或省略 ID。Token 字符集限英文字母、数字、`.`、`_`、`~`、`-`，最多 512 字符。面板 URL 支持 HTTPS 域名或 IPv4、端口和基本路径；暂不支持 IPv6 字面量、URL 用户名密码、查询或片段。

兼容复制时带入的不换行空格，以及安装脚本或面板网址的 `[https://网址](https://网址)` Markdown 格式；链接显示的网址必须与目标完全一致，仍校验官方脚本来源和 HTTPS 面板地址。不接受仅写链接标题或显示网址与目标不一致的链接。首次启动本脚本的 `curl` 命令仍应使用上方代码块中的纯网址。

**不要把自己的后台命令提交到 Issue、README、终端截图或公开聊天里。**

## 接入失败时

安装器区分网络、HTTPS、HTTP 状态和 JSON 格式错误，并给出对应排查建议；不会直接显示面板返回的原始内容、地址或 Token。

| 提示 | 下一步 |
| --- | --- |
| HTTP 403：机器不存在或已停用 | 在后台确认命令中的机器 ID 对应机器存在且已启用，再重新复制该机器的安装命令 |
| HTTP 401 / 其他 HTTP 403 | 核对当前机器 Token、启用状态及面板访问限制 |
| HTTP 404 / 返回格式不符 | 核对面板地址、machine API 支持及登录跳转 |
| HTTP 3xx 重定向 | 使用最终 HTTPS 面板地址，检查域名及登录跳转；安装器不会自动跟随鉴权重定向 |
| DNS / 连接 / 超时 / TLS 错误 | 检查服务器出站网络、域名、证书、系统时间和 CA 包 |
| HTTP 429 / 5xx | 检查面板或代理运行状态，稍后重试 |
| OpenRC crond 无法启动 | 查看本次私有诊断日志中的服务依赖错误，检查镜像基础服务 |
| 安装意外停止 | 提示会给出失败阶段、退出码及本次私有诊断日志路径 |

更换安装器不会修复后台停用或不存在的机器。鉴权失败发生在下载 Node 和写入服务之前；修正后台配置后重新运行即可。安装后复查失败会显示具体分类并保留已启动服务。

Alpine 会检查 `crond` 的 OpenRC 服务是否存在，缺少时安装 `busybox-openrc`，并在下载 Node 之前确认 cron 可以启动。某些精简镜像删除了已安装包中的 `hostname` 服务，导致 `syslog` 和 `crond` 无法启动：只有确认该文件缺失且已安装的 `openrc` 包清单包含它时，脚本才执行一次 `apk fix --no-cache openrc` 恢复包文件，再检查服务。采用包管理器的配置保护规则保留现有配置，不启用升级或覆盖配置选项。未恢复或其他依赖失败时停止，不绕过服务依赖。

本次诊断日志位于 `/var/log/xboard-node-install.随机后缀`，权限 600。依赖安装、摘要校验、二进制启动检查、官方配置生成错误和服务管理器的输出写入该文件，失败时显示路径和退出阶段；普通意外退出也会报告错误。失败清理 Node 文件前会保留最多 64KiB 的 Node 日志到诊断文件，成功后删除临时诊断文件。它可能包含私有信息，分享前必须脱敏；排查结束后可手动删除对应文件。无法创建诊断文件时会明确报错，强制 `kill -9`、断电或终端不显示输出仍无法保证反馈。

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

参见 [CONTRIBUTING.md](CONTRIBUTING.md)、[SECURITY.md](SECURITY.md) 和 [成熟安装器源码对照](docs/installer-research.md)。Linux 离线验证（需要 Python 3、jq、logrotate、ShellCheck）：

```sh
shellcheck -S warning install.sh
python3 tests/check.py
TEST_SHELL='busybox sh' python3 tests/check.py
```

检查覆盖受限命令解析与注入拒绝、cgroup v1/v2 及父级内存、私有鉴权、服务配置、并发锁和首装失败清理。服务管理器由隔离替身验证，不能当作真实 VPS / ARM64 部署或压力测试。维护者可使用 `XBOARD_TEST_BINARIES` 指向已下载的官方 amd64 二进制目录，额外验证摘要、版本、真实 `xbctl` 配置生成，以及两种内核连接本地模拟 HTTPS 面板和 VLESS TCP 转发；此项还需要 OpenSSL。CI 会执行这些检查。

安装器自身使用 MIT 许可证；Node、内核及下载依赖属于各自上游项目，其许可和分发条款由上游负责。本项目与 Xboard 官方没有隶属关系。
