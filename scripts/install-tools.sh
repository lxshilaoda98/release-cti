#!/bin/bash
###############################################################################
# install-tools.sh
# 常用运维工具包安装脚本（支持在线 / 离线双模式）
#
# 工具清单 (Ubuntu 官方仓库):
#   sip-tester (sipp)  SIP 压测/呼叫模拟
#   sipsak             SIP 探测 (OPTIONS/INVITE)
#   mtr                路由+丢包诊断
#   iftop              实时带宽
#   nethogs            按进程看流量
#   lnav               日志浏览器
#   jq                 JSON 命令行处理
#   htop               进程/资源监控
#   iotop              磁盘 IO 监控
#
# 用法:
#   在线安装:              ./install-tools.sh --online
#   离线安装:              ./install-tools.sh --offline
#   离线安装(自定义目录):  ./install-tools.sh --offline --pkg-dir /data/offline-bundle/packages/tools
#   卸载:                  ./install-tools.sh --uninstall
#   查看状态:              ./install-tools.sh --status
#
# 可选参数:
#   --pkg-dir  DIR    离线 .deb 包目录  (默认 /data/images, 自动探测 tools 子目录)
#
###############################################################################
set -euo pipefail

# ============================ 加载共享库 ============================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

# ============================ 默认参数 ============================
MODE=""
PKG_DIR="/data/images"

# 工具包清单 (apt 包名)
TOOLS=(sip-tester sipsak mtr iftop nethogs lnav jq htop iotop)

# ============================ 参数解析 ============================
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --online)    MODE="online";    shift ;;
            --offline)   MODE="offline";   shift ;;
            --uninstall) MODE="uninstall"; shift ;;
            --status)    MODE="status";    shift ;;
            --pkg-dir)   PKG_DIR="$2";     shift 2 ;;
            -h|--help)
                grep '^#' "$0" | head -26
                exit 0
                ;;
            *)
                log_error "未知参数: $1"
                exit 1
                ;;
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
        source /etc/os-release
        log_info "操作系统: $PRETTY_NAME"
    fi

    log_info "工具清单 (${#TOOLS[@]} 个): ${TOOLS[*]}"
}

# ============================ 在线安装 ============================
install_online() {
    log_step "在线安装运维工具包"

    apt_ensure_universe

    log_info "apt update ..."
    apt-get update -qq

    log_info "安装: ${TOOLS[*]} ..."
    apt-get install -y -qq "${TOOLS[@]}"

    log_ok "运维工具包在线安装完成"
}

# ============================ 离线安装 ============================
install_offline() {
    log_step "离线安装运维工具包"

    # 查找离线包目录: 优先独立 tools 子目录 (依赖树完整, 整目录安装)
    local pkg_dir="" d
    for d in "${PKG_DIR}/tools" "/data/offline-bundle/packages/tools" "$PKG_DIR" "/data/offline-bundle/packages"; do
        if [[ -d "$d" ]] && find "$d" -maxdepth 1 -name 'sipsak*.deb' -type f 2>/dev/null | grep -q .; then
            pkg_dir="$d"
            break
        fi
    done

    if [[ -z "$pkg_dir" ]]; then
        log_error "未找到工具包 .deb (查找: ${PKG_DIR}/tools, /data/offline-bundle/packages/tools, ${PKG_DIR})"
        log_info "请先在联网机器执行 prepare-offline.sh"
        exit 1
    fi
    log_info "离线包目录: ${pkg_dir}"

    local debs=()
    if [[ "$(basename "$pkg_dir")" == "tools" ]]; then
        # 独立目录: 完整依赖树, 全部安装
        while IFS= read -r f; do debs+=("$f"); done \
            < <(find "$pkg_dir" -maxdepth 1 -name '*.deb' -type f 2>/dev/null | sort)
    else
        # 混合目录: 只装工具包本体 (依赖不全时可能失败)
        local p f
        for p in "${TOOLS[@]}"; do
            while IFS= read -r f; do debs+=("$f"); done \
                < <(find "$pkg_dir" -maxdepth 1 -name "${p}*.deb" -type f 2>/dev/null | sort)
        done
    fi

    if [[ ${#debs[@]} -eq 0 ]]; then
        log_error "未找到任何匹配的 .deb 包"
        exit 1
    fi

    log_info "找到 ${#debs[@]} 个 .deb 包"
    log_info "安装 .deb 包 (多轮 dpkg 处理依赖顺序) ..."
    dpkg_install_debs "${debs[@]}"
    apt-get install -f -y -qq 2>/dev/null || true

    log_ok "运维工具包离线安装完成"
}

# ============================ 卸载 ============================
do_uninstall() {
    log_step "卸载运维工具包"

    log_info "卸载: ${TOOLS[*]} ..."
    apt-get remove -y -qq "${TOOLS[@]}" 2>/dev/null || true
    hash -r 2>/dev/null || true

    log_ok "运维工具包已卸载"
}

# ============================ 状态查看 ============================
do_status() {
    log_step "运维工具包状态"

    local t ver installed=0
    for t in "${TOOLS[@]}"; do
        if dpkg -s "$t" &>/dev/null 2>&1; then
            ver=$(dpkg -s "$t" 2>/dev/null | grep '^Version:' | awk '{print $2}')
            printf "    ${GREEN}✓${NC} %-14s %s\n" "$t" "$ver"
            installed=$((installed + 1))
        else
            printf "    ${RED}✗${NC} %-14s %s\n" "$t" "未安装"
        fi
    done

    echo ""
    log_info "已安装 ${installed}/${#TOOLS[@]}"
}

# ============================ 验证安装 ============================
verify_install() {
    local missing=()
    local t
    for t in "${TOOLS[@]}"; do
        dpkg -s "$t" &>/dev/null 2>&1 || missing+=("$t")
    done

    if [[ ${#missing[@]} -eq 0 ]]; then
        log_ok "全部 ${#TOOLS[@]} 个工具安装成功"
    else
        log_warn "以下工具安装失败: ${missing[*]}"
    fi
}

# ============================ 主流程 ============================
main() {
    parse_args "$@"
    init_log "install-tools"
    preflight_check

    case "$MODE" in
        online)
            install_online
            verify_install
            ;;
        offline)
            install_offline
            verify_install
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
