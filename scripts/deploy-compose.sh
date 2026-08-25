#!/bin/bash
###############################################################################
# deploy-compose.sh
# Docker Compose 服务部署脚本（支持在线拉取/离线加载镜像 + 启停管理）
#
# 用法:
#   部署服务:     ./deploy-compose.sh --up
#   离线部署:     ./deploy-compose.sh --up --offline --img-dir /data/offline-bundle/images
#   停止服务:     ./deploy-compose.sh --down
#   重启服务:     ./deploy-compose.sh --restart
#   查看状态:     ./deploy-compose.sh --status
#   查看日志:     ./deploy-compose.sh --logs [服务名]
#   拉取镜像:     ./deploy-compose.sh --pull
#   加载离线镜像: ./deploy-compose.sh --load --img-dir /data/offline-bundle/images
#   初始化模板:   ./deploy-compose.sh --init
#
###############################################################################
set -euo pipefail

# ============================ 加载共享库 ============================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

# ============================ 默认参数 ============================
ACTION=""
OFFLINE=false
IMG_DIR="/data/offline-bundle/images"
COMPOSE_FILE="/data/docker-compose.yml"
WORK_DIR="/data"
LOG_TAIL=50
SERVICE_NAME=""

# ============================ 参数解析 ============================
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --up)           ACTION="up";       shift ;;
            --down)         ACTION="down";     shift ;;
            --stop)         ACTION="stop";      shift ;;
            --restart)      ACTION="restart";  shift ;;
            --status)       ACTION="status";   shift ;;
            --logs)         ACTION="logs";     shift ;;
            --pull)         ACTION="pull";     shift ;;
            --load)         ACTION="load";     shift ;;
            --init)         ACTION="init";     shift ;;
            --extract-config) ACTION="extract"; shift ;;
            --offline)      OFFLINE=true;      shift ;;
            --img-dir)      IMG_DIR="$2";      shift 2 ;;
            --compose-file) COMPOSE_FILE="$2"; shift 2 ;;
            -h|--help)
                grep '^#' "$0" | head -20
                exit 0
                ;;
            *)
                log_error "未知参数: $1"
                exit 1
                ;;
        esac
    done

    if [[ -z "$ACTION" ]]; then
        log_error "请指定操作: --up / --down / --restart / --status / --logs / --pull / --load / --init"
        exit 1
    fi
}

# ============================ 获取 compose 命令 ============================
get_compose_cmd() {
    if docker compose version &>/dev/null 2>&1; then
        echo "docker compose"
    elif command -v docker-compose &>/dev/null 2>&1; then
        echo "docker-compose"
    else
        echo ""
    fi
}

# ============================ 前置检查 ============================
preflight_check() {
    if [[ $EUID -ne 0 ]]; then
        log_error "请以 root 用户运行此脚本"
        exit 1
    fi

    if ! command -v docker &>/dev/null; then
        log_error "Docker 未安装，请先执行 install-docker.sh"
        exit 1
    fi

    if ! docker info &>/dev/null 2>&1; then
        log_error "Docker 服务未运行"
        exit 1
    fi

    COMPOSE_CMD=$(get_compose_cmd)
    if [[ -z "$COMPOSE_CMD" ]]; then
        log_error "Docker Compose 未安装"
        exit 1
    fi
    log_info "Compose 命令: ${COMPOSE_CMD}"
}

# ============================ 检查 compose 文件 ============================
check_compose_file() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        log_error "docker-compose.yml 不存在: ${COMPOSE_FILE}"
        log_info "可通过 --init 从模板初始化"
        exit 1
    fi
    log_info "Compose 文件: ${COMPOSE_FILE}"

    # 检查配置目录
    local required_dirs=("config" "logs" "upload" "service")
    for d in "${required_dirs[@]}"; do
        if [[ ! -d "${WORK_DIR}/${d}" ]]; then
            log_warn "目录不存在: ${WORK_DIR}/${d}"
        fi
    done
}

# ============================ 初始化模板 ============================
do_init() {
    log_step "初始化 docker-compose.yml"

    local template="${SCRIPT_DIR}/../config/docker-compose.yml.template"
    if [[ ! -f "$template" ]]; then
        log_error "模板文件不存在: ${template}"
        exit 1
    fi

    if [[ -f "$COMPOSE_FILE" ]]; then
        log_info "docker-compose.yml 已存在，备份后覆盖 ..."
        backup_before_deploy "before-compose-init"
    fi

    cp "$template" "$COMPOSE_FILE"
    log_ok "已复制模板到: ${COMPOSE_FILE}"
    log_info "修改模板后重新执行: 菜单 -> 服务部署 -> Docker Compose 部署 -> 手动操作 -> 初始化模板"
}

# ============================ 解压配置文件 ============================
do_extract_config() {
    log_step "解压配置文件 config.zip"

    local config_zip="${WORK_DIR}/config/config.zip"

    # 也检查项目 config 目录下的
    if [[ ! -f "$config_zip" ]]; then
        config_zip="${SCRIPT_DIR}/../config/config.zip"
    fi

    if [[ ! -f "$config_zip" ]]; then
        log_error "config.zip 不存在"
        log_info "请将 config.zip 放到 /data/config/ 目录下"
        exit 1
    fi

    local zip_size
    zip_size=$(du -h "$config_zip" | awk '{print $1}')
    log_info "找到 config.zip: ${config_zip} (${zip_size})"

    # 检查 unzip 是否安装
    if ! command -v unzip &>/dev/null; then
        log_info "安装 unzip ..."
        apt-get install -y -qq unzip 2>/dev/null || true
    fi

    local target_dir="${WORK_DIR}/config"
    mkdir -p "$target_dir"

    # 备份现有 config 目录 (如果已有内容)
    if [[ -d "$target_dir" ]] && [[ -n "$(ls -A "$target_dir" 2>/dev/null)" ]]; then
        log_info "config 目录已有内容，先备份再覆盖 ..."
        backup_before_deploy "before-extract-config"
    fi

    # 解压到临时目录，检查结构
    local tmp_dir
    tmp_dir=$(mktemp -d)
    log_info "解压到临时目录 ..."
    unzip -q -o "$config_zip" -d "$tmp_dir" 2>/dev/null

    # 检查解压内容结构
    local top_items
    top_items=$(ls -1 "$tmp_dir" 2>/dev/null)

    # 判断是否有顶层 config/ 目录
    if [[ -d "${tmp_dir}/config" ]]; then
        log_info "检测到 zip 内有顶层 config/ 目录，提取其内容 ..."
        cp -rf "${tmp_dir}/config/"* "$target_dir/" 2>/dev/null || true
    else
        log_info "直接解压到 config/ ..."
        cp -rf "${tmp_dir}/"* "$target_dir/" 2>/dev/null || true
    fi

    # 清理 __MACOSX (macOS 打包产生的垃圾目录)
    rm -rf "${target_dir}/__MACOSX" 2>/dev/null || true

    # 清理临时目录
    rm -rf "$tmp_dir"

    # 验证结果
    local file_count
    file_count=$(find "$target_dir" -type f 2>/dev/null | wc -l | tr -d ' ')
    local dir_count
    dir_count=$(find "$target_dir" -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')

    log_ok "配置文件解压完成"
    log_info "目标目录: ${target_dir}"
    log_info "文件数量: ${file_count}"
    log_info "子目录:"
    ls -1 "$target_dir" | head -20 | sed 's/^/    /'
    if [[ $file_count -gt 20 ]]; then
        echo "    ..."
    fi
}

# ============================ 加载离线镜像 ============================
load_images() {
    log_step "加载离线 Docker 镜像"

    if [[ ! -d "$IMG_DIR" ]]; then
        log_error "镜像目录不存在: ${IMG_DIR}"
        exit 1
    fi

    local tar_files
    tar_files=$(find "$IMG_DIR" -name '*.tar' -type f 2>/dev/null || true)
    if [[ -z "$tar_files" ]]; then
        log_error "未找到镜像 tar 文件: ${IMG_DIR}"
        exit 1
    fi

    local total
    total=$(echo "$tar_files" | wc -l | tr -d ' ')
    log_info "共 ${total} 个镜像待加载"

    local current=0
    local failed=0
    for tar in $tar_files; do
        current=$((current + 1))
        local name
        name=$(basename "$tar")
        log_info "  [${current}/${total}] 加载: ${name}"
        if docker load -i "$tar" 2>/dev/null; then
            log_ok "           -> 成功"
        else
            log_warn "           -> 失败"
            failed=$((failed + 1))
        fi
    done

    log_info "镜像加载完成: 成功 $((total - failed))/${total}"
}

# ============================ 拉取镜像 ============================
pull_images() {
    log_step "拉取 Docker 镜像"

    cd "$WORK_DIR"
    $COMPOSE_CMD -f "$COMPOSE_FILE" pull 2>&1 | while read -r line; do
        echo "    $line"
    done
    log_ok "镜像拉取完成"
}

# ============================ 前置检查 ============================
check_prerequisites() {
    log_step "前置检查"
    local has_config=false has_compose=false has_conf_applied=false

    # 1. 检查 config 目录是否有内容
    if [[ -d /data/config ]] && [[ -n "$(ls -A /data/config 2>/dev/null)" ]]; then
        # 检查关键子目录是否存在
        local key_dirs=("cti" "fs" "goapi" "getcurl" "luahelper" "netcore" "autotask" "caddy")
        local found=0
        for d in "${key_dirs[@]}"; do
            [[ -d "/data/config/${d}" ]] && found=$((found + 1))
        done
        if [[ $found -ge 3 ]]; then
            has_config=true
        fi
    fi

    # 2. 检查 docker-compose.yml
    [[ -f "$COMPOSE_FILE" ]] && has_compose=true

    # 3. 检查配置是否已应用 (update-config.sh 完成后会生成标记文件)
    if [[ -f /data/config/.deploy-conf-applied ]]; then
        has_conf_applied=true
    fi

    # 汇报状态
    echo -e "  ${BOLD}部署前置检查:${NC}"
    print_line
    printf "    %-30s %s\n" "配置文件已解压" "$([[ $has_config == true ]] && echo -e "${GREEN}✓${NC}" || echo -e "${RED}✗${NC}")"
    printf "    %-30s %s\n" "docker-compose.yml" "$([[ $has_compose == true ]] && echo -e "${GREEN}✓${NC}" || echo -e "${RED}✗${NC}")"
    printf "    %-30s %s\n" "服务配置已修改" "$([[ $has_conf_applied == true ]] && echo -e "${GREEN}✓${NC}" || echo -e "${YELLOW}~ 未修改${NC}")"
    print_line
    echo ""

    # 处理缺失项
    if [[ "$has_config" != true ]]; then
        log_warn "配置文件未解压！请先执行: 菜单 -> 服务部署 -> Docker Compose 部署 -> 手动操作 -> 解压配置文件"
        if [[ -f /data/config/config.zip ]] || [[ -f "${SCRIPT_DIR}/../config/config.zip" ]]; then
            if confirm "是否现在解压 config.zip？"; then
                do_extract_config
                has_config=true
            fi
        else
            log_error "未找到 config.zip，请先将配置包放到 /data/config/ 目录"
            exit 1
        fi
    fi

    if [[ "$has_compose" != true ]]; then
        log_warn "docker-compose.yml 不存在"
        local template="${SCRIPT_DIR}/../config/docker-compose.yml.template"
        if [[ -f "$template" ]]; then
            if confirm "是否从模板生成 docker-compose.yml？"; then
                do_init
                has_compose=true
            fi
        else
            log_error "docker-compose.yml 和模板均不存在"
            exit 1
        fi
    fi

    if [[ "$has_conf_applied" != true ]]; then
        local conf_file="${SCRIPT_DIR}/../config/deploy.conf"
        if [[ -f "$conf_file" ]]; then
            log_warn "服务配置尚未通过 deploy.conf 修改"
            if confirm "是否现在应用 deploy.conf 配置？"; then
                bash "${SCRIPT_DIR}/update-config.sh" --force
                echo ""
            fi
        else
            log_warn "deploy.conf 不存在，跳过配置修改 (请后续手动修改各服务配置)"
        fi
    fi
}

# ============================ 部署服务 ============================
do_up() {
    log_step "部署/启动服务"

    # 前置检查: 配置解压 + 配置修改
    check_prerequisites

    check_compose_file

    # 部署前备份
    backup_before_deploy "before-compose-up"

    # 磁盘检查
    check_disk_space /data 10

    # 镜像处理
    if [[ "$OFFLINE" == true ]]; then
        load_images
    else
        # 检查是否需要拉取镜像
        local missing_images
        missing_images=$($COMPOSE_CMD -f "$COMPOSE_FILE" config --images 2>/dev/null | while read -r img; do
            if ! docker image inspect "$img" &>/dev/null 2>&1; then
                echo "$img"
            fi
        done || true)

        if [[ -n "$missing_images" ]]; then
            local count
            count=$(echo "$missing_images" | wc -l | tr -d ' ')
            log_info "有 ${count} 个镜像未拉取，开始拉取 ..."
            pull_images
        else
            log_info "所有镜像已存在，跳过拉取"
        fi
    fi

    # 按依赖顺序启动服务
    log_info "按顺序启动服务 ..."
    cd "$WORK_DIR"

    # 从 compose 文件获取所有服务名
    local all_services
    all_services=$($COMPOSE_CMD -f "$COMPOSE_FILE" config --services 2>/dev/null | sort || true)
    if [[ -z "$all_services" ]]; then
        log_error "无法从 compose 文件读取服务列表"
        exit 1
    fi
    log_info "compose 服务: $(echo "$all_services" | tr '\n' ' ')"

    # 第一梯队: 按优先级顺序启动 (仅启动 compose 文件中存在的)
    local tier1=("redis" "getcurl" "fs" "cti" "cc_core")
    local started=""

    local i=0
    for svc in "${tier1[@]}"; do
        if echo "$all_services" | grep -qx "$svc"; then
            i=$((i + 1))
            log_info "  [${i}] 启动 ${svc} ..."
            $COMPOSE_CMD -f "$COMPOSE_FILE" up -d --no-color "$svc" 2>&1 || true
            log_info "  ${svc} 已启动"
            sleep 3
            started="${started} ${svc}"
        fi
    done

    # 第二梯队: 启动剩余服务
    local tier2=""
    for svc in $all_services; do
        if ! echo "$started" | grep -qw "$svc"; then
            tier2="${tier2} ${svc}"
        fi
    done

    if [[ -n "$tier2" ]]; then
        log_info "  启动其他服务:${tier2}"
        $COMPOSE_CMD -f "$COMPOSE_FILE" up -d --no-color $tier2 2>&1 || true
        log_info "  其他服务已启动"
    fi

    log_ok "全部服务已启动"

    # 等待容器就绪
    log_info "等待容器启动 ..."
    sleep 5

    # 显示状态
    echo ""
    log_info "容器状态:"
    $COMPOSE_CMD -f "$COMPOSE_FILE" ps 2>/dev/null | sed 's/^/    /' || true

    # 健康检查
    echo ""
    check_container_health 60 "$COMPOSE_FILE" || true
}

# ============================ 停止服务 ============================
do_down() {
    log_step "停止服务"

    check_compose_file

    log_info "停止 docker compose 服务 ..."
    cd "$WORK_DIR"
    $COMPOSE_CMD -f "$COMPOSE_FILE" down 2>&1 | while read -r line; do
        echo "    $line"
    done

    log_ok "服务已停止"
}

# ============================ 停止容器 (不删除) ============================
do_stop() {
    log_step "停止容器 (不删除)"

    check_compose_file

    log_info "停止 docker compose 容器 ..."
    cd "$WORK_DIR"
    $COMPOSE_CMD -f "$COMPOSE_FILE" stop 2>&1 | while read -r line; do
        echo "    $line"
    done

    log_ok "容器已停止 (未删除，可用 start 恢复)"
}

# ============================ 重启服务 ============================
do_restart() {
    log_step "重启服务"

    check_compose_file

    cd "$WORK_DIR"

    # 从 compose 文件获取所有服务名
    local all_services
    all_services=$($COMPOSE_CMD -f "$COMPOSE_FILE" config --services 2>/dev/null | sort || true)
    if [[ -z "$all_services" ]]; then
        log_error "无法从 compose 文件读取服务列表"
        exit 1
    fi

    # 第一梯队: 按优先级顺序重启
    local tier1=("redis" "getcurl" "fs" "cti" "cc_core")
    local restarted=""

    local i=0
    for svc in "${tier1[@]}"; do
        if echo "$all_services" | grep -qx "$svc"; then
            i=$((i + 1))
            log_info "  [${i}] 重启 ${svc} ..."
            $COMPOSE_CMD -f "$COMPOSE_FILE" restart --no-color "$svc" 2>&1 || true
            log_info "  ${svc} 已重启"
            sleep 3
            restarted="${restarted} ${svc}"
        fi
    done

    # 第二梯队: 重启剩余服务
    local tier2=""
    for svc in $all_services; do
        if ! echo "$restarted" | grep -qw "$svc"; then
            tier2="${tier2} ${svc}"
        fi
    done

    if [[ -n "$tier2" ]]; then
        log_info "  重启其他服务:${tier2}"
        $COMPOSE_CMD -f "$COMPOSE_FILE" restart --no-color $tier2 2>&1 || true
        log_info "  其他服务已重启"
    fi

    log_ok "服务已重启"

    echo ""
    log_info "容器状态:"
    $COMPOSE_CMD -f "$COMPOSE_FILE" ps 2>/dev/null | sed 's/^/    /' || true
}

# ============================ 查看状态 ============================
do_status() {
    log_step "服务状态"

    check_compose_file

    cd "$WORK_DIR"
    $COMPOSE_CMD -f "$COMPOSE_FILE" ps 2>/dev/null | sed 's/^/    /' || true
}

# ============================ 查看日志 ============================
do_logs() {
    log_step "服务日志"

    check_compose_file

    cd "$WORK_DIR"
    if [[ -n "$SERVICE_NAME" ]]; then
        $COMPOSE_CMD -f "$COMPOSE_FILE" logs --tail "$LOG_TAIL" "$SERVICE_NAME" 2>/dev/null || true
    else
        $COMPOSE_CMD -f "$COMPOSE_FILE" logs --tail "$LOG_TAIL" 2>/dev/null || true
    fi
}

# ============================ 主流程 ============================
main() {
    parse_args "$@"
    init_log "deploy-compose"

    echo ""
    echo "========================================================"
    echo "  Docker Compose 服务管理"
    echo "========================================================"
    echo "  操作:       $ACTION"
    echo "  Compose:    $COMPOSE_FILE"
    echo "  工作目录:   $WORK_DIR"
    [[ "$ACTION" == "up" ]] && echo "  离线模式:   $([[ $OFFLINE == true ]] && echo '是' || echo '否')"
    echo "========================================================"
    echo ""

    case "$ACTION" in
        init)
            do_init
            ;;
        extract)
            do_extract_config
            ;;
        load)
            preflight_check
            load_images
            ;;
        pull)
            preflight_check
            check_compose_file
            pull_images
            ;;
        up)
            preflight_check
            do_up
            ;;
        down)
            preflight_check
            do_down
            ;;
        stop)
            preflight_check
            do_stop
            ;;
        restart)
            preflight_check
            do_restart
            ;;
        status)
            preflight_check
            do_status
            ;;
        logs)
            preflight_check
            do_logs
            ;;
        *)
            log_error "未知操作: $ACTION"
            exit 1
            ;;
    esac

    show_log_path
}

main "$@"
