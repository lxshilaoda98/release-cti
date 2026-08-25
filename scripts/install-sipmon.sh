#!/bin/bash
###############################################################################
# install-sipmon.sh
# sipmon (SIP/RTP 抓包监控工具) 安装脚本（支持在线 / 离线双模式）
#
# 项目地址: https://github.com/miuda-ai/sipmon
# 说明: 官方 Release 提供静态 musl 二进制 (x86_64 / aarch64)，零系统依赖，
#       直接放到 /usr/local/bin 即可使用
#
# 用法:
#   在线安装:              ./install-sipmon.sh --online
#   在线安装(指定版本):    ./install-sipmon.sh --online --version v0.1.17
#   离线安装:              ./install-sipmon.sh --offline
#   离线安装(自定义目录):  ./install-sipmon.sh --offline --pkg-dir /data/images
#   卸载:                  ./install-sipmon.sh --uninstall
#   查看状态:              ./install-sipmon.sh --status
#
# 可选参数:
#   --pkg-dir  DIR    离线二进制目录       (默认 /data/images)
#   --version  VER    指定版本号           (默认自动选择最新可用版本)
#   --proxy    URL    GitHub 下载代理前缀  (如 https://ghproxy.net/)
#
###############################################################################
set -euo pipefail

# ============================ 加载共享库 ============================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

# ============================ 默认参数 ============================
MODE=""
PKG_DIR="/data/images"
VERSION=""
INSTALL_BIN="/usr/local/bin/sipmon"
ASSET_SUFFIX=""

# ============================ 参数解析 ============================
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --online)    MODE="online";    shift ;;
            --offline)   MODE="offline";   shift ;;
            --uninstall) MODE="uninstall"; shift ;;
            --status)    MODE="status";    shift ;;
            --pkg-dir)   PKG_DIR="$2";     shift 2 ;;
            --version)   VERSION="$2";     shift 2 ;;
            --proxy)     SIPMON_GITHUB_PROXY="$2"; shift 2 ;;
            -h|--help)
                grep '^#' "$0" | head -28
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

    # 系统 / 架构检查 (status 模式除外)
    if [[ "$MODE" != "status" ]]; then
        if [[ "$(uname -s)" != "Linux" ]]; then
            log_error "此脚本仅支持 Linux 系统"
            exit 1
        fi

        # 架构检查 -> Release asset 后缀
        local arch
        arch=$(uname -m)
        case "$arch" in
            x86_64)        ASSET_SUFFIX="x86_64-unknown-linux-musl" ;;
            aarch64|arm64) ASSET_SUFFIX="aarch64-unknown-linux-musl" ;;
            *)
                log_error "不支持的 CPU 架构: $arch (仅支持 x86_64 / aarch64)"
                exit 1
                ;;
        esac
        log_info "CPU 架构: ${arch} (asset: ${ASSET_SUFFIX})"
    fi

    # 已安装检查 (安装模式下提示)
    if [[ "$MODE" == "online" || "$MODE" == "offline" ]]; then
        if command -v sipmon &>/dev/null || [[ -x "$INSTALL_BIN" ]]; then
            local cur_ver
            cur_ver=$(sipmon --version 2>/dev/null | head -1 || echo "未知")
            log_warn "sipmon 已安装 (${cur_ver})"
            read -rp "是否要覆盖安装？[y/N]: " ans
            [[ "$ans" =~ ^[Yy]$ ]] || { log_info "已取消安装"; exit 0; }
        fi
    fi
}

# ============================ 在线安装 ============================
install_online() {
    log_step "在线安装 sipmon"

    # curl 依赖检查
    if ! command -v curl &>/dev/null; then
        log_info "安装 curl ..."
        apt-get update -qq && apt-get install -y -qq curl ca-certificates
    fi

    [[ -n "$SIPMON_GITHUB_PROXY" ]] && log_info "GitHub 代理: ${SIPMON_GITHUB_PROXY}"

    local tmp_dir
    tmp_dir=$(mktemp -d)

    if ! sipmon_download "$ASSET_SUFFIX" "$tmp_dir" "$VERSION"; then
        rm -rf "$tmp_dir"
        log_error "下载失败，可尝试: --proxy <代理前缀> 或改用离线安装"
        exit 1
    fi

    install -m 0755 "$SIPMON_DOWNLOADED" "$INSTALL_BIN"
    log_ok "已安装: ${INSTALL_BIN} (版本 ${SIPMON_VERSION_RESOLVED})"
    rm -rf "$tmp_dir"
}

# ============================ 离线安装 ============================
install_offline() {
    log_step "离线安装 sipmon"

    # 查找离线二进制: 优先当前架构精确匹配
    local bin_file="" search_dir
    for search_dir in "$PKG_DIR" "/data/offline-bundle/images"; do
        [[ -d "$search_dir" ]] || continue
        bin_file=$(find "$search_dir" -maxdepth 1 -type f -name "sipmon-${ASSET_SUFFIX}" 2>/dev/null | head -1)
        [[ -n "$bin_file" ]] && break
    done

    # 精确匹配不到则放宽 (可能只有其他架构或手动改名)
    if [[ -z "$bin_file" ]]; then
        for search_dir in "$PKG_DIR" "/data/offline-bundle/images"; do
            [[ -d "$search_dir" ]] || continue
            bin_file=$(find "$search_dir" -maxdepth 1 -type f -name 'sipmon-*-linux-musl' 2>/dev/null | head -1)
            if [[ -n "$bin_file" ]]; then
                log_warn "未找到当前架构 (${ASSET_SUFFIX}) 的二进制，找到: $(basename "$bin_file")"
                read -rp "确认使用该文件？[y/N]: " ans
                [[ "$ans" =~ ^[Yy]$ ]] || { log_info "已取消安装"; exit 0; }
                break
            fi
        done
    fi

    if [[ -z "$bin_file" ]]; then
        log_error "未找到 sipmon 离线二进制 (查找目录: ${PKG_DIR}, /data/offline-bundle/images)"
        log_info "请先在联网机器执行 prepare-offline.sh，或手动下载 sipmon-${ASSET_SUFFIX} 放入上述目录"
        exit 1
    fi

    log_info "离线二进制: ${bin_file} ($(du -h "$bin_file" | awk '{print $1}'))"

    # SHA256 校验 (有 .sha256 则校验)
    sipmon_verify_file "$bin_file"

    install -m 0755 "$bin_file" "$INSTALL_BIN"
    log_ok "已安装: ${INSTALL_BIN}"
}

# ============================ 卸载 ============================
do_uninstall() {
    log_step "卸载 sipmon"

    if [[ ! -x "$INSTALL_BIN" ]] && ! command -v sipmon &>/dev/null; then
        log_info "sipmon 未安装，无需卸载"
        return 0
    fi

    rm -f "$INSTALL_BIN"
    hash -r 2>/dev/null || true
    log_ok "已删除: ${INSTALL_BIN}"
}

# ============================ 状态查看 ============================
do_status() {
    log_step "sipmon 状态"

    if command -v sipmon &>/dev/null || [[ -x "$INSTALL_BIN" ]]; then
        local bin
        bin=$(command -v sipmon 2>/dev/null || echo "$INSTALL_BIN")
        log_ok "已安装: ${bin}"
        sipmon --version 2>/dev/null | head -1 | sed 's/^/    版本: /' || true
        echo ""
        log_info "常用命令:"
        echo "    sipmon live -i any                            # 实时抓包监控 (TUI)"
        echo "    sipmon live -i any -f \"udp port 5060\"         # 带 BPF 过滤"
        echo "    sipmon record -i any -w cap.evlog --headless  # 后台录制"
        echo "    sipmon file -r capture.pcap                   # 离线 pcap 分析"
    else
        log_info "sipmon 未安装"
    fi
}

# ============================ 验证安装 ============================
verify_install() {
    log_step "验证安装"

    if [[ ! -x "$INSTALL_BIN" ]]; then
        log_error "安装失败: ${INSTALL_BIN} 不存在"
        exit 1
    fi

    if sipmon --version &>/dev/null 2>&1 || "$INSTALL_BIN" --help &>/dev/null 2>&1; then
        local ver
        ver=$("$INSTALL_BIN" --version 2>/dev/null | head -1 || echo "")
        log_ok "sipmon 可用 ${ver:+(${ver})}"
    else
        log_warn "二进制已安装但无法执行，请检查架构是否匹配"
    fi
}

# ============================ 主流程 ============================
main() {
    parse_args "$@"
    init_log "install-sipmon"
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
