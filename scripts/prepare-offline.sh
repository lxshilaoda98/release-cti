#!/bin/bash
###############################################################################
# prepare-offline.sh
# 离线部署包准备脚本 — 在有网络的机器上预下载全部依赖
#
# 生成内容:
#   1. Docker CE 全套 .deb 包 (含依赖)
#   2. Keepalived .deb 包 (含依赖)
#   3. sngrep .deb 包 (含依赖)
#   4. Docker 镜像 (docker save 导出为 tar)
#   5. sipmon 抓包工具静态二进制 (GitHub Releases)
#   6. daemon.json 模板
#
# 用法:
#   ./prepare-offline.sh                          # 默认输出到 /data/offline-bundle
#   ./prepare-offline.sh --output /tmp/bundle     # 自定义输出目录
#   ./prepare-offline.sh --skip-images            # 跳过镜像导出
#   ./prepare-offline.sh --skip-packages          # 跳过包下载
#
###############################################################################
set -euo pipefail

# ============================ 加载共享库 ============================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

# ============================ 参数 ============================
OUTPUT_DIR="/data/offline-bundle"
SKIP_IMAGES=false
SKIP_PACKAGES=false
COMPOSE_FILE="/data/docker-compose.yml"
DOCKER_CE_MIRROR="https://mirrors.aliyun.com/docker-ce/linux/ubuntu"

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --output)        OUTPUT_DIR="$2";    shift 2 ;;
            --skip-images)   SKIP_IMAGES=true;   shift ;;
            --skip-packages) SKIP_PACKAGES=true; shift ;;
            --compose-file)  COMPOSE_FILE="$2";  shift 2 ;;
            -h|--help)
                grep '^#' "$0" | head -20
                exit 0
                ;;
            *) log_error "未知参数: $1"; exit 1 ;;
        esac
    done
}

# ============================ 下载 Docker CE 包 ============================
download_docker_packages() {
    log_step "下载 Docker CE .deb 包"

    local pkg_dir="${OUTPUT_DIR}/packages"
    mkdir -p "$pkg_dir"

    source /etc/os-release
    local codename="$VERSION_CODENAME"

    # 确保 Docker CE apt 源已配置 (阿里云镜像)
    log_info "检查 Docker CE apt 源 ..."
    if ! grep -q "docker-ce" /etc/apt/sources.list.d/docker.list 2>/dev/null; then
        log_info "配置 Docker CE apt 源 (阿里云镜像) ..."
        apt-get install -y -qq ca-certificates curl gnupg
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL "${DOCKER_CE_MIRROR}/gpg" | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        chmod a+r /etc/apt/keyrings/docker.gpg
        echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.gpg] ${DOCKER_CE_MIRROR} ${codename} stable" \
            > /etc/apt/sources.list.d/docker.list
        log_info "Docker CE 源已配置"
    fi

    apt-get update -qq

    # 下载 Docker CE 相关包及依赖
    local docker_pkgs="docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"
    log_info "下载 Docker CE 包及依赖: $docker_pkgs"
    cd "$pkg_dir"
    apt-get download $(apt-cache depends --recurse --no-recommends --no-suggests \
        --no-conflicts --no-breaks --no-replaces --no-enhances \
        $docker_pkgs 2>/dev/null | grep "^\w" | sort -u) 2>/dev/null || true

    local deb_count
    deb_count=$(find "$pkg_dir" -name '*.deb' | wc -l | tr -d ' ')
    log_info "Docker CE 包下载完成: ${deb_count} 个 .deb 文件"
}

# ============================ 下载 Keepalived 包 ============================
download_keepalived_packages() {
    log_step "下载 Keepalived .deb 包"

    local pkg_dir="${OUTPUT_DIR}/packages"
    mkdir -p "$pkg_dir"

    log_info "下载 keepalived 及依赖 ..."
    cd "$pkg_dir"
    apt-get download $(apt-cache depends --recurse --no-recommends --no-suggests \
        --no-conflicts --no-breaks --no-replaces --no-enhances \
        keepalived 2>/dev/null | grep "^\w" | sort -u) 2>/dev/null || true

    local ka_count
    ka_count=$(find "$pkg_dir" -name '*keepalived*.deb' | wc -l | tr -d ' ')
    log_info "Keepalived 包下载完成: ${ka_count} 个 .deb 文件"
}

# ============================ 导出 Docker 镜像 ============================
export_docker_images() {
    log_step "导出 Docker 镜像"

    if ! command -v docker &>/dev/null; then
        log_warn "Docker 未安装，跳过镜像导出"
        return 0
    fi

    local img_dir="${OUTPUT_DIR}/images"
    mkdir -p "$img_dir"

    # 从 compose 文件提取镜像列表
    local images=""
    if [[ -f "$COMPOSE_FILE" ]]; then
        log_info "从 ${COMPOSE_FILE} 提取镜像列表 ..."
        images=$(docker compose -f "$COMPOSE_FILE" config --images 2>/dev/null || \
                 docker-compose -f "$COMPOSE_FILE" config --images 2>/dev/null || true)
    fi

    # 如果 compose 文件没有镜像，使用当前已加载的镜像
    if [[ -z "$images" ]]; then
        log_info "compose 文件无镜像或不存在，导出当前所有镜像 ..."
        images=$(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -v '<none>')
    fi

    if [[ -z "$images" ]]; then
        log_warn "没有可导出的镜像"
        return 0
    fi

    local total
    total=$(echo "$images" | wc -l | tr -d ' ')
    log_info "共 ${total} 个镜像待导出"

    local current=0
    local failed=0
    for img in $images; do
        current=$((current + 1))
        local filename
        filename=$(echo "$img" | tr '/:' '__')
        local tar_file="${img_dir}/${filename}.tar"

        # 如果镜像已存在则跳过
        if [[ -f "$tar_file" ]]; then
            log_info "  [${current}/${total}] 跳过 (已存在): ${img}"
            continue
        fi

        log_info "  [${current}/${total}] 导出: ${img}"
        if docker save -o "$tar_file" "$img" 2>/dev/null; then
            local size
            size=$(du -h "$tar_file" | awk '{print $1}')
            log_info "           -> ${tar_file} (${size})"
        else
            log_warn "           -> 导出失败"
            failed=$((failed + 1))
            rm -f "$tar_file" 2>/dev/null || true
        fi
    done

    log_info "镜像导出完成: 成功 $((total - failed))/${total}"
}

# ============================ 下载 sngrep 包 ============================
download_sngrep_packages() {
    log_step "下载 sngrep .deb 包"

    # 独立子目录: sngrep 依赖树完整放在一起, 离线安装时整目录 dpkg
    local pkg_dir="${OUTPUT_DIR}/packages/sngrep"
    mkdir -p "$pkg_dir"

    log_info "下载 sngrep 及依赖 ..."
    cd "$pkg_dir"
    apt-get download $(apt-cache depends --recurse --no-recommends --no-suggests \
        --no-conflicts --no-breaks --no-replaces --no-enhances \
        sngrep 2>/dev/null | grep "^\w" | sort -u) 2>/dev/null || true

    local sg_count
    sg_count=$(find "$pkg_dir" -name '*.deb' | wc -l | tr -d ' ')
    log_info "sngrep 包下载完成: ${sg_count} 个 .deb 文件 (含全部依赖)"
}

# ============================ 下载 sipmon 二进制 ============================
download_sipmon() {
    log_step "下载 sipmon 抓包工具"

    local arch suffix
    arch=$(uname -m)
    case "$arch" in
        x86_64)        suffix="x86_64-unknown-linux-musl" ;;
        aarch64|arm64) suffix="aarch64-unknown-linux-musl" ;;
        *)
            log_warn "不支持的架构: $arch，跳过 sipmon 下载"
            return 0
            ;;
    esac

    # 放到 images/ 子目录, 与 deploy-compose.sh 离线镜像目录一致
    local bin_dir="${OUTPUT_DIR}/images"
    mkdir -p "$bin_dir"

    # 已存在则跳过
    local existing
    existing=$(find "$bin_dir" -maxdepth 1 -type f -name "sipmon-${suffix}" 2>/dev/null | head -1)
    if [[ -n "$existing" ]]; then
        log_info "sipmon 二进制已存在，跳过: $(basename "$existing")"
        return 0
    fi

    if sipmon_download "$suffix" "$bin_dir" ""; then
        log_info "sipmon 下载完成: $(basename "$SIPMON_DOWNLOADED") (${SIPMON_VERSION_RESOLVED})"
    else
        log_warn "sipmon 下载失败，可稍后重试或在目标机在线安装"
    fi
}

# ============================ 生成 daemon.json 模板 ============================
copy_daemon_template() {
    log_step "生成 daemon.json 模板"

    local daemon_file="${OUTPUT_DIR}/daemon.json"

    if [[ -f /etc/docker/daemon.json ]]; then
        cp /etc/docker/daemon.json "$daemon_file"
        log_info "已从当前系统复制 daemon.json"
    else
        cat > "$daemon_file" << 'EOF'
{
    "log-driver": "json-file",
    "log-opts": {
        "max-size": "50m",
        "max-file": "5",
        "compress": "true"
    },
    "data-root": "/data/dockerdata",
    "registry-mirrors": [
        "https://docker.mirrors.ustc.edu.cn",
        "https://docker.m.daocloud.io"
    ]
}
EOF
        log_info "已生成默认 daemon.json 模板"
    fi
}

# ============================ 生成说明文件 ============================
generate_readme() {
    log_step "生成离线包说明文件"

    local readme="${OUTPUT_DIR}/README.txt"
    local pkg_count=0
    local img_count=0
    local sipmon_file=""
    local total_size=""

    [[ -d "${OUTPUT_DIR}/packages" ]] && pkg_count=$(find "${OUTPUT_DIR}/packages" -name '*.deb' | wc -l | tr -d ' ')
    [[ -d "${OUTPUT_DIR}/images" ]] && img_count=$(find "${OUTPUT_DIR}/images" -name '*.tar' | wc -l | tr -d ' ')
    sipmon_file=$(find "${OUTPUT_DIR}/images" -maxdepth 1 -type f -name 'sipmon-*-linux-musl' 2>/dev/null | head -1 || true)
    sipmon_file="${sipmon_file:+$(basename "$sipmon_file")}"
    total_size=$(du -sh "${OUTPUT_DIR}" 2>/dev/null | awk '{print $1}')

    cat > "$readme" << EOF
============================================================
  Release CTI 离线部署包
  生成时间: $(date '+%Y-%m-%d %H:%M:%S')
  生成主机: $(hostname)
============================================================

目录结构:
  packages/       ${pkg_count} 个 .deb 安装包
  images/         ${img_count} 个 Docker 镜像 tar 包${sipmon_file:+
                  + sipmon 抓包工具: ${sipmon_file}}
  daemon.json     Docker 配置模板
  README.txt      本文件

总大小: ${total_size}

使用方法:
  1. 将本目录拷贝到目标服务器的 /data/ 下
  2. 在目标服务器执行: ./deploy.sh
  3. 选择: 环境安装 -> Docker 安装 -> 离线安装
  4. 离线包目录指向: /data/offline-bundle/packages

加载镜像:
  for f in /data/offline-bundle/images/*.tar; do
      docker load -i "\$f"
  done

安装 sipmon 抓包工具:
  ./scripts/install-sipmon.sh --offline --pkg-dir /data/offline-bundle/images
  (或在 deploy.sh 菜单选择: 运维工具 -> SIP 抓包工具 -> 离线安装)

安装 sngrep 抓包工具:
  ./scripts/install-sngrep.sh --offline --pkg-dir /data/offline-bundle/packages/sngrep

============================================================
EOF
    log_info "说明文件已生成: ${readme}"
}

# ============================ 主流程 ============================
main() {
    parse_args "$@"
    init_log "prepare-offline"

    echo ""
    echo "========================================================"
    echo "  离线包准备"
    echo "========================================================"
    echo "  输出目录:     $OUTPUT_DIR"
    echo "  Compose 文件: $COMPOSE_FILE"
    echo "  下载包:       $([[ $SKIP_PACKAGES == false ]] && echo '是' || echo '跳过')"
    echo "  导出镜像:     $([[ $SKIP_IMAGES == false ]] && echo '是' || echo '跳过')"
    echo "========================================================"
    echo ""

    # 磁盘空间检查
    check_disk_space "$(dirname "$OUTPUT_DIR")" 5

    mkdir -p "$OUTPUT_DIR"

    if [[ "$SKIP_PACKAGES" == false ]]; then
        download_docker_packages
        download_keepalived_packages
        download_sngrep_packages
        download_sipmon
    else
        log_info "跳过包下载 (--skip-packages)"
    fi

    if [[ "$SKIP_IMAGES" == false ]]; then
        export_docker_images
    else
        log_info "跳过镜像导出 (--skip-images)"
    fi

    copy_daemon_template
    generate_readme

    log_step "离线包准备完成"
    log_info "输出目录: $OUTPUT_DIR"
    local total_size
    total_size=$(du -sh "$OUTPUT_DIR" 2>/dev/null | awk '{print $1}')
    log_info "总大小: ${total_size}"
    echo ""
    log_info "将 ${OUTPUT_DIR} 拷贝到目标服务器后，使用 deploy.sh 离线安装即可"
    show_log_path
}

main "$@"
