#!/bin/bash
###############################################################################
# gen-cert.sh
# 证书管理脚本（使用已有证书 / 生成自签 IP 证书 + 更新 Caddy 和 FreeSWITCH）
#
# 用法:
#   ./gen-cert.sh                    # 交互式
#   ./gen-cert.sh --use-existing /path/to/cert.pem /path/to/cert.key
#   ./gen-cert.sh --generate 10.160.4.88
#
###############################################################################
set -euo pipefail

# ============================ 加载共享库 ============================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

# ============================ 默认参数 ============================
ACTION=""
CERT_FILE=""
KEY_FILE=""
CERT_IP=""
CERT_NAME=""
DAYS="3650"

# 证书目录 (统一存放)
CERT_DIR="/data/config/cert"
FS_CERT_DIR="/data/config/fs/certs"
CADDYFILE="/data/config/caddy/Caddyfile"

# 临时工作目录
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

# ============================ 参数解析 ============================
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --use-existing)  ACTION="existing"; CERT_FILE="$2"; KEY_FILE="$3"; shift 3 ;;
            --generate)      ACTION="generate"; CERT_IP="$2"; shift 2 ;;
            --days)          DAYS="$2"; shift 2 ;;
            -h|--help)       grep '^#' "$0" | head -15; exit 0 ;;
            *) log_error "未知参数: $1"; exit 1 ;;
        esac
    done
}

# ============================ 交互式选择 ============================
interactive_choice() {
    if [[ -z "$ACTION" ]]; then
        echo ""
        echo -e "  ${BOLD}请选择证书来源:${NC}"
        echo ""
        echo -e "    ${CYAN}[1]${NC}  使用已有证书    ${DIM}(提供 .crt/.pem 和 .key 文件路径)${NC}"
        echo -e "    ${CYAN}[2]${NC}  生成自签 IP 证书 ${DIM}(内网环境，输入 IP 生成证书)${NC}"
        echo ""
        read -rp "$(echo -e "${BOLD}请输入序号 [默认 2]: ${NC}")" choice
        choice="${choice:-2}"

        case "$choice" in
            1)
                ACTION="existing"
                echo ""
                while true; do
                    read -rp "请输入证书文件路径 (.crt/.pem): " CERT_FILE
                    read -rp "请输入私钥文件路径 (.key): " KEY_FILE
                    if [[ -f "$CERT_FILE" ]] && [[ -f "$KEY_FILE" ]]; then
                        break
                    fi
                    log_warn "证书或私钥文件不存在，请重新输入 (Ctrl+C 退出)"
                    echo ""
                done
                ;;
            2)
                ACTION="generate"
                echo ""
                # 自动检测本机 IP 作为默认值
                local default_ip
                default_ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $NF; exit}' || echo "")
                read -rp "请输入证书绑定的 IP 地址 [默认 ${default_ip}]: " CERT_IP
                CERT_IP="${CERT_IP:-$default_ip}"
                if [[ -z "$CERT_IP" ]]; then
                    log_error "IP 地址不能为空"
                    exit 1
                fi
                ;;
            *)
                log_error "无效选择"
                exit 1
                ;;
        esac
    fi
}

# ============================ 确保目录存在 ============================
ensure_dirs() {
    mkdir -p "$CERT_DIR"
    mkdir -p "$FS_CERT_DIR"
}

# ============================ 使用已有证书 ============================
use_existing_cert() {
    log_step "使用已有证书"

    CERT_NAME=$(basename "$CERT_FILE" | sed 's/\.\(crt\|pem\)$//')

    log_info "证书文件: ${CERT_FILE}"
    log_info "私钥文件: ${KEY_FILE}"
    log_info "证书名称: ${CERT_NAME}"

    local dest_cert="${CERT_DIR}/${CERT_NAME}.crt"
    local dest_key="${CERT_DIR}/${CERT_NAME}.key"

    # 如果源文件和目标相同则跳过复制
    if [[ "$(readlink -f "$CERT_FILE")" != "$(readlink -f "$dest_cert")" ]]; then
        cp "$CERT_FILE" "$dest_cert"
    fi
    if [[ "$(readlink -f "$KEY_FILE")" != "$(readlink -f "$dest_key")" ]]; then
        cp "$KEY_FILE" "$dest_key"
    fi
    chmod 644 "$dest_cert"
    chmod 600 "$dest_key"

    log_ok "证书已复制到: ${CERT_DIR}/"
}

# ============================ 生成自签 IP 证书 ============================
generate_self_signed() {
    log_step "生成自签 IP 证书 (${CERT_IP})"

    if ! command -v openssl &>/dev/null; then
        log_error "openssl 未安装"
        apt-get install -y -qq openssl 2>/dev/null || true
        command -v openssl &>/dev/null || { log_error "无法安装 openssl"; exit 1; }
    fi

    CERT_NAME="$CERT_IP"

    local ca_key="${WORK_DIR}/ca.key"
    local ca_crt="${WORK_DIR}/ca.crt"
    local server_key="${WORK_DIR}/server.key"
    local server_csr="${WORK_DIR}/server.csr"
    local server_crt="${WORK_DIR}/server.crt"
    local san_cnf="${WORK_DIR}/san.cnf"

    # 1. 生成 CA 根证书
    log_info "生成 CA 根证书 ..."
    openssl genrsa -out "$ca_key" 2048 2>/dev/null
    openssl req -new -x509 -days "$DAYS" -key "$ca_key" -out "$ca_crt" \
        -subj "/C=CN/ST=Local/L=Local/O=CTI/CN=CTI-CA" 2>/dev/null

    # 2. 生成服务器私钥和 CSR
    log_info "生成服务器私钥 ..."
    openssl genrsa -out "$server_key" 2048 2>/dev/null
    openssl req -new -key "$server_key" -out "$server_csr" \
        -subj "/C=CN/ST=Local/L=Local/O=CTI/CN=${CERT_IP}" 2>/dev/null

    # 3. 生成 SAN 扩展配置 (支持 IP)
    cat > "$san_cnf" << EOF
[v3_req]
subjectAltName = @alt_names
[alt_names]
IP.1 = ${CERT_IP}
EOF

    # 4. 签发服务器证书
    log_info "签发服务器证书 (有效期 ${DAYS} 天) ..."
    openssl x509 -req -days "$DAYS" -in "$server_csr" \
        -CA "$ca_crt" -CAkey "$ca_key" -CAcreateserial \
        -out "$server_crt" -extfile "$san_cnf" -extensions v3_req 2>/dev/null

    # 5. 复制到证书目录
    local dest_cert="${CERT_DIR}/${CERT_NAME}.crt"
    local dest_key="${CERT_DIR}/${CERT_NAME}.key"

    cp "$server_crt" "$dest_cert"
    cp "$server_key" "$dest_key"
    cp "$ca_crt" "${CERT_DIR}/ca.crt"
    chmod 644 "$dest_cert" "${CERT_DIR}/ca.crt"
    chmod 600 "$dest_key"

    log_ok "自签证书已生成: ${CERT_DIR}/${CERT_NAME}.crt"

    # 显示证书信息
    log_info "证书信息:"
    openssl x509 -in "$dest_cert" -noout -subject -dates -ext subjectAltName 2>/dev/null | sed 's/^/    /'
}

# ============================ 生成 FreeSWITCH wss.pem ============================
generate_wss_pem() {
    log_step "生成 FreeSWITCH wss.pem"

    local cert_path="${CERT_DIR}/${CERT_NAME}.crt"
    local key_path="${CERT_DIR}/${CERT_NAME}.key"
    local wss_pem="${FS_CERT_DIR}/wss.pem"

    # 备份已有 wss.pem
    if [[ -f "$wss_pem" ]]; then
        cp "$wss_pem" "${wss_pem}.bak.$(date +%Y%m%d%H%M%S)"
        log_info "已备份 wss.pem"
    fi

    # wss.pem = 私钥 + 证书 (FreeSWITCH 要求合并格式)
    cat "$key_path" "$cert_path" > "$wss_pem"
    chmod 600 "$wss_pem"

    log_ok "wss.pem 已生成: ${wss_pem}"
    log_info "  格式: 私钥 + 证书 (PEM 合并)"
}

# ============================ 更新 Caddyfile ============================
update_caddyfile() {
    log_step "更新 Caddyfile 证书引用和站点地址"

    if [[ ! -f "$CADDYFILE" ]]; then
        log_warn "Caddyfile 不存在: ${CADDYFILE}，跳过"
        return 0
    fi

    # 备份
    cp "$CADDYFILE" "${CADDYFILE}.bak.$(date +%Y%m%d%H%M%S)"
    log_info "已备份 Caddyfile"

    local new_cert="${CERT_DIR}/${CERT_NAME}.crt"
    local new_key="${CERT_DIR}/${CERT_NAME}.key"

    # 1. 替换 tls 行中的证书路径 (匹配 .pem 或 .crt，不限目录)
    sed -i "/tls/s@[^ ]*\.\(pem\|crt\)@${new_cert}@g" "$CADDYFILE"
    # 2. 替换 tls 行中的私钥路径 (.key)
    sed -i "/tls/s@[^ ]*\.key@${new_key}@g" "$CADDYFILE"

    # 4. 替换站点地址中的域名 -> 证书名称 (IP 或域名)
    #    匹配: webrtcyc.95paas.com:port {  或  "https://webrtcyc.95paas.com:port"
    local old_domains
    old_domains=$(grep -oE '[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}:[0-9]+' "$CADDYFILE" 2>/dev/null | cut -d: -f1 | sort -u || true)
    for domain in $old_domains; do
        local count
        count=$(grep -c "$domain" "$CADDYFILE" 2>/dev/null || echo "0")
        if [[ "$domain" != "$CERT_NAME" ]] && [[ $count -gt 0 ]]; then
            sed -i "s|${domain}|${CERT_NAME}|g" "$CADDYFILE"
            log_info "  站点域名 ${domain} → ${CERT_NAME} (${count} 处)"
        fi
    done

    # 5. 替换站点地址中的旧 IP (非 127.0.0.1) -> 证书 IP
    #    只替换站点地址行 (行首 IP:port { 或 http://IP:port {)
    if [[ "$CERT_NAME" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        local old_ips
        old_ips=$(grep -oE '(https?://)?[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+' "$CADDYFILE" 2>/dev/null \
            | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | sort -u || true)
        for ip in $old_ips; do
            if [[ "$ip" != "127.0.0.1" ]] && [[ "$ip" != "$CERT_NAME" ]]; then
                local count
                count=$(grep -c "$ip" "$CADDYFILE" 2>/dev/null || echo "0")
                if [[ $count -gt 0 ]]; then
                    sed -i "s|${ip}|${CERT_NAME}|g" "$CADDYFILE"
                    log_info "  站点 IP ${ip} → ${CERT_NAME} (${count} 处)"
                fi
            fi
        done
    fi

    log_ok "Caddyfile 已更新"
    log_info "  证书路径: ${new_cert}"
    log_info "  私钥路径: ${new_key}"
    log_info "  站点地址: ${CERT_NAME}"

    # 显示更新后的站点地址和 tls 配置
    echo ""
    log_info "当前站点地址和 tls 配置:"
    grep -nE "^\s*(https?://)?[^[:space:]]+.*\{|tls " "$CADDYFILE" 2>/dev/null | sed 's/^/    /' || echo "    (无)"
}

# ============================ 汇总 ============================
show_summary() {
    log_step "证书配置完成"
    echo ""
    echo -e "  ${BOLD}证书部署位置:${NC}"
    print_line
    printf "    %-30s %s\n" "证书目录" "${CERT_DIR}/"
    printf "    %-30s %s\n" "服务器证书" "${CERT_DIR}/${CERT_NAME}.crt"
    printf "    %-30s %s\n" "服务器私钥" "${CERT_DIR}/${CERT_NAME}.key"
    printf "    %-30s %s\n" "CA 根证书" "${CERT_DIR}/ca.crt"
    printf "    %-30s %s\n" "FreeSWITCH wss.pem" "${FS_CERT_DIR}/wss.pem"
    printf "    %-30s %s\n" "Caddyfile" "${CADDYFILE}"
    print_line
    echo ""
    log_info "如需重启服务使证书生效:"
    echo "    docker restart caddy fs"
    echo ""
    show_log_path
}

# ============================ 主流程 ============================
main() {
    parse_args "$@"
    init_log "gen-cert"

    interactive_choice
    ensure_dirs

    if [[ "$ACTION" == "existing" ]]; then
        use_existing_cert
    elif [[ "$ACTION" == "generate" ]]; then
        generate_self_signed
    else
        log_error "未知操作: $ACTION"
        exit 1
    fi

    generate_wss_pem
    update_caddyfile
    show_summary
}

main "$@"
