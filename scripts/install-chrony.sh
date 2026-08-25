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
#   卸载:      ./install-chrony.sh --uninstall
#   查看状态:  ./install-chrony.sh --status
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
            --uninstall) MODE="uninstall"; shift ;;
            --status)    MODE="status";    shift ;;
            --pkg-dir)   PKG_DIR="$2";     shift 2 ;;
            -h|--help)   grep '^#' "$0" | head -18; exit 0 ;;
            *)           log_error "未知参数: $1"; exit 1 ;;
        esac
    done

    if [[ -z "$MODE" ]]; then
        log_error "请指定操作: --online / --offline / --uninstall / --status"
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

    cat > "$CHRONY_CONF" << EOF
# chrony.conf — 由 install-chrony.sh 生成 ($(date '+%Y-%m-%d %H:%M:%S'))
# 国内公共 NTP 源
$(printf 'pool %s iburst\n' "${NTP_POOLS[@]}")
# 内网隔离环境兜底: 无外网时本机作为本地时间源 (其他节点可指向本机)
local stratum 10

driftfile /var/lib/chrony/chrony.drift
makestep 1.0 3
rtcsync
logdir /var/log/chrony
EOF

    log_info "NTP 源: ${NTP_POOLS[*]}"
    log_ok "chrony.conf 已生成"
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
            start_and_verify
            ;;
        offline)
            install_offline
            configure_chrony
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
