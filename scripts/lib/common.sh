#!/bin/bash
###############################################################################
# common.sh — 部署脚本共享库
#
# 提供: 颜色输出 / 日志记录 / 磁盘预检 / 部署前备份 / 容器健康检查 / SSH 远程辅助
#
# 用法: 在其他脚本中 source 此文件
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
#
###############################################################################
# 防止重复 source
[[ -n "${_COMMON_SH_LOADED:-}" ]] && return 0 2>/dev/null || true
_COMMON_SH_LOADED=1

# ============================ 项目路径 ============================
COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${COMMON_DIR}/../.." && pwd)"
SCRIPTS_DIR="${PROJECT_DIR}/scripts"
CONFIG_DIR="${PROJECT_DIR}/config"

# ============================ 颜色定义 ============================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# ============================ 日志系统 ============================
LOG_DIR="/data/logs/deploy"
LOG_FILE=""
LOG_ENABLED=false
_LOG_TS=""

# 绘制分隔线
print_line() {
    echo -e "${DIM}─────────────────────────────────────────────────────────${NC}"
}

# 初始化日志文件
# 参数: $1 = 脚本名 (如 install-docker, uninstall-docker)
init_log() {
    local script_name="${1:-deploy}"
    if ! mkdir -p "$LOG_DIR" 2>/dev/null; then
        LOG_ENABLED=false
        return 0
    fi
    if [[ -z "$_LOG_TS" ]]; then
        _LOG_TS=$(date +%Y%m%d-%H%M%S)
    fi
    LOG_FILE="${LOG_DIR}/${_LOG_TS}-${script_name}.log"
    LOG_ENABLED=true
}

# 内部: 写入日志文件 (去除颜色码)
_log_write() {
    if [[ "$LOG_ENABLED" == true && -n "$LOG_FILE" ]]; then
        local clean_msg
        clean_msg=$(echo -e "$*" | sed 's/\x1b\[[0-9;]*m//g')
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ${clean_msg}" >> "$LOG_FILE"
    fi
}

log_info()  { echo -e "${GREEN}[INFO]${NC}  $*"; _log_write "[INFO]  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; _log_write "[WARN]  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; _log_write "[ERROR] $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*"; _log_write "[OK]    $*"; }
log_step()  { echo -e "\n${BLUE}========== $* ==========${NC}"; _log_write "========== $* =========="; }

# 打印日志文件路径
show_log_path() {
    if [[ "$LOG_ENABLED" == true && -n "$LOG_FILE" ]]; then
        echo ""
        log_info "日志文件: ${LOG_FILE}"
    fi
}

# ============================ 磁盘空间预检 ============================
# 参数: $1 = 检查路径 (默认 /data)
#       $2 = 最低可用空间 GB (默认 20)
# 返回: 0=通过 1=不足
check_disk_space() {
    local path="${1:-/data}"
    local threshold="${2:-20}"

    if [[ ! -d "$path" ]]; then
        log_warn "路径不存在: $path，跳过磁盘检查"
        return 0
    fi

    local available_kb available_gb
    available_kb=$(df -k "$path" 2>/dev/null | tail -1 | awk '{print $4}')
    if [[ -z "$available_kb" ]]; then
        log_warn "无法获取磁盘信息: $path"
        return 0
    fi
    available_gb=$((available_kb / 1024 / 1024))

    if [[ $available_gb -lt $threshold ]]; then
        log_error "磁盘空间不足: ${path} 可用 ${available_gb}GB，需要至少 ${threshold}GB"
        return 1
    fi

    log_info "磁盘空间检查通过: ${path} 可用 ${available_gb}GB (阈值 ${threshold}GB)"
    return 0
}

# ============================ 确认提示 ============================
# 参数: $1 = 提示语
# 返回: 0=确认 1=取消
confirm() {
    local prompt="$1"
    read -rp "$(echo -e "${YELLOW}${prompt} [Y/n]: ${NC}")" ans
    [[ "$ans" =~ ^[Yy]$ || -z "$ans" ]]
}

# ============================ 菜单选择读取 ============================
# 支持 ESC 键返回 (ESC + 回车 = 返回), 退格正常工作
# 参数: $1 = 提示语, $2 = 默认值 (可选)
# 结果写入全局变量 REPLY
read_choice() {
    local prompt="$1"
    local default="${2:-}"

    read -rp "$(echo -e "${BOLD}${prompt}${NC}")" input

    # ESC 键 -> 返回 0 (用户按 ESC 后回车, input 以 \x1b 开头)
    if [[ "${input:0:1}" == $'\x1b' ]]; then
        REPLY="0"
        return 0
    fi

    # 回车 -> 使用默认值
    if [[ -z "$input" ]]; then
        REPLY="${default}"
        return 0
    fi

    REPLY="$input"
    return 0
}

# ============================ 部署前备份 ============================
# 参数: $1 = 备份内容标签 (如 before-docker-install)
#       $2 = 额外要备份的文件/目录列表 (可选)
# 返回: 备份目录路径 (stdout)
BACKUP_BASE="/data/backup"

backup_before_deploy() {
    local label="${1:-manual}"
    shift 2>/dev/null || true
    local extra_paths=("$@")

    local backup_dir="${BACKUP_BASE}/$(date +%Y%m%d-%H%M%S)-${label}"
    mkdir -p "$backup_dir"

    local backed_up=0

    # 备份 docker-compose.yml
    if [[ -f /data/docker-compose.yml ]]; then
        cp /data/docker-compose.yml "$backup_dir/"
        backed_up=1
    fi

    # 备份 .env
    if [[ -f /data/.env ]]; then
        cp /data/.env "$backup_dir/"
        backed_up=1
    fi

    # 备份 config 目录
    if [[ -d /data/config ]]; then
        cp -r /data/config "$backup_dir/" 2>/dev/null || true
        backed_up=1
    fi

    # 备份 daemon.json
    if [[ -f /etc/docker/daemon.json ]]; then
        mkdir -p "$backup_dir/docker"
        cp /etc/docker/daemon.json "$backup_dir/docker/"
        backed_up=1
    fi

    # 备份 keepalived 配置
    if [[ -f /etc/keepalived/keepalived.conf ]]; then
        mkdir -p "$backup_dir/keepalived"
        cp /etc/keepalived/keepalived.conf "$backup_dir/keepalived/"
        backed_up=1
    fi

    # 备份额外指定的路径
    for ep in "${extra_paths[@]}"; do
        if [[ -e "$ep" ]]; then
            cp -r "$ep" "$backup_dir/" 2>/dev/null || true
            backed_up=1
        fi
    done

    if [[ $backed_up -eq 1 ]]; then
        log_info "已备份到: $backup_dir"
        echo "$backup_dir"
    else
        log_info "无需要备份的文件"
        rmdir "$backup_dir" 2>/dev/null || true
        echo ""
    fi
}

# ============================ 容器健康检查 ============================
# 参数: $1 = 最大等待秒数 (默认 60)
#       $2 = docker-compose.yml 路径 (默认 /data/docker-compose.yml)
# 返回: 0=全部健康 1=有异常
check_container_health() {
    local max_wait="${1:-60}"
    local compose_file="${2:-/data/docker-compose.yml}"

    if ! command -v docker &>/dev/null; then
        log_warn "Docker 未安装，跳过健康检查"
        return 0
    fi

    local running_count
    running_count=$(docker ps -q 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$running_count" -eq 0 ]]; then
        log_info "没有运行中的容器"
        return 0
    fi

    log_info "开始容器健康检查 (最长等待 ${max_wait}s) ..."

    local waited=0
    while [[ $waited -lt $max_wait ]]; do
        local unhealthy starting

        unhealthy=$(docker ps --filter "health=unhealthy" --format '{{.Names}}' 2>/dev/null || true)
        starting=$(docker ps --filter "health=starting" --format '{{.Names}}' 2>/dev/null || true)

        if [[ -z "$unhealthy" && -z "$starting" ]]; then
            log_ok "全部 ${running_count} 个容器状态正常"
            return 0
        fi

        [[ -n "$starting" ]]  && log_info "启动中: ${starting}"
        [[ -n "$unhealthy" ]] && log_warn "不健康: ${unhealthy}"

        sleep 5
        waited=$((waited + 5))
    done

    # 超时，打印详细状态
    log_warn "健康检查超时，当前容器状态:"
    docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}' 2>/dev/null | sed 's/^/    /'

    # 打印不健康容器的最近日志
    local unhealthy_containers
    unhealthy_containers=$(docker ps --filter "health=unhealthy" --format '{{.Names}}' 2>/dev/null || true)
    if [[ -n "$unhealthy_containers" ]]; then
        log_warn "不健康容器日志摘要:"
        for c in $unhealthy_containers; do
            echo -e "\n    ${YELLOW}--- ${c} ---${NC}"
            docker logs --tail 10 "$c" 2>&1 | sed 's/^/    /' || true
        done
    fi

    return 1
}

# ============================ SSH 远程辅助 ============================
# 创建临时密码文件 (避免命令行暴露密码)
# 设置全局变量: _SSH_JUMP_PASS_FILE, _SSH_TARGET_PASS_FILE
ssh_init_passfiles() {
    local jump_pass="$1"
    local target_pass="$2"

    _SSH_JUMP_PASS_FILE=$(mktemp /tmp/.ssh_jump_XXXXXX)
    _SSH_TARGET_PASS_FILE=$(mktemp /tmp/.ssh_target_XXXXXX)

    echo -n "$jump_pass" > "$_SSH_JUMP_PASS_FILE"
    echo -n "$target_pass" > "$_SSH_TARGET_PASS_FILE"
    chmod 600 "$_SSH_JUMP_PASS_FILE" "$_SSH_TARGET_PASS_FILE"
}

# 清理临时密码文件
ssh_cleanup_passfiles() {
    [[ -n "${_SSH_JUMP_PASS_FILE:-}" ]] && rm -f "$_SSH_JUMP_PASS_FILE" 2>/dev/null || true
    [[ -n "${_SSH_TARGET_PASS_FILE:-}" ]] && rm -f "$_SSH_TARGET_PASS_FILE" 2>/dev/null || true
}

# 构建 SSH ProxyCommand 字符串 (跳板机)
# 依赖: _SSH_JUMP_PASS_FILE, 及全局 JUMP_* 变量
_build_proxy_cmd() {
    echo "sshpass -f ${_SSH_JUMP_PASS_FILE} ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p ${JUMP_PORT:-22} ${JUMP_USER:-root}@${JUMP_HOST} -W %h:%p"
}

# 远程执行命令 (通过跳板机)
# 参数: $1 = 要执行的命令
ssh_remote_exec() {
    local cmd="$1"
    sshpass -f "$_SSH_TARGET_PASS_FILE" ssh \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=15 \
        -o ProxyCommand="$(_build_proxy_cmd)" \
        -p "${TARGET_PORT:-22}" \
        "${TARGET_USER:-root}@${TARGET_HOST}" \
        "$cmd"
}

# 远程推送文件 (通过跳板机)
# 参数: $@ = scp 参数 (源... 目标)
ssh_remote_scp() {
    sshpass -f "$_SSH_TARGET_PASS_FILE" scp \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=15 \
        -o ProxyCommand="$(_build_proxy_cmd)" \
        -P "${TARGET_PORT:-22}" \
        "$@"
}

# 测试远程连接
# 返回: 0=成功 1=失败
ssh_test_connection() {
    local result
    result=$(ssh_remote_exec "echo '__SSH_OK__'" 2>/dev/null || true)
    if [[ "$result" == *__SSH_OK__* ]]; then
        return 0
    else
        return 1
    fi
}
