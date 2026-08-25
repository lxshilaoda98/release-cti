#!/bin/bash
###############################################################################
# update-config.sh
# 读取 deploy.conf 集中配置，自动更新所有服务的配置文件
#
# 用法:
#   ./update-config.sh                    # 交互确认后更新
#   ./update-config.sh --force            # 跳过确认直接更新
#   ./update-config.sh --conf /path/to/deploy.conf  # 指定配置文件
#
###############################################################################
set -euo pipefail

# ============================ 加载共享库 ============================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

# ============================ 默认参数 ============================
CONF_FILE="${SCRIPT_DIR}/../config/deploy.conf"
CONFIG_DIR="/data/config"
FORCE=false
COMPOSE_FILE="/data/docker-compose.yml"

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --conf)   CONF_FILE="$2";   shift 2 ;;
            --force)  FORCE=true;        shift ;;
            --config-dir) CONFIG_DIR="$2"; shift 2 ;;
            -h|--help) grep '^#' "$0" | head -15; exit 0 ;;
            *) log_error "未知参数: $1"; exit 1 ;;
        esac
    done
}

# ============================ sed 转义 ============================
sed_escape() {
    printf '%s\n' "$1" | sed 's/[&/\|]/\\&/g'
}

# ============================ JSON 行替换 ============================
# 替换 "key": "value" 格式 (字符串值)
json_replace_str() {
    local file="$1" key="$2" val="$3"
    local escaped
    escaped=$(sed_escape "$val")
    sed -i "/^[[:space:]]*\/\//!s|\"${key}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"|\"${key}\": \"${escaped}\"|g" "$file"
}

# 替换 "key": number 格式 (数字值)
json_replace_num() {
    local file="$1" key="$2" val="$3"
    sed -i "/^[[:space:]]*\/\//!s|\"${key}\"[[:space:]]*:[[:space:]]*[0-9]*|\"${key}\": ${val}|g" "$file"
}

# 只在指定 JSON 区段内替换 "key": "value"
# 参数: file, section, key, value
json_replace_in_section() {
    local file="$1" section="$2" key="$3" val="$4"
    local escaped
    escaped=$(sed_escape "$val")
    sed -i "/\"${section}\"/,/^[[:space:]]*}[[:space:]]*\(,\|$\)/s|\"${key}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"|\"${key}\": \"${escaped}\"|" "$file"
}

# ============================ YAML 行替换 ============================
# 替换 key: value 或 key: "value" 格式
yaml_replace() {
    local file="$1" key="$2" val="$3"
    local escaped
    escaped=$(sed_escape "$val")
    sed -i "s|^${key}:[[:space:]]*.*|${key}: \"${escaped}\"|" "$file"
}

yaml_replace_raw() {
    local file="$1" key="$2" val="$3"
    sed -i "s|^${key}:[[:space:]]*.*|${key}: ${val}|" "$file"
}

# ============================ 加载配置 ============================
load_config() {
    log_step "加载集中配置"

    if [[ ! -f "$CONF_FILE" ]]; then
        log_error "配置文件不存在: ${CONF_FILE}"
        exit 1
    fi

    source "$CONF_FILE"

    echo ""
    echo -e "  ${BOLD}当前配置值:${NC}"
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
    printf "    %-20s %s\n" "VIP 地址" "${VIP:-未配置 (跳过 FreeSWITCH VIP 修改)}"
    print_line
    echo ""
}

# ============================ 引擎映射 ============================
# .NET DBType 映射
get_dotnet_dbtype() {
    case "$DB_ENGINE" in
        mssql)  echo "SqlServer" ;;
        mysql)  echo "MySql" ;;
        pgsql)  echo "PostgreSQL" ;;
        *)      echo "SqlServer" ;;
    esac
}

# Go ORM driver 映射
get_go_driver() {
    case "$DB_ENGINE" in
        mssql)  echo "mssql" ;;
        mysql)  echo "mysql" ;;
        pgsql)  echo "pgsql" ;;
        *)      echo "mssql" ;;
    esac
}

# ============================ 构建 ConnectionString ============================
# .NET 服务用的连接字符串 (cti, autotask)
build_connstr() {
    case "$DB_ENGINE" in
        mssql)
            echo "Data Source=${DB_HOST},${DB_PORT};Initial Catalog=${DB_NAME};User ID=${DB_USER};Password=${DB_PASSWORD};MultipleActiveResultSets=true;Encrypt=True;TrustServerCertificate=True;"
            ;;
        mysql)
            echo "Server=${DB_HOST};Port=${DB_PORT};UID=${DB_USER};PWD=${DB_PASSWORD};database=${DB_NAME};"
            ;;
        pgsql)
            echo "Server=${DB_HOST};Port=${DB_PORT};UID=${DB_USER};PWD=${DB_PASSWORD};database=${DB_NAME};"
            ;;
        *)
            echo "Data Source=${DB_HOST},${DB_PORT};Initial Catalog=${DB_NAME};User ID=${DB_USER};Password=${DB_PASSWORD};MultipleActiveResultSets=true;Encrypt=True;TrustServerCertificate=True;"
            ;;
    esac
}

# Go 服务用的 DataBase 连接串 (goapi AppConfig.DataBase)
build_go_dbstr() {
    case "$DB_ENGINE" in
        mssql)
            echo "${DB_USER}:${DB_PASSWORD}@tcp(${DB_HOST}:${DB_PORT})/${DB_NAME}?parseTime=true"
            ;;
        mysql)
            echo "${DB_USER}:${DB_PASSWORD}@tcp(${DB_HOST}:${DB_PORT})/${DB_NAME}?parseTime=true"
            ;;
        pgsql)
            echo "host=${DB_HOST} port=${DB_PORT} user=${DB_USER} password=${DB_PASSWORD} dbname=${DB_NAME} sslmode=disable"
            ;;
        *)
            echo "${DB_USER}:${DB_PASSWORD}@tcp(${DB_HOST}:${DB_PORT})/${DB_NAME}?parseTime=true"
            ;;
    esac
}

# getcurl/luahelper 用的 dbcms.connstr
build_cms_connstr() {
    case "$DB_ENGINE" in
        mssql)
            echo "server=${DB_HOST};port=${DB_PORT};database=${DB_NAME};user id=${DB_USER};password=${DB_PASSWORD};encrypt=disable"
            ;;
        mysql)
            echo "${DB_USER}:${DB_PASSWORD}@tcp(${DB_HOST}:${DB_PORT})/${DB_NAME}?charset=utf8mb4&parseTime=true"
            ;;
        pgsql)
            echo "host=${DB_HOST} port=${DB_PORT} user=${DB_USER} password=${DB_PASSWORD} dbname=${DB_NAME} sslmode=disable"
            ;;
        *)
            echo "server=${DB_HOST};port=${DB_PORT};database=${DB_NAME};user id=${DB_USER};password=${DB_PASSWORD};encrypt=disable"
            ;;
    esac
}

# netcore 用的 DefaultConnection (带 {0} 占位符)
build_netcore_connstr() {
    case "$DB_ENGINE" in
        mssql)
            echo "Data Source=${DB_HOST},${DB_PORT};Initial Catalog={0};User ID=${DB_USER};Password=${DB_PASSWORD};MultipleActiveResultSets=true;Encrypt=True;TrustServerCertificate=True;"
            ;;
        mysql)
            echo "server=${DB_HOST};Database={0};Uid=${DB_USER};Pwd=${DB_PASSWORD};AllowLoadLocalInfile=true"
            ;;
        pgsql)
            echo "PORT=${DB_PORT};DATABASE={0};HOST=${DB_HOST};PASSWORD=${DB_PASSWORD};USER ID=${DB_USER}"
            ;;
        *)
            echo "Data Source=${DB_HOST},${DB_PORT};Initial Catalog={0};User ID=${DB_USER};Password=${DB_PASSWORD};MultipleActiveResultSets=true;Encrypt=True;TrustServerCertificate=True;"
            ;;
    esac
}

# ============================ 更新 netcore/Configurations ============================
update_netcore() {
    local cs_file="${CONFIG_DIR}/netcore/Configurations/ConnectionStrings.json"
    local cache_file="${CONFIG_DIR}/netcore/Configurations/Cache.json"

    # --- ConnectionStrings.json ---
    if [[ ! -f "$cs_file" ]]; then
        log_warn "跳过: $cs_file 不存在"
    else
        log_info "更新 netcore/Configurations/ConnectionStrings.json ..."
        backup_file "$cs_file"

        local dotnet_type go_driver
        dotnet_type=$(get_dotnet_dbtype)
        local nc_connstr
        nc_connstr=$(build_netcore_connstr)

        # 有两个连接配置 (default + ICRM-Job), sed -g 会同时替换
        json_replace_str "$cs_file" "DBType" "$dotnet_type"
        json_replace_str "$cs_file" "DBName" "$DB_NAME"
        json_replace_str "$cs_file" "Host" "$DB_HOST"
        json_replace_str "$cs_file" "Port" "$DB_PORT"
        json_replace_str "$cs_file" "UserName" "$DB_USER"
        json_replace_str "$cs_file" "Password" "$DB_PASSWORD"
        json_replace_str "$cs_file" "DefaultConnection" "$nc_connstr"

        log_ok "netcore/ConnectionStrings.json 已更新"
    fi

    # --- Cache.json (Redis) ---
    if [[ ! -f "$cache_file" ]]; then
        log_warn "跳过: $cache_file 不存在"
    else
        log_info "更新 netcore/Configurations/Cache.json ..."
        backup_file "$cache_file"

        json_replace_str "$cache_file" "ip" "$REDIS_HOST"
        json_replace_num "$cache_file" "port" "$REDIS_PORT"
        json_replace_str "$cache_file" "password" "$REDIS_PASSWORD"

        log_ok "netcore/Cache.json 已更新"
    fi
}

# ============================ 更新 cti/appsettings.json ============================
update_cti() {
    local file="${CONFIG_DIR}/cti/appsettings.json"
    [[ ! -f "$file" ]] && { log_warn "跳过: $file 不存在"; return 0; }

    log_info "更新 cti/appsettings.json ..."
    backup_file "$file"

    local connstr
    connstr=$(build_connstr)
    local dotnet_type
    dotnet_type=$(get_dotnet_dbtype)

    json_replace_str "$file" "ConnectionString" "$connstr"
    json_replace_str "$file" "DBType" "$dotnet_type"
    json_replace_str "$file" "FreeSwitch_Ip" "$FS_HOST"
    json_replace_num "$file" "FreeSwitch_Port" "$FS_PORT"
    json_replace_str "$file" "FreeSwitch_User" "$FS_PASSWORD"
    json_replace_str "$file" "FreeSwitch_Domain" "$FS_HOST"
    json_replace_str "$file" "RecordServerIP" "$FS_HOST"

    log_ok "cti/appsettings.json 已更新"
}

# ============================ 更新 autotask/appsettings.json ============================
update_autotask() {
    local file="${CONFIG_DIR}/autotask/appsettings.json"
    [[ ! -f "$file" ]] && { log_warn "跳过: $file 不存在"; return 0; }

    log_info "更新 autotask/appsettings.json ..."
    backup_file "$file"

    local connstr
    connstr=$(build_connstr)
    local dotnet_type
    dotnet_type=$(get_dotnet_dbtype)

    json_replace_str "$file" "DBType" "$dotnet_type"
    json_replace_str "$file" "DataSource" "$DB_HOST"
    json_replace_num "$file" "MySqlPort" "$DB_PORT"
    json_replace_str "$file" "DBUserID" "$DB_USER"
    json_replace_str "$file" "DBPassword" "$DB_PASSWORD"
    json_replace_str "$file" "Database" "$DB_NAME"
    json_replace_str "$file" "ConnectionString" "$connstr"
    json_replace_str "$file" "FreeSwitch_Ip" "$FS_HOST"
    json_replace_num "$file" "FreeSwitch_Port" "$FS_PORT"
    json_replace_str "$file" "FreeSwitch_User" "$FS_PASSWORD"
    json_replace_str "$file" "FreeSwitch_Domain" "$FS_HOST"

    log_ok "autotask/appsettings.json 已更新"
}

# ============================ 更新 goapi/config.json ============================
update_goapi() {
    local file="${CONFIG_DIR}/goapi/config.json"
    [[ ! -f "$file" ]] && { log_warn "跳过: $file 不存在"; return 0; }

    log_info "更新 goapi/config.json ..."
    backup_file "$file"

    local go_driver go_db
    go_driver=$(get_go_driver)
    go_db=$(build_go_dbstr)

    # EslConfig 区段: fshost, fsport, password (FS 密码)
    json_replace_in_section "$file" "EslConfig" "fshost" "$FS_HOST"
    json_replace_in_section "$file" "EslConfig" "fsport" "$FS_PORT"
    json_replace_in_section "$file" "EslConfig" "password" "$FS_PASSWORD"

    # orm 区段: driver, path, port, db-name, username, password (DB 密码)
    json_replace_in_section "$file" "orm" "driver" "$go_driver"
    json_replace_in_section "$file" "orm" "path" "$DB_HOST"
    json_replace_in_section "$file" "orm" "port" "$DB_PORT"
    json_replace_in_section "$file" "orm" "db-name" "$DB_NAME"
    json_replace_in_section "$file" "orm" "username" "$DB_USER"
    json_replace_in_section "$file" "orm" "password" "$DB_PASSWORD"

    # AppConfig 区段: 只改 DataBase, 不动 port
    json_replace_in_section "$file" "AppConfig" "DataBase" "$go_db"

    # redis 区段
    json_replace_in_section "$file" "redis" "redishost" "$REDIS_HOST"
    json_replace_in_section "$file" "redis" "redisport" "$REDIS_PORT"
    json_replace_in_section "$file" "redis" "redispw" "$REDIS_PASSWORD"

    log_ok "goapi/config.json 已更新"
}

# ============================ 更新 getcurl/config.yml ============================
update_getcurl() {
    local file="${CONFIG_DIR}/getcurl/config.yml"
    [[ ! -f "$file" ]] && { log_warn "跳过: $file 不存在"; return 0; }

    log_info "更新 getcurl/config.yml ..."
    backup_file "$file"

    # 数据库 (ormcore)
    local go_driver
    go_driver=$(get_go_driver)
    yaml_replace_raw "$file" "  driver" "$go_driver"
    yaml_replace_raw "$file" "  path" "$DB_HOST"
    yaml_replace "$file" "  port" "$DB_PORT"
    yaml_replace "$file" "  db-name" "$DB_NAME"
    yaml_replace "$file" "  username" "$DB_USER"
    yaml_replace "$file" "  password" "$DB_PASSWORD"

    # dbcms
    yaml_replace_raw "$file" "  name" "$go_driver"
    local cms_connstr
    cms_connstr=$(build_cms_connstr)
    sed -i "s|^  connstr:[[:space:]]*.*|  connstr: \"${cms_connstr}\"|" "$file"

    # FreeSWITCH ESL (fsstr)
    yaml_replace "$file" "  fshost" "$FS_HOST"
    yaml_replace_raw "$file" "  fsport" "$FS_PORT"
    yaml_replace "$file" "  fspw" "$FS_PASSWORD"

    # Redis
    yaml_replace "$file" "  redishost" "$REDIS_HOST"
    yaml_replace "$file" "  redisport" "$REDIS_PORT"
    yaml_replace "$file" "  redispw" "$REDIS_PASSWORD"

    log_ok "getcurl/config.yml 已更新"
}

# ============================ 更新 luahelper/config.yml ============================
update_luahelper() {
    local file="${CONFIG_DIR}/luahelper/config.yml"
    [[ ! -f "$file" ]] && { log_warn "跳过: $file 不存在"; return 0; }

    log_info "更新 luahelper/config.yml ..."
    backup_file "$file"

    # ormfs + ormcms (使用相同的缩进, sed 会同时替换两处)
    local go_driver
    go_driver=$(get_go_driver)
    yaml_replace_raw "$file" "  driver" "$go_driver"
    yaml_replace_raw "$file" "  path" "$DB_HOST"
    yaml_replace "$file" "  port" "$DB_PORT"
    yaml_replace "$file" "  db-name" "$DB_NAME"
    yaml_replace "$file" "  username" "$DB_USER"
    yaml_replace "$file" "  password" "$DB_PASSWORD"

    # FreeSwitch ESL (fsstr)
    yaml_replace "$file" "  fshost" "$FS_HOST"
    yaml_replace_raw "$file" "  fsport" "$FS_PORT"
    yaml_replace "$file" "  fspw" "$FS_PASSWORD"

    log_ok "luahelper/config.yml 已更新"
}

# ============================ 更新 FreeSWITCH event_socket ============================
update_fs_esl() {
    local file="${CONFIG_DIR}/fs/conf/autoload_configs/event_socket.conf.xml"
    [[ ! -f "$file" ]] && { log_warn "跳过: $file 不存在"; return 0; }

    log_info "更新 fs event_socket.conf.xml ..."
    backup_file "$file"

    sed -i "s|<param name=\"listen-port\" value=\"[^\"]*\"|<param name=\"listen-port\" value=\"${FS_PORT}\"|" "$file"
    sed -i "s|<param name=\"password\" value=\"[^\"]*\"|<param name=\"password\" value=\"${FS_PASSWORD}\"|" "$file"

    log_ok "fs event_socket.conf.xml 已更新"
}

# ============================ 更新 FreeSWITCH VIP 绑定 ============================
# VIP 非空时, 将 FS 的 domain / rtp-ip / sip-ip 绑定到 VIP 地址 (Keepalived 高可用场景)
update_fs_vip() {
    local vip="${VIP:-}"

    if [[ -z "$vip" ]]; then
        log_info "VIP 未配置，跳过 FreeSWITCH VIP 绑定修改"
        return 0
    fi

    # IPv4 格式校验
    if ! [[ "$vip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        log_error "VIP 格式不正确: ${vip} (应为 IPv4 地址，如 10.160.4.88)"
        exit 1
    fi

    log_step "更新 FreeSWITCH VIP 绑定 (${vip})"

    # --- vars.xml: domain / domain_name ---
    local vars_file="${CONFIG_DIR}/fs/conf/vars.xml"
    if [[ ! -f "$vars_file" ]]; then
        log_warn "跳过: $vars_file 不存在"
    else
        log_info "更新 fs/conf/vars.xml (domain, domain_name) ..."
        backup_file "$vars_file"

        # 注意: data="domain= 不会误匹配 data="domain_name= (domain 后是 _ 不是 =)
        sed -i "s|data=\"domain=[^\"]*\"|data=\"domain=${vip}\"|g" "$vars_file"
        sed -i "s|data=\"domain_name=[^\"]*\"|data=\"domain_name=${vip}\"|g" "$vars_file"

        log_ok "fs/conf/vars.xml 已更新"
    fi

    # --- sip_profiles: external.xml / internal.xml ---
    local profile
    for profile in external internal; do
        local file="${CONFIG_DIR}/fs/conf/sip_profiles/${profile}.xml"
        if [[ ! -f "$file" ]]; then
            log_warn "跳过: $file 不存在"
            continue
        fi

        log_info "更新 fs/conf/sip_profiles/${profile}.xml (rtp-ip, sip-ip, ext-rtp-ip, ext-sip-ip) ..."
        backup_file "$file"

        sed -i "s|<param name=\"rtp-ip\" value=\"[^\"]*\"/>|<param name=\"rtp-ip\" value=\"${vip}\"/>|g" "$file"
        sed -i "s|<param name=\"sip-ip\" value=\"[^\"]*\"/>|<param name=\"sip-ip\" value=\"${vip}\"/>|g" "$file"
        sed -i "s|<param name=\"ext-rtp-ip\" value=\"[^\"]*\"/>|<param name=\"ext-rtp-ip\" value=\"${vip}\"/>|g" "$file"
        sed -i "s|<param name=\"ext-sip-ip\" value=\"[^\"]*\"/>|<param name=\"ext-sip-ip\" value=\"${vip}\"/>|g" "$file"

        log_ok "fs/conf/sip_profiles/${profile}.xml 已更新"
    done
}

# ============================ 更新 Caddyfile ============================
update_caddyfile() {
    local caddyfile="${CONFIG_DIR}/caddy/Caddyfile"
    [[ ! -f "$caddyfile" ]] && { log_warn "跳过: $caddyfile 不存在"; return 0; }

    # 有证书时跳过 (由 gen-cert.sh 维护 HTTPS 配置)
    local cert_dir="/data/config/cert"
    if ls "$cert_dir"/*.crt &>/dev/null 2>&1; then
        log_info "检测到证书已存在，跳过 Caddyfile (由证书管理维护 HTTPS)"
        return 0
    fi

    log_info "更新 Caddyfile 为 HTTP 模式 (无证书) ..."
    backup_file "$caddyfile"

    # 1. 注释掉所有未注释的 tls 行
    sed -i "/^[[:space:]]*tls /s/^/# /" "$caddyfile"

    # 2. https:// → http:// (CORS 头等)
    sed -i "s|https://|http://|g" "$caddyfile"

    # 3. 给没有 http:// 前缀的站点地址加 http://
    #    匹配: 行首(字母/数字) + hostname:port + {  (排除 reverse_proxy 等缩进行的干扰)
    sed -i "/^[a-zA-Z0-9].*:[0-9]\+.*[[:space:]]*{$/{
        /http:\/\//!s/^/http:\/\//
    }" "$caddyfile"

    log_ok "Caddyfile 已更新为 HTTP 模式"
}

# ============================ 更新 docker-compose.yml Redis 密码 ============================
update_compose_redis() {
    [[ ! -f "$COMPOSE_FILE" ]] && { log_warn "跳过: $COMPOSE_FILE 不存在"; return 0; }

    log_info "更新 docker-compose.yml Redis 密码 ..."
    backup_file "$COMPOSE_FILE"

    sed -i "s|redis-server --requirepass [^\"]*|redis-server --requirepass ${REDIS_PASSWORD}|" "$COMPOSE_FILE"

    log_ok "docker-compose.yml Redis 密码已更新"
}

# ============================ 主流程 ============================
main() {
    parse_args "$@"
    init_log "update-config"
    load_config

    if [[ "$FORCE" != true ]]; then
        if ! confirm "确认以上配置将更新到所有服务配置文件？"; then
            log_info "已取消"
            exit 0
        fi
    fi

    log_step "开始更新配置文件"

    update_netcore
    update_cti
    update_autotask
    update_goapi
    update_getcurl
    update_luahelper
    update_fs_esl
    update_fs_vip
    update_caddyfile
    update_compose_redis

    # 标记配置已应用 (deploy-compose.sh 前置检查依据)
    touch "${CONFIG_DIR}/.deploy-conf-applied" 2>/dev/null || true

    log_step "配置更新完成"
    echo ""
    log_info "已更新的文件:"
    echo "    netcore/Configurations/ConnectionStrings.json  (数据库)"
    echo "    netcore/Configurations/Cache.json              (Redis)"
    echo "    cti/appsettings.json           (数据库 + ESL)"
    echo "    autotask/appsettings.json       (数据库 + ESL)"
    echo "    goapi/config.json               (数据库 + ESL + Redis)"
    echo "    getcurl/config.yml              (数据库 + ESL + Redis)"
    echo "    luahelper/config.yml            (数据库 + ESL)"
    echo "    fs/.../event_socket.conf.xml     (ESL 端口 + 密码)"
    echo "    fs/conf/vars.xml + sip_profiles  (VIP 绑定, VIP 非空时)"
    echo "    caddy/Caddyfile                 (HTTP 模式, 有证书时跳过)"
    echo "    docker-compose.yml              (Redis 密码)"
    echo ""
    log_info "原文件已备份到 ${BACKUP_BASE}/"
    show_log_path
}

main "$@"
