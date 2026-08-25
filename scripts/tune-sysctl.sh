#!/bin/bash
###############################################################################
# tune-sysctl.sh
# VoIP/CTI 服务器内核参数调优
#
# 调优项:
#   nf_conntrack 表调大    (SIP 服务器经典坑: conntrack 满导致丢包)
#   UDP buffer / somaxconn / 端口范围 / 文件句柄
#
# 用法:
#   应用调优:  ./tune-sysctl.sh --apply
#   查看状态:  ./tune-sysctl.sh --status
#
###############################################################################
set -euo pipefail

# ============================ 加载共享库 ============================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

SYSCTL_CONF="/etc/sysctl.d/99-cti-voip.conf"

# ============================ 参数解析 ============================
ACTION=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --apply)  ACTION="apply";  shift ;;
        --status) ACTION="status"; shift ;;
        -h|--help) grep '^#' "$0" | head -14; exit 0 ;;
        *) log_error "未知参数: $1"; exit 1 ;;
    esac
done
[[ -z "$ACTION" ]] && { log_error "请指定操作: --apply / --status"; exit 1; }

# ============================ 调优项定义 (key = 期望值) ============================
TUNE_KEYS=(
    "net.netfilter.nf_conntrack_max"
    "net.core.somaxconn"
    "net.core.rmem_max"
    "net.core.wmem_max"
    "net.ipv4.udp_rmem_min"
    "net.ipv4.udp_wmem_min"
    "net.ipv4.ip_local_port_range"
    "fs.file-max"
    "fs.inotify.max_user_watches"
)
TUNE_VALS=(
    "1048576"
    "65535"
    "26214400"
    "26214400"
    "8192"
    "8192"
    "1024 65535"
    "2097152"
    "524288"
)

# ============================ 应用调优 ============================
do_apply() {
    log_step "应用内核参数调优"

    if [[ $EUID -ne 0 ]]; then
        log_error "请以 root 用户运行"
        exit 1
    fi

    # conntrack sysctl 依赖内核模块, 未加载则先加载
    if [[ ! -e /proc/sys/net/netfilter/nf_conntrack_max ]]; then
        log_info "加载 nf_conntrack 内核模块 ..."
        modprobe nf_conntrack 2>/dev/null || log_warn "nf_conntrack 模块加载失败，conntrack 项将被跳过"
        # 开机自动加载
        echo "nf_conntrack" > /etc/modules-load.d/nf_conntrack.conf 2>/dev/null || true
    fi

    backup_file "$SYSCTL_CONF"

    {
        echo "# VoIP/CTI 服务器内核调优 — 由 tune-sysctl.sh 生成 ($(date '+%Y-%m-%d %H:%M:%S'))"
        local i
        for i in "${!TUNE_KEYS[@]}"; do
            local key="${TUNE_KEYS[$i]}"
            # 内核不支持该项则跳过 (注释掉)
            if [[ -e "/proc/sys/${key//.//}" ]]; then
                echo "${key} = ${TUNE_VALS[$i]}"
            else
                echo "# ${key} = ${TUNE_VALS[$i]}  # 当前内核不支持, 跳过"
            fi
        done
    } > "$SYSCTL_CONF"

    log_info "已写入: ${SYSCTL_CONF}"
    cat "$SYSCTL_CONF" | sed 's/^/    /'

    log_info "应用 sysctl ..."
    sysctl --system > /dev/null 2>&1 || true

    do_status
}

# ============================ 查看状态 ============================
do_status() {
    log_step "内核参数状态"

    printf "    ${BOLD}%-42s %-14s %-14s${NC}\n" "参数" "当前值" "推荐值"
    print_line

    local i all_ok=true
    for i in "${!TUNE_KEYS[@]}"; do
        local key="${TUNE_KEYS[$i]}" cur
        cur=$(sysctl -n "$key" 2>/dev/null || echo "不支持")
        if [[ "$cur" == "${TUNE_VALS[$i]}" ]]; then
            printf "    %-42s %-14s %-14s ${GREEN}✓${NC}\n" "$key" "$cur" "${TUNE_VALS[$i]}"
        elif [[ "$cur" == "不支持" ]]; then
            printf "    %-42s %-14s %-14s ${DIM}-${NC}\n" "$key" "$cur" "${TUNE_VALS[$i]}"
        else
            printf "    %-42s %-14s %-14s ${YELLOW}~${NC}\n" "$key" "$cur" "${TUNE_VALS[$i]}"
            all_ok=false
        fi
    done

    echo ""
    [[ "$all_ok" == true ]] && log_ok "全部参数已调优" || log_info "有参数未调优, 可执行 --apply"
}

# ============================ 主流程 ============================
init_log "tune-sysctl"

case "$ACTION" in
    apply)  do_apply ;;
    status) do_status ;;
esac

echo ""
show_log_path
