# xboard-node-onekey

xboard-node（machine 模式）一键部署脚本。

新买一台服务器，一条命令，输入面板地址 + `machine_id` + `token`，几分钟内机器上线并连上面板。节点增删、端口协议仍在面板后端操作，脚本只负责机器上线。

## 特性

- **双系统支持**：Alpine（OpenRC）和 Debian / Ubuntu（systemd），官方安装脚本只支持 systemd
- **内存自动识别**：容器里 `free` 看到的是宿主机的内存，脚本以 cgroup 上限为准、取最小值，识别错了会主动提醒
- **内存二选一**：显示检测到的可用内存，给出推荐的 `GOMEMLIMIT`，可选自动配置或手动输入
- **小内存优化**：`GOMEMLIMIT` + `GOGC=50`、日志级别 `warn`、systemd 追加内存硬上限、journald 日志限额（<1GB 机器）
- **配置官方兼容**：用官方 `xbctl config init` 生成配置，token 存 `credentials.env`（600 权限）
- **自检 + 小结**：启动后检查服务状态与健康接口，最后打印安装小结，参数填错当场发现

## 一键安装

仓库是私有的，下载脚本需要一个 GitHub token（建议用 Fine-grained token，只给本仓库 Contents 的 Read 权限）：

```bash
export GH_TOKEN=<你的token>
curl -fsSL -H "Authorization: Bearer ${GH_TOKEN}" https://raw.githubusercontent.com/longfeng258-tech/xboard-node-onekey/main/install.sh | sudo bash
```

按提示输入面板地址、`machine_id`、`token`（输入不回显），然后选择内存配置即可。

## 参数（免交互）

```bash
curl -fsSL -H "Authorization: Bearer ${GH_TOKEN}" https://raw.githubusercontent.com/longfeng258-tech/xboard-node-onekey/main/install.sh \
  | sudo bash -s -- --panel https://panel.example.com --machine-id 3 --token <token> --mem-limit 48 -y
```

| 参数 | 说明 |
|---|---|
| `--panel URL` | 面板地址（必填，未提供则交互输入） |
| `--machine-id ID` | 面板中的机器 ID（必填） |
| `--token TOKEN` | 面板 Token（必填） |
| `--version VER` | xboard-node 版本，`latest` 或 `v1.13`（默认 `latest`） |
| `--mem-limit MB` | 直接指定 `GOMEMLIMIT`（MiB），跳过交互选择 |
| `-y, --yes` | 非交互：内存使用自动推荐值 |
| `-h, --help` | 帮助 |

## 内存推荐值

`GOMEMLIMIT` 默认取检测到的可用内存的 40%（保底 24MiB），systemd 小机器（<1GB）会追加 `MemoryHigh`（1.4 倍）/ `MemoryMax`（1.7 倍）硬上限，防止内存触顶后整机卡死。

## 卸载

```bash
# systemd
sudo systemctl disable --now xboard-node
sudo rm -f /etc/systemd/system/xboard-node.service
sudo rm -rf /etc/xboard-node /usr/local/bin/xboard-node /usr/local/bin/xbctl

# OpenRC (Alpine)
sudo rc-service xboard-node stop
sudo rc-update del xboard-node default
sudo rm -f /etc/init.d/xboard-node
sudo rm -rf /etc/xboard-node /usr/local/bin/xboard-node /usr/local/bin/xbctl
```

## 致谢

- xboard-node：[cedar2025/Xboard-Node](https://github.com/cedar2025/Xboard-Node)，内核 sing-box

## License

MIT
