#!/bin/bash
###############################################################################
# install-docker.sh
# Docker CE + Docker Compose 安装脚本（支持在线 / 离线双模式，国内网络优化）
#
# 适用系统: Ubuntu 22.04 / 24.04 (x86_64)
#
# 用法:
#   在线安装:  ./install-docker.sh --online
#   离线安装:  ./install-docker.sh --offline
#   离线安装(自定义包目录):  ./install-docker.sh --offline --pkg-dir /data/images
#
# 可选参数:
#   --data-root  DIR    Docker 数据目录        (默认 /data/dockerdata)
#   --pkg-dir    DIR    离线 .deb 包目录       (默认 /data/images, 无 .deb 时自动回退 /data/offline-bundle/packages)
#   --apt-mirror URL    Ubuntu apt 镜像源      (默认 https://repo.huaweicloud.com/ubuntu)
#   --skip-apt-mirror   跳过 apt 源更换
#
# 示例:
#   ./install-docker.sh --online --data-root /data/dockerdata
#   ./install-docker.sh --offline --pkg-dir /data/images
###############################################################################
set -euo pipefail

# ============================ 加载共享库 ============================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

# ============================ 默认参数 ============================
MODE=""
DATA_ROOT="/data/dockerdata"
PKG_DIR="/data/images"
APT_MIRROR="https://repo.huaweicloud.com/ubuntu"
SKIP_APT_MIRROR=false
DOCKER_CE_MIRROR="https://mirrors.aliyun.com/docker-ce/linux/ubuntu"

# Docker 镜像加速器（多个备用，按顺序尝试）
REGISTRY_MIRRORS=(
    "https://docker.mirrors.ustc.edu.cn"
    "https://docker.m.daocloud.io"
)

# ============================ 参数解析 ============================
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --online)        MODE="online";  shift ;;
            --offline)       MODE="offline"; shift ;;
            --data-root)     DATA_ROOT="$2"; shift 2 ;;
            --pkg-dir)       PKG_DIR="$2";   shift 2 ;;
            --apt-mirror)    APT_MIRROR="$2"; shift 2 ;;
            --skip-apt-mirror) SKIP_APT_MIRROR=true; shift ;;
            --docker-ce-mirror) DOCKER_CE_MIRROR="$2"; shift 2 ;;
            -h|--help)
                grep '^#' "$0" | head -30
                exit 0
                ;;
            *)
                log_error "未知参数: $1"
                exit 1
                ;;
        esac
    done

    if [[ -z "$MODE" ]]; then
        log_error "请指定安装模式: --online 或 --offline"
        echo "  用法: $0 --online    或    $0 --offline"
        exit 1
    fi
}

# ============================ 前置检查 ============================
preflight_check() {
    log_step "前置检查"

    # root 检查
    if [[ $EUID -ne 0 ]]; then
        log_error "请以 root 用户运行此脚本"
        exit 1
    fi
    log_info "root 用户检查通过"

    # 系统检查
    if ! grep -qiE 'ubuntu' /etc/os-release 2>/dev/null; then
        log_error "此脚本仅支持 Ubuntu 系统"
        exit 1
    fi

    source /etc/os-release
    log_info "操作系统: $PRETTY_NAME"

    # 架构检查
    local arch
    arch=$(uname -m)
    if [[ "$arch" != "x86_64" ]]; then
        log_error "此脚本仅支持 x86_64 架构，当前架构: $arch"
        exit 1
    fi
    log_info "CPU 架构: $arch"

    # 检查 Docker 是否已安装
    if command -v docker &>/dev/null; then
        local ver
        ver=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "未知")
        log_warn "Docker 已安装 (版本 $ver)"
        read -rp "是否要继续安装/覆盖？[y/N]: " confirm
        [[ "$confirm" =~ ^[Yy]$ ]] || { log_info "已取消安装"; exit 0; }
    fi
}

# ============================ 在线：配置 Ubuntu apt 源 ============================
setup_apt_mirror() {
    log_step "配置 Ubuntu apt 国内镜像源"

    if [[ "$SKIP_APT_MIRROR" == true ]]; then
        log_info "跳过 apt 源更换 (--skip-apt-mirror)"
        return 0
    fi

    source /etc/os-release
    local codename="$VERSION_CODENAME"

    # Ubuntu 24.04+ 使用 DEB822 格式 (ubuntu.sources)
    local sources_d="/etc/apt/sources.list.d"
    local old_sources="/etc/apt/sources.list"

    # 备份
    local backup_ts
    backup_ts=$(date +%Y%m%d%H%M%S)

    if [[ -f "${sources_d}/ubuntu.sources" ]]; then
        cp "${sources_d}/ubuntu.sources" "${sources_d}/ubuntu.sources.bak.${backup_ts}"
        log_info "已备份 ubuntu.sources -> ubuntu.sources.bak.${backup_ts}"

        # 写入华为云镜像源 (DEB822 格式)
        cat > "${sources_d}/ubuntu.sources" << EOF
Types: deb
URIs: ${APT_MIRROR}
Suites: ${codename} ${codename}-updates ${codename}-backports
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb
URIs: ${APT_MIRROR}
Suites: ${codename}-security
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
        log_info "Ubuntu apt 源已切换为: ${APT_MIRROR} (DEB822 格式)"

    elif [[ -f "$old_sources" ]]; then
        # 旧版格式 (Ubuntu 22.04)
        cp "$old_sources" "${old_sources}.bak.${backup_ts}"
        log_info "已备份 sources.list -> sources.list.bak.${backup_ts}"

        cat > "$old_sources" << EOF
deb ${APT_MIRROR} ${codename} main restricted universe multiverse
deb ${APT_MIRROR} ${codename}-security main restricted universe multiverse
deb ${APT_MIRROR} ${codename}-updates main restricted universe multiverse
deb ${APT_MIRROR} ${codename}-backports main restricted universe multiverse
EOF
        log_info "Ubuntu apt 源已切换为: ${APT_MIRROR}"
    else
        log_warn "未找到 apt 源配置文件，跳过"
        return 0
    fi

    log_info "执行 apt update ..."
    apt-get update -qq
}

# ============================ 在线：安装 Docker CE ============================
install_docker_online() {
    log_step "在线安装 Docker CE"

    source /etc/os-release
    local codename="$VERSION_CODENAME"

    # 1. 安装依赖
    log_info "安装基础依赖包 ..."
    apt-get install -y -qq \
        ca-certificates curl gnupg lsb-release \
        apt-transport-https software-properties-common

    # 2. 添加 Docker CE GPG 密钥（阿里云镜像）
    log_info "添加 Docker CE GPG 密钥 (阿里云镜像) ..."
    install -m 0755 -d /etc/apt/keyrings
    if curl -fsSL "${DOCKER_CE_MIRROR}/gpg" | gpg --dearmor -o /etc/apt/keyrings/docker.gpg 2>/dev/null; then
        chmod a+r /etc/apt/keyrings/docker.gpg
        log_info "GPG 密钥已安装"
    else
        log_error "GPG 密钥下载失败，请检查网络或手动配置"
        exit 1
    fi

    # 3. 添加 Docker CE apt 源（阿里云镜像）
    log_info "添加 Docker CE apt 源 (阿里云镜像) ..."
    echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.gpg] ${DOCKER_CE_MIRROR} ${codename} stable" \
        > /etc/apt/sources.list.d/docker.list
    log_info "Docker CE 源: ${DOCKER_CE_MIRROR} (${codename})"

    # 4. 安装 Docker
    log_info "apt update 并安装 Docker CE ..."
    apt-get update -qq
    apt-get install -y -qq \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin

    log_info "Docker CE 在线安装完成"
}

# ============================ 离线：安装 Docker CE ============================
install_docker_offline() {
    log_step "离线安装 Docker CE"

    # 自动回退到离线包 bundle 目录
    PKG_DIR=$(resolve_pkg_dir "$PKG_DIR")

    # 检查离线包目录
    if [[ ! -d "$PKG_DIR" ]]; then
        log_error "离线包目录不存在: $PKG_DIR"
        log_error "请通过 --pkg-dir 指定正确的离线包目录"
        exit 1
    fi
    log_info "离线包目录: $PKG_DIR"

    # 查找 .deb 包
    local deb_files
    deb_files=$(find "$PKG_DIR" -name '*.deb' -type f 2>/dev/null || true)
    if [[ -z "$deb_files" ]]; then
        log_error "在 $PKG_DIR 中未找到任何 .deb 包"
        exit 1
    fi

    log_info "找到以下 .deb 包:"
    find "$PKG_DIR" -name '*.deb' -type f | sort | while read -r f; do
        echo "    $(basename "$f")"
    done

    # 安装所有 .deb 包 (dpkg 会自动处理依赖顺序)
    log_info "安装 .deb 包 ..."
    if ! dpkg -i $(find "$PKG_DIR" -name '*.deb' -type f | sort) 2>/dev/null; then
        log_warn "dpkg 报告依赖问题，尝试 apt 修复 ..."
        apt-get install -f -y -qq
    fi
    log_info ".deb 包安装完成"

    # 如果有独立的 docker-compose 二进制文件，安装为兜底
    local compose_binary
    compose_binary=$(find "$PKG_DIR" -name 'docker-compose-linux-x86_64' -type f 2>/dev/null | head -1 || true)
    if [[ -n "$compose_binary" ]] && ! command -v docker-compose &>/dev/null; then
        log_info "安装 docker-compose 独立二进制 ..."
        cp "$compose_binary" /usr/bin/docker-compose
        chmod +x /usr/bin/docker-compose
        log_info "docker-compose 已安装到 /usr/bin/docker-compose"
    fi

    log_info "Docker CE 离线安装完成"
}

# ============================ 配置 daemon.json ============================
setup_daemon_json() {
    log_step "配置 Docker daemon.json"

    local daemon_json="/etc/docker/daemon.json"
    local backup_ts
    backup_ts=$(date +%Y%m%d%H%M%S)

    # 创建配置目录
    mkdir -p /etc/docker

    # 备份已有配置
    if [[ -f "$daemon_json" ]]; then
        cp "$daemon_json" "${daemon_json}.bak.${backup_ts}"
        log_info "已备份 daemon.json -> daemon.json.bak.${backup_ts}"
    fi

    # 构建 registry-mirrors JSON 数组
    local mirrors_json
    mirrors_json=$(printf ',"%s"' "${REGISTRY_MIRRORS[@]}")
    mirrors_json="[${mirrors_json:1}]"

    # 写入 daemon.json
    cat > "$daemon_json" << EOF
{
    "log-driver": "json-file",
    "log-opts": {
        "max-size": "50m",
        "max-file": "5",
        "compress": "true"
    },
    "data-root": "${DATA_ROOT}",
    "registry-mirrors": ${mirrors_json}
}
EOF

    log_info "daemon.json 已写入:"
    cat "$daemon_json" | sed 's/^/    /'

    # 创建数据目录
    mkdir -p "$DATA_ROOT"
    log_info "Docker 数据目录: $DATA_ROOT"
}

# ============================ 启动并验证 ============================
start_and_verify() {
    log_step "启动 Docker 服务并验证"

    # 启动 Docker
    log_info "启动 docker 服务 ..."
    systemctl daemon-reload
    systemctl enable docker.service containerd.service 2>/dev/null || true
    systemctl restart docker.service

    # 等待 Docker 就绪
    log_info "等待 Docker daemon 就绪 ..."
    local retries=0
    while ! docker info &>/dev/null; do
        retries=$((retries + 1))
        if [[ $retries -ge 15 ]]; then
            log_error "Docker daemon 启动超时"
            systemctl status docker.service --no-pager
            exit 1
        fi
        sleep 2
    done
    log_info "Docker daemon 已就绪"

    # 验证 Docker
    local docker_ver
    docker_ver=$(docker version --format '{{.Server.Version}}' 2>/dev/null)
    log_info "Docker 版本: $docker_ver"

    # 验证 Compose
    if docker compose version &>/dev/null; then
        local compose_ver
        compose_ver=$(docker compose version 2>/dev/null | awk '{print $NF}')
        log_info "Docker Compose (plugin) 版本: $compose_ver"
    elif command -v docker-compose &>/dev/null; then
        local compose_ver
        compose_ver=$(docker-compose version 2>/dev/null | awk '{print $NF}')
        log_info "Docker Compose (standalone) 版本: $compose_ver"
    else
        log_warn "Docker Compose 未找到"
    fi

    # 验证 data-root
    local actual_data_root
    actual_data_root=$(docker info 2>/dev/null | grep "Docker Root Dir" | awk '{print $NF}')
    log_info "Docker 数据目录: $actual_data_root"

    # 验证镜像加速器
    log_info "Docker 镜像加速器:"
    docker info 2>/dev/null | grep -A5 "Registry Mirrors" | sed 's/^/    /' || true

    # 拉取测试镜像（仅在线模式）
    if [[ "$MODE" == "online" ]]; then
        log_info "拉取测试镜像 hello-world ..."
        if docker pull hello-world &>/dev/null; then
            log_info "测试镜像拉取成功，镜像加速器工作正常"
            docker rmi hello-world &>/dev/null || true
        else
            log_warn "测试镜像拉取失败，请检查镜像加速器配置或网络"
        fi
    fi
}

# ============================ 主流程 ============================
main() {
    parse_args "$@"
    init_log "install-docker"
    preflight_check

    echo ""
    echo "========================================================"
    echo "  Docker 安装配置摘要"
    echo "========================================================"
    echo "  安装模式:     $MODE"
    echo "  Docker 数据目录: $DATA_ROOT"
    if [[ "$MODE" == "offline" ]]; then
        echo "  离线包目录:   $PKG_DIR"
    else
        echo "  Ubuntu apt 源: $APT_MIRROR"
        echo "  Docker CE 源:  $DOCKER_CE_MIRROR"
    fi
    echo "  镜像加速器:   ${REGISTRY_MIRRORS[*]}"
    echo "========================================================"
    echo ""

    # 磁盘空间预检
    check_disk_space "$(dirname "$DATA_ROOT")" 10

    # 部署前备份
    log_step "部署前备份"
    if [[ -f /etc/docker/daemon.json ]]; then
        backup_before_deploy "before-docker-install"
    else
        log_info "首次安装，无需备份 daemon.json"
    fi

    if [[ "$MODE" == "online" ]]; then
        setup_apt_mirror
        install_docker_online
    else
        install_docker_offline
    fi

    setup_daemon_json
    start_and_verify

    log_step "安装完成"
    log_info "Docker 安装配置全部完成！"
    echo ""
    log_info "常用命令:"
    echo "    docker ps              # 查看运行中容器"
    echo "    docker compose up -d   # 启动 compose 服务"
    echo "    docker info            # 查看 Docker 信息"
    echo ""
    show_log_path
}

main "$@"
