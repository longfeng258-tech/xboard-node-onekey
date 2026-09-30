#!/usr/bin/env bash
#
# xboard-node-onekey
# xboard-node (machine 模式) 一键部署脚本
#
# 支持: Alpine (OpenRC) / Debian / Ubuntu (systemd)
# 用法:
#   curl -fsSL https://raw.githubusercontent.com/longfeng258-tech/xboard-node-onekey/main/install.sh | sudo bash
#   或带参数(免交互):
#   curl -fsSL .../install.sh | sudo bash -s -- --panel https://panel.example.com --machine-id 3 --token <token>
#
set -Eeuo pipefail

# ---------------- 颜色输出 ----------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
log_ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[!!]${NC} $1"; }
log_err()  { echo -e "${RED}[XX]${NC} $1" >&2; }
log_step() { echo -e "${CYAN}==>${NC} ${BOLD}$1${NC}"; }

# ---------------- 默认值 ----------------
PANEL_URL=""                  # 面板地址：--panel 传入，未给则交互输入（必填）
MACHINE_ID=""
TOKEN=""
VERSION="latest"          # xboard-node 版本: latest 或 v1.13 这样的 tag
MEM_LIMIT=""              # 手动指定 GOMEMLIMIT(MiB)，为空则交互选择
GOGC=50
KERNEL="singbox"
HEALTH_PORT=65530

INSTALL_ROOT="/etc/xboard-node"
BIN_PATH="/usr/local/bin/xboard-node"
XBCTL_PATH="/usr/local/bin/xbctl"
CONFIG_FILE="${INSTALL_ROOT}/config.yml"
CREDS_FILE="${INSTALL_ROOT}/credentials.env"
DOWNLOAD_BASE="https://github.com/cedar2025/xboard-node/releases"
TMPD=""

usage() {
    cat <<EOF
用法:
  install.sh [选项]

选项:
  --panel URL        面板地址 (必填，未提供则交互输入)
  --machine-id ID    面板中的机器 ID (必填)
  --token TOKEN      面板 Token (必填，命令行不给则交互输入)
  --version VER      xboard-node 版本，latest 或 v1.13 (默认: latest)
  --mem-limit MB     直接指定 GOMEMLIMIT(MiB)，跳过交互选择
  -y, --yes          非交互：内存使用自动推荐值
  -h, --help         显示帮助

示例:
  curl -fsSL https://raw.githubusercontent.com/longfeng258-tech/xboard-node-onekey/main/install.sh | sudo bash
  curl -fsSL .../install.sh | sudo bash -s -- --panel https://panel.example.com --machine-id 3 --token xxx --mem-limit 48 -y
EOF
}

# 从终端读取输入(兼容 curl | bash，stdin 被占用的情况)
prompt() {
    local var_name="$1" prompt_text="$2" default_val="${3-}" silent="${4-0}" input=""
    if [[ ! -e /dev/tty ]]; then
        log_err "无交互终端，请用参数传入 --${var_name//_/-}"
        exit 1
    fi
    if [[ "$silent" == "1" ]]; then
        read -rsp "${prompt_text}" input < /dev/tty; echo >&2
    elif [[ -n "$default_val" ]]; then
        read -rp "${prompt_text} [${default_val}]: " input < /dev/tty
        input="${input:-$default_val}"
    else
        read -rp "${prompt_text}: " input < /dev/tty
    fi
    printf -v "$var_name" '%s' "$input"
}

# ---------------- 参数解析 ----------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --panel)      PANEL_URL="$2"; shift 2 ;;
        --machine-id) MACHINE_ID="$2"; shift 2 ;;
        --token)      TOKEN="$2"; shift 2 ;;
        --version)    VERSION="$2"; shift 2 ;;
        --mem-limit)  MEM_LIMIT="$2"; shift 2 ;;
        -y|--yes)     YES=1; shift ;;
        -h|--help)    usage; exit 0 ;;
        *) log_err "未知参数: $1"; usage; exit 1 ;;
    esac
done

echo -e "${BOLD}=== xboard-node 一键部署 ===${NC}"
echo

# ---------------- 1. root 检查 ----------------
if [[ $EUID -ne 0 ]]; then
    log_err "请用 root 用户运行 (sudo bash)"
    exit 1
fi

# ---------------- 2. 系统识别 ----------------
OS=""; INIT=""
if [[ -f /etc/alpine-release ]]; then
    OS="alpine"; INIT="openrc"
elif [[ -f /etc/debian_version ]]; then
    OS="debian"; INIT="systemd"
else
    log_err "不支持的系统，仅支持 Alpine / Debian / Ubuntu"
    exit 1
fi
log_step "系统识别: ${OS} (${INIT})"

# ---------------- 3. 架构识别 ----------------
case "$(uname -m)" in
    x86_64|amd64)   ARCH="amd64" ;;
    aarch64|arm64)  ARCH="arm64" ;;
    *) log_err "不支持的架构 $(uname -m)，仅支持 amd64/arm64"; exit 1 ;;
esac
log_step "架构识别: ${ARCH}"

# ---------------- 4. 安装依赖 ----------------
log_step "安装依赖 (curl, ca-certificates)..."
if [[ "$OS" == "alpine" ]]; then
    apk add --no-cache curl ca-certificates >/dev/null 2>&1
else
    apt-get update -qq >/dev/null 2>&1
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl ca-certificates >/dev/null 2>&1
fi
log_ok "依赖就绪"

# ---------------- 5. 内存识别 ----------------
# 容器里 free 显示的是宿主机的内存，必须以 cgroup 上限为准，取最小值
MEM_TOTAL_MB=$(( $(awk '/MemTotal/{print $2}' /proc/meminfo) / 1024 ))
CGROUP_MB=""
if [[ -f /sys/fs/cgroup/memory.max ]]; then
    v="$(cat /sys/fs/cgroup/memory.max)"
    [[ "$v" != "max" ]] && CGROUP_MB=$(( v / 1024 / 1024 ))
elif [[ -f /sys/fs/cgroup/memory/memory.limit_in_bytes ]]; then
    v="$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes)"
    # v1 无限制时是个极大数，超过 1TB 视为无限制
    [[ "$v" -lt 1099511627776 ]] && CGROUP_MB=$(( v / 1024 / 1024 ))
fi

EFF_MB=$MEM_TOTAL_MB
CGROUP_LIMITED=0
if [[ -n "$CGROUP_MB" && "$CGROUP_MB" -lt "$MEM_TOTAL_MB" ]]; then
    EFF_MB=$CGROUP_MB
    CGROUP_LIMITED=1
fi

log_step "内存检测"
echo "  系统内存: ${MEM_TOTAL_MB}MB"
[[ -n "$CGROUP_MB" ]] && echo "  容器限制: ${CGROUP_MB}MB"
echo "  可用内存: ${EFF_MB}MB"
if [[ "$CGROUP_LIMITED" -eq 1 && "$MEM_TOTAL_MB" -gt $(( CGROUP_MB * 2 )) ]]; then
    log_warn "系统显示 ${MEM_TOTAL_MB}MB，但容器实际只分配了 ${CGROUP_MB}MB，以 ${CGROUP_MB}MB 为准!"
fi

# ---------------- 6. 下载 xboard-node ----------------
if [[ "$VERSION" == "latest" ]]; then
    DL_BASE="${DOWNLOAD_BASE}/latest/download"
else
    DL_BASE="${DOWNLOAD_BASE}/download/${VERSION}"
fi
log_step "下载 xboard-node (${VERSION}, linux-${ARCH})..."
if ! curl -fsSL "${DL_BASE}/xboard-node-linux-${ARCH}" -o "$BIN_PATH"; then
    log_err "xboard-node 下载失败: ${DL_BASE}/xboard-node-linux-${ARCH}"
    exit 1
fi
chmod +x "$BIN_PATH"
if curl -fsSL "${DL_BASE}/xbctl-linux-${ARCH}" -o "$XBCTL_PATH" 2>/dev/null; then
    chmod +x "$XBCTL_PATH"
    log_ok "xbctl 就绪"
else
    log_warn "xbctl 下载失败，将手写配置文件"
    XBCTL_PATH=""
fi
BIN_VER="$([[ -n "$XBCTL_PATH" ]] && "$XBCTL_PATH" version 2>/dev/null | head -1 || echo "$VERSION")"
log_ok "二进制就绪 (${BIN_VER})"

# ---------------- 7. 输入面板信息 ----------------
log_step "面板信息"
if [[ -z "$PANEL_URL" ]]; then
    prompt PANEL_INPUT "面板地址" "" 0
    PANEL_URL="$PANEL_INPUT"
fi
if [[ -z "$PANEL_URL" ]]; then log_err "面板地址不能为空"; exit 1; fi
if [[ -z "$MACHINE_ID" ]]; then
    prompt MACHINE_ID "机器 ID (面板中的 machine_id)" "" 0
fi
if [[ -z "$MACHINE_ID" ]]; then log_err "machine_id 不能为空"; exit 1; fi
if ! [[ "$MACHINE_ID" =~ ^[0-9]+$ ]]; then
    log_warn "machine_id 通常是数字，请确认输入正确: ${MACHINE_ID}"
fi
if [[ -z "$TOKEN" ]]; then
    prompt TOKEN "面板 Token (输入不回显)" "" 1
fi
if [[ -z "$TOKEN" ]]; then log_err "token 不能为空"; exit 1; fi
# 面板地址规范化：去掉末尾斜杠；没写 scheme 的自动补 https://
PANEL_URL="${PANEL_URL%/}"
if [[ ! "$PANEL_URL" =~ :// ]]; then
    PANEL_URL="https://${PANEL_URL}"
    log_warn "面板地址自动补全为 ${PANEL_URL}"
fi

# ---------------- 8. 内存配置选择 ----------------
# 建议值: 可用内存的 40%，保底 24MiB
SUGGEST_MB=$(( EFF_MB * 40 / 100 ))
[[ "$SUGGEST_MB" -lt 24 ]] && SUGGEST_MB=24

log_step "内存配置"
echo "  检测到可用内存: ${EFF_MB}MB"
echo "  推荐 GOMEMLIMIT: ${SUGGEST_MB}MiB (可用内存的 40%)"
if [[ -n "$MEM_LIMIT" ]]; then
    GOMEMLIMIT="$MEM_LIMIT"; MEM_MODE="手动(参数)"
elif [[ "${YES:-0}" == "1" ]]; then
    GOMEMLIMIT="$SUGGEST_MB"; MEM_MODE="自动"
else
    echo "  [1] 自动配置 (推荐)   [2] 手动输入"
    prompt CHOICE "请选择" "1" 0
    if [[ "$CHOICE" == "2" ]]; then
        prompt GOMEMLIMIT "请输入 GOMEMLIMIT (MiB)" "$SUGGEST_MB" 0
        MEM_MODE="手动"
    else
        GOMEMLIMIT="$SUGGEST_MB"; MEM_MODE="自动"
    fi
fi
if ! [[ "$GOMEMLIMIT" =~ ^[0-9]+$ ]] || [[ "$GOMEMLIMIT" -lt 16 ]]; then
    log_err "GOMEMLIMIT 非法: ${GOMEMLIMIT} (至少 16MiB)"
    exit 1
fi
log_ok "GOMEMLIMIT=${GOMEMLIMIT}MiB (${MEM_MODE})，GOGC=${GOGC}"

# ---------------- 9. 生成配置 ----------------
log_step "生成配置..."
mkdir -p "$INSTALL_ROOT"
TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

if [[ -n "$XBCTL_PATH" ]]; then
    # 用官方 xbctl 生成配置，保证格式兼容
    "$XBCTL_PATH" config init \
        --mode machine \
        --panel-url "$PANEL_URL" \
        --token "$TOKEN" \
        --machine-id "$MACHINE_ID" \
        --kernel "$KERNEL" \
        --health-port "$HEALTH_PORT" \
        --gomemlimit "${GOMEMLIMIT}MiB" \
        --gogc "$GOGC" \
        --output "$TMPD/config.yml" \
        --credentials-out "$TMPD/credentials.env" \
        --meta "$TMPD/install-meta.json" \
        --install-root "$INSTALL_ROOT" >/dev/null
    # xbctl 默认日志 info，小内存机器改 warn
    sed -i 's/^\(\s*\)level: info$/\1level: warn/' "$TMPD/config.yml"
else
    # 兜底：手写最小配置
    cat > "$TMPD/config.yml" <<EOF
instances:
    - id: machine-${MACHINE_ID}
      panel:
        url: ${PANEL_URL}
      kernel:
        type: "${KERNEL}"
        log_level: warn
      log:
        level: warn
        output: stdout
      runtime:
        gomemlimit: ${GOMEMLIMIT}MiB
        gogc: ${GOGC}
      machine:
        machine_id: ${MACHINE_ID}
        token_env: XBOARD_MACHINE_TOKEN
EOF
    printf 'XBOARD_MACHINE_TOKEN=%s\n' "$TOKEN" > "$TMPD/credentials.env"
fi

# 备份旧配置
if [[ -f "$CONFIG_FILE" ]]; then
    BK="${CONFIG_FILE}.bak-$(date +%Y%m%d%H%M%S)"
    cp "$CONFIG_FILE" "$BK"
    log_warn "已备份旧配置 -> ${BK}"
fi
install -m 600 "$TMPD/config.yml" "$CONFIG_FILE"
install -m 600 "$TMPD/credentials.env" "$CREDS_FILE"
log_ok "配置已写入 ${CONFIG_FILE}"

# ---------------- 10. 安装系统服务 ----------------
log_step "安装系统服务 (${INIT})..."
if [[ "$INIT" == "openrc" ]]; then
    cat > /etc/init.d/xboard-node <<'EOF_INIT'
#!/sbin/openrc-run
description="Xboard Node Backend (xboard-node-onekey)"

command="/usr/local/bin/xboard-node"
command_args="-c /etc/xboard-node/config.yml"
command_background=true
pidfile="/run/xboard-node.pid"
directory="/etc/xboard-node"

depend() {
    need net
    after firewall
}

start_pre() {
    # 加载 credentials.env (含面板 token)
    if [ -f /etc/xboard-node/credentials.env ]; then
        set -a
        . /etc/xboard-node/credentials.env
        set +a
    fi
}
EOF_INIT
    chmod +x /etc/init.d/xboard-node
    rc-update add xboard-node default >/dev/null 2>&1 || true
    log_ok "OpenRC 服务已安装并加入开机启动"
else
    # systemd；小内存机器(<1GB)加上内存硬上限，防止触顶后整机卡死
    MEM_LIMIT_CONF=""
    if [[ "$EFF_MB" -lt 1024 ]]; then
        MH=$(( GOMEMLIMIT * 14 / 10 ))
        MM=$(( GOMEMLIMIT * 17 / 10 ))
        MEM_LIMIT_CONF="MemoryHigh=${MH}M
MemoryMax=${MM}M
MemorySwapMax=0"
        log_warn "小内存机器，追加 systemd 内存限制: MemoryHigh=${MH}M / MemoryMax=${MM}M"
    fi
    cat > /etc/systemd/system/xboard-node.service <<EOF_UNIT
[Unit]
Description=Xboard Node Backend (xboard-node-onekey)
Documentation=https://github.com/cedar2025/Xboard-Node
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${INSTALL_ROOT}
EnvironmentFile=-${CREDS_FILE}
ExecStart=${BIN_PATH} -c ${CONFIG_FILE}
Restart=always
RestartSec=5
LimitNOFILE=1048576
NoNewPrivileges=true
StandardOutput=journal
StandardError=journal
${MEM_LIMIT_CONF}

[Install]
WantedBy=multi-user.target
EOF_UNIT
    # 小内存机器同时限制 journald 日志占用
    if [[ "$EFF_MB" -lt 1024 ]]; then
        mkdir -p /etc/systemd/journald.conf.d
        printf '[Journal]\nSystemMaxUse=16M\nRuntimeMaxUse=8M\n' > /etc/systemd/journald.conf.d/lowmem.conf
        systemctl restart systemd-journald 2>/dev/null || true
    fi
    systemctl daemon-reload
    systemctl enable xboard-node >/dev/null 2>&1
    log_ok "systemd 服务已安装并加入开机启动"
fi

# ---------------- 11. 启动 + 自检 ----------------
log_step "启动服务..."
if [[ "$INIT" == "openrc" ]]; then
    rc-service xboard-node restart >/dev/null 2>&1 || rc-service xboard-node start
else
    systemctl restart xboard-node
fi

log_step "自检..."
OK=0
for _ in $(seq 1 30); do
    if [[ "$INIT" == "openrc" ]]; then
        rc-service xboard-node status >/dev/null 2>&1 && { OK=1; break; }
    else
        systemctl is-active xboard-node >/dev/null 2>&1 && { OK=1; break; }
    fi
    sleep 1
done
if [[ "$OK" != "1" ]]; then
    log_err "服务启动失败，日志如下:"
    if [[ "$INIT" == "systemd" ]]; then
        journalctl -u xboard-node -n 30 --no-pager 2>/dev/null || true
    else
        tail -30 /var/log/messages 2>/dev/null | grep -i xboard || true
    fi
    exit 1
fi
log_ok "服务运行中"

# 健康检查(尽力而为，不阻塞)
HEALTH_OK=0
for _ in $(seq 1 10); do
    if curl -fsS --max-time 2 "http://127.0.0.1:${HEALTH_PORT}/healthz" >/dev/null 2>&1; then
        HEALTH_OK=1; break
    fi
    sleep 2
done
[[ "$HEALTH_OK" == "1" ]] && log_ok "健康检查通过 (127.0.0.1:${HEALTH_PORT}/healthz)"

# ---------------- 12. 安装小结 ----------------
echo
echo -e "${GREEN}${BOLD}========================================${NC}"
echo -e "${GREEN}${BOLD}  安装完成${NC}"
echo -e "${GREEN}${BOLD}========================================${NC}"
echo "  面板:     ${PANEL_URL}"
echo "  机器 ID:  ${MACHINE_ID}"
echo "  版本:     ${BIN_VER}"
echo "  内存:     检测到 ${EFF_MB}MB -> GOMEMLIMIT=${GOMEMLIMIT}MiB (${MEM_MODE})"
echo "  服务:     运行中 (${INIT})"
echo
echo "  下一步: 登录面板后端，确认机器在线，然后添加节点"
echo -e "${GREEN}${BOLD}========================================${NC}"
