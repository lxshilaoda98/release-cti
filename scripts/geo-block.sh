#!/bin/bash
###############################################################################
# geo-block.sh
# 海外 IP 封禁 (Geo-IP 白名单) — 只放行中国 IP 访问 SIP 端口, 其余全部丢弃
#
# 原理: ipset (hash:net) 存中国网段 + iptables 专用链 GEO-SIP, O(1) 匹配无性能损耗
# 端口: SIP 5060/5061 (UDP+TCP), 其他端口 (SSH/HTTP 等) 不受影响
# 白名单: 中国 IP 列表 + RFC1918 内网网段 (内网话机永不误伤)
#
# 用法:
#   获取中国IP列表:  ./geo-block.sh --fetch [--proxy https://ghproxy.net/]
#   本地导入列表:    ./geo-block.sh --import /path/china-ip.txt
#   启用封禁:        ./geo-block.sh --apply
#   关闭封禁:        ./geo-block.sh --unblock
#   查看状态:        ./geo-block.sh --status
#   放行 IP:         ./geo-block.sh --allow-ip 1.2.3.4 (支持 CIDR, 可多次)
#   移除放行 IP:     ./geo-block.sh --remove-ip 1.2.3.4
#   添加保护端口:    ./geo-block.sh --add-port 5080
#   移除保护端口:    ./geo-block.sh --remove-port 5080
#
###############################################################################
set -euo pipefail

# ============================ 加载共享库 ============================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

# ============================ 默认参数 ============================
GEO_DIR="/data/config/geoip"
GEO_FILE="${GEO_DIR}/china-ip.txt"
ALLOW_FILE="${GEO_DIR}/allow-extra.txt"
PORTS_FILE="${GEO_DIR}/protected-ports.txt"
GEO_URL="https://raw.githubusercontent.com/17mon/china_ip_list/master/china_ip_list.txt"
PROXY=""
IPSET_NAME="china"
IPT_CHAIN="GEO-SIP"
DEFAULT_PORTS="5060 5061"
SYSTEMD_UNIT="/etc/systemd/system/geo-block.service"

# 内网网段始终放行 (china_ip_list 不含私有地址)
PRIVATE_NETS=("10.0.0.0/8" "172.16.0.0/12" "192.168.0.0/16" "127.0.0.0/8")

# ============================ 参数解析 ============================
ACTION=""
IMPORT_FILE=""
IP_ARGS=()
PORT_ARG=""
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --fetch)       ACTION="fetch";   shift ;;
            --import)      ACTION="import"; IMPORT_FILE="$2"; shift 2 ;;
            --apply)       ACTION="apply";   shift ;;
            --restore)     ACTION="restore"; shift ;;
            --unblock)     ACTION="unblock"; shift ;;
            --status)      ACTION="status";  shift ;;
            --allow-ip)    ACTION="allow-ip"; IP_ARGS+=("$2"); shift 2 ;;
            --remove-ip)   ACTION="remove-ip"; IP_ARGS+=("$2"); shift 2 ;;
            --add-port)    ACTION="add-port"; PORT_ARG="$2"; shift 2 ;;
            --remove-port) ACTION="remove-port"; PORT_ARG="$2"; shift 2 ;;
            --proxy)       PROXY="$2";       shift 2 ;;
            -h|--help)     grep '^#' "$0" | head -24; exit 0 ;;
            *) log_error "未知参数: $1"; exit 1 ;;
        esac
    done

    if [[ -z "$ACTION" ]]; then
        log_error "请指定操作: --fetch / --import / --apply / --unblock / --status / --allow-ip / --remove-ip / --add-port / --remove-port"
        exit 1
    fi
}

# ============================ 端口列表读写 ============================
# 输出空格分隔的端口列表 (文件不存在时用默认值)
read_ports() {
    if [[ -f "$PORTS_FILE" ]]; then
        grep -oE '[0-9]+' "$PORTS_FILE" | sort -un | tr '\n' ' '
    else
        echo "$DEFAULT_PORTS"
    fi
}

# 逗号分隔端口列表 (供 iptables multiport)
ports_csv() {
    read_ports | tr ' ' ',' | sed 's/,$//'
}

# 校验端口号
valid_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && [[ "$1" -ge 1 && "$1" -le 65535 ]]
}

# 规范化 IP: 裸 IP 补 /32, 带 / 的保持
norm_ip() {
    if [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$1/32"
    elif [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
        echo "$1"
    else
        echo ""
    fi
}

# ============================ 前置检查 ============================
need_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "请以 root 用户运行"
        exit 1
    fi
}

# ipset/iptables 依赖: 缺失时自动安装 (在线 apt, 离线用工具包 deb)
ensure_deps() {
    local missing=()
    command -v ipset    &>/dev/null || missing+=("ipset")
    command -v iptables &>/dev/null || missing+=("iptables")
    [[ ${#missing[@]} -eq 0 ]] && return 0

    log_info "缺少依赖: ${missing[*]}，尝试自动安装 ..."

    # 1. 在线 apt
    if apt-get install -y -qq "${missing[@]}" &>/dev/null 2>&1; then
        log_ok "依赖已安装 (在线)"
        return 0
    fi

    # 2. 离线: 从工具包 deb 目录安装
    local d
    for d in /data/offline-bundle/packages/tools /data/images/tools; do
        if [[ -d "$d" ]] && find "$d" -maxdepth 1 -name 'ipset*.deb' -type f 2>/dev/null | grep -q .; then
            log_info "使用离线包: ${d}"
            local debs=()
            while IFS= read -r f; do debs+=("$f"); done \
                < <(find "$d" -maxdepth 1 -name '*.deb' -type f 2>/dev/null | sort)
            dpkg_install_debs "${debs[@]}"
            break
        fi
    done

    # 3. 最终检查
    local still=()
    command -v ipset    &>/dev/null || still+=("ipset")
    command -v iptables &>/dev/null || still+=("iptables")
    if [[ ${#still[@]} -gt 0 ]]; then
        log_error "依赖安装失败: ${still[*]}"
        log_info "在线: apt-get install -y ${still[*]}"
        log_info "离线: 菜单 -> 运维工具 -> 常用运维工具包 -> 离线安装 (含 ipset)"
        exit 1
    fi
    log_ok "依赖已安装 (离线)"
}

# ============================ 获取中国 IP 列表 ============================
do_fetch() {
    log_step "获取中国 IP 列表"

    need_root
    mkdir -p "$GEO_DIR"

    local url="${PROXY}${GEO_URL}"
    log_info "下载: ${url}"

    local tmp
    tmp=$(mktemp)
    if ! curl -fsSL --connect-timeout 15 -o "$tmp" "$url"; then
        rm -f "$tmp"
        log_error "下载失败，可尝试: --proxy <GitHub代理前缀> 或手动下载后 --import"
        exit 1
    fi

    # 校验: 行数 + CIDR 格式抽查
    local total
    total=$(grep -cE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+' "$tmp" || true)
    if [[ "$total" -lt 1000 ]]; then
        rm -f "$tmp"
        log_error "列表校验失败 (有效网段 ${total} 条, 预期 >1000)，文件可能损坏"
        exit 1
    fi

    backup_file "$GEO_FILE"
    mv "$tmp" "$GEO_FILE"
    log_ok "中国 IP 列表已更新: ${GEO_FILE} (${total} 条网段)"
}

# ============================ 本地导入 ============================
do_import() {
    log_step "导入本地 IP 列表"

    need_root

    if [[ ! -f "$IMPORT_FILE" ]]; then
        log_error "文件不存在: ${IMPORT_FILE}"
        exit 1
    fi

    local total
    total=$(grep -cE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+' "$IMPORT_FILE" || true)
    if [[ "$total" -lt 1 ]]; then
        log_error "文件中没有有效 CIDR 网段: ${IMPORT_FILE}"
        exit 1
    fi

    mkdir -p "$GEO_DIR"

    # 源文件与目标相同时跳过拷贝 (默认路径导入即此情况)
    if [[ "$(readlink -f "$IMPORT_FILE")" == "$(readlink -f "$GEO_FILE" 2>/dev/null || echo "$GEO_FILE")" ]]; then
        log_ok "文件已就位: ${GEO_FILE} (${total} 条网段)"
    else
        backup_file "$GEO_FILE"
        cp "$IMPORT_FILE" "$GEO_FILE"
        log_ok "已导入: ${GEO_FILE} (${total} 条网段)"
    fi
}

# ============================ 构建 ipset ============================
build_ipset() {
    log_info "构建 ipset 集合 ${IPSET_NAME} ..."

    if [[ ! -f "$GEO_FILE" ]]; then
        log_error "IP 列表不存在: ${GEO_FILE}"
        log_info "请先执行 --fetch 下载，或 --import 导入"
        exit 1
    fi

    # swap 方式原子替换: 先建临时集合, 再交换
    ipset create "${IPSET_NAME}-tmp" hash:net -exist

    {
        # 内网网段
        local n
        for n in "${PRIVATE_NETS[@]}"; do
            echo "add ${IPSET_NAME}-tmp $n"
        done
        # 自定义放行 IP
        if [[ -f "$ALLOW_FILE" ]]; then
            grep -E '^[0-9]' "$ALLOW_FILE" 2>/dev/null | sed "s|^|add ${IPSET_NAME}-tmp |"
        fi
        # 中国网段 (过滤注释/空行)
        grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+' "$GEO_FILE" \
            | sed "s|^|add ${IPSET_NAME}-tmp |"
    } | ipset restore -exist

    ipset create "$IPSET_NAME" hash:net -exist
    ipset swap "${IPSET_NAME}-tmp" "$IPSET_NAME"
    ipset destroy "${IPSET_NAME}-tmp"

    local count
    count=$(ipset list "$IPSET_NAME" 2>/dev/null | grep -c "^[0-9]" || true)
    log_ok "ipset ${IPSET_NAME}: ${count} 条网段 (含内网 ${#PRIVATE_NETS[@]} 条)"
}

# ============================ 移除 INPUT 中的所有 GEO-SIP 跳转 ============================
remove_input_jumps() {
    local rule
    while read -r rule; do
        [[ -n "$rule" ]] && iptables $rule 2>/dev/null || true
    done < <(iptables -S INPUT 2>/dev/null | grep -- "-j ${IPT_CHAIN}" | sed 's/^-A /-D /' || true)
    return 0
}

# ============================ 添加 iptables 规则 (幂等, 按当前端口列表重建) ============================
add_rules() {
    # 建专用链
    iptables -N "$IPT_CHAIN" 2>/dev/null || true
    iptables -F "$IPT_CHAIN"
    iptables -A "$IPT_CHAIN" -m set --match-set "$IPSET_NAME" src -j ACCEPT
    iptables -A "$IPT_CHAIN" -j DROP

    # 先摘掉旧跳转 (端口列表可能变化), 再按当前列表挂接
    remove_input_jumps

    local ports_csv_val proto
    ports_csv_val=$(ports_csv)
    for proto in udp tcp; do
        iptables -I INPUT -p "$proto" -m multiport --dports "$ports_csv_val" -j "$IPT_CHAIN"
    done
    log_info "iptables 规则已生效 (端口 ${ports_csv_val} UDP+TCP)"
}

# ============================ systemd 持久化 ============================
setup_systemd() {
    cat > "$SYSTEMD_UNIT" << EOF
[Unit]
Description=Geo-IP block (SIP ports, China whitelist)
After=network-pre.target docker.service
Before=docker.service
Wants=network-pre.target

[Service]
Type=oneshot
ExecStart=${SCRIPT_DIR}/geo-block.sh --restore
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload 2>/dev/null || true
    systemctl enable geo-block.service 2>/dev/null || true
    log_info "已配置开机自动恢复: geo-block.service"
}

# ============================ 启用封禁 ============================
do_apply() {
    log_step "启用海外 IP 封禁"

    need_root
    ensure_deps
    build_ipset
    add_rules
    setup_systemd

    echo ""
    log_ok "海外 IP 封禁已启用"
    log_info "端口 ($(ports_csv)) 仅中国 IP + 内网 + 自定义放行 IP 可访问，其余丢弃"
}

# ============================ 开机恢复 (quiet) ============================
do_restore() {
    # 开机恢复: 静默, 集合存在才挂规则
    command -v ipset &>/dev/null || exit 0
    command -v iptables &>/dev/null || exit 0
    [[ -f "$GEO_FILE" ]] || exit 0

    build_ipset > /dev/null 2>&1 || exit 0
    add_rules > /dev/null 2>&1 || true
}

# ============================ 关闭封禁 ============================
do_unblock() {
    log_step "关闭海外 IP 封禁"

    need_root

    # 摘挂 INPUT 规则
    remove_input_jumps

    # 清链
    iptables -F "$IPT_CHAIN" 2>/dev/null || true
    iptables -X "$IPT_CHAIN" 2>/dev/null || true

    # 清集合
    ipset destroy "$IPSET_NAME" 2>/dev/null && log_info "ipset ${IPSET_NAME} 已删除" || true

    # 关 systemd
    if [[ -f "$SYSTEMD_UNIT" ]]; then
        systemctl disable geo-block.service 2>/dev/null || true
        rm -f "$SYSTEMD_UNIT"
        systemctl daemon-reload 2>/dev/null || true
        log_info "geo-block.service 已移除"
    fi

    log_ok "海外 IP 封禁已关闭 (IP 列表文件保留: ${GEO_FILE})"
}

# ============================ 放行 IP 管理 ============================
# 集合当前已启用时, 立即重建生效
_rebuild_if_active() {
    if iptables -S "$IPT_CHAIN" &>/dev/null 2>&1; then
        build_ipset
        add_rules
    fi
}

do_allow_ip() {
    log_step "添加放行 IP"

    need_root
    mkdir -p "$GEO_DIR"
    touch "$ALLOW_FILE"

    local raw nip
    for raw in "${IP_ARGS[@]}"; do
        nip=$(norm_ip "$raw")
        if [[ -z "$nip" ]]; then
            log_warn "IP 格式无效, 跳过: ${raw}"
            continue
        fi
        if grep -qxF "$nip" "$ALLOW_FILE" 2>/dev/null; then
            log_info "已存在, 跳过: ${nip}"
            continue
        fi
        echo "$nip" >> "$ALLOW_FILE"
        log_ok "已加入放行列表: ${nip}"
    done

    _rebuild_if_active
}

do_remove_ip() {
    log_step "移除放行 IP"

    need_root

    if [[ ! -f "$ALLOW_FILE" ]]; then
        log_info "放行列表为空"
        return 0
    fi

    local raw nip
    for raw in "${IP_ARGS[@]}"; do
        nip=$(norm_ip "$raw")
        if grep -qxF "$nip" "$ALLOW_FILE" 2>/dev/null; then
            sed -i "/^$(echo "$nip" | sed 's/\./\\./g; s/\//\\\//g')$/d" "$ALLOW_FILE"
            log_ok "已移除: ${nip}"
        else
            log_warn "不在放行列表中: ${raw}"
        fi
    done

    _rebuild_if_active
}

# ============================ 保护端口管理 ============================
do_add_port() {
    log_step "添加保护端口"

    need_root

    if ! valid_port "$PORT_ARG"; then
        log_error "端口无效: ${PORT_ARG} (1-65535)"
        exit 1
    fi

    mkdir -p "$GEO_DIR"
    [[ -f "$PORTS_FILE" ]] || echo "$DEFAULT_PORTS" | tr ' ' '\n' > "$PORTS_FILE"

    if grep -qx "$PORT_ARG" "$PORTS_FILE" 2>/dev/null; then
        log_info "端口已在保护列表中: ${PORT_ARG}"
    else
        echo "$PORT_ARG" >> "$PORTS_FILE"
        log_ok "已添加保护端口: ${PORT_ARG} (当前: $(ports_csv))"
    fi

    _rebuild_if_active
}

do_remove_port() {
    log_step "移除保护端口"

    need_root

    if [[ ! -f "$PORTS_FILE" ]]; then
        log_info "保护端口为默认: ${DEFAULT_PORTS}, 未做自定义"
        return 0
    fi

    if grep -qx "$PORT_ARG" "$PORTS_FILE" 2>/dev/null; then
        sed -i "/^${PORT_ARG}$/d" "$PORTS_FILE"
        log_ok "已移除保护端口: ${PORT_ARG} (当前: $(ports_csv))"
    else
        log_warn "端口不在保护列表中: ${PORT_ARG}"
        return 0
    fi

    _rebuild_if_active
}

# ============================ 查看状态 ============================
do_status() {
    log_step "海外 IP 封禁状态"

    # IP 列表
    if [[ -f "$GEO_FILE" ]]; then
        local cnt mtime
        cnt=$(grep -cE '^[0-9]' "$GEO_FILE" || true)
        mtime=$(stat -c '%y' "$GEO_FILE" 2>/dev/null | cut -d. -f1)
        log_ok "IP 列表: ${GEO_FILE} (${cnt} 条, 更新于 ${mtime})"
    else
        log_warn "IP 列表不存在: ${GEO_FILE} (需 --fetch 或 --import)"
    fi

    # 自定义放行 IP
    if [[ -f "$ALLOW_FILE" ]] && grep -qE '^[0-9]' "$ALLOW_FILE" 2>/dev/null; then
        log_info "自定义放行 IP ($(grep -cE '^[0-9]' "$ALLOW_FILE") 条):"
        grep -E '^[0-9]' "$ALLOW_FILE" | sed 's/^/    /'
    else
        log_info "自定义放行 IP: (无, 文件: ${ALLOW_FILE})"
    fi

    # 保护端口
    log_info "保护端口: $(ports_csv) (UDP+TCP)"

    # ipset
    if ipset list "$IPSET_NAME" &>/dev/null 2>&1; then
        local scount
        scount=$(ipset list "$IPSET_NAME" | grep -c "^[0-9]" || true)
        log_ok "ipset ${IPSET_NAME}: ${scount} 条网段已加载"
    else
        log_info "ipset ${IPSET_NAME}: 未创建"
    fi

    # iptables 规则
    if iptables -S "$IPT_CHAIN" &>/dev/null 2>&1; then
        log_ok "iptables 链 ${IPT_CHAIN} 已启用:"
        iptables -L INPUT -n 2>/dev/null | grep "$IPT_CHAIN" | sed 's/^/    /'
        echo ""
        log_info "规则及命中统计:"
        iptables -L "$IPT_CHAIN" -n -v 2>/dev/null | sed 's/^/    /'
    else
        log_info "iptables 链 ${IPT_CHAIN}: 未启用"
    fi

    # systemd
    if systemctl is-enabled geo-block.service &>/dev/null 2>&1; then
        log_ok "开机自启: 已启用"
    else
        log_info "开机自启: 未启用"
    fi
}

# ============================ 主流程 ============================
main() {
    parse_args "$@"
    init_log "geo-block"

    case "$ACTION" in
        fetch)       do_fetch ;;
        import)      do_import ;;
        apply)       do_apply ;;
        restore)     do_restore ;;
        unblock)     do_unblock ;;
        status)      do_status ;;
        allow-ip)    do_allow_ip ;;
        remove-ip)   do_remove_ip ;;
        add-port)    do_add_port ;;
        remove-port) do_remove_port ;;
    esac

    echo ""
    show_log_path
}

main "$@"
