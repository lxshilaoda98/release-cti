#!/bin/bash
###############################################################################
# deploy.sh
# Release CTI 自动化部署工具 — 交互式菜单入口
#
# 用法:
#   本地部署:   sudo ./deploy.sh
#   远程部署:   ./deploy.sh --remote
#
# 功能模块:
#   [1] 一键全量部署
#   [2] 环境安装    (Docker / Keepalived / 自签证书)
#   [3] 服务部署    (Docker Compose 部署 / 修改服务配置)
#   [4] 运维工具    (离线包准备 / 卸载管理 / sipmon / sngrep)
#
# 远程模式通过跳板机 SSH 连接目标服务器，自动推送脚本并执行。
# 连接配置见 config/remote.conf
#
###############################################################################
set -euo pipefail

# ============================ 路径 & 共享库 ============================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${SCRIPT_DIR}/scripts"
source "${SCRIPTS_DIR}/lib/common.sh"

# ============================ deploy.sh 专属工具函数 ============================

# 清屏
clear_screen() {
    echo -en "\033[2J\033[H"
}

# 绘制分隔线
print_line() {
    echo -e "${DIM}─────────────────────────────────────────────────────────${NC}"
}

# 打印标题
print_header() {
    clear_screen
    echo ""
    echo -e "${CYAN}╔═════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}          ${BOLD}Release CTI 自动化部署工具${NC}                        ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}          ${DIM}Interactive Deployment Console${NC}                  ${CYAN}║${NC}"
    echo -e "${CYAN}╚═════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

# 状态检测: 返回 ✓ 已安装 / ✗ 未安装
check_docker() {
    if command -v docker &>/dev/null; then
        local ver
        ver=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "?")
        echo -e "${GREEN}✓ 已安装 v${ver}${NC}"
    else
        echo -e "${RED}✗ 未安装${NC}"
    fi
}

check_compose() {
    if docker compose version &>/dev/null 2>&1; then
        local ver
        ver=$(docker compose version 2>/dev/null | grep -oE 'v[0-9.]+' || echo "?")
        echo -e "${GREEN}✓ 已安装 ${ver}${NC}"
    elif command -v docker-compose &>/dev/null 2>&1; then
        echo -e "${GREEN}✓ 已安装 (standalone)${NC}"
    else
        echo -e "${RED}✗ 未安装${NC}"
    fi
}

check_keepalived() {
    if command -v keepalived &>/dev/null; then
        local ver
        ver=$(keepalived --version 2>/dev/null | head -1 | awk '{print $2}' || echo "?")
        echo -e "${GREEN}✓ 已安装 v${ver}${NC}"
    else
        echo -e "${RED}✗ 未安装${NC}"
    fi
}

check_cert() {
    local cert_dir="/data/config/cert"
    local fs_wss="/data/config/fs/certs/wss.pem"
    local has_caddy=false has_wss=false

    if [[ -d "$cert_dir" ]]; then
        if ls "$cert_dir"/*.crt &>/dev/null 2>&1 || ls "$cert_dir"/*.pem &>/dev/null 2>&1; then
            has_caddy=true
        fi
    fi
    [[ -f "$fs_wss" ]] && has_wss=true

    if [[ "$has_caddy" == true && "$has_wss" == true ]]; then
        echo -e "${GREEN}✓ 已生成${NC}"
    elif [[ "$has_caddy" == true || "$has_wss" == true ]]; then
        echo -e "${YELLOW}~ 部分生成${NC}"
    else
        echo -e "${RED}✗ 未生成${NC}"
    fi
}

check_compose_deployed() {
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q .; then
        local count
        count=$(docker ps -q 2>/dev/null | wc -l | tr -d ' ')
        echo -e "${GREEN}✓ 运行中 (${count} 个容器)${NC}"
    else
        echo -e "${RED}✗ 未部署${NC}"
    fi
}

# 状态检测: sipmon 抓包工具
check_sipmon() {
    if command -v sipmon &>/dev/null || [[ -x /usr/local/bin/sipmon ]]; then
        local ver
        ver=$(sipmon --version 2>/dev/null | head -1 | awk '{print $NF}' || echo "?")
        echo -e "${GREEN}✓ 已安装 ${ver}${NC}"
    else
        echo -e "${RED}✗ 未安装${NC}"
    fi
}

# 状态检测: sngrep 抓包工具
check_sngrep() {
    if command -v sngrep &>/dev/null; then
        local ver
        ver=$(sngrep -V 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9.]+' || echo "?")
        echo -e "${GREEN}✓ 已安装 ${ver}${NC}"
    else
        echo -e "${RED}✗ 未安装${NC}"
    fi
}

# 确认提示: 传参为提示语, 返回 0=是 1=否
confirm() {
    local prompt="$1"
    read -rp "$(echo -e "${YELLOW}${prompt} [Y/n]: ${NC}")" ans
    [[ "$ans" =~ ^[Yy]$ || -z "$ans" ]]
}

# 等待用户按回车继续
pause_enter() {
    echo ""
    read -rp "$(echo -e "${DIM}按回车键返回主菜单...${NC}")"
}

# ============================ 远程部署 ============================
run_remote_deploy() {
    local conf_file="${SCRIPT_DIR}/config/remote.conf"
    if [[ ! -f "$conf_file" ]]; then
        echo -e "${RED}[ERROR]${NC} 远程配置文件不存在: $conf_file"
        echo "请参考 config/remote.conf 创建配置"
        exit 1
    fi
    source "$conf_file"

    if ! command -v sshpass &>/dev/null; then
        echo -e "${RED}[ERROR]${NC} sshpass 未安装"
        echo "  macOS:   brew install sshpass"
        echo "  Ubuntu:  apt install sshpass"
        exit 1
    fi

    echo ""
    echo -e "${CYAN}=== 远程部署模式 ===${NC}"
    echo "  跳板机:  ${JUMP_USER}@${JUMP_HOST}:${JUMP_PORT}"
    echo "  目标机:  ${TARGET_USER}@${TARGET_HOST}:${TARGET_PORT}"
    echo "  远程目录: ${REMOTE_DIR}"
    echo ""

    # 创建临时密码文件
    ssh_init_passfiles "$JUMP_PASS" "$TARGET_PASS"
    trap ssh_cleanup_passfiles EXIT

    # 测试连接
    log_info "测试 SSH 连接 ..."
    if ! ssh_test_connection; then
        log_error "无法连接到目标服务器，请检查 config/remote.conf"
        ssh_cleanup_passfiles
        exit 1
    fi
    log_ok "SSH 连接成功"

    # 获取远程服务器信息
    local remote_info
    remote_info=$(ssh_remote_exec "hostname; grep PRETTY_NAME /etc/os-release 2>/dev/null; uname -m; nproc; free -h | head -2 | tail -1" 2>/dev/null || true)
    log_info "远程服务器信息:"
    echo "$remote_info" | sed 's/^/    /'
    echo ""

    # 推送脚本到远程
    log_info "推送部署脚本到远程服务器 ..."
    ssh_remote_exec "mkdir -p ${REMOTE_DIR}" 2>/dev/null || true
    ssh_remote_scp -r "${SCRIPT_DIR}/scripts" "${SCRIPT_DIR}/config" "${SCRIPT_DIR}/deploy.sh" \
        "${TARGET_USER}@${TARGET_HOST}:${REMOTE_DIR}/" 2>/dev/null

    log_ok "脚本推送完成"

    # 远程执行 deploy.sh (分配 TTY 以支持交互式菜单)
    echo ""
    log_info "启动远程交互式部署 ..."
    echo -e "${DIM}    (按 Ctrl+C 可中断远程会话)${NC}"
    echo ""

    sshpass -f "$_SSH_TARGET_PASS_FILE" ssh -tt \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ProxyCommand="$(_build_proxy_cmd)" \
        -p "${TARGET_PORT}" \
        "${TARGET_USER}@${TARGET_HOST}" \
        "cd ${REMOTE_DIR} && bash deploy.sh" || true

    echo ""
    log_info "远程会话已结束"
    ssh_cleanup_passfiles
}

# ============================ 主菜单 ============================
main_menu() {
    while true; do
        print_header

        echo -e "  ${BOLD}当前环境状态:${NC}"
        print_line
        printf "    %-20s %s\n" "Docker" "$(check_docker)"
        printf "    %-20s %s\n" "Docker Compose" "$(check_compose)"
        printf "    %-20s %s\n" "Keepalived" "$(check_keepalived)"
        printf "    %-20s %s\n" "自签证书" "$(check_cert)"
        printf "    %-20s %s\n" "Compose 服务" "$(check_compose_deployed)"
        printf "    %-20s %s\n" "sipmon 抓包工具" "$(check_sipmon)"
        printf "    %-20s %s\n" "sngrep 抓包工具" "$(check_sngrep)"
        print_line

        echo ""
        echo -e "  ${BOLD}请选择要执行的操作:${NC}"
        echo ""
        echo -e "    ${CYAN}[1]${NC}  一键全量部署    ${DIM}(按顺序执行全部部署步骤)${NC}"
        echo -e "    ${CYAN}[2]${NC}  环境安装        ${DIM}(Docker / Keepalived / 证书)${NC}"
        echo -e "    ${CYAN}[3]${NC}  服务部署        ${DIM}(Compose 部署 / 修改服务配置)${NC}"
        echo -e "    ${CYAN}[4]${NC}  运维工具        ${DIM}(离线包准备 / 卸载管理 / sipmon / sngrep)${NC}"
        echo ""
        echo -e "    ${DIM}[0] 退出 / [ESC] 返回${NC}"
        echo ""

        read_choice "请输入序号: " ""
        choice="$REPLY"

        case "$choice" in
            1) menu_full_deploy ;;
            2) menu_env_install ;;
            3) menu_service_deploy ;;
            4) menu_ops_tools ;;
            0)
                echo ""
                log_info "再见！"
                show_log_path
                exit 0
                ;;
            *) log_warn "无效输入，请重新选择"; sleep 1 ;;
        esac
    done
}

# ============================ 二级菜单: 环境安装 ============================
menu_env_install() {
    while true; do
        print_header
        echo -e "  ${BOLD}环境安装${NC}"
        echo -e "  ${DIM}Docker:$(check_docker) | Keepalived:$(check_keepalived)${NC}"
        print_line
        echo ""
        echo -e "  请选择操作:"
        echo ""
        echo -e "    ${CYAN}[1]${NC}  Docker 安装            ${DIM}(在线/离线安装 Docker CE + Compose)${NC}"
        echo -e "    ${CYAN}[2]${NC}  Keepalived 安装        ${DIM}(标准/CTI 模式 HA 配置)${NC}"
        echo -e "    ${CYAN}[3]${NC}  自签证书生成          ${DIM}(使用已有证书 / 生成自签 IP 证书)${NC}"
        echo ""
        echo -e "    ${DIM}[0] 返回 / [ESC] 返回${NC}"
        echo ""

        read_choice "请输入序号: " ""
        choice="$REPLY"

        case "$choice" in
            1) menu_docker ;;
            2) menu_keepalived ;;
            3) menu_cert ;;
            0) return ;;
            *) log_warn "无效输入，请重新选择"; sleep 1 ;;
        esac
    done
}

# ============================ 二级菜单: 服务部署 ============================
menu_service_deploy() {
    while true; do
        print_header
        echo -e "  ${BOLD}服务部署${NC}"
        echo -e "  ${DIM}Compose 服务:$(check_compose_deployed)${NC}"
        print_line
        echo ""
        echo -e "  请选择操作:"
        echo ""
        echo -e "    ${CYAN}[1]${NC}  Docker Compose 部署    ${DIM}(启动/停止/重启/日志/手动操作)${NC}"
        echo -e "    ${CYAN}[2]${NC}  修改服务配置          ${DIM}(集中修改 DB/Redis/ESL/VIP 配置)${NC}"
        echo ""
        echo -e "    ${DIM}[0] 返回 / [ESC] 返回${NC}"
        echo ""

        read_choice "请输入序号: " ""
        choice="$REPLY"

        case "$choice" in
            1) menu_compose ;;
            2) menu_update_config ;;
            0) return ;;
            *) log_warn "无效输入，请重新选择"; sleep 1 ;;
        esac
    done
}

# ============================ 二级菜单: 运维工具 ============================
menu_ops_tools() {
    while true; do
        print_header
        echo -e "  ${BOLD}运维工具${NC}"
        print_line
        echo ""
        echo -e "  请选择操作:"
        echo ""
        echo -e "    ${CYAN}[1]${NC}  离线包准备            ${DIM}(下载 deb 包 + 导出镜像 + sipmon 二进制)${NC}"
        echo -e "    ${CYAN}[2]${NC}  卸载管理              ${DIM}(分组件卸载 / 一键全部卸载)${NC}"
        echo -e "    ${CYAN}[3]${NC}  SIP 抓包工具 (sipmon)  ${DIM}(在线/离线安装)${NC}"
        echo -e "    ${CYAN}[4]${NC}  SIP 抓包工具 (sngrep)  ${DIM}(在线/离线安装)${NC}"
        echo ""
        echo -e "    ${DIM}[0] 返回 / [ESC] 返回${NC}"
        echo ""

        read_choice "请输入序号: " ""
        choice="$REPLY"

        case "$choice" in
            1) menu_offline_prepare ;;
            2) menu_uninstall ;;
            3) menu_sipmon ;;
            4) menu_sngrep ;;
            0) return ;;
            *) log_warn "无效输入，请重新选择"; sleep 1 ;;
        esac
    done
}

# ============================ Docker 子菜单 ============================
menu_docker() {
    while true; do
        print_header
        echo -e "  ${BOLD}Docker 安装${NC}"
        echo -e "  ${DIM}当前状态:$(check_docker) | Compose:$(check_compose)${NC}"
        print_line
        echo ""
        echo -e "  请选择安装方式:"
        echo ""
        echo -e "    ${CYAN}[1]${NC}  离线安装    ${DIM}(使用本地 .deb 包，无需联网)${NC}"
        echo -e "    ${CYAN}[2]${NC}  在线安装    ${DIM}(国内镜像源下载安装)${NC}"
        echo ""
        echo -e "    ${DIM}[0] 返回 / [ESC] 返回${NC}"
        echo ""

        read_choice "请输入序号: " ""
        choice="$REPLY"

        case "$choice" in
            1)
                echo ""
                if confirm "确认执行 Docker 离线安装？"; then
                    bash "${SCRIPTS_DIR}/install-docker.sh" --offline
                    pause_enter
                fi
                return
                ;;
            2)
                echo ""
                if confirm "确认执行 Docker 在线安装？"; then
                    bash "${SCRIPTS_DIR}/install-docker.sh" --online
                    pause_enter
                fi
                return
                ;;
            0) return ;;
            *) log_warn "无效输入"; sleep 1 ;;
        esac
    done
}

# ============================ Keepalived 子菜单 ============================
menu_keepalived() {
    while true; do
        print_header
        echo -e "  ${BOLD}Keepalived 管理${NC}"
        echo -e "  ${DIM}当前状态:$(check_keepalived)${NC}"
        print_line
        echo ""
        echo -e "  请选择操作:"
        echo ""
        echo -e "    ${CYAN}[1]${NC}  离线安装    ${DIM}(使用本地 .deb 包)${NC}"
        echo -e "    ${CYAN}[2]${NC}  在线安装    ${DIM}(国内镜像源下载安装)${NC}"
        echo -e "    ${CYAN}[3]${NC}  仅重新配置  ${DIM}(跳过安装，只更新 VIP/角色等)${NC}"
        echo -e "    ${CYAN}[4]${NC}  查看状态    ${DIM}(显示 keepalived 运行状态和配置)${NC}"
        echo ""
        echo -e "    ${DIM}[0] 返回 / [ESC] 返回${NC}"
        echo ""

        read_choice "请输入序号: " ""
        choice="$REPLY"

        case "$choice" in
            1)
                echo ""
                if confirm "确认执行 Keepalived 离线安装？"; then
                    bash "${SCRIPTS_DIR}/install-keepalived.sh" --offline
                    pause_enter
                fi
                return
                ;;
            2)
                echo ""
                if confirm "确认执行 Keepalived 在线安装？"; then
                    bash "${SCRIPTS_DIR}/install-keepalived.sh" --online
                    pause_enter
                fi
                return
                ;;
            3)
                echo ""
                if confirm "确认仅重新配置 Keepalived？"; then
                    bash "${SCRIPTS_DIR}/install-keepalived.sh" --reconfig
                    pause_enter
                fi
                return
                ;;
            4)
                echo ""
                bash "${SCRIPTS_DIR}/install-keepalived.sh" --status
                pause_enter
                return
                ;;
            0) return ;;
            *) log_warn "无效输入"; sleep 1 ;;
        esac
    done
}

# ============================ 证书管理子菜单 ============================
menu_cert() {
    while true; do
        print_header
        echo -e "  ${BOLD}证书管理${NC}"
        echo -e "  ${DIM}当前状态:$(check_cert)${NC}"
        print_line
        echo ""
        echo -e "  请选择操作:"
        echo ""
        echo -e "    ${CYAN}[1]${NC}  使用已有证书    ${DIM}(提供 .crt/.pem 和 .key 文件)${NC}"
        echo -e "    ${CYAN}[2]${NC}  生成自签 IP 证书 ${DIM}(内网环境，输入 IP 生成)${NC}"
        echo -e "    ${CYAN}[3]${NC}  查看当前证书    ${DIM}(显示证书文件和路径)${NC}"
        echo ""
        echo -e "    ${DIM}[0] 返回 / [ESC] 返回${NC}"
        echo ""

        read_choice "请输入序号: " ""
        choice="$REPLY"

        case "$choice" in
            1)
                echo ""
                if confirm "使用已有证书？需要提供证书和私钥文件路径"; then
                    bash "${SCRIPTS_DIR}/gen-cert.sh"
                    pause_enter
                fi
                return
                ;;
            2)
                echo ""
                if confirm "生成自签 IP 证书 (10年有效期)？"; then
                    bash "${SCRIPTS_DIR}/gen-cert.sh"
                    pause_enter
                fi
                return
                ;;
            3)
                echo ""
                log_info "证书目录: /data/config/cert/"
                ls -la /data/config/cert/ 2>/dev/null | sed 's/^/    /' || echo "    (目录不存在)"
                echo ""
                log_info "FreeSWITCH 证书目录: /data/config/fs/certs/"
                ls -la /data/config/fs/certs/ 2>/dev/null | sed 's/^/    /' || echo "    (目录不存在)"
                echo ""
                log_info "Caddyfile 中的 tls 引用:"
                grep -n "tls " /data/config/caddy/Caddyfile 2>/dev/null | sed 's/^/    /' || echo "    (无 tls 配置)"
                pause_enter
                return
                ;;
            0) return ;;
            *) log_warn "无效输入"; sleep 1 ;;
        esac
    done
}

# ============================ Docker Compose 部署子菜单 ============================
menu_compose() {
    while true; do
        print_header
        echo -e "  ${BOLD}Docker Compose 部署${NC}"
        echo -e "  ${DIM}当前状态:$(check_compose_deployed)${NC}"
        print_line
        echo ""
        echo -e "  请选择分类:"
        echo ""
        echo -e "    ${CYAN}[1]${NC}  服务管理    ${DIM}(启动 / 停止 / 重启)${NC}"
        echo -e "    ${CYAN}[2]${NC}  状态查看    ${DIM}(状态 / 日志 / 健康检查)${NC}"
        echo -e "    ${CYAN}[3]${NC}  手动操作    ${DIM}(初始化模板 / 拉取镜像 / 解压配置)${NC}"
        echo ""
        echo -e "    ${DIM}[0] 返回 / [ESC] 返回${NC}"
        echo ""

        read_choice "请输入序号: " ""
        choice="$REPLY"

        case "$choice" in
            1) menu_compose_service ;;
            2) menu_compose_status ;;
            3) menu_compose_manual ;;
            0) return ;;
            *) log_warn "无效输入"; sleep 1 ;;
        esac
    done
}

# ============================ Compose 二级菜单: 服务管理 ============================
menu_compose_service() {
    while true; do
        print_header
        echo -e "  ${BOLD}Docker Compose 部署 > 服务管理${NC}"
        echo -e "  ${DIM}当前状态:$(check_compose_deployed)${NC}"
        print_line
        echo ""
        echo -e "  请选择操作:"
        echo ""
        echo -e "    ${CYAN}[1]${NC}  部署/启动服务    ${DIM}(docker compose up -d)${NC}"
        echo -e "    ${CYAN}[2]${NC}  停止服务          ${DIM}(docker compose down)${NC}"
        echo -e "    ${CYAN}[3]${NC}  停止容器          ${DIM}(docker compose stop, 不删除容器)${NC}"
        echo -e "    ${CYAN}[4]${NC}  重启服务          ${DIM}(docker compose restart)${NC}"
        echo ""
        echo -e "    ${DIM}[0] 返回 / [ESC] 返回${NC}"
        echo ""

        read_choice "请输入序号: " ""
        choice="$REPLY"

        case "$choice" in
            1)
                echo ""
                if confirm "确认部署/启动服务？"; then
                    if [[ -f "${SCRIPTS_DIR}/deploy-compose.sh" ]]; then
                        bash "${SCRIPTS_DIR}/deploy-compose.sh" --up
                    else
                        log_warn "deploy-compose.sh 尚未实现"
                    fi
                    pause_enter
                fi
                return
                ;;
            2)
                echo ""
                if confirm "确认停止所有服务 (down, 删除容器)？"; then
                    bash "${SCRIPTS_DIR}/deploy-compose.sh" --down
                    pause_enter
                fi
                return
                ;;
            3)
                echo ""
                if confirm "确认停止容器 (stop, 不删除)？"; then
                    bash "${SCRIPTS_DIR}/deploy-compose.sh" --stop
                    pause_enter
                fi
                return
                ;;
            4)
                echo ""
                if confirm "确认重启所有服务？"; then
                    bash "${SCRIPTS_DIR}/deploy-compose.sh" --restart
                    pause_enter
                fi
                return
                ;;
            0) return ;;
            *) log_warn "无效输入"; sleep 1 ;;
        esac
    done
}

# ============================ Compose 二级菜单: 状态查看 ============================
menu_compose_status() {
    while true; do
        print_header
        echo -e "  ${BOLD}Docker Compose 部署 > 状态查看${NC}"
        echo -e "  ${DIM}当前状态:$(check_compose_deployed)${NC}"
        print_line
        echo ""
        echo -e "  请选择操作:"
        echo ""
        echo -e "    ${CYAN}[1]${NC}  查看服务状态    ${DIM}(docker compose ps)${NC}"
        echo -e "    ${CYAN}[2]${NC}  查看服务日志    ${DIM}(docker compose logs)${NC}"
        echo -e "    ${CYAN}[3]${NC}  容器健康检查    ${DIM}(检查容器健康状态)${NC}"
        echo ""
        echo -e "    ${DIM}[0] 返回 / [ESC] 返回${NC}"
        echo ""

        read_choice "请输入序号: " ""
        choice="$REPLY"

        case "$choice" in
            1)
                echo ""
                bash "${SCRIPTS_DIR}/deploy-compose.sh" --status
                pause_enter
                return
                ;;
            2)
                echo ""
                read -rp "输入服务名 (留空查看全部): " svc
                if [[ -n "$svc" ]]; then
                    bash "${SCRIPTS_DIR}/deploy-compose.sh" --logs
                    docker compose -f /data/docker-compose.yml logs --tail 50 "$svc" 2>/dev/null || \
                    docker-compose -f /data/docker-compose.yml logs --tail 50 "$svc" 2>/dev/null || true
                else
                    bash "${SCRIPTS_DIR}/deploy-compose.sh" --logs
                fi
                pause_enter
                return
                ;;
            3)
                echo ""
                check_container_health 60 /data/docker-compose.yml || true
                pause_enter
                return
                ;;
            0) return ;;
            *) log_warn "无效输入"; sleep 1 ;;
        esac
    done
}

# ============================ Compose 二级菜单: 手动操作 ============================
menu_compose_manual() {
    while true; do
        print_header
        echo -e "  ${BOLD}Docker Compose 部署 > 手动操作${NC}"
        echo -e "  ${DIM}部署/启动服务时会自动检查, 一般无需手动执行${NC}"
        print_line
        echo ""
        echo -e "  请选择操作:"
        echo ""
        echo -e "    ${CYAN}[1]${NC}  初始化模板    ${DIM}(从模板生成 docker-compose.yml)${NC}"
        echo -e "    ${CYAN}[2]${NC}  拉取镜像      ${DIM}(docker compose pull)${NC}"
        echo -e "    ${CYAN}[3]${NC}  解压配置文件  ${DIM}(解压 config.zip 到 /data/config)${NC}"
        echo ""
        echo -e "    ${DIM}[0] 返回 / [ESC] 返回${NC}"
        echo ""

        read_choice "请输入序号: " ""
        choice="$REPLY"

        case "$choice" in
            1)
                echo ""
                bash "${SCRIPTS_DIR}/deploy-compose.sh" --init
                pause_enter
                return
                ;;
            2)
                echo ""
                if confirm "确认拉取所有镜像？"; then
                    bash "${SCRIPTS_DIR}/deploy-compose.sh" --pull
                    pause_enter
                fi
                return
                ;;
            3)
                echo ""
                if confirm "确认解压 config.zip 到 /data/config？"; then
                    bash "${SCRIPTS_DIR}/deploy-compose.sh" --extract-config
                    pause_enter
                fi
                return
                ;;
            0) return ;;
            *) log_warn "无效输入"; sleep 1 ;;
        esac
    done
}

# ============================ 一键全量部署 ============================
menu_full_deploy() {
    print_header
    echo -e "  ${BOLD}一键全量部署${NC}"
    print_line
    echo ""
    echo -e "  将按顺序执行以下步骤:"
    echo -e "    ${DIM}1. Docker 安装${NC}"
    echo -e "    ${DIM}2. Keepalived 安装${NC}"
    echo -e "    ${DIM}3. 自签证书生成${NC}"
    echo -e "    ${DIM}4. Docker Compose 部署${NC}"
    echo -e "    ${DIM}5. 容器健康检查${NC}"
    echo ""

    if ! confirm "确认执行全量部署？(任意步骤失败将中止)"; then
        return
    fi

    # 选择在线/离线
    echo ""
    echo -e "  请选择安装模式:"
    echo -e "    ${CYAN}[1]${NC}  离线"
    echo -e "    ${CYAN}[2]${NC}  在线"
    read_choice "请输入序号: " ""
    mode_choice="$REPLY"

    local mode_flag
    case "$mode_choice" in
        1) mode_flag="--offline" ;;
        2) mode_flag="--online" ;;
        *) log_warn "无效选择，取消全量部署"; pause_enter; return ;;
    esac

    # 全量部署前备份
    log_step "全量部署前备份"
    backup_before_deploy "before-full-deploy" || true

    # 磁盘空间预检
    check_disk_space /data 20 || { log_error "磁盘空间不足，中止部署"; pause_enter; return; }

    echo ""
    print_line
    log_info "步骤 1/5: Docker 安装"
    print_line
    bash "${SCRIPTS_DIR}/install-docker.sh" "$mode_flag"

    echo ""
    print_line
    log_info "步骤 2/5: Keepalived 安装"
    print_line
    if [[ -f "${SCRIPTS_DIR}/install-keepalived.sh" ]]; then
        bash "${SCRIPTS_DIR}/install-keepalived.sh" "$mode_flag"
    else
        log_warn "install-keepalived.sh 尚未实现，跳过"
    fi

    echo ""
    print_line
    log_info "步骤 3/5: 自签证书生成"
    print_line
    if [[ -f "${SCRIPTS_DIR}/gen-cert.sh" ]]; then
        bash "${SCRIPTS_DIR}/gen-cert.sh"
    else
        log_warn "gen-cert.sh 尚未实现，跳过"
    fi

    echo ""
    print_line
    log_info "步骤 4/5: Docker Compose 部署"
    print_line
    if [[ -f "${SCRIPTS_DIR}/deploy-compose.sh" ]]; then
        bash "${SCRIPTS_DIR}/deploy-compose.sh" --up
    else
        log_warn "deploy-compose.sh 尚未实现，跳过"
    fi

    echo ""
    print_line
    log_info "步骤 5/5: 容器健康检查"
    print_line
    check_container_health 60 /data/docker-compose.yml || true

    echo ""
    print_line
    log_ok "全量部署流程完成！"
    show_log_path
    pause_enter
}

# ============================ 卸载管理子菜单 ============================
menu_uninstall() {
    while true; do
        print_header
        echo -e "  ${BOLD}卸载管理${NC}"
        echo -e "  ${RED}⚠️  卸载操作不可逆，请谨慎选择${NC}"
        print_line
        echo ""
        echo -e "  请选择要卸载的组件:"
        echo ""
        echo -e "    ${CYAN}[1]${NC}  卸载 Docker           ${DIM}(停止服务 + 删除包)${NC}"
        echo -e "    ${CYAN}[2]${NC}  卸载 Keepalived       ${DIM}(停止服务 + 删除包)${NC}"
        echo -e "    ${CYAN}[3]${NC}  删除自签证书          ${DIM}(删除 cert 文件)${NC}"
        echo -e "    ${CYAN}[4]${NC}  停止 Compose 服务     ${DIM}(docker compose down)${NC}"
        echo -e "    ${CYAN}[5]${NC}  一键全部卸载          ${DIM}(卸载全部组件 + 清理数据)${NC}"
        echo ""
        echo -e "    ${DIM}[0] 返回 / [ESC] 返回${NC}"
        echo ""

        read_choice "请输入序号: " ""
        choice="$REPLY"

        case "$choice" in
            1) uninstall_docker_menu; return ;;
            2) uninstall_keepalived_menu; return ;;
            3) uninstall_cert_menu; return ;;
            4) uninstall_compose_menu; return ;;
            5) uninstall_all_menu; return ;;
            0) return ;;
            *) log_warn "无效输入"; sleep 1 ;;
        esac
    done
}

# ----- Docker 卸载子菜单 -----
uninstall_docker_menu() {
    print_header
    echo -e "  ${BOLD}卸载 Docker${NC}"
    echo -e "  ${DIM}当前状态:$(check_docker)${NC}"
    print_line
    echo ""
    echo -e "  请选择卸载方式:"
    echo ""
    echo -e "    ${CYAN}[1]${NC}  仅卸载软件          ${DIM}(保留数据目录和镜像)${NC}"
    echo -e "    ${CYAN}[2]${NC}  卸载并清理镜像      ${DIM}(删除镜像和容器，保留 volumes)${NC}"
    echo -e "    ${CYAN}[3]${NC}  彻底卸载            ${DIM}(删除全部数据，不可恢复)${NC}"
    echo ""
    echo -e "    ${DIM}[0] 返回 / [ESC] 返回${NC}"
    echo ""

    read_choice "请输入序号: " ""
    choice="$REPLY"

    local flag=""
    local confirm_msg=""
    case "$choice" in
        1) flag=""; confirm_msg="确认卸载 Docker（保留数据）？" ;;
        2) flag="--purge"; confirm_msg="确认卸载 Docker 并清理镜像？" ;;
        3) flag="--purge --clean-images"; confirm_msg="⚠️ 确认彻底卸载 Docker？全部数据将被删除！" ;;
        0) return ;;
        *) log_warn "无效输入"; sleep 1; return ;;
    esac

    echo ""
    if [[ "$choice" == "3" ]]; then
        read -rp "$(echo -e "${RED}${confirm_msg} 输入 yes 确认: ${NC}")" ans
        [[ "$ans" == "yes" ]] || { log_info "已取消"; pause_enter; return; }
    else
        confirm "$confirm_msg" || { log_info "已取消"; pause_enter; return; }
    fi

    bash "${SCRIPTS_DIR}/uninstall-docker.sh" $flag
    pause_enter
}

# ----- Keepalived 卸载 -----
uninstall_keepalived_menu() {
    print_header
    echo -e "  ${BOLD}卸载 Keepalived${NC}"
    echo -e "  ${DIM}当前状态:$(check_keepalived)${NC}"
    print_line
    echo ""

    if ! command -v keepalived &>/dev/null; then
        log_info "Keepalived 未安装，无需卸载"
        pause_enter
        return
    fi

    if confirm "确认卸载 Keepalived？"; then
        echo ""
        log_info "停止 keepalived 服务 ..."
        systemctl stop keepalived 2>/dev/null || true
        systemctl disable keepalived 2>/dev/null || true

        log_info "卸载软件包 ..."
        apt-get remove -y -qq keepalived 2>/dev/null || dpkg -r keepalived 2>/dev/null || true
        apt-get autoremove -y -qq 2>/dev/null || true

        if [[ -f /etc/keepalived/keepalived.conf ]]; then
            rm -rf /etc/keepalived/
            log_info "已删除 /etc/keepalived/"
        fi

        systemctl daemon-reload 2>/dev/null || true
        log_ok "Keepalived 卸载完成"
    fi
    pause_enter
}

# ----- 证书删除 -----
uninstall_cert_menu() {
    print_header
    echo -e "  ${BOLD}删除自签证书${NC}"
    echo -e "  ${DIM}当前状态:$(check_cert)${NC}"
    print_line
    echo ""

    local cert_dir="/data/config/cert"
    if [[ ! -d "$cert_dir" ]]; then
        log_info "证书目录不存在: $cert_dir"
        pause_enter
        return
    fi

    echo -e "  将删除以下文件:"
    find "$cert_dir" -type f 2>/dev/null | sed 's/^/    /'
    echo ""

    if confirm "确认删除所有证书文件？"; then
        rm -rf "$cert_dir"
        log_ok "证书已删除: $cert_dir"
    fi
    pause_enter
}

# ----- Compose 服务停止 -----
uninstall_compose_menu() {
    print_header
    echo -e "  ${BOLD}停止并清理 Compose 服务${NC}"
    echo -e "  ${DIM}当前状态:$(check_compose_deployed)${NC}"
    print_line
    echo ""

    if ! docker ps -q 2>/dev/null | grep -q .; then
        log_info "没有运行中的容器"
        pause_enter
        return
    fi

    echo -e "  当前运行中的容器:"
    docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}' 2>/dev/null | sed 's/^/    /'
    echo ""

    echo -e "  请选择操作:"
    echo -e "    ${CYAN}[1]${NC}  停止服务      ${DIM}(docker compose down，保留容器)${NC}"
    echo -e "    ${CYAN}[2]${NC}  停止并删除    ${DIM}(docker compose down --volumes)${NC}"
    echo -e "    ${DIM}[0]  返回${NC}"
    echo ""

    read_choice "请输入序号: " ""
    choice="$REPLY"

    case "$choice" in
        1)
            if confirm "确认停止所有服务？"; then
                echo ""
                if [[ -f "${SCRIPTS_DIR}/deploy-compose.sh" ]]; then
                    bash "${SCRIPTS_DIR}/deploy-compose.sh" --down
                else
                    docker compose -f /data/docker-compose.yml down 2>/dev/null || \
                    docker-compose -f /data/docker-compose.yml down 2>/dev/null || \
                    { log_warn "未找到 docker-compose.yml"; }
                fi
                log_ok "服务已停止"
            fi
            ;;
        2)
            echo ""
            read -rp "$(echo -e "${RED}⚠️ 确认停止并删除所有容器和 volumes？输入 yes: ${NC}")" ans
            if [[ "$ans" == "yes" ]]; then
                docker compose -f /data/docker-compose.yml down --volumes 2>/dev/null || \
                docker-compose -f /data/docker-compose.yml down --volumes 2>/dev/null || \
                { log_warn "未找到 docker-compose.yml"; }
                log_ok "容器和 volumes 已删除"
            fi
            ;;
        0) ;;
        *) log_warn "无效输入"; sleep 1 ;;
    esac
    pause_enter
}

# ----- 一键全部卸载 -----
uninstall_all_menu() {
    print_header
    echo -e "  ${BOLD}一键全部卸载${NC}"
    echo -e "  ${RED}⚠️  此操作将卸载所有组件并清理数据，不可恢复！${NC}"
    print_line
    echo ""
    echo -e "  将执行以下操作:"
    echo -e "    ${DIM}1. 停止并删除 Compose 服务 (含 volumes)${NC}"
    echo -e "    ${DIM}2. 卸载 Keepalived${NC}"
    echo -e "    ${DIM}3. 删除自签证书${NC}"
    echo -e "    ${DIM}4. 彻底卸载 Docker (含全部数据)${NC}"
    echo ""

    read -rp "$(echo -e "${RED}确认全部卸载？输入 yes 继续: ${NC}")" ans
    [[ "$ans" == "yes" ]] || { log_info "已取消"; pause_enter; return; }

    echo ""
    log_info "开始执行全部卸载 ..."

    # 卸载前备份配置 (仅备份配置，不备份数据)
    backup_before_deploy "before-uninstall-all" || true

    echo ""
    print_line
    log_info "步骤 1/4: 停止 Compose 服务"
    print_line
    docker compose -f /data/docker-compose.yml down --volumes 2>/dev/null || \
    docker-compose -f /data/docker-compose.yml down --volumes 2>/dev/null || \
    log_warn "未找到 docker-compose.yml，跳过"

    echo ""
    print_line
    log_info "步骤 2/4: 卸载 Keepalived"
    print_line
    if command -v keepalived &>/dev/null; then
        systemctl stop keepalived 2>/dev/null || true
        systemctl disable keepalived 2>/dev/null || true
        apt-get remove -y -qq keepalived 2>/dev/null || dpkg -r keepalived 2>/dev/null || true
        rm -rf /etc/keepalived/ 2>/dev/null || true
        log_info "Keepalived 已卸载"
    else
        log_info "Keepalived 未安装，跳过"
    fi

    echo ""
    print_line
    log_info "步骤 3/4: 删除自签证书"
    print_line
    local cert_dir="/data/config/cert"
    if [[ -d "$cert_dir" ]]; then
        rm -rf "$cert_dir"
        log_info "证书已删除: ${cert_dir}"
    else
        log_info "无证书文件，跳过"
    fi

    echo ""
    print_line
    log_info "步骤 4/4: 卸载 Docker"
    print_line
    if command -v docker &>/dev/null; then
        bash "${SCRIPTS_DIR}/uninstall-docker.sh" --purge --clean-images --yes
    else
        log_info "Docker 未安装，跳过"
    fi

    echo ""
    print_line
    log_ok "全部卸载完成！"
    show_log_path
    pause_enter
}

# ============================ SIP 抓包工具 (sipmon) 子菜单 ============================
menu_sipmon() {
    while true; do
        print_header
        echo -e "  ${BOLD}SIP 抓包工具 (sipmon)${NC}"
        echo -e "  ${DIM}当前状态:$(check_sipmon)${NC}"
        echo -e "  ${DIM}SIP/RTP 信令与媒体质量监控, 静态二进制零依赖${NC}"
        print_line
        echo ""
        echo -e "  请选择操作:"
        echo ""
        echo -e "    ${CYAN}[1]${NC}  在线安装    ${DIM}(GitHub Releases 下载静态二进制)${NC}"
        echo -e "    ${CYAN}[2]${NC}  离线安装    ${DIM}(从 /data/images 安装本地二进制)${NC}"
        echo -e "    ${CYAN}[3]${NC}  卸载        ${DIM}(删除 /usr/local/bin/sipmon)${NC}"
        echo -e "    ${CYAN}[4]${NC}  查看状态    ${DIM}(显示版本与常用命令)${NC}"
        echo ""
        echo -e "    ${DIM}[0] 返回 / [ESC] 返回${NC}"
        echo ""

        read_choice "请输入序号: " ""
        choice="$REPLY"

        case "$choice" in
            1)
                echo ""
                if confirm "确认在线安装 sipmon？"; then
                    bash "${SCRIPTS_DIR}/install-sipmon.sh" --online
                    pause_enter
                fi
                return
                ;;
            2)
                echo ""
                if confirm "确认离线安装 sipmon？"; then
                    bash "${SCRIPTS_DIR}/install-sipmon.sh" --offline
                    pause_enter
                fi
                return
                ;;
            3)
                echo ""
                if confirm "确认卸载 sipmon？"; then
                    bash "${SCRIPTS_DIR}/install-sipmon.sh" --uninstall
                    pause_enter
                fi
                return
                ;;
            4)
                echo ""
                bash "${SCRIPTS_DIR}/install-sipmon.sh" --status
                pause_enter
                return
                ;;
            0) return ;;
            *) log_warn "无效输入"; sleep 1 ;;
        esac
    done
}

# ============================ SIP 抓包工具 (sngrep) 子菜单 ============================
menu_sngrep() {
    while true; do
        print_header
        echo -e "  ${BOLD}SIP 抓包工具 (sngrep)${NC}"
        echo -e "  ${DIM}当前状态:$(check_sngrep)${NC}"
        echo -e "  ${DIM}SIP 信令抓包分析 (ncurses TUI), Ubuntu 官方仓库安装${NC}"
        print_line
        echo ""
        echo -e "  请选择操作:"
        echo ""
        echo -e "    ${CYAN}[1]${NC}  在线安装    ${DIM}(apt 安装 sngrep)${NC}"
        echo -e "    ${CYAN}[2]${NC}  离线安装    ${DIM}(从本地 .deb 包安装)${NC}"
        echo -e "    ${CYAN}[3]${NC}  卸载        ${DIM}(apt remove sngrep)${NC}"
        echo -e "    ${CYAN}[4]${NC}  查看状态    ${DIM}(显示版本与常用命令)${NC}"
        echo ""
        echo -e "    ${DIM}[0] 返回 / [ESC] 返回${NC}"
        echo ""

        read_choice "请输入序号: " ""
        choice="$REPLY"

        case "$choice" in
            1)
                echo ""
                if confirm "确认在线安装 sngrep？"; then
                    bash "${SCRIPTS_DIR}/install-sngrep.sh" --online
                    pause_enter
                fi
                return
                ;;
            2)
                echo ""
                if confirm "确认离线安装 sngrep？"; then
                    bash "${SCRIPTS_DIR}/install-sngrep.sh" --offline
                    pause_enter
                fi
                return
                ;;
            3)
                echo ""
                if confirm "确认卸载 sngrep？"; then
                    bash "${SCRIPTS_DIR}/install-sngrep.sh" --uninstall
                    pause_enter
                fi
                return
                ;;
            4)
                echo ""
                bash "${SCRIPTS_DIR}/install-sngrep.sh" --status
                pause_enter
                return
                ;;
            0) return ;;
            *) log_warn "无效输入"; sleep 1 ;;
        esac
    done
}

# ============================ 离线包准备子菜单 ============================
menu_offline_prepare() {
    print_header
    echo -e "  ${BOLD}离线包准备${NC}"
    echo -e "  ${DIM}在有网络的机器上预下载离线部署所需的全部依赖${NC}"
    print_line
    echo ""
    echo -e "  将下载以下内容:"
    echo -e "    ${DIM}- Docker CE 全套 .deb 包 (含依赖)${NC}"
    echo -e "    ${DIM}- Keepalived .deb 包${NC}"
    echo -e "    ${DIM}- sngrep .deb 包 (含依赖)${NC}"
    echo -e "    ${DIM}- Docker 镜像 (docker save 导出)${NC}"
    echo -e "    ${DIM}- sipmon 抓包工具静态二进制${NC}"
    echo -e "    ${DIM}- daemon.json 模板${NC}"
    echo ""

    if confirm "确认开始准备离线包？"; then
        if [[ -f "${SCRIPTS_DIR}/prepare-offline.sh" ]]; then
            bash "${SCRIPTS_DIR}/prepare-offline.sh"
        else
            log_warn "prepare-offline.sh 尚未实现，请等待下一步开发"
        fi
    fi
    pause_enter
}

# ============================ 修改服务配置子菜单 ============================
menu_update_config() {
    local conf_file="${SCRIPT_DIR}/config/deploy.conf"

    print_header
    echo -e "  ${BOLD}修改服务配置${NC}"
    echo -e "  ${DIM}集中修改数据库 / Redis / FreeSwitch ESL 配置，自动同步到所有服务${NC}"
    print_line
    echo ""

    if [[ ! -f "$conf_file" ]]; then
        log_error "配置文件不存在: ${conf_file}"
        pause_enter
        return
    fi

    # 显示当前配置
    source "$conf_file"
    echo -e "  ${BOLD}当前配置值 (来源: config/deploy.conf):${NC}"
    print_line
    printf "    %-20s %s\n" "数据库地址" "$DB_HOST"
    printf "    %-20s %s\n" "数据库端口" "$DB_PORT"
    printf "    %-20s %s\n" "数据库用户" "$DB_USER"
    printf "    %-20s %s\n" "数据库密码" "********"
    printf "    %-20s %s\n" "数据库名称" "$DB_NAME"
    printf "    %-20s %s\n" "数据库引擎" "$DB_ENGINE"
    print_line
    printf "    %-20s %s\n" "Redis 地址" "$REDIS_HOST"
    printf "    %-20s %s\n" "Redis 端口" "$REDIS_PORT"
    printf "    %-20s %s\n" "Redis 密码" "********"
    print_line
    printf "    %-20s %s\n" "FS ESL 地址" "$FS_HOST"
    printf "    %-20s %s\n" "FS ESL 端口" "$FS_PORT"
    printf "    %-20s %s\n" "FS ESL 密码" "********"
    print_line
    printf "    %-20s %s\n" "VIP 地址" "${VIP:-未配置}"
    print_line
    echo ""

    echo -e "  请选择操作:"
    echo ""
    echo -e "    ${CYAN}[1]${NC}  编辑配置文件      ${DIM}(用 vi 打开 deploy.conf)${NC}"
    echo -e "    ${CYAN}[2]${NC}  应用配置到所有服务  ${DIM}(读取 deploy.conf 更新全部配置)${NC}"
    echo -e "    ${CYAN}[3]${NC}  查看当前配置      ${DIM}(显示 deploy.conf 内容)${NC}"
    echo ""
    echo -e "    ${DIM}[0] 返回 / [ESC] 返回${NC}"
    echo ""

    read_choice "请输入序号: " ""
    choice="$REPLY"

    case "$choice" in
        1)
            echo ""
            log_info "打开编辑器 (vi) ..."
            vi "$conf_file"
            return
            ;;
        2)
            echo ""
            if confirm "确认将 deploy.conf 的配置应用到所有服务？"; then
                bash "${SCRIPTS_DIR}/update-config.sh" --force
                pause_enter
            fi
            return
            ;;
        3)
            echo ""
            log_info "deploy.conf 内容:"
            cat "$conf_file" | sed 's/^/    /'
            pause_enter
            return
            ;;
        0) return ;;
        *) log_warn "无效输入"; sleep 1 ;;
    esac
}

# ============================ 入口 ============================
main() {
    # 解析 --remote 参数
    local remote_mode=false
    for arg in "$@"; do
        case "$arg" in
            --remote) remote_mode=true ;;
            -h|--help)
                grep '^#' "$0" | head -25
                exit 0
                ;;
        esac
    done

    # 远程模式: 推送脚本到目标服务器并执行
    if [[ "$remote_mode" == true ]]; then
        run_remote_deploy
        exit $?
    fi

    # 本地模式: root 检查
    if [[ $EUID -ne 0 ]]; then
        log_error "请以 root 用户运行: sudo ./deploy.sh"
        log_info "或使用远程模式: ./deploy.sh --remote"
        exit 1
    fi

    # 检查 scripts 目录
    if [[ ! -d "$SCRIPTS_DIR" ]]; then
        log_error "scripts 目录不存在: $SCRIPTS_DIR"
        exit 1
    fi

    # 初始化日志
    init_log "deploy"

    main_menu
}

main "$@"
