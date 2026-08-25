#!/bin/bash
###############################################################################
# install-sngrep.sh
# sngrep (SIP 信令抓包分析工具) 安装脚本（支持在线 / 离线双模式）
#
# 项目地址: https://github.com/irontec/sngrep
# 说明: 使用 Ubuntu 官方仓库的 sngrep .deb 包 (ncurses TUI),
#       依赖: libpcap / libncursesw / libtinfo / libgcrypt / libgnutls / libpcre2
#
# 用法:
#   在线安装:              ./install-sngrep.sh --online
#   离线安装:              ./install-sngrep.sh --offline
#   离线安装(自定义目录):  ./install-sngrep.sh --offline --pkg-dir /data/offline-bundle/packages/sngrep
#   卸载:                  ./install-sngrep.sh --uninstall
#   查看状态:              ./install-sngrep.sh --status
#
# 可选参数:
#   --pkg-dir  DIR    离线 .deb 包目录  (默认 /data/images, 自动探测 sngrep 子目录)
#
###############################################################################
set -euo pipefail

# ============================ 加载共享库 ============================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

# ============================ 默认参数 ============================
MODE=""
PKG_DIR="/data/images"

# sngrep 及其依赖的 .deb 包名匹配模式
DEB_PATTERNS=("sngrep" "libpcap" "libncursesw" "libtinfo" "libgcrypt" "libgnutls" "libpcre2-8")

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
                grep '^#' "$0" | head -22
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

    # root 检查 (status 模式除外)
    if [[ "$MODE" != "status" && $EUID -ne 0 ]]; then
        log_error "请以 root 用户运行此脚本"
        exit 1
    fi

    # 系统检查
    if [[ "$MODE" != "status" ]]; then
        if ! grep -qiE 'ubuntu|debian' /etc/os-release 2>/dev/null; then
            log_error "此脚本仅支持 Ubuntu / Debian 系统"
            exit 1
        fi
        source /etc/os-release
        log_info "操作系统: $PRETTY_NAME"
    fi

    # 已安装检查 (安装模式下提示)
    if [[ "$MODE" == "online" || "$MODE" == "offline" ]]; then
        if command -v sngrep &>/dev/null; then
            local cur_ver
            cur_ver=$(sngrep -V 2>/dev/null | head -1 || echo "未知")
            log_warn "sngrep 已安装 (${cur_ver})"
            read -rp "是否要覆盖安装？[y/N]: " ans
            [[ "$ans" =~ ^[Yy]$ ]] || { log_info "已取消安装"; exit 0; }
        fi
    fi
}

# ============================ 在线安装 ============================
install_online() {
    log_step "在线安装 sngrep"

    log_info "apt update ..."
    apt-get update -qq

    log_info "安装 sngrep (Ubuntu 官方仓库) ..."
    apt-get install -y -qq sngrep

    log_ok "sngrep 在线安装完成"
}

# ============================ 离线安装 ============================
install_offline() {
    log_step "离线安装 sngrep"

    # 查找离线包目录: 优先独立 sngrep 子目录 (依赖树完整, 整目录安装)
    local pkg_dir="" d
    for d in "${PKG_DIR}/sngrep" "/data/offline-bundle/packages/sngrep" "$PKG_DIR" "/data/offline-bundle/packages"; do
        if [[ -d "$d" ]] && find "$d" -maxdepth 1 -name 'sngrep*.deb' -type f 2>/dev/null | grep -q .; then
            pkg_dir="$d"
            break
        fi
    done

    if [[ -z "$pkg_dir" ]]; then
        log_error "未找到 sngrep .deb 包 (查找: ${PKG_DIR}/sngrep, /data/offline-bundle/packages/sngrep, ${PKG_DIR})"
        log_info "请先在联网机器执行 prepare-offline.sh，或手动下载 sngrep 及依赖的 .deb 包"
        exit 1
    fi
    log_info "离线包目录: ${pkg_dir}"

    local debs=()
    if [[ "$(basename "$pkg_dir")" == "sngrep" ]]; then
        # 独立目录: 里面是完整的 sngrep 依赖树, 全部安装
        while IFS= read -r f; do debs+=("$f"); done \
            < <(find "$pkg_dir" -maxdepth 1 -name '*.deb' -type f 2>/dev/null | sort)
    else
        # 混合目录: 只装 sngrep + 已知依赖 (依赖不全时可能失败)
        local p f
        for p in "${DEB_PATTERNS[@]}"; do
            while IFS= read -r f; do debs+=("$f"); done \
                < <(find "$pkg_dir" -maxdepth 1 -name "${p}*.deb" -type f 2>/dev/null | sort)
        done
    fi

    if [[ ${#debs[@]} -eq 0 ]]; then
        log_error "未找到任何匹配的 .deb 包"
        exit 1
    fi

    log_info "找到 ${#debs[@]} 个 .deb 包:"
    printf '    %s\n' "${debs[@]##*/}"

    # dpkg 安装 (多轮处理依赖顺序)
    log_info "安装 .deb 包 ..."
    dpkg_install_debs "${debs[@]}"
    apt-get install -f -y -qq 2>/dev/null || true

    log_ok "sngrep 离线安装完成"
}

# ============================ 卸载 ============================
do_uninstall() {
    log_step "卸载 sngrep"

    if ! command -v sngrep &>/dev/null; then
        log_info "sngrep 未安装，无需卸载"
        return 0
    fi

    apt-get remove -y -qq sngrep 2>/dev/null || dpkg -r sngrep
    hash -r 2>/dev/null || true
    log_ok "sngrep 已卸载"
}

# ============================ 状态查看 ============================
do_status() {
    log_step "sngrep 状态"

    if command -v sngrep &>/dev/null; then
        log_ok "已安装: $(command -v sngrep)"
        sngrep -V 2>/dev/null | head -1 | sed 's/^/    版本: /' || true
        echo ""
        log_info "常用命令:"
        echo "    sngrep                              # 实时抓 SIP 包 (默认所有接口)"
        echo "    sngrep -d eth0 port 5060            # 指定网卡 + BPF 过滤"
        echo "    sngrep -r capture.pcap              # 离线分析 pcap 文件"
    else
        log_info "sngrep 未安装"
    fi
}

# ============================ 验证安装 ============================
verify_install() {
    log_step "验证安装"

    if ! command -v sngrep &>/dev/null; then
        log_error "安装失败: sngrep 命令不存在"
        exit 1
    fi

    local ver
    ver=$(sngrep -V 2>/dev/null | head -1 || echo "")
    log_ok "sngrep 可用 ${ver:+(${ver})}"
}

# ============================ 主流程 ============================
main() {
    parse_args "$@"
    init_log "install-sngrep"
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
