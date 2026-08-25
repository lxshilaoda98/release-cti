#!/bin/bash
###############################################################################
# install-keepalived.sh
# Keepalived 安装配置脚本（支持在线/离线 + 标准/CTI 双模式 + 仅重配置）
#
# 适用系统: Ubuntu 22.04 / 24.04 (x86_64)
#
# 用法:
#   在线安装:  ./install-keepalived.sh --online
#   离线安装:  ./install-keepalived.sh --offline
#   仅重配置:  ./install-keepalived.sh --reconfig
#   查看状态:  ./install-keepalived.sh --status
#
###############################################################################
set -euo pipefail

# ============================ 加载共享库 ============================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

# ============================ 默认参数 ============================
MODE=""
VIP=""
VIP_MASK=""
STATE=""
INTERFACE=""
PRIORITY=""
ROUTER_ID="51"
AUTH_PASS=""
PKG_DIR="/data/images"
KEEPALIVED_CONF="/etc/keepalived/keepalived.conf"
CHECK_SCRIPT="/etc/keepalived/check_docker.sh"
NOTIFY_SCRIPT="/etc/keepalived/notify.sh"
RECONFIG_ONLY=false

# CTI 模式参数
CONFIG_MODE=""
NOPREEMPT=false
GARP_DELAY=0
SMTP_ALERT=false
DYNAMIC_INTERFACES=false
AUTH_TYPE="PASS"
VIP_LABEL=""
COMPOSE_FILE="/data/docker-compose.yml"

# ============================ 参数解析 ============================
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --online)             MODE="online";        shift ;;
            --offline)            MODE="offline";       shift ;;
            --reconfig)          MODE="reconfig";       shift ;;
            --status)            MODE="status";         shift ;;
            --vip)                VIP="$2";             shift 2 ;;
            --vip-mask)           VIP_MASK="$2";        shift 2 ;;
            --state)              STATE="$2";           shift 2 ;;
            --interface)          INTERFACE="$2";       shift 2 ;;
            --priority)           PRIORITY="$2";        shift 2 ;;
            --router-id)          ROUTER_ID="$2";       shift 2 ;;
            --auth-pass)          AUTH_PASS="$2";       shift 2 ;;
            --config-mode)        CONFIG_MODE="$2";     shift 2 ;;
            --nopreempt)          NOPREEMPT=true;       shift ;;
            --garp-delay)         GARP_DELAY="$2";      shift 2 ;;
            --smtp-alert)         SMTP_ALERT=true;      shift ;;
            --dynamic-interfaces) DYNAMIC_INTERFACES=true; shift ;;
            --auth-type)          AUTH_TYPE="$2";       shift 2 ;;
            --vip-label)          VIP_LABEL="$2";       shift 2 ;;
            --compose-file)       COMPOSE_FILE="$2";    shift 2 ;;
            --pkg-dir)            PKG_DIR="$2";         shift 2 ;;
            -h|--help)
                grep '^#' "$0" | head -15
                exit 0
                ;;
            *) log_error "未知参数: $1"; exit 1 ;;
        esac
    done
}

# ============================ 获取 compose 命令 ============================
get_compose_cmd() {
    if docker compose version &>/dev/null 2>&1; then
        echo "docker compose"
    elif command -v docker-compose &>/dev/null 2>&1; then
        echo "docker-compose"
    else
        echo "docker-compose"
    fi
}

# ============================ 查看当前状态 ============================
show_status() {
    log_step "Keepalived 当前状态"

    if ! command -v keepalived &>/dev/null; then
        log_warn "Keepalived 未安装"
        exit 0
    fi

    local ver
    ver=$(keepalived --version 2>/dev/null | head -1 | awk '{print $2}')
    log_info "版本: ${ver}"

    echo ""
    log_info "服务状态:"
    systemctl status keepalived --no-pager 2>/dev/null | head -10 | sed 's/^/    /' || true

    echo ""
    log_info "配置文件 (${KEEPALIVED_CONF}):"
    if [[ -f "$KEEPALIVED_CONF" ]]; then
        cat "$KEEPALIVED_CONF" | sed 's/^/    /'
    else
        echo "    (不存在)"
    fi

    echo ""
    log_info "VIP 绑定状态:"
    ip -4 addr | grep -oE 'inet [0-9.]+' | awk '{print $2}' | sed 's/^/    /' || true

    echo ""
    log_info "notify 日志 (最近 20 行):"
    if [[ -f /var/log/keepalived-notify.log ]]; then
        tail -20 /var/log/keepalived-notify.log | sed 's/^/    /' || true
    else
        echo "    (无日志文件)"
    fi

    echo ""
    log_info "notify.sh:"
    if [[ -f "$NOTIFY_SCRIPT" ]]; then
        echo "    存在: ${NOTIFY_SCRIPT}"
    else
        echo "    不存在"
    fi

    log_info "check_docker.sh:"
    if [[ -f "$CHECK_SCRIPT" ]]; then
        echo "    存在: ${CHECK_SCRIPT}"
    else
        echo "    不存在"
    fi

    show_log_path
}

# ============================ 前置检查 ============================
preflight_check() {
    log_step "前置检查"

    if [[ $EUID -ne 0 ]]; then
        log_error "请以 root 用户运行此脚本"
        exit 1
    fi

    if ! grep -qiE 'ubuntu' /etc/os-release 2>/dev/null; then
        log_error "此脚本仅支持 Ubuntu 系统"
        exit 1
    fi
    source /etc/os-release
    log_info "操作系统: $PRETTY_NAME"

    local arch
    arch=$(uname -m)
    if [[ "$arch" != "x86_64" ]]; then
        log_error "此脚本仅支持 x86_64 架构，当前: $arch"
        exit 1
    fi

    # 已安装时提供选择
    if command -v keepalived &>/dev/null; then
        local ver
        ver=$(keepalived --version 2>/dev/null | head -1 | awk '{print $2}')
        log_info "Keepalived 已安装 (v${ver})"
        echo ""
        echo -e "  请选择操作:"
        echo -e "    ${CYAN}[1]${NC}  重新安装"
        echo -e "    ${CYAN}[2]${NC}  仅重新配置  ${DIM}(跳过安装，只更新配置)${NC}"
        echo -e "    ${CYAN}[3]${NC}  取消"
        read -rp "$(echo -e "${BOLD}请输入序号 [默认 2]: ${NC}")" ka_choice
        ka_choice="${ka_choice:-2}"
        case "$ka_choice" in
            1) RECONFIG_ONLY=false ;;
            2) RECONFIG_ONLY=true; log_info "跳过安装，仅重新配置" ;;
            3) log_info "已取消"; exit 0 ;;
            *) RECONFIG_ONLY=true; log_info "默认: 仅重新配置" ;;
        esac
    fi
}

# ============================ 在线安装 ============================
install_online() {
    log_step "在线安装 Keepalived"
    log_info "apt update ..."
    apt-get update -qq
    log_info "安装 keepalived ..."
    apt-get install -y -qq keepalived
    log_info "Keepalived 在线安装完成"
}

# ============================ 离线安装 ============================
install_offline() {
    log_step "离线安装 Keepalived"

    # 自动回退到离线包 bundle 目录
    PKG_DIR=$(resolve_pkg_dir "$PKG_DIR")

    if [[ ! -d "$PKG_DIR" ]]; then
        log_error "离线包目录不存在: $PKG_DIR"
        exit 1
    fi

    local ka_debs
    ka_debs=$(find "$PKG_DIR" -name '*keepalived*.deb' -type f 2>/dev/null || true)
    if [[ -z "$ka_debs" ]]; then
        log_error "在 $PKG_DIR 中未找到 keepalived .deb 包"
        log_info "请先在有网络的机器上运行 prepare-offline.sh 下载离线包"
        exit 1
    fi

    log_info "找到 keepalived 包:"
    find "$PKG_DIR" -name '*keepalived*.deb' -type f | sort | while read -r f; do
        echo "    $(basename "$f")"
    done

    local all_debs
    all_debs=$(find "$PKG_DIR" -name '*.deb' -type f 2>/dev/null | sort)

    log_info "安装 .deb 包 ..."
    if ! dpkg -i $all_debs 2>/dev/null; then
        log_warn "dpkg 报告依赖问题，尝试 apt 修复 ..."
        apt-get install -f -y -qq 2>/dev/null || true
    fi
    log_info "Keepalived 离线安装完成"
}

# ============================ 交互式配置 ============================
interactive_config() {
    log_step "Keepalived HA 配置"

    # 配置模式选择
    if [[ -z "$CONFIG_MODE" ]]; then
        echo ""
        echo -e "  请选择配置模式:"
        echo -e "    ${CYAN}[1]${NC}  标准模式  ${DIM}(简单 VRRP + Docker 健康检查)${NC}"
        echo -e "    ${CYAN}[2]${NC}  CTI 模式  ${DIM}(完整 HA: nopreempt + notify 脚本 + 容器自动启停)${NC}"
        read -rp "$(echo -e "${BOLD}请输入序号 [默认 2]: ${NC}")" mode_choice
        mode_choice="${mode_choice:-2}"
        case "$mode_choice" in
            1) CONFIG_MODE="standard" ;;
            *) CONFIG_MODE="cti" ;;
        esac
    fi

    # CTI 模式默认值
    if [[ "$CONFIG_MODE" == "cti" ]]; then
        [[ "$GARP_DELAY" -eq 0 ]] && GARP_DELAY=10
        NOPREEMPT=true
        DYNAMIC_INTERFACES=true
    fi

    # 自动检测网络接口
    if [[ -z "$INTERFACE" ]]; then
        INTERFACE=$(ip route show default 2>/dev/null | awk '{print $5}' | head -1)
        if [[ -z "$INTERFACE" ]]; then
            log_error "无法自动检测网络接口，请通过 --interface 指定"
            exit 1
        fi
    fi

    # 获取本机 IP 和子网掩码
    local local_ip local_cidr local_mask
    local_cidr=$(ip -o -f inet addr show "$INTERFACE" 2>/dev/null | awk '{print $4}' | head -1)
    local_ip="${local_cidr%%/*}"
    local_mask="${local_cidr#*/}"

    if [[ -z "$local_ip" ]]; then
        log_error "无法获取接口 $INTERFACE 的 IP 地址"
        exit 1
    fi

    # 自动检测子网掩码作为 VIP 默认值
    if [[ -z "$VIP_MASK" ]]; then
        VIP_MASK="$local_mask"
    fi

    echo ""
    echo -e "  ${BOLD}当前网络信息:${NC}"
    echo -e "    接口:     ${CYAN}${INTERFACE}${NC}"
    echo -e "    本机 IP:   ${CYAN}${local_ip}/${local_mask}${NC}"
    echo -e "    配置模式:  ${CYAN}${CONFIG_MODE}${NC}"
    echo ""

    # VIP
    if [[ -z "$VIP" ]]; then
        read -rp "请输入 VIP 虚拟 IP 地址: " VIP
        if [[ -z "$VIP" ]]; then
            log_error "VIP 不能为空"
            exit 1
        fi
    fi

    # VIP 子网掩码
    if [[ -z "$VIP_MASK" ]] || [[ "$VIP_MASK" == "$local_mask" ]]; then
        echo ""
        read -rp "请输入 VIP 子网掩码 [默认 ${local_mask}]: " input_mask
        VIP_MASK="${input_mask:-$local_mask}"
    fi

    # CTI 模式: VIP 标签
    if [[ "$CONFIG_MODE" == "cti" ]] && [[ -z "$VIP_LABEL" ]]; then
        read -rp "请输入 VIP 标签 (如 callcenter, 可留空): " VIP_LABEL
    fi

    # 节点角色
    if [[ -z "$STATE" ]]; then
        echo ""
        echo -e "  请选择本节点角色:"
        if [[ "$CONFIG_MODE" == "cti" ]]; then
            echo -e "    ${CYAN}[1]${NC}  MASTER  ${DIM}(主节点，优先级 200)${NC}"
            echo -e "    ${CYAN}[2]${NC}  BACKUP  ${DIM}(备节点，优先级 100)${NC}"
        else
            echo -e "    ${CYAN}[1]${NC}  MASTER  ${DIM}(主节点，优先级 100)${NC}"
            echo -e "    ${CYAN}[2]${NC}  BACKUP  ${DIM}(备节点，优先级 90)${NC}"
        fi
        read -rp "$(echo -e "${BOLD}请输入序号 [默认 1]: ${NC}")" role_choice
        role_choice="${role_choice:-1}"
        case "$role_choice" in
            2) STATE="BACKUP" ;;
            *) STATE="MASTER" ;;
        esac
    fi

    # 优先级
    if [[ -z "$PRIORITY" ]]; then
        if [[ "$CONFIG_MODE" == "cti" ]]; then
            [[ "$STATE" == "MASTER" ]] && PRIORITY=200 || PRIORITY=100
        else
            [[ "$STATE" == "MASTER" ]] && PRIORITY=100 || PRIORITY=90
        fi
    fi

    # 认证密码
    if [[ -z "$AUTH_PASS" ]]; then
        AUTH_PASS=$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c 8)
        log_info "已自动生成 VRRP 认证密码: ${AUTH_PASS}"
    fi

    # CTI 模式: 认证类型
    if [[ "$CONFIG_MODE" == "cti" ]] && [[ "$AUTH_TYPE" == "PASS" ]]; then
        echo ""
        read -rp "请输入认证类型 [默认 PASS, 可自定义如 callcenter]: " input_auth_type
        [[ -n "$input_auth_type" ]] && AUTH_TYPE="$input_auth_type"
    fi

    # CTI 模式: compose 文件路径
    if [[ "$CONFIG_MODE" == "cti" ]]; then
        echo ""
        read -rp "docker-compose.yml 路径 [默认 ${COMPOSE_FILE}]: " input_compose
        [[ -n "$input_compose" ]] && COMPOSE_FILE="$input_compose"
    fi

    # 配置摘要
    echo ""
    echo -e "  ${BOLD}配置摘要:${NC}"
    print_line
    printf "    %-20s %s\n" "配置模式" "$CONFIG_MODE"
    printf "    %-20s %s\n" "VIP" "${VIP}/${VIP_MASK}"
    [[ -n "$VIP_LABEL" ]] && printf "    %-20s %s\n" "VIP 标签" "$VIP_LABEL"
    printf "    %-20s %s\n" "节点角色" "$STATE"
    printf "    %-20s %s\n" "网络接口" "$INTERFACE"
    printf "    %-20s %s\n" "优先级" "$PRIORITY"
    printf "    %-20s %s\n" "虚拟路由 ID" "$ROUTER_ID"
    printf "    %-20s %s\n" "认证类型" "$AUTH_TYPE"
    printf "    %-20s %s\n" "认证密码" "$AUTH_PASS"
    printf "    %-20s %s\n" "本机 IP" "${local_ip}/${local_mask}"
    if [[ "$CONFIG_MODE" == "cti" ]]; then
        printf "    %-20s %s\n" "nopreempt" "$([[ $NOPREEMPT == true ]] && echo '是' || echo '否')"
        printf "    %-20s %s\n" "garp_master_delay" "$GARP_DELAY"
        printf "    %-20s %s\n" "smtp_alert" "$([[ $SMTP_ALERT == true ]] && echo '是' || echo '否')"
        printf "    %-20s %s\n" "dynamic_interfaces" "$([[ $DYNAMIC_INTERFACES == true ]] && echo '是' || echo '否')"
        printf "    %-20s %s\n" "notify 脚本" "$NOTIFY_SCRIPT"
        printf "    %-20s %s\n" "compose 文件" "$COMPOSE_FILE"
    fi
    print_line
    echo ""

    if ! confirm "确认以上配置？"; then
        log_info "已取消"
        exit 0
    fi
}

# ============================ 生成健康检查脚本 ============================
generate_check_script() {
    log_info "生成 Docker 健康检查脚本 ..."
    mkdir -p /etc/keepalived

    cat > "$CHECK_SCRIPT" << 'EOF'
#!/bin/bash
# check_docker.sh - Keepalived 健康检查脚本
if ! docker info &>/dev/null; then
    exit 1
fi
running=$(docker ps -q 2>/dev/null | wc -l)
if [[ "$running" -eq 0 ]]; then
    exit 1
fi
exit 0
EOF
    chmod +x "$CHECK_SCRIPT"
    log_info "健康检查脚本: ${CHECK_SCRIPT}"
}

# ============================ 生成 notify.sh 脚本 ============================
generate_notify_script() {
    if [[ "$CONFIG_MODE" != "cti" ]]; then
        return 0
    fi

    log_info "生成 notify.sh 容器启停脚本 ..."

    cat > "$NOTIFY_SCRIPT" << 'NOTIFY_EOF'
#!/bin/bash
# notify.sh - Keepalived 状态切换通知脚本
# 主备切换时自动启停 Docker 容器
# 参数: $1=TYPE  $2=NAME  $3=STATE

TYPE=$1
NAME=$2
STATE=$3

COMPOSE_FILE="COMPOSE_FILE_PLACEHOLDER"

# 自动检测 compose 命令
if docker compose version &>/dev/null 2>&1; then
    COMPOSE_CMD="docker compose"
elif command -v docker-compose &>/dev/null 2>&1; then
    COMPOSE_CMD="docker-compose"
else
    echo "$(date) [$STATE] ERROR: docker-compose not found" >> /var/log/keepalived-notify.log
    exit 1
fi

log() {
    echo "$(date) [$STATE] $1" >> /var/log/keepalived-notify.log
}

execute_docker_compose() {
    local action=$1
    local cmd=""

    case $action in
        "up")
            cmd="$COMPOSE_CMD -f ${COMPOSE_FILE} restart"
            ;;
        "down")
            cmd="$COMPOSE_CMD -f ${COMPOSE_FILE} stop"
            ;;
    esac

    log "Executing: $cmd"
    if $cmd; then
        log "Success: $action containers"
    else
        log "ERROR: Failed to $action containers"
        return 1
    fi
}

restart_additional_services() {
    log "Waiting 10 seconds before restarting getcurl..."
    sleep 10

    log "Restarting getcurl container..."
    if docker restart getcurl; then
        log "Success: getcurl container restarted"
    else
        log "ERROR: Failed to restart getcurl container"
        return 1
    fi

    log "Waiting 5 seconds before restarting fs..."
    sleep 5

    log "Restarting fs container..."
    if docker restart fs; then
        log "Success: fs container restarted"
    else
        log "ERROR: Failed to restart fs container"
    fi
}

case $STATE in
    "MASTER")
        log "Becoming MASTER, starting services..."
        execute_docker_compose "up"

        log "Starting additional services sequence..."
        restart_additional_services
        ;;
    "BACKUP")
        log "Becoming BACKUP, stopping services..."
        execute_docker_compose "down"
        ;;
    "FAULT")
        log "FAULT state detected, stopping services..."
        execute_docker_compose "down"
        ;;
    *)
        log "Unknown state: $STATE"
        ;;
esac
NOTIFY_EOF

    # 替换 compose 文件路径占位符
    sed -i "s|COMPOSE_FILE_PLACEHOLDER|${COMPOSE_FILE}|" "$NOTIFY_SCRIPT"
    chmod +x "$NOTIFY_SCRIPT"
    log_info "notify 脚本: ${NOTIFY_SCRIPT}"
}

# ============================ 生成 keepalived.conf ============================
generate_config() {
    log_step "生成 keepalived.conf"

    local backup_ts
    backup_ts=$(date +%Y%m%d%H%M%S)

    if [[ -f "$KEEPALIVED_CONF" ]]; then
        cp "$KEEPALIVED_CONF" "${KEEPALIVED_CONF}.bak.${backup_ts}"
        log_info "已备份 keepalived.conf -> keepalived.conf.bak.${backup_ts}"
    fi

    mkdir -p /etc/keepalived

    # 构建 virtual_ipaddress 行
    local vip_line="${VIP}/${VIP_MASK}"
    if [[ -n "$VIP_LABEL" ]]; then
        vip_line="${VIP} ${VIP_LABEL} ${INTERFACE}"
    fi

    if [[ "$CONFIG_MODE" == "cti" ]]; then
        cat > "$KEEPALIVED_CONF" << EOF
global_defs {
    router_id CTI_HA
    enable_script_security
}

vrrp_script check_docker {
    script "${CHECK_SCRIPT}"
    interval 2
    weight -30
    fall 3
    rise 2
}

vrrp_instance VI_1 {
    state ${STATE}
    interface ${INTERFACE}
    garp_master_delay ${GARP_DELAY}
    $( [[ "$SMTP_ALERT" == true ]] && echo "smtp_alert" )
    virtual_router_id ${ROUTER_ID}
    priority ${PRIORITY}
    $( [[ "$NOPREEMPT" == true ]] && echo "nopreempt" )
    $( [[ "$DYNAMIC_INTERFACES" == true ]] && echo "dynamic_interfaces" )
    track_interface {
        ${INTERFACE}
    }
    advert_int 1
    authentication {
        auth_type ${AUTH_TYPE}
        auth_pass ${AUTH_PASS}
    }
    virtual_ipaddress {
        ${vip_line}
    }
    track_script {
        check_docker
    }
    notify "${NOTIFY_SCRIPT}"
}
EOF
    else
        cat > "$KEEPALIVED_CONF" << EOF
global_defs {
    router_id CTI_HA
    enable_script_security
}

vrrp_script check_docker {
    script "${CHECK_SCRIPT}"
    interval 2
    weight -30
    fall 3
    rise 2
}

vrrp_instance VI_1 {
    state ${STATE}
    interface ${INTERFACE}
    virtual_router_id ${ROUTER_ID}
    priority ${PRIORITY}
    advert_int 1

    authentication {
        auth_type PASS
        auth_pass ${AUTH_PASS}
    }

    virtual_ipaddress {
        ${vip_line}
    }

    track_script {
        check_docker
    }

    notify_master "/bin/echo 'keepalived: 切换为 MASTER 状态' >> /var/log/keepalived-notify.log"
    notify_backup "/bin/echo 'keepalived: 切换为 BACKUP 状态' >> /var/log/keepalived-notify.log"
    notify_fault  "/bin/echo 'keepalived: 发生 FAULT' >> /var/log/keepalived-notify.log"
}
EOF
    fi

    log_info "keepalived.conf 已生成 (${CONFIG_MODE} 模式):"
    cat "$KEEPALIVED_CONF" | sed 's/^/    /'
}

# ============================ 系统优化 ============================
system_tweaks() {
    log_step "系统网络配置优化"

    local sysctl_conf="/etc/sysctl.d/99-keepalived.conf"
    cat > "$sysctl_conf" << 'EOF'
# Keepalived VRRP 优化
net.ipv4.ip_nonlocal_bind = 1
net.ipv4.ip_forward = 1
EOF
    sysctl -p "$sysctl_conf" 2>/dev/null || true
    log_info "sysctl 已配置: ip_nonlocal_bind=1, ip_forward=1"

    if command -v ufw &>/dev/null; then
        ufw allow 112/vrrp 2>/dev/null || true
        log_info "ufw 已放行 VRRP 协议"
    elif command -v iptables &>/dev/null; then
        iptables -I INPUT -p vrrp -j ACCEPT 2>/dev/null || true
        log_info "iptables 已放行 VRRP 协议"
    fi
}

# ============================ 启动并验证 ============================
start_and_verify() {
    log_step "启动 Keepalived 并验证"

    log_info "启动 keepalived 服务 ..."
    systemctl daemon-reload
    systemctl enable keepalived 2>/dev/null || true
    systemctl restart keepalived

    sleep 2

    if ! systemctl is-active --quiet keepalived; then
        log_error "keepalived 服务启动失败"
        systemctl status keepalived --no-pager
        journalctl -u keepalived --no-pager -n 20
        exit 1
    fi
    log_info "keepalived 服务已启动"

    local ver
    ver=$(keepalived --version 2>/dev/null | head -1 | awk '{print $2}')
    log_info "Keepalived 版本: ${ver}"

    local vip_bound=false
    if ip -4 addr show "$INTERFACE" 2>/dev/null | grep -q "$VIP"; then
        vip_bound=true
    fi

    if [[ "$STATE" == "MASTER" ]]; then
        if [[ "$vip_bound" == true ]]; then
            log_ok "VIP ${VIP} 已绑定到 ${INTERFACE} (MASTER 节点)"
        else
            log_warn "VIP ${VIP} 尚未绑定 (可能正在选举中，请稍后检查: ip addr show ${INTERFACE})"
        fi
    else
        log_info "本节点为 BACKUP，VIP ${VIP} 应在 MASTER 节点上"
    fi

    echo ""
    log_info "Keepalived 状态:"
    systemctl status keepalived --no-pager 2>/dev/null | head -10 | sed 's/^/    /'
}

# ============================ 主流程 ============================
main() {
    parse_args "$@"
    init_log "install-keepalived"

    # 查看状态模式
    if [[ "$MODE" == "status" ]]; then
        show_status
        exit 0
    fi

    if [[ -z "$MODE" ]]; then
        log_error "请指定模式: --online / --offline / --reconfig / --status"
        exit 1
    fi

    preflight_check

    echo ""
    echo "========================================================"
    echo "  Keepalived 安装配置摘要"
    echo "========================================================"
    if [[ "$RECONFIG_ONLY" == true ]]; then
        echo "  模式: 仅重新配置"
    else
        echo "  安装模式: $MODE"
        [[ "$MODE" == "offline" ]] && echo "  离线包目录: $PKG_DIR"
    fi
    echo "========================================================"
    echo ""

    check_disk_space / 5

    if [[ -f "$KEEPALIVED_CONF" ]]; then
        backup_before_deploy "before-keepalived-install"
    fi

    # 安装 (仅重配置模式跳过)
    if [[ "$RECONFIG_ONLY" != true ]]; then
        if [[ "$MODE" == "online" ]]; then
            install_online
        else
            install_offline
        fi
    fi

    interactive_config
    generate_check_script
    generate_notify_script
    generate_config
    system_tweaks
    start_and_verify

    log_step "安装完成"
    log_info "Keepalived 安装配置全部完成！ (${CONFIG_MODE} 模式)"
    echo ""
    log_info "常用命令:"
    echo "    systemctl status keepalived     # 查看服务状态"
    echo "    ip addr show ${INTERFACE}       # 查看 VIP 是否绑定"
    echo "    tail -f /var/log/keepalived-notify.log  # 查看主备切换日志"
    echo ""
    if [[ "$CONFIG_MODE" == "cti" ]]; then
        log_info "CTI 模式: 主备切换时 notify.sh 会自动:"
        echo "    MASTER -> docker compose restart + 重启 getcurl/fs"
        echo "    BACKUP -> docker compose stop"
        echo ""
    fi
    if [[ "$STATE" == "MASTER" ]]; then
        log_warn "请在备用节点上执行相同安装，角色选 BACKUP，使用相同的:"
        echo "    虚拟路由 ID: ${ROUTER_ID}"
        echo "    认证密码:   ${AUTH_PASS}"
        echo "    VIP:        ${VIP}/${VIP_MASK}"
    fi
    echo ""
    show_log_path
}

main "$@"
