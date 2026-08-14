#!/bin/bash
###############################################################################
# uninstall-docker.sh
# Docker CE 卸载脚本（支持保留/清理数据）
#
# 用法:
#   卸载但保留数据:   ./uninstall-docker.sh
#   卸载并清理数据:   ./uninstall-docker.sh --purge
#   卸载并清理全部:   ./uninstall-docker.sh --purge --clean-images
#
###############################################################################
set -euo pipefail

# ============================ 加载共享库 ============================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

# ============================ 参数 ============================
PURGE=false
CLEAN_IMAGES=false
DATA_ROOT="/data/dockerdata"

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --purge)         PURGE=true;         shift ;;
            --clean-images)  CLEAN_IMAGES=true;  shift ;;
            --data-root)     DATA_ROOT="$2";     shift 2 ;;
            -h|--help)
                grep '^#' "$0" | head -15
                exit 0
                ;;
            *) log_error "未知参数: $1"; exit 1 ;;
        esac
    done
}

# ============================ 停止容器和服务 ============================
stop_services() {
    log_step "停止 Docker 容器和服务"

    if ! command -v docker &>/dev/null; then
        log_info "Docker 未安装，无需停止"
        return 0
    fi

    # 停止所有运行中的容器
    local containers
    containers=$(docker ps -q 2>/dev/null || true)
    if [[ -n "$containers" ]]; then
        local count
        count=$(echo "$containers" | wc -l | tr -d ' ')
        log_info "停止 ${count} 个运行中的容器 ..."
        docker stop $containers 2>/dev/null || true
    else
        log_info "没有运行中的容器"
    fi

    # 停止 Docker 服务
    log_info "停止 docker.service ..."
    systemctl stop docker.service 2>/dev/null || true
    systemctl stop docker.socket 2>/dev/null || true
    systemctl stop containerd.service 2>/dev/null || true

    log_info "Docker 服务已停止"
}

# ============================ 卸载软件包 ============================
remove_packages() {
    log_step "卸载 Docker 软件包"

    local pkgs
    pkgs=$(dpkg -l 2>/dev/null | grep -iE 'docker-ce|docker-buildx|docker-compose|containerd\.io|docker-ce-rootless|docker-ce-cli' | awk '{print $2}' || true)

    if [[ -z "$pkgs" ]]; then
        log_info "未找到 Docker 相关软件包"
        return 0
    fi

    log_info "将卸载以下包:"
    echo "$pkgs" | sed 's/^/    /'

    if [[ "$PURGE" == true ]]; then
        log_info "执行 apt purge (含配置文件) ..."
        apt-get purge -y -qq $pkgs 2>/dev/null || dpkg -r $pkgs 2>/dev/null || true
    else
        log_info "执行 apt remove ..."
        apt-get remove -y -qq $pkgs 2>/dev/null || dpkg -r $pkgs 2>/dev/null || true
    fi

    # 清理残留依赖
    apt-get autoremove -y -qq 2>/dev/null || true

    log_info "软件包卸载完成"
}

# ============================ 清理文件 ============================
cleanup_files() {
    log_step "清理 Docker 相关文件"

    # 删除独立 docker-compose 二进制
    if [[ -f /usr/bin/docker-compose ]]; then
        rm -f /usr/bin/docker-compose
        log_info "已删除 /usr/bin/docker-compose"
    fi

    # 删除 Docker apt 源
    if [[ -f /etc/apt/sources.list.d/docker.list ]]; then
        rm -f /etc/apt/sources.list.d/docker.list
        log_info "已删除 /etc/apt/sources.list.d/docker.list"
    fi

    # 删除 GPG 密钥
    if [[ -f /etc/apt/keyrings/docker.gpg ]]; then
        rm -f /etc/apt/keyrings/docker.gpg
        log_info "已删除 /etc/apt/keyrings/docker.gpg"
    fi

    # 删除 daemon.json
    if [[ -f /etc/docker/daemon.json ]]; then
        rm -f /etc/docker/daemon.json
        log_info "已删除 /etc/docker/daemon.json"
    fi

    # 清理 systemd 残留
    systemctl daemon-reload 2>/dev/null || true

    # 清理数据目录
    if [[ "$PURGE" == true ]]; then
        log_warn "正在清理数据目录: $DATA_ROOT"
        if [[ "$CLEAN_IMAGES" == true ]]; then
            # 彻底删除整个数据目录
            if [[ -d "$DATA_ROOT" ]]; then
                rm -rf "$DATA_ROOT"
                log_info "已删除数据目录: $DATA_ROOT"
            fi
        else
            # 仅删除镜像和容器，保留 volumes
            if [[ -d "${DATA_ROOT}/image" ]]; then
                rm -rf "${DATA_ROOT}/image"
                log_info "已删除镜像数据: ${DATA_ROOT}/image"
            fi
            if [[ -d "${DATA_ROOT}/containers" ]]; then
                rm -rf "${DATA_ROOT}/containers"
                log_info "已删除容器数据: ${DATA_ROOT}/containers"
            fi
            log_info "已保留 volumes 数据: ${DATA_ROOT}/volumes"
        fi

        # 清理网络接口
        if ip link show docker0 &>/dev/null 2>&1; then
            ip link delete docker0 2>/dev/null || true
            log_info "已删除 docker0 网桥"
        fi
    else
        log_info "保留数据目录 (--purge 可清理): $DATA_ROOT"
    fi
}

# ============================ 验证 ============================
verify() {
    log_step "验证卸载结果"

    if command -v docker &>/dev/null; then
        log_warn "docker 命令仍存在，可能需要手动清理"
    else
        log_info "docker 命令已移除 ✓"
    fi

    if command -v docker-compose &>/dev/null; then
        log_warn "docker-compose 命令仍存在"
    else
        log_info "docker-compose 命令已移除 ✓"
    fi

    log_info "卸载流程完成"
}

# ============================ 主流程 ============================
main() {
    parse_args "$@"
    init_log "uninstall-docker"

    echo ""
    echo "========================================================"
    echo "  Docker 卸载配置摘要"
    echo "========================================================"
    echo "  清理配置文件:     $PURGE"
    echo "  清理镜像数据:     $CLEAN_IMAGES"
    echo "  数据目录:         $DATA_ROOT"
    echo "========================================================"
    echo ""

    if [[ "$PURGE" == true ]]; then
        log_warn "⚠️  警告: 将清理 Docker 数据，此操作不可逆！"
        read -rp "确认继续？输入 yes 继续: " confirm_text
        [[ "$confirm_text" == "yes" ]] || { log_info "已取消"; exit 0; }
    fi

    stop_services
    remove_packages
    cleanup_files
    verify

    log_step "卸载完成"
    show_log_path
}

main "$@"
