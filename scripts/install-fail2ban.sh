#!/bin/bash
###############################################################################
# install-fail2ban.sh
# fail2ban 安全防护安装配置脚本（支持在线 / 离线双模式）
#
# 说明: SSH + FreeSWITCH SIP 防暴力破解
#       - sshd jail: 防 SSH 爆破
#       - freeswitch jail: 监控 /data/logs/fs/freeswitch.log 的 SIP 认证失败
#         (该日志由 docker-compose 卷挂载到宿主机; 目录不存在时跳过此 jail)
#
# 用法:
#   在线安装:  ./install-fail2ban.sh --online
#   离线安装:  ./install-fail2ban.sh --offline [--pkg-dir /data/images]
#   卸载:      ./install-fail2ban.sh --uninstall
#   查看状态:  ./install-fail2ban.sh --status
#
###############################################################################
set -euo pipefail

# ============================ 加载共享库 ============================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

# ============================ 默认参数 ============================
MODE=""
PKG_DIR="/data/images"
JAIL_CONF="/etc/fail2ban/jail.local"
FS_LOG_DIR="/data/logs/fs"

# ============================ 参数解析 ============================
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --online)    MODE="online";    shift ;;
            --offline)   MODE="offline";   shift ;;
            --uninstall) MODE="uninstall"; shift ;;
            --status)    MODE="status";    shift ;;
            --pkg-dir)   PKG_DIR="$2";     shift 2 ;;
            -h|--help)   grep '^#' "$0" | head -20; exit 0 ;;
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
}

# ============================ 在线安装 ============================
install_online() {
    log_step "在线安装 fail2ban"

    apt-get update -qq
    apt-get install -y -qq fail2ban

    log_ok "fail2ban 在线安装完成"
}

# ============================ 离线安装 ============================
install_offline() {
    log_step "离线安装 fail2ban"

    local pkg_dir="" d
    for d in "${PKG_DIR}/fail2ban" "/data/offline-bundle/packages/fail2ban" "$PKG_DIR" "/data/offline-bundle/packages"; do
        if [[ -d "$d" ]] && find "$d" -maxdepth 1 -name 'fail2ban*.deb' -type f 2>/dev/null | grep -q .; then
            pkg_dir="$d"
            break
        fi
    done

    if [[ -z "$pkg_dir" ]]; then
        log_error "未找到 fail2ban .deb 包 (查找: ${PKG_DIR}/fail2ban, /data/offline-bundle/packages/fail2ban)"
        log_info "请先在联网机器执行 prepare-offline.sh"
        exit 1
    fi
    log_info "离线包目录: ${pkg_dir}"

    local debs=()
    if [[ "$(basename "$pkg_dir")" == "fail2ban" ]]; then
        while IFS= read -r f; do debs+=("$f"); done \
            < <(find "$pkg_dir" -maxdepth 1 -name '*.deb' -type f 2>/dev/null | sort)
    else
        while IFS= read -r f; do debs+=("$f"); done \
            < <(find "$pkg_dir" -maxdepth 1 -name 'fail2ban*.deb' -type f 2>/dev/null | sort)
    fi

    log_info "找到 ${#debs[@]} 个 .deb 包，安装 ..."
    dpkg_install_debs "${debs[@]}"
    apt-get install -f -y -qq 2>/dev/null || true

    log_ok "fail2ban 离线安装完成"
}

# ============================ 配置 jail ============================
configure_jail() {
    log_step "配置 fail2ban jail"

    backup_file "$JAIL_CONF"

    # 是否启用 freeswitch jail (日志卷存在才启用)
    local fs_jail=false
    [[ -d "$FS_LOG_DIR" ]] && fs_jail=true

    {
        cat << EOF
# jail.local — 由 install-fail2ban.sh 生成 ($(date '+%Y-%m-%d %H:%M:%S'))
# 注意: 不要改 jail.conf, 本文件优先级更高

[DEFAULT]
# 内网/本机永不封禁
ignoreip = 127.0.0.1/8 ::1 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16
# 永久封禁 (bantime -1), 10 分钟内失败 5 次触发
bantime  = -1
findtime = 600
maxretry = 5

[sshd]
enabled = true
EOF

        if [[ "$fs_jail" == true ]]; then
            cat << EOF

[freeswitch]
# mode=normal: 只统计 用户不存在 / 认证失败
# (extra 模式会把正常的 401 auth challenge 也算作失败, 会误封正常话机)
enabled  = true
mode     = normal
logpath  = ${FS_LOG_DIR}/freeswitch.log
maxretry = 5
EOF
        fi
    } > "$JAIL_CONF"

    # 日志必须在重定向块外输出, 否则会写进配置文件
    if [[ "$fs_jail" == true ]]; then
        log_info "已启用 freeswitch jail (监控 ${FS_LOG_DIR}/freeswitch.log)"
    else
        log_info "${FS_LOG_DIR} 不存在，跳过 freeswitch jail (部署 FS 后可重新执行本脚本启用)"
    fi

    log_ok "jail.local 已生成"
}

# ============================ 启动并验证 ============================
start_and_verify() {
    log_step "启动 fail2ban 并验证"

    if ! command -v fail2ban-client &>/dev/null; then
        log_error "安装失败: fail2ban-client 不存在"
        exit 1
    fi

    # 配置校验 (避免有语法错误时直接 restart 导致服务起不来)
    if ! fail2ban-client --test &>/dev/null; then
        log_error "fail2ban 配置校验失败:"
        fail2ban-client --test 2>&1 | tail -5 | sed 's/^/    /'
        exit 1
    fi
    log_info "配置校验通过"
    systemctl enable fail2ban 2>/dev/null || true
    systemctl restart fail2ban

    sleep 2
    if systemctl is-active fail2ban &>/dev/null; then
        log_ok "fail2ban 服务运行中"
        fail2ban-client status 2>/dev/null | sed 's/^/    /' || true
    else
        log_error "fail2ban 启动失败"
        systemctl status fail2ban --no-pager | tail -5
        exit 1
    fi
}

# ============================ 卸载 ============================
do_uninstall() {
    log_step "卸载 fail2ban"

    if ! command -v fail2ban-client &>/dev/null; then
        log_info "fail2ban 未安装，无需卸载"
        return 0
    fi

    systemctl stop fail2ban 2>/dev/null || true
    systemctl disable fail2ban 2>/dev/null || true
    apt-get remove -y -qq fail2ban 2>/dev/null || dpkg -r fail2ban
    rm -f "$JAIL_CONF"
    hash -r 2>/dev/null || true
    log_ok "fail2ban 已卸载"
}

# ============================ 状态查看 ============================
do_status() {
    log_step "fail2ban 状态"

    if ! command -v fail2ban-client &>/dev/null; then
        log_info "fail2ban 未安装"
        return 0
    fi

    log_ok "已安装: $(fail2ban-client --version 2>/dev/null | head -1)"
    echo ""

    # 配置文件位置
    log_info "配置文件:"
    echo "    jail 配置:    ${JAIL_CONF} $( [[ -f "$JAIL_CONF" ]] && echo '' || echo '(不存在)' )"
    echo "    默认配置:     /etc/fail2ban/jail.conf (勿改, 用 jail.local 覆盖)"
    echo "    过滤规则目录: /etc/fail2ban/filter.d/ (freeswitch.conf / asterisk.conf 等)"
    echo ""

    if systemctl is-active fail2ban &>/dev/null; then
        fail2ban-client status 2>/dev/null | sed 's/^/    /'
        echo ""
        # 各 jail 详情 (含封禁 IP 列表)
        local jails
        jails=$(fail2ban-client status 2>/dev/null | grep "Jail list" | sed 's/.*://; s/,//g' || true)
        local j
        for j in $jails; do
            log_info "jail [${j}]:"
            fail2ban-client status "$j" 2>/dev/null | grep -E "Currently failed|Currently banned|Total banned" | sed 's/^/    /' || true
            # 当前封禁的 IP 列表
            local banned
            banned=$(fail2ban-client status "$j" 2>/dev/null | grep "Banned IP list" | sed 's/.*://; s/^ *//' || true)
            if [[ -n "$banned" ]]; then
                echo -e "    ${RED}已封禁 IP: ${banned}${NC}"
            else
                echo -e "    ${DIM}已封禁 IP: (无)${NC}"
            fi
        done
    else
        log_warn "fail2ban 服务未运行"
    fi
}

# ============================ 主流程 ============================
main() {
    parse_args "$@"
    init_log "install-fail2ban"
    preflight_check

    case "$MODE" in
        online)
            install_online
            configure_jail
            start_and_verify
            ;;
        offline)
            install_offline
            configure_jail
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
