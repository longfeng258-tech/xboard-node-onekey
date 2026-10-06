# 一键首装器的上游实现调查

研究日期：2026-10-07。比较基线为本仓库 main `c390e056b308592bfa6fda190b13d2b63a41b876`。以下是源码审阅所得的建议，并非实施或服务器测试报告。

结论：继续让官方 `xbctl` 生成配置、官方 `xboard-node` 运行内核；首装器只补齐发行版服务集成、资源边界和用户反馈。当前最值得改善的是输入纠错、下载可见性、失败诊断以及入口命令的失败传递，无需引入新下载器、交互框架或常驻监控。

## 核对过的第一手实现

| 来源与固定版本 | 实际实现 | 适用范围与取舍 |
| --- | --- | --- |
| [cedar2025/Xboard-Node install.sh，0a29338e](https://github.com/cedar2025/Xboard-Node/blob/0a29338e1f102a462363ce3527417029f89bab28/install.sh) | 通过 `xbctl config init` 生成配置；阶段提示；限次依赖重试；服务启动后轮询 `/healthz`。 | 官方脚本要求正在运行的 systemd，使用 Bash。继续复用官方 CLI，而不是把它的整套安装/升级/回滚器搬进 POSIX sh 的 Alpine 首装器。 |
| [XTLS/Xray-install install-release.sh，e741a4f5](https://github.com/XTLS/Xray-install/blob/e741a4f56d368afbb9e5be3361b40c4552d3710d/install-release.sh) | curl 自带重试；下载时显示进度；对下载归档检查 SHA256；调用 systemd 检查服务状态。 | 借鉴使用系统工具的方式。该脚本装的是独立 Xray，本项目运行的是 Xboard-Node 内嵌内核，不能直接替换。 |
| [SagerNet/sing-box install.sh，a4331b8d](https://github.com/SagerNet/sing-box/blob/a4331b8d745971fdc1be33bba5513ab16105e2d3/docs/installation/tools/install.sh) | POSIX 风格入口识别包管理器，下载已有发布包；明确检查 curl 返回码，再调用系统包管理器。 | 借鉴小包装器的职责划分。不要额外安装独立 sing-box；那不会给 Xboard-Node 的内嵌内核带来收益。[官方安装说明](https://sing-box.sagernet.org/installation/package-manager/) |
| [rust-lang/rustup rustup-init.sh，63144eec](https://github.com/rust-lang/rustup/blob/63144eecda0f7e83397f22f63e83955037e0b8f5/rustup-init.sh#L822-L835) | 引导脚本委托真正安装器；curl 原生有限重试，必要时检测已有参数支持。 | 可借鉴委托与原生重试；它的大量平台兼容分支和下载恢复逻辑不适合为了当前两种架构完整照搬。 |

## 最小优先项

1. **错选菜单留在当前步骤。** 基线 `choose_options` 中内核、优化选项或预算格式错误会立刻退出；已经粘贴成功的接入信息也随进程丢失。复用当前私有命令输入已有的 `read`/`case` 重试结构，让每项输入有效后才进入下一项；EOF/信号仍退出并恢复终端。无需引入菜单库，也无需换掉官方 CLI。[基线输入代码](https://github.com/longfeng258-tech/xboard-node-onekey/blob/c390e056b308592bfa6fda190b13d2b63a41b876/install.sh#L192-L241)

2. **下载使用 curl 原生反馈和停滞超时。** 基线已有 `--retry 2`、连接/单次时间上限、HTTPS 限制、文件大小限制和固定 SHA256，保留这些。将静默下载改为 `--progress-bar`，加 `--speed-time 60 --speed-limit 1` 检测持续停滞；不要同时保留 `--silent`。curl 会自行处理适合重试的暂时性失败；不用再写外层下载重试器，也不要默认增加 `--retry-all-errors`。有进度不等于更快，已知文件大小时才有百分比。1 byte/s 和 60 秒是本项目建议值，不是上游推荐的通用最优值。[curl 官方参数](https://curl.se/docs/manpage.html#--progress-bar)、[低速超时](https://curl.se/docs/manpage.html#--speed-time)、[重试](https://curl.se/docs/manpage.html#--retry)，[Xray 的原生重试](https://github.com/XTLS/Xray-install/blob/e741a4f56d368afbb9e5be3361b40c4552d3710d/install-release.sh#L100-L102)

3. **保留官方工具的具体失败原因。** 基线的二进制可运行性检查与 `xbctl config init` 把 stderr 丢弃，失败时只有固定中文提示。复用已有 root 私有诊断日志，将这两处 stderr 写入同一文件；配置生成的 stdout 仍必须留给 `ENV_KEY` 元数据读取。失败时显示阶段、原因分类和日志位置，不把原始输出直接贴到终端。官方安装器同样把版本检查与配置生成作为独立失败边界；本项目已有隐私日志机制，补接输出即可。[基线检查/配置](https://github.com/longfeng258-tech/xboard-node-onekey/blob/c390e056b308592bfa6fda190b13d2b63a41b876/install.sh#L327-L365)，[官方配置生成](https://github.com/cedar2025/Xboard-Node/blob/0a29338e1f102a462363ce3527417029f89bab28/install.sh#L546-L589)

4. **推荐入口先下载成功再执行。** 用下载到本地文件且成功后 `&& sh ...` 的形式作为 README 推荐命令，继续兼容老的管道入口。没有启用 pipefail 的 shell 中，`curl ... | sh` 默认取末端 shell 的状态；下载失败但 shell 读到空输入正常退出时，会出现入口返回成功。安装器内部无法修复其尚未被下载/执行之前的错误。已有“下载审阅再运行”说明可以直接改进，不另建启动器。[POSIX 2018 管道与 AND 列表](https://pubs.opengroup.org/onlinepubs/9699919799/utilities/V3_chap02.html#tag_18_09_02)，[GNU Bash 管道规则](https://www.gnu.org/software/bash/manual/html_node/Pipelines.html)。Open Group 正文在本轮抓取时返回 403；该语义已由其官方搜索索引及 Bash 第一手文档交叉核对。

## 验收与低内存：哪些不能照搬

- **官方 healthz 只证明 HTTP handler 存活。** 上游 65 行监听 `:<port>`，绑定所有地址；71–75 行无条件回 HTTP 200；91 行在实例服务运行前启动健康监听。没有检测每个节点的内核、监听端口或客户端转发。`xbctl health` 也只检查该 HTTP 状态。[Node 实际 handler](https://github.com/cedar2025/Xboard-Node/blob/0a29338e1f102a462363ce3527417029f89bab28/cmd/xboard-node/main.go#L59-L91)，[CLI 判定](https://github.com/cedar2025/Xboard-Node/blob/0a29338e1f102a462363ce3527417029f89bab28/cmd/xbctl/main.go#L1084-L1128)。因此保持本项目 `health-port 0`；不为了静态存活接口增加端口，也不把它称作“节点可用”。若以后补首装验收，应明确区分主进程稳定、面板授权和节点分配、协议监听、客户端实际转发，并逐项记录未验证的部分。
- **已有稳定 PID 验收比只看一次 is-active 更合适。** 本项目连续检测同一 PID；Xray 的默认首次安装结尾只检查一次 systemd 状态，失败输出 warning。不能因“成熟上游这样写”就降低现有严格性。[基线启动检查](https://github.com/longfeng258-tech/xboard-node-onekey/blob/c390e056b308592bfa6fda190b13d2b63a41b876/install.sh#L462-L487)，[Xray 首次启动结尾](https://github.com/XTLS/Xray-install/blob/e741a4f56d368afbb9e5be3361b40c4552d3710d/install-release.sh#L963-L974)
- **保持系统工具而非增加常驻服务。** 已有 apk/apt、logrotate、systemd/OpenRC 足够承担安装与日志职责。不引入 Docker、独立代理内核、彩色 TUI 依赖或持续探测进程。
- **Go 软内存预算不能当 RSS 硬上限。** Go 官方说明该限制作用于运行时管理的内存，而且是 soft limit；过紧预算可能增加 GC CPU 消耗。现有预算必须保留系统余量，64MiB 的实际首装和负载适配仍需要独立测试，不能从这些上游脚本推导保证。[Go 官方 GC 指南](https://go.dev/doc/gc-guide#Memory_limit)

## 复用与许可证

本仓库为 MIT。上述建议调用现有工具或借鉴行为模式，没有复制上游函数正文。实际直接复制时先按对应许可证处理：

- Xboard-Node 的固定版本 README 声明 MPL-2.0；该树没有 LICENSE 文件且 GitHub API license 为 null。此次仅复用发布的 CLI 接口；若要直接移植源码，先核对维护者提供的许可文本和文件级义务。[上游声明](https://github.com/cedar2025/Xboard-Node/blob/0a29338e1f102a462363ce3527417029f89bab28/README.md#L68-L70)
- Xray-install 的根 LICENSE 是 GPL-3.0；不要将其函数直接复制后声称为 MIT。[许可证](https://github.com/XTLS/Xray-install/blob/e741a4f56d368afbb9e5be3361b40c4552d3710d/LICENSE)
- sing-box 的根许可证为 GPL-3.0-or-later，并附有名称关联限制文字；不直接移植其脚本正文。[许可证](https://github.com/SagerNet/sing-box/blob/a4331b8d745971fdc1be33bba5513ab16105e2d3/LICENSE)
- rustup 提供 MIT/Apache-2.0 双许可证；直接采用 MIT 代码仍应保留相应版权和许可声明。当前无需复制，已有 curl 和输入逻辑就能完成上述优化。[MIT 文本](https://github.com/rust-lang/rustup/blob/63144eecda0f7e83397f22f63e83955037e0b8f5/LICENSE-MIT)、[Apache 文本](https://github.com/rust-lang/rustup/blob/63144eecda0f7e83397f22f63e83955037e0b8f5/LICENSE-APACHE)

