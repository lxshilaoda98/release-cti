# Release CTI 自动化部署工具

CTI（计算机电话集成）系统的自动化部署工具，支持 Docker + Keepalived 高可用架构，提供在线/离线双模式部署、自签证书管理、集中配置修改等功能。

## 目录结构

```
release-cti/
├── deploy.sh                         # 主入口 (交互式菜单)
├── .gitignore
├── config/
│   ├── deploy.conf                   # 集中配置文件 (数据库/Redis/ESL)
│   ├── remote.conf                   # 远程部署连接配置 (跳板机+目标机)
│   └── docker-compose.yml.template   # docker-compose 模板
└── scripts/
    ├── lib/
    │   └── common.sh                 # 共享库 (日志/备份/磁盘检查/健康检查/SSH)
    ├── install-docker.sh             # Docker CE 安装 (在线/离线)
    ├── uninstall-docker.sh           # Docker 卸载 (三级清理)
    ├── install-keepalived.sh         # Keepalived 安装 (标准/CTI 模式)
    ├── gen-cert.sh                   # 证书管理 (已有证书/自签IP证书)
    ├── deploy-compose.sh             # Compose 服务管理 (启停/镜像/配置)
    ├── update-config.sh              # 集中配置同步 (DB/Redis/ESL)
    └── prepare-offline.sh            # 离线包准备 (下载deb+导出镜像)
```

## 快速开始

### 本地部署（在目标服务器上执行）

```bash
cd /data
sudo ./deploy.sh
```

### 远程部署（通过跳板机）

```bash
# 1. 编辑远程连接配置
vi config/remote.conf

# 2. 一键远程部署
./deploy.sh --remote
```

`remote.conf` 配置示例：
```bash
# 跳板机
JUMP_HOST="121.199.31.43"
JUMP_PORT="22"
JUMP_USER="root"
JUMP_PASS="your_password"

# 目标服务器
TARGET_HOST="223.111.145.7"
TARGET_PORT="65022"
TARGET_USER="root"
TARGET_PASS="your_password"

# 远程部署目录
REMOTE_DIR="/data/deploy"
```

## 功能菜单

```
[1] Docker 安装          在线/离线安装 Docker CE + Compose
[2] Keepalived 安装       标准/CTI 模式 HA 配置
[3] 自签证书生成          使用已有证书 / 生成自签 IP 证书
[4] Docker Compose 部署   按顺序启动/停止/重启服务
[5] 修改服务配置          集中修改 DB/Redis/ESL 配置
[6] 一键全量部署          按顺序执行全部部署步骤
[7] 离线包准备            下载 deb 包 + 导出 Docker 镜像
[8] 卸载管理              分组件卸载 / 一键全部卸载
[0] 退出 / [ESC] 返回
```

## 部署流程

### 标准部署顺序

```
1. [1] Docker 安装          → 安装 Docker 环境
2. [2] Keepalived 安装       → 配置高可用 (可选)
3. [3] 自签证书生成          → 生成证书 + 更新 Caddyfile
4. [5] 修改服务配置          → 修改数据库/Redis/ESL 配置
5. [4] Docker Compose 部署
   ├── [10] 解压配置文件     → 解压 config.zip 到 /data/config
   ├── [8] 初始化模板        → 从模板生成 docker-compose.yml
   ├── [9] 拉取镜像          → 拉取所有 Docker 镜像
   └── [1] 部署/启动服务     → 按顺序启动容器
```

### 一键全量部署

选 [6] 自动执行上述全部步骤，选择在线或离线模式即可。

## 各模块说明

### Docker 安装 (`install-docker.sh`)

| 模式 | 说明 |
|------|------|
| 在线安装 | 华为云 apt 源 + 阿里云 Docker CE 源 |
| 离线安装 | 从本地 .deb 包安装 (默认 `/data/images`) |

- 自动配置 `daemon.json`（日志限制、data-root、镜像加速器）
- 镜像加速器：USTC + DaoCloud
- 支持 `--data-root` 自定义数据目录

### Keepalived 安装 (`install-keepalived.sh`)

| 模式 | 说明 |
|------|------|
| 标准模式 | 简单 VRRP + Docker 健康检查 |
| CTI 模式 | 完整 HA：nopreempt + notify 脚本 + 容器自动启停 |

- 自动检测网络接口和子网掩码
- CTI 模式生成 `notify.sh`：MASTER 切换时自动重启容器，BACKUP 时停止容器
- 支持 `--reconfig` 仅重新配置（跳过安装）
- 支持 `--status` 查看运行状态

### 证书管理 (`gen-cert.sh`)

| 模式 | 说明 |
|------|------|
| 使用已有证书 | 提供已有的 .crt/.pem 和 .key 文件 |
| 生成自签 IP 证书 | 输入 IP 地址，生成 10 年有效期证书 |

- 证书存放于 `/data/config/cert/`
- 自动生成 FreeSWITCH `wss.pem`（私钥 + 证书合并）
- 自动更新 Caddyfile：tls 路径、站点域名/IP、CORS 头

### 集中配置 (`deploy.conf` + `update-config.sh`)

修改 `config/deploy.conf` 一个文件，自动同步到所有服务配置：

```bash
# 数据库引擎: mssql / mysql / pgsql
DB_ENGINE="mssql"
DB_HOST="10.160.4.69"
DB_PORT="1433"
DB_USER="sa"
DB_PASSWORD="SA01234sa.."
DB_NAME="iCRM_VueCoreNew35"

# Redis
REDIS_HOST="127.0.0.1"
REDIS_PORT="6379"
REDIS_PASSWORD="1qaz@WSX.."

# FreeSWITCH ESL
FS_HOST="127.0.0.1"
FS_PORT="8021"
FS_PASSWORD="1qaz@WSX.."
```

**自动更新的配置文件：**

| 文件 | 更新内容 |
|------|---------|
| `netcore/Configurations/ConnectionStrings.json` | 数据库（两个连接配置） |
| `netcore/Configurations/Cache.json` | Redis |
| `cti/appsettings.json` | 数据库 + ESL |
| `autotask/appsettings.json` | 数据库 + ESL |
| `goapi/config.json` | 数据库 + ESL + Redis（按 JSON 区段精确修改） |
| `getcurl/config.yml` | 数据库 + ESL + Redis |
| `luahelper/config.yml` | 数据库 + ESL |
| `fs/.../event_socket.conf.xml` | ESL 端口 + 密码 |
| `docker-compose.yml` | Redis 密码 |

### Compose 服务管理 (`deploy-compose.sh`)

**启动顺序（按依赖关系）：**

```
[1] redis      → [2] getcurl → [3] fs → [4] cti → [5] cc_core → 其他服务
```

每个核心服务间隔 3 秒启动，其余服务最后一起启动。

**部署前自动检查：**
- 配置文件是否已解压
- docker-compose.yml 是否存在
- 服务配置是否已通过 deploy.conf 修改

### 离线包准备 (`prepare-offline.sh`)

在有网络的机器上一键下载：
- Docker CE 全套 .deb 包（含依赖）
- Keepalived .deb 包（含依赖）
- Docker 镜像（docker save 导出为 tar）
- daemon.json 模板

```bash
./scripts/prepare-offline.sh --output /data/offline-bundle
```

## 优化功能

| 功能 | 说明 |
|------|------|
| 远程推送执行 | `--remote` 模式通过跳板机自动推送脚本并执行 |
| 操作日志 | 所有操作记录到 `/data/logs/deploy/` |
| 部署前备份 | 修改前自动备份到 `/data/backup/` |
| 磁盘空间预检 | 安装前检查可用空间 |
| 容器健康检查 | 启动后轮询容器健康状态，异常打印日志 |
| ESC 快速返回 | 菜单中按 ESC + 回车返回上级 |

## 适用环境

- **操作系统**: Ubuntu 22.04 / 24.04 (x86_64)
- **网络**: 国内网络优化（华为云/阿里云镜像源）
- **部署模式**: 在线 / 离线
- **架构**: 单节点 / Keepalived 双节点 HA

## 服务列表

| 服务 | 容器名 | 镜像 | 说明 |
|------|--------|------|------|
| OpenSIPS | opensips | integine/opensips:3.6 | SIP 代理 |
| CTI | cti | integinenew/cti:latest | CTI 服务 |
| FreeSWITCH | fs | integine/fs:1.10.12 | 语音交换 |
| Redis | redis | redis:latest | 缓存 |
| Core | cc_core | integinenew/core:341 | 核心服务 |
| LuaHelper | luahelper | integine/luahelper | Lua 辅助 |
| GoAPI | goapi | integine/goapi | Go API |
| GetCurl | getcurl | integine/getcurl | 通话处理 |
| Caddy | caddy | integine/caddy:v2.11.3 | 反向代理 |
| AutoTask | autotask | dotnet/sdk:6.0 | 自动外呼 |
