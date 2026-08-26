#!/bin/bash
###############################################################################
# install-chrony.sh
# chrony 时间同步安装配置脚本（支持在线 / 离线双模式）
#
# 说明: VoIP/双节点 HA 场景对时间敏感 (CDR 话单 / RTP 时间戳 / 日志对齐),
#       配置国内公共 NTP 源 + local 兜底 (内网隔离环境可作为本地时间源)
#
# 用法:
#   在线安装:  ./install-chrony.sh --online
#   离线安装:  ./install-chrony.sh --offline [--pkg-dir /data/images]
#   仅重新配置: ./install-chrony.sh --config [--timezone TZ] [--allow CIDR]
#   卸载:      ./install-chrony.sh --uninstall
#   查看状态:  ./install-chrony.sh --status
#
# 可选参数:
#   --timezone TZ    系统时区        (默认 Asia/Shanghai)
#   --allow    CIDR  允许同步的网段  (本机作为 NTP 服务器, 可多次指定)
#                    例: --allow 10.160.4.0/24
#   --server   IP    上游 NTP 服务器 (本机从它同步, 替代公共源, 可多次指定)
#                    例: --server 10.160.4.88
#
# 内网 NTP 用法:
#   时间源节点:  ./install-chrony.sh --online --allow 10.160.4.0/24
#   其他节点:    ./install-chrony.sh --config --server <时间源节点IP>
#
###############################################################################
set -euo pipefail

# ============================ 加载共享库 ============================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

# ============================ 默认参数 ============================
MODE=""
PKG_DIR="/data/images"
CHRONY_CONF="/etc/chrony/chrony.conf"
TIMEZONE="Asia/Shanghai"
TZ_EXPLICIT=false
ALLOW_NETS=()
NTP_SERVERS=()

# 国内公共 NTP 源
NTP_POOLS=(
    "ntp.aliyun.com"
    "ntp.tencent.com"
    "ntp.tuna.tsinghua.edu.cn"
)

# ============================ 参数解析 ============================
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --online)    MODE="online";    shift ;;
            --offline)   MODE="offline";   shift ;;
            --config)    MODE="config";    shift ;;
            --uninstall) MODE="uninstall"; shift ;;
            --status)    MODE="status";    shift ;;
            --pkg-dir)   PKG_DIR="$2";     shift 2 ;;
            --timezone)  TIMEZONE="$2"; TZ_EXPLICIT=true; shift 2 ;;
            --allow)     ALLOW_NETS+=("$2"); shift 2 ;;
            --server)    NTP_SERVERS+=("$2"); shift 2 ;;
            -h|--help)   grep '^#' "$0" | head -28; exit 0 ;;
            *)           log_error "未知参数: $1"; exit 1 ;;
        esac
    done

    if [[ -z "$MODE" ]]; then
        log_error "请指定操作: --online / --offline / --config / --uninstall / --status"
        exit 1
    fi
}

# ============================ 前置检查 ============================
preflight_check() {
    log_step "前置检查"

    if [[ "$MODE" != "status" ]]; then
        if [[ $EUID -ne 0 ]]; then
            log_error "请以 root 用户运行此脚本"
            exit 1
        fi
        if ! grep -qiE 'ubuntu|debian' /etc/os-release 2>/dev/null; then
            log_error "此脚本仅支持 Ubuntu / Debian 系统"
            exit 1
        fi
    fi

    # 与 systemd-timesyncd 冲突检查
    if [[ "$MODE" == "online" || "$MODE" == "offline" ]]; then
        if systemctl is-active systemd-timesyncd &>/dev/null; then
            log_info "停止 systemd-timesyncd (避免与 chrony 冲突) ..."
            systemctl stop systemd-timesyncd 2>/dev/null || true
            systemctl disable systemd-timesyncd 2>/dev/null || true
        fi
    fi

    # 仅重新配置模式: 要求已安装
    if [[ "$MODE" == "config" ]] && ! command -v chronyd &>/dev/null; then
        log_error "chrony 未安装，请先执行 --online 或 --offline 安装"
        exit 1
    fi
}

# ============================ 在线安装 ============================
install_online() {
    log_step "在线安装 chrony"

    apt-get update -qq
    apt-get install -y -qq chrony

    log_ok "chrony 在线安装完成"
}

# ============================ 离线安装 ============================
install_offline() {
    log_step "离线安装 chrony"

    local pkg_dir="" d
    for d in "${PKG_DIR}/chrony" "/data/offline-bundle/packages/chrony" "$PKG_DIR" "/data/offline-bundle/packages"; do
        if [[ -d "$d" ]] && find "$d" -maxdepth 1 -name 'chrony*.deb' -type f 2>/dev/null | grep -q .; then
            pkg_dir="$d"
            break
        fi
    done

    if [[ -z "$pkg_dir" ]]; then
        log_error "未找到 chrony .deb 包 (查找: ${PKG_DIR}/chrony, /data/offline-bundle/packages/chrony)"
        log_info "请先在联网机器执行 prepare-offline.sh"
        exit 1
    fi
    log_info "离线包目录: ${pkg_dir}"

    local debs=()
    if [[ "$(basename "$pkg_dir")" == "chrony" ]]; then
        while IFS= read -r f; do debs+=("$f"); done \
            < <(find "$pkg_dir" -maxdepth 1 -name '*.deb' -type f 2>/dev/null | sort)
    else
        while IFS= read -r f; do debs+=("$f"); done \
            < <(find "$pkg_dir" -maxdepth 1 -name 'chrony*.deb' -type f 2>/dev/null | sort)
    fi

    log_info "找到 ${#debs[@]} 个 .deb 包，安装 ..."
    dpkg_install_debs "${debs[@]}"
    apt-get install -f -y -qq 2>/dev/null || true

    log_ok "chrony 离线安装完成"
}

# ============================ 配置 NTP 源 ============================
configure_chrony() {
    log_step "配置 NTP 源"

    backup_file "$CHRONY_CONF"

    {
        if [[ ${#NTP_SERVERS[@]} -gt 0 ]]; then
            # 指定了上游服务器: 用它替代公共源
            cat << EOF
# chrony.conf — 由 install-chrony.sh 生成 ($(date '+%Y-%m-%d %H:%M:%S'))
# 上游 NTP 服务器
$(printf 'server %s iburst\n' "${NTP_SERVERS[@]}")
EOF
        else
            cat << EOF
# chrony.conf — 由 install-chrony.sh 生成 ($(date '+%Y-%m-%d %H:%M:%S'))
# 国内公共 NTP 源
$(printf 'pool %s iburst\n' "${NTP_POOLS[@]}")
EOF
        fi

        cat << EOF
# 内网隔离环境兜底: 无法联系上游时本机作为本地时间源
local stratum 10
EOF

        # 允许内网网段从本机同步 (本机作为 NTP 服务器)
        local net
        for net in "${ALLOW_NETS[@]:-}"; do
            [[ -n "$net" ]] && echo "allow $net"
        done

        cat << EOF

driftfile /var/lib/chrony/chrony.drift
makestep 1.0 3
rtcsync
logdir /var/log/chrony
EOF
    } > "$CHRONY_CONF"

    if [[ ${#NTP_SERVERS[@]} -gt 0 ]]; then
        log_info "上游 NTP 服务器: ${NTP_SERVERS[*]}"
    else
        log_info "NTP 源: ${NTP_POOLS[*]}"
    fi
    if [[ ${#ALLOW_NETS[@]} -gt 0 ]]; then
        log_info "本机作为 NTP 服务器, 允许网段: ${ALLOW_NETS[*]}"
        log_info "其他节点配置: pool <本机IP> iburst"
    fi
    log_ok "chrony.conf 已生成"
}

# ============================ 配置系统时区 ============================
configure_timezone() {
    log_step "配置系统时区"

    local current_tz
    current_tz=$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo "未知")

    if [[ "$current_tz" == "$TIMEZONE" ]]; then
        log_ok "时区已是 ${TIMEZONE}"
        return 0
    fi

    log_info "当前时区: ${current_tz} -> ${TIMEZONE}"
    if timedatectl set-timezone "$TIMEZONE" 2>/dev/null; then
        log_ok "时区已设置: ${TIMEZONE}"
    else
        # timedatectl 不可用时手动设置
        ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
        echo "$TIMEZONE" > /etc/timezone
        log_ok "时区已设置 (手动): ${TIMEZONE}"
    fi
}

# ============================ 启动并验证 ============================
start_and_verify() {
    log_step "启动 chrony 并验证"

    if ! command -v chronyd &>/dev/null; then
        log_error "安装失败: chronyd 不存在"
        exit 1
    fi
    systemctl enable chrony 2>/dev/null || true
    systemctl restart chrony

    sleep 2
    if systemctl is-active chrony &>/dev/null; then
        log_ok "chrony 服务运行中"
    else
        log_error "chrony 启动失败"
        systemctl status chrony --no-pager | tail -5
        exit 1
    fi

    # 等待首次同步 (有网时)
    log_info "时间源状态:"
    chronyc sources 2>/dev/null | sed 's/^/    /' || true

    local offset
    offset=$(chronyc tracking 2>/dev/null | grep -iE "^(Last offset|System time)" || true)
    [[ -n "$offset" ]] && echo "$offset" | sed 's/^/    /'

    log_info "当前时间: $(date '+%Y-%m-%d %H:%M:%S %Z')"
}

# ============================ 卸载 ============================
do_uninstall() {
    log_step "卸载 chrony"

    if ! command -v chronyd &>/dev/null; then
        log_info "chrony 未安装，无需卸载"
        return 0
    fi

    systemctl stop chrony 2>/dev/null || true
    systemctl disable chrony 2>/dev/null || true
    apt-get remove -y -qq chrony 2>/dev/null || dpkg -r chrony
    hash -r 2>/dev/null || true
    log_ok "chrony 已卸载"
}

# ============================ 状态查看 ============================
do_status() {
    log_step "chrony 状态"

    if ! command -v chronyd &>/dev/null; then
        log_info "chrony 未安装"
        return 0
    fi

    log_ok "已安装: $(chronyd --version 2>/dev/null | head -1)"
    echo ""
    timedatectl 2>/dev/null | grep -E "Local time|Time zone|synchronized|NTP service" | sed 's/^/    /' || true
    echo ""
    log_info "时间源:"
    chronyc sources 2>/dev/null | sed 's/^/    /' || log_warn "无法查询 (chrony 未运行?)"
    echo ""
    log_info "偏移量:"
    chronyc tracking 2>/dev/null | grep -iE "^(System time|Last offset|RMS offset)" | sed 's/^/    /' || true
}

# ============================ 主流程 ============================
main() {
    parse_args "$@"
    init_log "install-chrony"
    preflight_check

    case "$MODE" in
        online)
            install_online
            configure_chrony
            configure_timezone
            start_and_verify
            ;;
        offline)
            install_offline
            configure_chrony
            configure_timezone
            start_and_verify
            ;;
        config)
            configure_chrony
            # 仅显式指定 --timezone 时才改时区 (避免重配 allow 时重置时区)
            [[ "$TZ_EXPLICIT" == true ]] && configure_timezone
            start_and_verify
            ;;
        uninstall)
            do_uninstall
            ;;
        status)
            do_status
            ;;
    esac

    echo ""
    show_log_path
}

main "$@"
