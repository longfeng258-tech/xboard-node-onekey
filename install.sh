#!/bin/sh
# Xboard-Node fresh installer. MIT; see LICENSE.
# Never run, eval, or source the command pasted by the operator.
set +x
set -eu
export LC_ALL=C
umask 077

VERSION=v1.13
RELEASE=https://github.com/cedar2025/Xboard-Node/releases/download
BIN_DIR=/usr/local/lib/xboard-node
CONFIG_DIR=/etc/xboard-node
LOG_DIR=/var/log/xboard-node
ROTATE_CONFIG=/etc/logrotate.d/xboard-node
UNIT=/etc/systemd/system/xboard-node.service
ROTATE_UNIT=/etc/systemd/system/xboard-node-logrotate.service
ROTATE_TIMER=/etc/systemd/system/xboard-node-logrotate.timer
RC_UNIT=/etc/init.d/xboard-node
RC_ROTATE=/etc/periodic/15min/xboard-node-logrotate
LOCK=/run/xboard-node-install.lock
STAGE=
OWNED=0
LOCKED=0
COMPLETE=0
TTY_STATE=

say() { printf '%s\n' "$*"; }
die() { say "错误：$*" >&2; exit 1; }

parse_command() {
    # A small, deliberately restricted lexer for the backend's one-line format.
    # Shell expansion, escaping, redirection and extra commands are unsupported.
    awk '
    function bad() { exit 1 }
    function link_url(value, end_label, label, target) {
        if (substr(value,1,1) != "[") return value
        end_label=index(value,"](")
        if (!end_label || substr(value,length(value),1) != ")") bad()
        label=substr(value,2,end_label-2)
        target=substr(value,end_label+2,length(value)-end_label-2)
        if (label != target) bad()
        return target
    }
    { if (NR != 1 || length($0) > 8192) bad(); line=$0 }
    END {
        if (NR != 1 || line ~ /[$`\\;&<>\r]/) bad()
        gsub(/\302\240/," ",line)
        quote=""; word=""; n=0; started=0
        for (i=1; i<=length(line); i++) {
            c=substr(line,i,1)
            if (quote != "") {
                if (c == quote) quote=""; else word=word c
            } else if (c == "\047" || c == "\042") { quote=c; started=1 }
            else if (c ~ /[ \t]/) {
                if (started) { a[++n]=word; word=""; started=0 }
            } else if (c == "|") {
                if (started) { a[++n]=word; word=""; started=0 }
                a[++n]="|"
            } else { word=word c; started=1 }
        }
        if (quote != "") bad()
        if (started) a[++n]=word
        if (a[1] != "curl" || a[2] != "-fsSL" ||
            tolower(link_url(a[3])) != "https://raw.githubusercontent.com/cedar2025/xboard-node/dev/install.sh" || a[4] != "|") bad()
        p=5; if (a[p] == "sudo") p++
        if (a[p++] != "bash" || a[p++] != "-s" || a[p++] != "--") bad()
        while (p<=n) {
            key=a[p++]; value=a[p++]
            if (seen[key]++ || value == "") bad()
            if (key == "--mode") mode=value
            else if (key == "--panel") panel=link_url(value)
            else if (key == "--token") token=value
            else if (key == "--machine-id") id=value
            else bad()
        }
        if (mode != "machine" || id !~ /^[1-9][0-9]*$/ || length(id)>9) bad()
        if (token !~ /^[A-Za-z0-9._~-]+$/ || length(token)>512) bad()
        # HTTPS, optional port/base path; no URL credentials, query or fragment.
        if (panel !~ /^https:\/\/[A-Za-z0-9.-]+(:[0-9]+)?(\/[A-Za-z0-9._~\/-]*)?$/) bad()
        host=panel; sub(/^https:\/\//,"",host); sub(/\/.*/,"",host)
        if (host ~ /:/) {
            split(host,h,":"); if (h[2]+0<1 || h[2]+0>65535) bad(); host=h[1]
        }
        if (host !~ /^[A-Za-z0-9]/ || host !~ /[A-Za-z0-9]$/ || host ~ /\.\./) bad()
        sub(/\/+$/,"",panel)
        print panel; print token; print id
    }'
}

effective_memory() {
    # Read the process cgroup AND visible ancestors, not the host free(1) value.
    proc=${1:-/proc}
    limit_kib=$(awk '/^MemTotal:/ { print $2; exit }' "$proc/meminfo")
    [ -n "$limit_kib" ] || return 1
    cg_path=$(awk -F: '$1=="0" && $2=="" {print $3;exit}' "$proc/self/cgroup")
    cg_kind=cgroup2
    cg_file=memory.max
    if [ -z "$cg_path" ]; then
        cg_path=$(awk -F: '$2 ~ /(^|,)memory(,|$)/ {print $3;exit}' "$proc/self/cgroup")
        cg_kind=cgroup
        cg_file=memory.limit_in_bytes
    fi
    mount=$(awk -v kind="$cg_kind" '
        { for(i=7;i<=NF;i++) if($i=="-" && $(i+1)==kind &&
          (kind=="cgroup2" || $(i+3) ~ /(^|,)memory(,|$)/)) {print $4 "|" $5;exit} }
        ' "$proc/self/mountinfo")
    if [ -n "$mount" ]; then
        cg_root=${mount%%|*}; cg_mount=${mount#*|}
        case "$cg_path" in
            /../*|*/../*|*/..) cg_dir=$cg_mount ;;
            "$cg_root") cg_dir=$cg_mount ;;
            "$cg_root"/*) cg_dir=$cg_mount/${cg_path#"$cg_root"/} ;;
            *) if [ "$cg_root" = / ]; then cg_dir=$cg_mount$cg_path; else cg_dir=$cg_mount; fi ;;
        esac
        while :; do
            if [ -r "$cg_dir/$cg_file" ]; then
                cg_value=$(cat "$cg_dir/$cg_file")
                limit_kib=$(awk -v old="$limit_kib" -v b="$cg_value" 'BEGIN {
                    if(b ~ /^[0-9]+$/ && b+0>0 && (b+0)/1024<old) old=int(b/1024)
                    print old
                }')
            fi
            [ "$cg_dir" != "$cg_mount" ] || break
            cg_dir=${cg_dir%/*}
            case "$cg_dir" in "$cg_mount"|"$cg_mount"/*) ;; *) break ;; esac
        done
    fi
    awk -v k="$limit_kib" 'BEGIN { print int(k/1024) }'
}

recommended_budget() {
    # ponytail: a conservative starting budget, not a workload benchmark.
    awk -v m="$1" 'BEGIN { if(m<=80) print 28; else print int(m*0.4) }'
}

check_existing() {
    for path in "$BIN_DIR" "$CONFIG_DIR" "$LOG_DIR" "$ROTATE_CONFIG" \
        "$UNIT" "$RC_UNIT" "$ROTATE_UNIT" "$ROTATE_TIMER" "$RC_ROTATE" \
        /usr/local/bin/xboard-node /usr/local/bin/xbctl /opt/xboard-node /root/xboard-node; do
        if [ -e "$path" ] || [ -L "$path" ]; then
            say '检测到已有 Node 安装或相关文件；首装器退出，不覆盖、不重启。'
            return 0
        fi
    done
    if command -v xboard-node >/dev/null 2>&1 || pgrep -x xboard-node >/dev/null 2>&1; then
        say '检测到已有 Node 进程或程序；首装器退出。'
        return 0
    fi
    return 1
}

detect_platform() {
    [ "$(uname -s)" = Linux ] || die '仅支持 Linux。'
    case "$(uname -m)" in
        x86_64|amd64) ARCH=amd64 ;;
        aarch64|arm64) ARCH=arm64 ;;
        *) die '仅支持 x86_64 / ARM64。' ;;
    esac
    # os-release is a root-owned OS file, never operator input.
    [ -r /etc/os-release ] || die '无法识别发行版。'
    . /etc/os-release
    case "$ID" in
        debian|ubuntu)
            [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1 || die '需要正在运行的 systemd。'
            INIT=systemd ;;
        alpine)
            [ -d /run/openrc ] && command -v rc-service >/dev/null 2>&1 || die '需要正在运行的 OpenRC。'
            INIT=openrc ;;
        *) die '当前支持 Debian、Ubuntu、Alpine；此系统未适配。' ;;
    esac
    MEMORY=$(effective_memory /proc) || die '无法读取有效内存。'
    [ "$MEMORY" -ge 64 ] || die '有效内存低于 64MiB，停止首装。'
    # Do not stage a ~70MiB release in /tmp (often tmpfs on tiny VPSs).
    mkdir -p /usr/local/lib
    [ ! -L /usr/local/lib ] || die '/usr/local/lib 不能是符号链接。'
    fs_type=$(stat -f -c %T /usr/local/lib)
    case "$fs_type" in tmpfs|ramfs) die '安装目录位于内存文件系统，需要磁盘存储。' ;; esac
    disk_kib=$(df -Pk /usr/local/lib | awk 'END {print $4}')
    [ "$disk_kib" -ge 153600 ] || die '安装磁盘至少需要 150MiB 可用空间。'
    say "系统：$ID / $INIT；架构：$ARCH；有效内存：${MEMORY}MiB。"
}

read_private_command() {
    exec 3<>/dev/tty || die '需要交互终端；请在服务器控制台运行。'
    TTY_STATE=$(stty -g <&3) || die '无法设置终端。'
    stty -echo <&3
    parsed=
    for attempt in 1 2 3; do
        say '粘贴面板后台的完整 machine 安装命令，然后回车（输入隐藏）：' >&3
        IFS= read -r pasted <&3 || die '没有读取到安装命令。'
        printf '\n' >&3
        if parsed=$(printf '%s\n' "$pasted" | parse_command); then break; fi
        unset pasted
        say '命令格式无效：请复制完整 machine 命令，包含面板地址、Token 和机器 ID；网址链接的显示文本与目标必须一致。' >&3
        [ "$attempt" != 3 ] || die '连续三次输入无效；请从面板后台重新复制完整安装命令后重试。'
    done
    stty "$TTY_STATE" <&3
    TTY_STATE=
    unset pasted
    PANEL=$(printf '%s\n' "$parsed" | sed -n '1p')
    TOKEN=$(printf '%s\n' "$parsed" | sed -n '2p')
    MACHINE_ID=$(printf '%s\n' "$parsed" | sed -n '3p')
    unset parsed
}

choose_options() {
    printf '内核：1) sing-box（默认推荐）  2) Xray [1]: ' >&3
    IFS= read -r answer <&3 || die '输入中断。'
    case "$answer" in ''|1) KERNEL=singbox ;; 2) KERNEL=xray ;; *) die '请输入 1 或 2。' ;; esac
    BUDGET=$(recommended_budget "$MEMORY")
    say "推荐 Go 软内存预算：${BUDGET}MiB；它不等于服务器内存或进程 RSS。" >&3
    printf '内存优化：1) 推荐  2) 自定义预算（MiB） [1]: ' >&3
    IFS= read -r answer <&3 || die '输入中断。'
    case "$answer" in
        ''|1) ;;
        2) printf '输入 Go 预算整数（MiB）：' >&3
           IFS= read -r BUDGET <&3 || die '输入中断。' ;;
        *) die '请输入 1 或 2。' ;;
    esac
    case "$BUDGET" in ''|*[!0-9]*) die '内存预算必须是整数。' ;; esac
    [ "${#BUDGET}" -le 8 ] && [ "$BUDGET" -ge 16 ] && [ "$BUDGET" -le "$((MEMORY - 32))" ] || die '预算必须至少 16MiB，并保留至少 32MiB 给 Go 以外的占用和系统。'
    BUDGET=$(awk -v m="$BUDGET" 'BEGIN {printf "%d", m}')
    GOGC=100
    [ "$MEMORY" -gt 256 ] || GOGC=50
    say "已选 $KERNEL；Go 预算 ${BUDGET}MiB；GOGC=$GOGC。" >&3
}

install_dependencies() {
    missing=
    for cmd in curl jq sha256sum logrotate; do
        command -v "$cmd" >/dev/null 2>&1 || missing=1
    done
    [ -s /etc/ssl/certs/ca-certificates.crt ] || missing=1
    if [ "$INIT" = openrc ]; then
        rc-service --exists crond >/dev/null 2>&1 || missing=1
    fi
    [ -n "$missing" ] || return 0
    say '安装缺少的下载、JSON 校验、证书和日志轮转工具……'
    if [ "$INIT" = openrc ]; then
        set -- curl ca-certificates jq logrotate
        if ! rc-service --exists crond >/dev/null 2>&1; then set -- "$@" busybox-openrc; fi
        apk add --no-cache "$@" >/dev/null 2>&1 || die '依赖安装失败，请检查 apk 软件源和可用资源。'
    else
        apt-get -o Acquire::Languages=none update -qq >/dev/null 2>&1 || die 'apt 软件源更新失败。'
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends curl ca-certificates jq logrotate >/dev/null 2>&1 || die '依赖安装失败，请检查 apt 软件源和可用资源。'
    fi
    for cmd in curl jq sha256sum logrotate; do
        command -v "$cmd" >/dev/null 2>&1 || die '安装后仍缺少必要工具。'
    done
    if [ "$INIT" = openrc ]; then
        rc-service --exists crond >/dev/null 2>&1 || die '缺少 crond 的 OpenRC 服务；请检查 busybox-openrc 软件包。'
    fi
}

check_panel() {
    # Secret stays in stdin, not argv/env/URL. No redirect and no error body echo.
    PANEL_ERROR=
    NODE_COUNT=0
    if status=$(printf '{"machine_id":%s,"token":"%s"}' "$MACHINE_ID" "$TOKEN" |
        curl -q --silent --proto '=https' --connect-timeout 10 --max-time 30 \
        --max-filesize 1048576 --request POST --header 'Content-Type: application/json' \
        --header 'Accept: application/json' --data-binary @- \
        --output "$STAGE/panel.json" --write-out '%{http_code}' \
        "$PANEL/api/v2/server/machine/nodes" 2>/dev/null); then
        case "$status" in
            200) ;;
            403)
                if jq -e 'type == "object" and .message == "Machine not found or disabled"' "$STAGE/panel.json" >/dev/null 2>&1; then
                    PANEL_ERROR='面板拒绝接入（HTTP 403）：机器不存在或已停用；请在后台确认机器 ID 和启用状态，再重新复制安装命令。'
                else
                    PANEL_ERROR='面板接入被拒绝（HTTP 403）；请核对机器启用状态、Token 和面板访问限制。'
                fi ;;
            401) PANEL_ERROR='面板鉴权未通过（HTTP 401）；请从后台重新复制当前机器的安装命令。' ;;
            404) PANEL_ERROR='找不到机器 API（HTTP 404）；请核对面板地址和面板版本是否支持 machine 模式。' ;;
            3[0-9][0-9]) PANEL_ERROR="面板接口发生重定向（HTTP $status）；请核对最终 HTTPS 地址及面板登录跳转。" ;;
            429) PANEL_ERROR='面板请求过于频繁（HTTP 429）；请稍后重试并检查面板访问限制。' ;;
            5[0-9][0-9]) PANEL_ERROR="面板或代理服务异常（HTTP $status）；请检查面板运行状态后重试。" ;;
            [0-9][0-9][0-9]) PANEL_ERROR="面板返回非预期状态（HTTP $status）；请检查面板机器接口。" ;;
            *) PANEL_ERROR='无法识别面板 HTTP 状态；请检查网络和面板机器接口。' ;;
        esac
    else
        case "$?" in
            5|6) PANEL_ERROR='面板 DNS 解析失败；请检查域名和服务器 DNS。' ;;
            7) PANEL_ERROR='无法连接面板；请检查面板运行状态和服务器出站网络。' ;;
            28) PANEL_ERROR='面板请求超时；请检查网络和面板运行状态后重试。' ;;
            35|51|58|60|77) PANEL_ERROR='面板 HTTPS/TLS 校验失败；请检查证书、系统时间和 CA 证书包。' ;;
            63) PANEL_ERROR='面板响应超过 1MiB 限制；请检查机器接口是否返回了异常页面或过大的配置。' ;;
            *) PANEL_ERROR='面板网络请求失败；请检查网络、HTTPS 和面板运行状态。' ;;
        esac
    fi
    if [ -z "$PANEL_ERROR" ]; then
        NODE_COUNT=$(jq -er '
        if type == "object" and (.nodes | type == "array") and
           all(.nodes[]; type == "object" and (.id | type == "number") and
               (.id > 0) and (.id == (.id | floor)) and (.type | type == "string"))
        then .nodes | length else error("invalid machine response") end
        ' "$STAGE/panel.json" 2>/dev/null) || PANEL_ERROR='面板返回格式不符；需要 machine API 的 JSON 节点列表，请检查面板版本、地址和登录跳转。'
    fi
    rm -f "$STAGE/panel.json"
    [ -z "$PANEL_ERROR" ]
}

download_binaries() {
    case "$ARCH" in
        amd64)
            node_sha=55bf71fa9d9f2048d3255ae7c0af929a41897ca7743f6ead34132a6ca4c79043
            ctl_sha=8ec7b9bbf0abb99a9c24b1b3ceef1ed5496f458e7dc22b09c33b098d5b2aad9e ;;
        arm64)
            node_sha=40835fd216cdeaa731f69cab3f0cb0b93b6e9a145a0489beddbc25b6473658d7
            ctl_sha=0c9b67e767d7baa9d4dae53b8ace31b9eb3209a3f1e41e62dc1b0f410dc8ba18 ;;
    esac
    mkdir "$STAGE/bin" "$STAGE/config"
    for name in xboard-node xbctl; do
        say "下载官方 $VERSION / $ARCH / $name……"
        curl -q --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
            --connect-timeout 15 --max-time 900 --retry 2 --max-filesize 80000000 \
            --output "$STAGE/bin/$name" "$RELEASE/$VERSION/$name-linux-$ARCH" || die '官方二进制下载失败。'
    done
    printf '%s  %s\n%s  %s\n' "$node_sha" "$STAGE/bin/xboard-node" "$ctl_sha" "$STAGE/bin/xbctl" |
        sha256sum -c - >/dev/null 2>&1 || die 'SHA256 校验失败，停止安装。'
    chmod 755 "$STAGE/bin/xboard-node" "$STAGE/bin/xbctl"
    GOMEMLIMIT="${BUDGET}MiB" GOGC="$GOGC" "$STAGE/bin/xboard-node" -v >/dev/null 2>&1 || die '二进制无法在当前系统运行。'
}

generate_config() {
    # Official xbctl generates the version's YAML schema; token deliberately absent.
    env GOMEMLIMIT="${BUDGET}MiB" GOGC="$GOGC" "$STAGE/bin/xbctl" config init \
        --mode machine --panel-url "$PANEL" --machine-id "$MACHINE_ID" \
        --kernel "$KERNEL" --gomemlimit "${BUDGET}MiB" --gogc "$GOGC" \
        --health-port 0 --install-root "$CONFIG_DIR" --output "$STAGE/config/config.yml" \
        >"$STAGE/config-meta" 2>/dev/null || die '官方配置生成失败。'
    env_key=$(sed -n 's/^ENV_KEY=//p' "$STAGE/config-meta")
    case "$env_key" in INSTANCE_*_MACHINE_TOKEN) ;; *) die '凭据字段生成失败。' ;; esac
    case "$env_key" in *[!A-Z0-9_]*) die '凭据字段无效。' ;; esac
    printf "%s='%s'\n" "$env_key" "$TOKEN" >"$STAGE/config/credentials.env"
    # Generated global log.level is info; kernel.log_level is already warn.
    sed 's/^\([[:space:]]*level:\) info$/\1 warn/' "$STAGE/config/config.yml" >"$STAGE/config/config.new"
    mv "$STAGE/config/config.new" "$STAGE/config/config.yml"
    chmod 600 "$STAGE/config/config.yml" "$STAGE/config/credentials.env"
    rm -f "$STAGE/config-meta"
}

write_services() {
    mkdir -p "$LOG_DIR" /etc/logrotate.d
    : >"$LOG_DIR/node.log"
    chmod 600 "$LOG_DIR/node.log"
    logrotate_bin=$(command -v logrotate)
    cat >"$ROTATE_CONFIG" <<EOF
$LOG_DIR/node.log {
    size 1M
    rotate 2
    missingok
    notifempty
    copytruncate
    nocompress
    su root root
}
EOF
    if [ "$INIT" = systemd ]; then
        cat >"$UNIT" <<EOF
[Unit]
Description=Xboard-Node machine agent
Wants=network-online.target
After=network-online.target
StartLimitIntervalSec=60
StartLimitBurst=3
[Service]
Type=simple
EnvironmentFile=$CONFIG_DIR/credentials.env
ExecStart=$BIN_DIR/xboard-node -c $CONFIG_DIR/config.yml
Restart=on-failure
RestartSec=5
TimeoutStopSec=20
UMask=0077
NoNewPrivileges=true
LimitNOFILE=8192
StandardOutput=append:$LOG_DIR/node.log
StandardError=append:$LOG_DIR/node.log
[Install]
WantedBy=multi-user.target
EOF
        # Independent process headroom; Go's budget is NOT the RSS limit.
        if [ "$MEMORY" -le 256 ]; then
            high=$((MEMORY * 5 / 8))
            max=$((MEMORY - 16))
            [ "$high" -ge "$((BUDGET + 8))" ] || high=$((BUDGET + 8))
            sed "/^LimitNOFILE=/a MemoryAccounting=yes\nMemoryHigh=${high}M\nMemoryMax=${max}M" "$UNIT" >"$STAGE/unit.new"
            mv "$STAGE/unit.new" "$UNIT"
        fi
        cat >"$ROTATE_UNIT" <<EOF
[Unit]
Description=Rotate Xboard-Node private logs
[Service]
Type=oneshot
ExecStart=$logrotate_bin -s $CONFIG_DIR/logrotate.state $ROTATE_CONFIG
EOF
        cat >"$ROTATE_TIMER" <<EOF
[Unit]
Description=Check Xboard-Node log size every fifteen minutes
[Timer]
OnBootSec=2min
OnUnitActiveSec=15min
[Install]
WantedBy=timers.target
EOF
        chmod 644 "$UNIT" "$ROTATE_UNIT" "$ROTATE_TIMER"
    else
        cat >"$RC_UNIT" <<EOF
#!/sbin/openrc-run
description="Xboard-Node machine agent"
supervisor="supervise-daemon"
command="$BIN_DIR/xboard-node"
command_args="-c $CONFIG_DIR/config.yml"
pidfile="/run/xboard-node.pid"
respawn_delay=5
respawn_max=3
respawn_period=60
output_log="$LOG_DIR/node.log"
error_log="$LOG_DIR/node.log"
depend() { need net; }
start_pre() {
    umask 077
    set -a
    . "$CONFIG_DIR/credentials.env"
    set +a
    ulimit -n 8192 || return 1
}
EOF
        mkdir -p /etc/periodic/15min
        cat >"$RC_ROTATE" <<EOF
#!/bin/sh
exec "$logrotate_bin" -s "$CONFIG_DIR/logrotate.state" "$ROTATE_CONFIG"
EOF
        chmod 755 "$RC_UNIT" "$RC_ROTATE"
    fi
}

start_services() {
    if [ "$INIT" = systemd ]; then
        systemctl daemon-reload >/dev/null 2>&1 &&
        systemctl enable --now xboard-node-logrotate.timer xboard-node.service >/dev/null 2>&1 || return 1
    else
        rc-update add xboard-node default >/dev/null 2>&1 &&
        rc-service xboard-node start >/dev/null 2>&1 || return 1
    fi
    # Require stable process identity, not a transient active/restart state.
    old_pid=
    for iteration in 1 2 3; do
        if [ "$INIT" = systemd ]; then
            systemctl is-active --quiet xboard-node.service || return 1
            current_pid=$(systemctl show --property MainPID --value xboard-node.service)
        else
            rc-service xboard-node status >/dev/null 2>&1 || return 1
            # supervise-daemon pidfile names its supervisor, not the Node child.
            current_pid=$(pidof xboard-node 2>/dev/null) || return 1
        fi
        case "$current_pid" in ''|0|*[!0-9]*) return 1 ;; esac
        kill -0 "$current_pid" 2>/dev/null || return 1
        [ -z "$old_pid" ] || [ "$old_pid" = "$current_pid" ] || return 1
        old_pid=$current_pid
        [ "$iteration" = 3 ] || sleep 2
    done
}

cleanup() {
    result=$?
    trap - EXIT HUP INT TERM
    [ -z "$TTY_STATE" ] || stty "$TTY_STATE" <&3 2>/dev/null || :
    if [ "$OWNED" = 1 ] && [ "$COMPLETE" != 1 ]; then
        say '首装未完成，清理本次新增的 Node 文件；依赖包保留。' >&2
        if [ "$INIT" = systemd ]; then
            systemctl disable --now xboard-node.service xboard-node-logrotate.timer >/dev/null 2>&1 || :
        else
            rc-service xboard-node stop >/dev/null 2>&1 || :
            rc-update del xboard-node default >/dev/null 2>&1 || :
        fi
        rm -f "$UNIT" "$RC_UNIT" "$ROTATE_CONFIG" "$ROTATE_UNIT" "$ROTATE_TIMER" "$RC_ROTATE"
        rm -rf "$BIN_DIR" "$CONFIG_DIR" "$LOG_DIR"
        [ "$INIT" != systemd ] || systemctl daemon-reload >/dev/null 2>&1 || :
    fi
    case "$STAGE" in /usr/local/lib/.xboard-node.*) rm -rf "$STAGE" ;; esac
    [ "$LOCKED" != 1 ] || rmdir "$LOCK" 2>/dev/null || :
    exit "$result"
}

main() {
    [ "$#" = 0 ] || die '无需传递参数；接入信息在交互终端私下输入。'
    [ "$(id -u)" = 0 ] || die '请以 root 或 sudo sh 运行。'
    if check_existing; then return 0; fi
    mkdir "$LOCK" 2>/dev/null || die '另一个安装正在进行，或有中断遗留锁；确认没有安装进程后再移除 /run/xboard-node-install.lock。'
    LOCKED=1
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' HUP TERM
    detect_platform
    read_private_command
    choose_options
    install_dependencies
    disk_kib=$(df -Pk /usr/local/lib | awk 'END {print $4}')
    [ "$disk_kib" -ge 102400 ] || die '安装依赖后磁盘不足 100MiB。'
    STAGE=$(mktemp -d /usr/local/lib/.xboard-node.XXXXXX) || die '无法创建磁盘暂存目录。'
    check_panel || die "$PANEL_ERROR"
    say "面板机器鉴权通过；已分配节点数：$NODE_COUNT（不显示接入地址或凭据）。"
    if [ "$INIT" = openrc ]; then
        rc-update add crond default >/dev/null 2>&1 &&
        rc-service crond start >/dev/null 2>&1 ||
            die 'OpenRC crond 服务无法启动；请检查 hostname、logger 等基础服务及系统日志。精简镜像缺失包文件时可用 apk fix openrc 修复，脚本不会自动修复系统服务。'
    fi
    download_binaries
    generate_config
    if check_existing; then die '安装期间出现已有安装，停止写入。'; fi
    OWNED=1
    mv "$STAGE/bin" "$BIN_DIR"
    mv "$STAGE/config" "$CONFIG_DIR"
    chmod 700 "$CONFIG_DIR"
    write_services
    chmod 700 "$LOG_DIR"
    start_services || die '服务启动或稳定性检查失败；请检查系统资源及服务管理器。'
    COMPLETE=1
    if check_panel; then panel_ok=1; else panel_ok=0; fi
    unset TOKEN
    say "安装完成：官方 $VERSION / $ARCH / $KERNEL；服务已启动并设为开机启动。"
    if [ "$panel_ok" = 0 ]; then
        say '安装前面板鉴权通过，但安装后复查失败；服务保留，请在面板确认接入状态。'
        say "$PANEL_ERROR"
    elif [ "$NODE_COUNT" = 0 ]; then
        say '面板暂未分配节点；Node 等待后台添加，无需重装。'
    else
        say '已通过面板鉴权并发现分配节点；请在面板确认各节点在线，再用客户端验证协议。'
    fi
    say '本次未验证客户端连通性。私有日志：/var/log/xboard-node/node.log（提交问题前脱敏）。'
}

# Library switch is used only by isolated tests; no alternate install-root mode.
if [ "${XBOARD_INSTALL_LIBRARY:-0}" != 1 ]; then main "$@"; fi
